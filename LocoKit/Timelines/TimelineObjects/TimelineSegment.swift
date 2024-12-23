//
//  TimelineSegment.swift
//  LocoKit
//
//  Created by Matt Greenfield on 29/04/18.
//

import Foundation
import Combine
import GRDB

public extension NSNotification.Name {
    static let timelineSegmentUpdated = Notification.Name("timelineSegmentUpdated")
}

public final class TimelineSegment: TransactionObserver, Encodable, Hashable, ObservableObject {

    // MARK: -

    public var debugLogging = false
    public var shouldReprocessOnUpdate = false
    public var shouldUpdateMarkovValues = true
    public var shouldReclassifySamples = true

    // MARK: -

    public let store: TimelineStore
    public var onUpdate: (() -> Void)?

    // MARK: -

    private var _timelineItems: [TimelineItem]?
    public var timelineItems: [TimelineItem] {
        if pendingChanges || _timelineItems == nil {
            _timelineItems = store.items(for: query, arguments: arguments)
            pendingChanges = false
        }
        return _timelineItems ?? []
    }

    private let query: String
    private let arguments: StatementArguments
    public var dateRange: DateInterval?

    // MARK: -

    private var debouncer = Debouncer()
    private var lastSaveDate: Date?
    private var lastItemCount: Int?
    private var pendingChanges = false {
        willSet(haveChanges) { if haveChanges { onMain { self.objectWillChange.send() } } }
    }
    private var updatingEnabled = true

    // MARK: -

    public init(where query: String, arguments: StatementArguments? = nil, in store: TimelineStore,
                onUpdate: (() -> Void)? = nil) {
        self.store = store
        self.query = "SELECT * FROM TimelineItem WHERE " + query
        self.arguments = arguments ?? StatementArguments()
        self.onUpdate = onUpdate
        store.pool?.add(transactionObserver: self)
    }

    public func startUpdating() {
        if updatingEnabled { return }
        updatingEnabled = true
        needsUpdate()
    }

    public func stopUpdating() {
        if !updatingEnabled { return }
        updatingEnabled = false
        _timelineItems = nil
    }

    // MARK: - Result updating

    private func needsUpdate() {
        guard self.updatingEnabled else { return }
        self.debouncer.debounce(duration: 1) {
            await self.update()
        }
    }

    @TimelineActor
    private func update() async {
        guard updatingEnabled else { return }
        guard store.pool != nil else { return }
        guard hasChanged else { return }

        if shouldReprocessOnUpdate {
            timelineItems.forEach {
                TimelineProcessor.healEdges(of: $0)
            }
        }

        reclassifySamples()

        if shouldReprocessOnUpdate {
            process()
        }

        onUpdate?()

        NotificationCenter.default.post(Notification(name: .timelineSegmentUpdated, object: self))
    }

    private var hasChanged: Bool {
        let items = timelineItems 

        let freshLastSaveDate = items.compactMap { $0.lastSaved }.max()
        let freshItemCount = items.count

        defer {
            lastSaveDate = freshLastSaveDate
            lastItemCount = freshItemCount
        }

        if freshItemCount != lastItemCount { return true }
        if freshLastSaveDate != lastSaveDate { return true }
        return false
    }

    // Note: this expects samples to be in date ascending order
    private func reclassifySamples() {
        guard shouldReclassifySamples else { return }
        
        guard let classifier = store.recorder?.classifier else { return }

        store.connectToDatabase()

        for item in timelineItems {
            var count = 0

            for sample in item.samples where sample.confirmedType == nil {
                
                // only samples with no cached classified type
                guard sample._classifiedType == nil else { continue }

                let oldClassifiedType = sample._classifiedType
                sample._classifiedType = nil
                sample.classifierResults = classifier.classify(sample)
                if sample.classifiedType != oldClassifiedType {
                    count += 1
                }
            }

            // item needs rebuild?
            if count > 0 { item.sampleTypesChanged() }

            if debugLogging && count > 0 {
                logger.debug("Reclassified samples: \(count)")
            }
        }
    }

    private func process() {

        // shouldn't do processing if currentItem is in the segment and isn't a keeper
        // (the TimelineRecorder should be the sole authority on processing those cases)
        for item in timelineItems { if item.isCurrentItem && !item.isWorthKeeping { return } }

        TimelineProcessor.process(timelineItems)
    }

    // MARK: - TransactionObserver

    public func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        guard updatingEnabled else { return false }
        return eventKind.tableName == "TimelineItem"
    }

    public func databaseDidChange(with event: DatabaseEvent) {
        pendingChanges = true

        // it is pointless to keep on tracking further changes
        stopObservingDatabaseChangesUntilNextTransaction()
    }

    public func databaseDidCommit(_ db: Database) {
        guard pendingChanges else { return }
        onMain { [weak self] in
            self?.needsUpdate()
        }
    }

    public func databaseDidRollback(_ db: Database) {
        pendingChanges = false
    }

    // MARK: - Export helpers

    public var filename: String? {
        if dateRange == nil, timelineItems.count == 1 {
            return singleItemFilename
        }

        guard let dateRange = dateRange else { return nil }

        if (dateRange.start + 1).isSameDayAs(dateRange.end - 1) {
            return dayFilename
        }

        if (dateRange.start + 1).isSameMonthAs(dateRange.end - 1) {
            return monthFilename
        }

        return yearFilename
    }

    public var singleItemFilename: String? {
        guard let firstRange = timelineItems.first?.dateRange else { return nil }
        guard timelineItems.count == 1 else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: firstRange.start)
    }

    public var dayFilename: String? {
        guard let dateRange = dateRange else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: dateRange.middle)
    }

    public var weekFilename: String? {
        guard let dateRange else { return nil }
        let formatter: ISO8601DateFormatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withWeekOfYear, .withDashSeparatorInDate]
        return formatter.string(from: dateRange.middle)
    }

    public var monthFilename: String? {
        guard let dateRange = dateRange else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: dateRange.middle)
    }

    public var yearFilename: String? {
        guard let dateRange = dateRange else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: dateRange.middle)
    }

    // MARK: - ObservableObject

    public let objectWillChange = ObservableObjectPublisher()

    // MARK: - Encodable

    enum CodingKeys: String, CodingKey {
        case timelineItems
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timelineItems, forKey: .timelineItems)
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(query)
        hasher.combine(arguments.description)
    }

    // MARK: - Equatable

    public static func == (lhs: TimelineSegment, rhs: TimelineSegment) -> Bool {
        return lhs.query == rhs.query && lhs.arguments == rhs.arguments
    }

}