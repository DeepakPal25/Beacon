import Foundation

enum Command: Sendable {
    case track(AnalyticsEvent)
    case identify(userID: String, traits: [String: AnalyticsValue])
    case reset
    case consent(ConsentState)
    case flush(CheckedContinuation<Void, Never>?)
    case sync(CheckedContinuation<Void, Never>)
}

/// Owns all mutable analytics state. Commands arrive one at a time, in the
/// order they were tracked, from ``AnalyticsClient``'s stream.
actor Pipeline {
    enum SendOutcome: Sendable {
        case delivered
        case nothingToSend
        case deferred
        case failed
    }

    struct Backoff {
        var failures: Int
        var retryAt: Date
    }

    private let providers: [any AnalyticsProvider]
    private let processors: [any EventProcessor]
    private let store: any EventStore
    private let consentStorage: any ConsentStorage
    private let configuration: AnalyticsClient.Configuration

    private(set) var consent: ConsentState
    private var userID: String?
    private var sessionID = UUID().uuidString
    private var lastActivity: Date?
    private var undecidedBuffer: [AnalyticsEvent] = []
    private var queues: [String: [AnalyticsEvent]]
    private var backoff: [String: Backoff] = [:]
    private var inFlight: [String: Task<SendOutcome, Never>] = [:]

    init(
        providers: [any AnalyticsProvider],
        processors: [any EventProcessor],
        store: any EventStore,
        consentStorage: any ConsentStorage,
        configuration: AnalyticsClient.Configuration
    ) {
        self.providers = providers
        self.processors = processors
        self.store = store
        self.consentStorage = consentStorage
        self.configuration = configuration
        self.consent = consentStorage.load() ?? configuration.defaultConsent

        var queues: [String: [AnalyticsEvent]] = [:]
        for provider in providers {
            queues[provider.id] = store.load(providerID: provider.id)
        }
        self.queues = queues
    }

    func handle(_ command: Command) async {
        switch command {
        case .track(let event):
            track(event)
        case .identify(let userID, let traits):
            self.userID = userID
            for provider in allowedProviders() {
                await provider.identify(userID: userID, traits: traits)
            }
        case .reset:
            userID = nil
            sessionID = UUID().uuidString
            for provider in providers {
                await provider.reset()
            }
        case .consent(let state):
            updateConsent(state)
        case .flush(let done):
            await flushAll()
            done?.resume()
        case .sync(let done):
            done.resume()
        }
    }

    // MARK: Ingest

    private func track(_ incoming: AnalyticsEvent) {
        let now = configuration.now()
        if let lastActivity, now.timeIntervalSince(lastActivity) > configuration.sessionTimeout {
            sessionID = UUID().uuidString
        }
        lastActivity = now

        var event = incoming
        event.userID = event.userID ?? userID
        event.sessionID = sessionID
        for processor in processors {
            guard let processed = processor.process(event) else { return }
            event = processed
        }

        switch consent {
        case .undecided:
            undecidedBuffer.append(event)
            let overflow = undecidedBuffer.count - configuration.undecidedBufferLimit
            if overflow > 0 { undecidedBuffer.removeFirst(overflow) }
        case .decided(let granted):
            route(event, granted: granted)
        }
    }

    private func route(_ event: AnalyticsEvent, granted: Set<ConsentCategory>) {
        guard event.category.isAllowed(by: granted) else { return }
        for provider in providers where provider.consentCategory.isAllowed(by: granted) {
            enqueue(event, for: provider.id)
            if (queues[provider.id]?.count ?? 0) >= provider.maxBatchSize {
                Task { _ = await self.sendNextBatch(to: provider) }
            }
        }
    }

    private func enqueue(_ event: AnalyticsEvent, for providerID: String) {
        var queue = queues[providerID, default: []]
        queue.append(event)
        let overflow = queue.count - configuration.maxQueueSize
        if overflow > 0 {
            // Drop the oldest: recent behaviour is more useful than stale history.
            queue.removeFirst(overflow)
            queues[providerID] = queue
            store.replace(with: queue, providerID: providerID)
        } else {
            queues[providerID] = queue
            store.append([event], providerID: providerID)
        }
    }

    // MARK: Consent

    private func updateConsent(_ state: ConsentState) {
        let previous = consent
        consent = state
        consentStorage.save(state)

        guard case .decided(let granted) = state else { return }

        // Purge anything already queued that the user no longer allows.
        for provider in providers {
            let queue = queues[provider.id] ?? []
            let kept = provider.consentCategory.isAllowed(by: granted)
                ? queue.filter { $0.category.isAllowed(by: granted) }
                : []
            if kept.count != queue.count {
                queues[provider.id] = kept
                store.replace(with: kept, providerID: provider.id)
            }
        }

        if case .undecided = previous {
            let buffered = undecidedBuffer
            undecidedBuffer = []
            for event in buffered {
                route(event, granted: granted)
            }
        }
    }

    private func allowedProviders() -> [any AnalyticsProvider] {
        guard case .decided(let granted) = consent else { return [] }
        return providers.filter { $0.consentCategory.isAllowed(by: granted) }
    }

    // MARK: Delivery

    private func flushAll() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { await self.drain(provider) }
            }
        }
    }

    /// Sends batches until the queue is empty or a send fails or is deferred.
    private func drain(_ provider: any AnalyticsProvider) async {
        while await sendNextBatch(to: provider) == .delivered {}
    }

    private func sendNextBatch(to provider: any AnalyticsProvider) async -> SendOutcome {
        let id = provider.id
        // Only one batch per provider at a time, which keeps delivery in order.
        if let running = inFlight[id] {
            return await running.value
        }

        dropExpiredEvents(for: id)
        guard let queue = queues[id], !queue.isEmpty else { return .nothingToSend }
        if let backoff = backoff[id], backoff.retryAt > configuration.now() {
            return .deferred
        }

        let batch = Array(queue.prefix(max(provider.maxBatchSize, 1)))
        let task = Task { await self.deliver(batch, to: provider) }
        inFlight[id] = task
        return await task.value
    }

    private func deliver(_ batch: [AnalyticsEvent], to provider: any AnalyticsProvider) async -> SendOutcome {
        let id = provider.id
        defer { inFlight[id] = nil }
        do {
            try await provider.send(batch)
            remove(batch, from: id)
            backoff[id] = nil
            return .delivered
        } catch is BatchRejectedError {
            remove(batch, from: id)
            backoff[id] = nil
            return .delivered
        } catch {
            let failures = (backoff[id]?.failures ?? 0) + 1
            let delay = min(
                configuration.retryBaseDelay * pow(2, Double(failures - 1)),
                configuration.maxRetryDelay
            )
            backoff[id] = Backoff(failures: failures, retryAt: configuration.now().addingTimeInterval(delay))
            return .failed
        }
    }

    private func remove(_ batch: [AnalyticsEvent], from providerID: String) {
        // Remove by ID: events may have been added (or purged) while the batch was in flight.
        let sent = Set(batch.map(\.id))
        let remaining = (queues[providerID] ?? []).filter { !sent.contains($0.id) }
        queues[providerID] = remaining
        store.replace(with: remaining, providerID: providerID)
    }

    private func dropExpiredEvents(for providerID: String) {
        guard let queue = queues[providerID], !queue.isEmpty else { return }
        let cutoff = configuration.now().addingTimeInterval(-configuration.maxEventAge)
        let fresh = queue.filter { $0.timestamp >= cutoff }
        if fresh.count != queue.count {
            queues[providerID] = fresh
            store.replace(with: fresh, providerID: providerID)
        }
    }
}
