@testable import Beacon
import BeaconTesting
import Foundation
import Testing

let everything: ConsentState = .decided(granted: ConsentCategory.allOptional)

func makeAnalytics(
    _ providers: [any AnalyticsProvider],
    processors: [any EventProcessor] = [],
    store: InMemoryEventStore = InMemoryEventStore(),
    consent: ConsentState = everything,
    clock: TestClock = TestClock(),
    configure: (inout AnalyticsClient.Configuration) -> Void = { _ in }
) -> AnalyticsClient {
    var configuration = AnalyticsClient.Configuration(
        flushInterval: nil,
        defaultConsent: consent,
        now: { clock.now }
    )
    configure(&configuration)
    return AnalyticsClient(
        providers: providers,
        processors: processors,
        store: store,
        consentStorage: InMemoryConsentStorage(),
        configuration: configuration
    )
}

// MARK: - Delivery

@Suite("Delivery")
struct DeliveryTests {
    @Test("Fans each event out to every provider")
    func fanOut() async {
        let firebase = RecordingProvider(id: "firebase")
        let mixpanel = RecordingProvider(id: "mixpanel")
        let analytics = makeAnalytics([firebase, mixpanel])

        analytics.track("signup")
        await analytics.flush()

        #expect(await firebase.eventNames == ["signup"])
        #expect(await mixpanel.eventNames == ["signup"])
    }

    @Test("Preserves tracking order")
    func ordering() async {
        let provider = RecordingProvider(maxBatchSize: 7)
        let analytics = makeAnalytics([provider])
        let names = (0..<100).map { "event_\($0)" }

        for name in names {
            analytics.track(name)
        }
        await analytics.flush()

        #expect(await provider.eventNames == names)
    }

    @Test("Splits the queue into batches no larger than maxBatchSize")
    func batching() async {
        let provider = RecordingProvider(maxBatchSize: 3)
        let analytics = makeAnalytics([provider])

        for index in 0..<7 {
            analytics.track("e\(index)")
        }
        await analytics.flush()

        let batches = await provider.batches
        #expect(batches.allSatisfy { $0.count <= 3 })
        #expect(batches.flatMap { $0 }.count == 7)
    }

    @Test("Drops the oldest events beyond maxQueueSize")
    func queueCap() async {
        let provider = RecordingProvider()
        let analytics = makeAnalytics([provider]) { $0.maxQueueSize = 3 }

        for name in ["a", "b", "c", "d", "e"] {
            analytics.track(name)
        }
        await analytics.flush()

        #expect(await provider.eventNames == ["c", "d", "e"])
    }

    @Test("Drops events older than maxEventAge")
    func expiry() async {
        let clock = TestClock()
        let provider = RecordingProvider()
        let analytics = makeAnalytics([provider], clock: clock)

        analytics.track(AnalyticsEvent("stale", timestamp: clock.now.addingTimeInterval(-8 * 24 * 60 * 60)))
        analytics.track(AnalyticsEvent("fresh", timestamp: clock.now))
        await analytics.flush()

        #expect(await provider.eventNames == ["fresh"])
    }
}

// MARK: - Offline and retries

@Suite("Offline and retries")
struct RetryTests {
    @Test("Failed events persist and are delivered after relaunch")
    func persistence() async {
        let store = InMemoryEventStore()
        let offline = RecordingProvider(id: "backend")
        await offline.fail(times: 100)

        let firstLaunch = makeAnalytics([offline], store: store)
        firstLaunch.track("a")
        firstLaunch.track("b")
        await firstLaunch.flush()

        #expect(await offline.events.isEmpty)
        #expect(store.load(providerID: "backend").map(\.name) == ["a", "b"])

        let online = RecordingProvider(id: "backend")
        let secondLaunch = makeAnalytics([online], store: store)
        await secondLaunch.flush()

        #expect(await online.eventNames == ["a", "b"])
        #expect(store.load(providerID: "backend").isEmpty)
    }

    @Test("Backs off after a failure, then retries")
    func backoff() async {
        let clock = TestClock()
        let provider = RecordingProvider()
        await provider.fail(times: 1)
        let analytics = makeAnalytics([provider], clock: clock) { $0.retryBaseDelay = 10 }

        analytics.track("a")
        await analytics.flush()
        #expect(await provider.sendAttempts == 1)

        await analytics.flush()
        #expect(await provider.sendAttempts == 1, "Still inside the backoff window")

        clock.advance(by: 11)
        await analytics.flush()
        #expect(await provider.sendAttempts == 2)
        #expect(await provider.eventNames == ["a"])
    }

    @Test("A rejected batch is dropped instead of retried forever")
    func rejection() async {
        let store = InMemoryEventStore()
        let provider = RecordingProvider()
        await provider.reject(times: 1)
        let analytics = makeAnalytics([provider], store: store)

        analytics.track("malformed")
        await analytics.flush()
        await analytics.flush()

        #expect(await provider.sendAttempts == 1)
        #expect(store.load(providerID: provider.id).isEmpty)
    }

    @Test("One failing provider doesn't block the others")
    func isolation() async {
        let down = RecordingProvider(id: "down")
        await down.fail(times: 100)
        let up = RecordingProvider(id: "up")
        let analytics = makeAnalytics([down, up])

        analytics.track("a")
        await analytics.flush()

        #expect(await up.eventNames == ["a"])
        #expect(await down.events.isEmpty)
    }
}

// MARK: - Consent

@Suite("Consent")
struct ConsentTests {
    @Test("Events wait in memory until the user decides")
    func undecided() async {
        let store = InMemoryEventStore()
        let provider = RecordingProvider()
        let analytics = makeAnalytics([provider], store: store, consent: .undecided)

        analytics.track("app_open")
        await analytics.flush()
        #expect(await provider.events.isEmpty)
        #expect(store.load(providerID: provider.id).isEmpty, "Nothing is written to disk before consent")

        analytics.setConsent(granted: [.analytics])
        await analytics.flush()
        #expect(await provider.eventNames == ["app_open"])
    }

    @Test("Providers only receive events for granted categories")
    func gating() async {
        let product = RecordingProvider(id: "product", consentCategory: .analytics)
        let ads = RecordingProvider(id: "ads", consentCategory: .marketing)
        let analytics = makeAnalytics([product, ads], consent: .decided(granted: [.analytics]))

        analytics.track("viewed_item")
        analytics.track("ad_click", category: .marketing)
        await analytics.flush()

        #expect(await product.eventNames == ["viewed_item"])
        #expect(await ads.events.isEmpty)
    }

    @Test("Necessary events and providers ignore consent")
    func necessary() async {
        let crashes = RecordingProvider(id: "crashes", consentCategory: .necessary)
        let analytics = makeAnalytics([crashes], consent: .decided(granted: []))

        analytics.track("fatal_error", category: .necessary)
        analytics.track("tapped_button")
        await analytics.flush()

        #expect(await crashes.eventNames == ["fatal_error"])
    }

    @Test("Withdrawing consent deletes queued events")
    func withdrawal() async {
        let store = InMemoryEventStore()
        let provider = RecordingProvider()
        let analytics = makeAnalytics([provider], store: store)

        analytics.track("a")
        await analytics.waitUntilIdle()
        #expect(store.load(providerID: provider.id).count == 1)

        analytics.setConsent(granted: [])
        await analytics.flush()

        #expect(await provider.events.isEmpty)
        #expect(store.load(providerID: provider.id).isEmpty)
        #expect(await analytics.consent == .decided(granted: []))
    }
}

// MARK: - Identity and processing

@Suite("Identity and processing")
struct ProcessingTests {
    @Test("identify stamps the user ID; reset clears it and starts a new session")
    func identity() async throws {
        let provider = RecordingProvider()
        let analytics = makeAnalytics([provider])

        analytics.track("anonymous")
        analytics.identify(userID: "u_42")
        analytics.track("signed_in")
        analytics.reset()
        analytics.track("signed_out")
        await analytics.flush()

        let events = await provider.events
        #expect(events.map(\.userID) == [nil, "u_42", nil])
        #expect(events[0].sessionID == events[1].sessionID)
        #expect(events[1].sessionID != events[2].sessionID)
        #expect(await provider.identifiedUserIDs == ["u_42"])
        #expect(await provider.resetCount == 1)
    }

    @Test("A new session starts after inactivity")
    func sessionTimeout() async {
        let clock = TestClock()
        let provider = RecordingProvider()
        let analytics = makeAnalytics([provider], clock: clock) { $0.sessionTimeout = 60 }

        analytics.track("first")
        await analytics.waitUntilIdle()
        clock.advance(by: 61)
        analytics.track("second")
        await analytics.flush()

        let sessions = await provider.events.map(\.sessionID)
        #expect(sessions[0] != sessions[1])
    }

    @Test("Processors enrich, redact and filter in order")
    func processors() async {
        let provider = RecordingProvider()
        let analytics = makeAnalytics(
            [provider],
            processors: [
                PropertyEnricher(static: ["app_version": "3.2.0", "plan": "free"]),
                PIIRedactor(),
                EventFilter(blocking: ["noisy_event"]),
            ]
        )

        analytics.track("contact_support", properties: [
            "plan": "pro",
            "email": "ada@example.com",
            "message": "Reach me at ada@example.com or +44 20 7946 0958 before 2026-10-02",
        ])
        analytics.track("noisy_event")
        await analytics.flush()

        let events = await provider.events
        #expect(events.map(\.name) == ["contact_support"])
        let properties = events[0].properties
        #expect(properties["app_version"] == "3.2.0")
        #expect(properties["plan"] == "pro", "Enrichment never overwrites event values")
        #expect(properties["email"] == "[redacted]")
        #expect(properties["message"] == "Reach me at [email] or [phone] before 2026-10-02")
    }
}

// MARK: - Persistence format

@Suite("FileEventStore")
struct FileEventStoreTests {
    func temporaryStore() -> FileEventStore {
        FileEventStore(directory: FileManager.default.temporaryDirectory.appending(path: "beacon-tests-\(UUID().uuidString)"))
    }

    @Test("Appends and reloads events")
    func roundTrip() {
        let store = temporaryStore()
        store.append([AnalyticsEvent("a")], providerID: "p")
        store.append([AnalyticsEvent("b", properties: ["n": 1])], providerID: "p")

        let loaded = store.load(providerID: "p")
        #expect(loaded.map(\.name) == ["a", "b"])
        #expect(loaded[1].properties["n"] == 1)
    }

    @Test("Skips a corrupted trailing line instead of losing the queue")
    func corruption() throws {
        let store = temporaryStore()
        store.append([AnalyticsEvent("a"), AnalyticsEvent("b")], providerID: "p")

        let handle = try FileHandle(forWritingTo: store.fileURL(for: "p"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\": \"trunc".utf8))
        try handle.close()

        #expect(store.load(providerID: "p").map(\.name) == ["a", "b"])
    }

    @Test("Replacing with an empty queue deletes the file")
    func clear() {
        let store = temporaryStore()
        store.append([AnalyticsEvent("a")], providerID: "p")
        store.replace(with: [], providerID: "p")
        #expect(store.load(providerID: "p").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: "p").path()))
    }
}
