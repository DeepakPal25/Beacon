import Foundation

/// A destination for events: Firebase, Mixpanel, Amplitude, your own backend…
///
/// Each provider gets its own persistent queue, so a provider that is down
/// never blocks the others. Adapting an SDK takes a few lines:
///
/// ```swift
/// struct MixpanelProvider: AnalyticsProvider {
///     let id = "mixpanel"
///
///     func send(_ events: [AnalyticsEvent]) async throws {
///         for event in events {
///             Mixpanel.mainInstance().track(event: event.name, properties: event.properties.mixpanelProperties)
///         }
///     }
///
///     func identify(userID: String, traits: [String: AnalyticsValue]) async {
///         Mixpanel.mainInstance().identify(distinctId: userID)
///     }
///
///     func reset() async { Mixpanel.mainInstance().reset() }
/// }
/// ```
public protocol AnalyticsProvider: Sendable {
    /// Stable identifier. Also names the provider's on-disk queue, so don't change it between releases.
    var id: String { get }
    /// The consent the user must grant before this provider receives anything.
    var consentCategory: ConsentCategory { get }
    /// Events per `send` call. Reaching this many queued events also triggers a send.
    var maxBatchSize: Int { get }

    /// Delivers a batch. Throw to retry later with backoff; throw ``BatchRejectedError`` to drop the batch.
    func send(_ events: [AnalyticsEvent]) async throws
    func identify(userID: String, traits: [String: AnalyticsValue]) async
    /// Called on sign-out.
    func reset() async
}

extension AnalyticsProvider {
    public var consentCategory: ConsentCategory { .analytics }
    public var maxBatchSize: Int { 50 }
    public func identify(userID: String, traits: [String: AnalyticsValue]) async {}
    public func reset() async {}
}

/// Thrown by a provider when a batch can never succeed (e.g. HTTP 400).
///
/// The pipeline drops the batch instead of retrying, so one malformed event
/// can't block every event behind it forever (a "poison pill").
public struct BatchRejectedError: Error, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

// MARK: - Built-in providers

/// Prints events. Handy in debug builds.
public struct ConsoleProvider: AnalyticsProvider {
    public let id: String
    public let maxBatchSize: Int
    private let log: @Sendable (String) -> Void

    public init(id: String = "console", maxBatchSize: Int = 1, log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.id = id
        self.maxBatchSize = maxBatchSize
        self.log = log
    }

    public var consentCategory: ConsentCategory { .necessary }

    public func send(_ events: [AnalyticsEvent]) async throws {
        for event in events {
            let properties = event.properties
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.anyValue)" }
                .joined(separator: " ")
            log("📊 \(event.name) \(properties)")
        }
    }
}

/// Posts batches as JSON to your own collector endpoint.
///
/// Body: `{"events": [{"id", "name", "timestamp", "user_id", "session_id", "properties"}]}`.
/// `4xx` responses (other than `408` and `429`) drop the batch; everything else is retried.
public struct HTTPBatchProvider: AnalyticsProvider {
    public let id: String
    public let endpoint: URL
    public let consentCategory: ConsentCategory
    public let maxBatchSize: Int
    private let headers: [String: String]
    private let session: URLSession

    public init(
        id: String = "http",
        endpoint: URL,
        headers: [String: String] = [:],
        consentCategory: ConsentCategory = .analytics,
        maxBatchSize: Int = 100,
        session: URLSession = .shared
    ) {
        self.id = id
        self.endpoint = endpoint
        self.headers = headers
        self.consentCategory = consentCategory
        self.maxBatchSize = maxBatchSize
        self.session = session
    }

    public func send(_ events: [AnalyticsEvent]) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try Self.body(for: events)

        let (_, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw URLError(.badServerResponse)
        }
        switch status {
        case 200..<300:
            return
        case 408, 429:
            throw URLError(.timedOut)
        case 400..<500:
            throw BatchRejectedError(reason: "HTTP \(status)")
        default:
            throw URLError(.badServerResponse)
        }
    }

    static func body(for events: [AnalyticsEvent]) throws -> Data {
        let payload: [[String: Any]] = events.map { event in
            var json: [String: Any] = [
                "id": event.id.uuidString,
                "name": event.name,
                "timestamp": event.timestamp.formatted(.iso8601),
                "properties": event.properties.anyValues,
            ]
            json["user_id"] = event.userID
            json["session_id"] = event.sessionID
            return json
        }
        return try JSONSerialization.data(withJSONObject: ["events": payload])
    }
}
