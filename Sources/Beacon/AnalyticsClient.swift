import Foundation

/// One analytics API that fans events out to every provider, with batching,
/// offline persistence, retries and a consent gate.
///
/// ```swift
/// let analytics = AnalyticsClient(
///     providers: [FirebaseProvider(), MixpanelProvider(), HTTPBatchProvider(endpoint: collectorURL)],
///     processors: [PIIRedactor(), PropertyEnricher(static: ["app_version": "3.2.0"])]
/// )
///
/// analytics.setConsent(granted: [.analytics])
/// analytics.track("onboarding_completed", properties: ["step_count": 4])
/// ```
///
/// `track` is synchronous and non-blocking, so it's safe to call from any
/// thread or actor. Events are processed strictly in the order they were tracked.
public final class AnalyticsClient: Sendable {
    public struct Configuration: Sendable {
        /// How often queued events are sent. `nil` sends only on batch size or `flush()`.
        public var flushInterval: Duration?
        /// Per-provider queue cap. The oldest events are dropped beyond it.
        public var maxQueueSize: Int
        /// Events older than this are dropped instead of sent.
        public var maxEventAge: TimeInterval
        /// Events kept in memory while consent is undecided.
        public var undecidedBufferLimit: Int
        /// Inactivity after which a new session ID is issued.
        public var sessionTimeout: TimeInterval
        /// First retry delay after a failed send; doubles per consecutive failure.
        public var retryBaseDelay: TimeInterval
        public var maxRetryDelay: TimeInterval
        /// Used when no consent decision has been stored yet.
        public var defaultConsent: ConsentState
        /// Injected for tests.
        public var now: @Sendable () -> Date

        public init(
            flushInterval: Duration? = .seconds(30),
            maxQueueSize: Int = 1_000,
            maxEventAge: TimeInterval = 7 * 24 * 60 * 60,
            undecidedBufferLimit: Int = 500,
            sessionTimeout: TimeInterval = 30 * 60,
            retryBaseDelay: TimeInterval = 5,
            maxRetryDelay: TimeInterval = 10 * 60,
            defaultConsent: ConsentState = .undecided,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.flushInterval = flushInterval
            self.maxQueueSize = maxQueueSize
            self.maxEventAge = maxEventAge
            self.undecidedBufferLimit = undecidedBufferLimit
            self.sessionTimeout = sessionTimeout
            self.retryBaseDelay = retryBaseDelay
            self.maxRetryDelay = maxRetryDelay
            self.defaultConsent = defaultConsent
            self.now = now
        }
    }

    private let pipeline: Pipeline
    private let commands: AsyncStream<Command>.Continuation
    private let consumer: Task<Void, Never>
    private let timer: Task<Void, Never>?

    public init(
        providers: [any AnalyticsProvider],
        processors: [any EventProcessor] = [],
        store: any EventStore = FileEventStore(),
        consentStorage: any ConsentStorage = UserDefaultsConsentStorage(),
        configuration: Configuration = Configuration()
    ) {
        let pipeline = Pipeline(
            providers: providers,
            processors: processors,
            store: store,
            consentStorage: consentStorage,
            configuration: configuration
        )
        let (stream, commands) = AsyncStream<Command>.makeStream()

        self.pipeline = pipeline
        self.commands = commands
        self.consumer = Task {
            for await command in stream {
                await pipeline.handle(command)
            }
        }
        if let interval = configuration.flushInterval {
            self.timer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    commands.yield(.flush(nil))
                }
            }
        } else {
            self.timer = nil
        }
    }

    deinit {
        timer?.cancel()
        commands.finish()
    }

    // MARK: Tracking

    public func track(_ event: AnalyticsEvent) {
        commands.yield(.track(event))
    }

    public func track(
        _ name: String,
        properties: [String: AnalyticsValue] = [:],
        category: ConsentCategory = .analytics
    ) {
        track(AnalyticsEvent(name, properties: properties, category: category))
    }

    /// Associates subsequent events with a user.
    public func identify(userID: String, traits: [String: AnalyticsValue] = [:]) {
        commands.yield(.identify(userID: userID, traits: traits))
    }

    /// Call on sign-out: clears the user ID, starts a new session, and resets every provider.
    public func reset() {
        commands.yield(.reset)
    }

    // MARK: Consent

    /// Records the user's decision. Queued events in withdrawn categories are deleted.
    public func setConsent(granted: Set<ConsentCategory>) {
        commands.yield(.consent(.decided(granted: granted)))
    }

    public var consent: ConsentState {
        get async { await pipeline.consent }
    }

    // MARK: Delivery

    /// Sends everything queued, e.g. when the app moves to the background.
    public func flush() async {
        await perform { .flush($0) }
    }

    /// Waits until every event tracked so far has been processed (not necessarily sent).
    public func waitUntilIdle() async {
        await perform { .sync($0) }
    }

    private func perform(_ makeCommand: (CheckedContinuation<Void, Never>) -> Command) async {
        await withCheckedContinuation { continuation in
            if case .terminated = commands.yield(makeCommand(continuation)) {
                continuation.resume()
            }
        }
    }
}
