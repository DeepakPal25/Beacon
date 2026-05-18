import Beacon
import Foundation

/// A provider that records what it receives, for asserting analytics in tests.
///
/// ```swift
/// let provider = RecordingProvider()
/// let analytics = AnalyticsClient(providers: [provider], store: InMemoryEventStore(), ...)
/// analytics.track("signup")
/// await analytics.flush()
/// #expect(await provider.eventNames == ["signup"])
/// ```
public actor RecordingProvider: AnalyticsProvider {
    public nonisolated let id: String
    public nonisolated let consentCategory: ConsentCategory
    public nonisolated let maxBatchSize: Int

    public private(set) var batches: [[AnalyticsEvent]] = []
    public private(set) var sendAttempts = 0
    public private(set) var identifiedUserIDs: [String] = []
    public private(set) var resetCount = 0

    private var failuresRemaining = 0
    private var rejectionsRemaining = 0

    public init(id: String = "recording", consentCategory: ConsentCategory = .analytics, maxBatchSize: Int = 100) {
        self.id = id
        self.consentCategory = consentCategory
        self.maxBatchSize = maxBatchSize
    }

    public var events: [AnalyticsEvent] { batches.flatMap { $0 } }
    public var eventNames: [String] { events.map(\.name) }

    /// The next `count` sends throw a retryable network error.
    public func fail(times count: Int) {
        failuresRemaining = count
    }

    /// The next `count` sends throw ``BatchRejectedError``.
    public func reject(times count: Int) {
        rejectionsRemaining = count
    }

    public func send(_ events: [AnalyticsEvent]) async throws {
        sendAttempts += 1
        if rejectionsRemaining > 0 {
            rejectionsRemaining -= 1
            throw BatchRejectedError(reason: "Rejected by RecordingProvider")
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw URLError(.notConnectedToInternet)
        }
        batches.append(events)
    }

    public func identify(userID: String, traits: [String: AnalyticsValue]) async {
        identifiedUserIDs.append(userID)
    }

    public func reset() async {
        resetCount += 1
    }
}

/// A clock you can move forward by hand, for testing retries and expiry.
public final class TestClock: @unchecked Sendable {
    // Guarded by `lock`.
    private var current: Date
    private let lock = NSLock()

    public init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.current = start
    }

    public var now: Date {
        lock.withLock { current }
    }

    public func advance(by interval: TimeInterval) {
        lock.withLock { current.addTimeInterval(interval) }
    }
}
