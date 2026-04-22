import Foundation

/// A single analytics event.
///
/// Define your app's events as static constructors so names and property
/// keys live in one place:
///
/// ```swift
/// extension AnalyticsEvent {
///     static func purchase(sku: String, price: Double) -> AnalyticsEvent {
///         AnalyticsEvent("purchase_completed", properties: ["sku": .string(sku), "price": .double(price)])
///     }
/// }
///
/// analytics.track(.purchase(sku: "pro_yearly", price: 49.99))
/// ```
public struct AnalyticsEvent: Sendable, Hashable, Codable, Identifiable {
    /// A unique ID, so backends can de-duplicate events retried after a network failure.
    public let id: UUID
    public var name: String
    public var properties: [String: AnalyticsValue]
    /// The consent category this event needs before it may be sent.
    public var category: ConsentCategory
    public var timestamp: Date
    /// Stamped by the pipeline from the last `identify(userID:)` call.
    public internal(set) var userID: String?
    /// Stamped by the pipeline. A new session starts after a period of inactivity.
    public internal(set) var sessionID: String?

    public init(
        _ name: String,
        properties: [String: AnalyticsValue] = [:],
        category: ConsentCategory = .analytics,
        timestamp: Date = Date(),
        id: UUID = UUID()
    ) {
        self.id = id
        self.name = name
        self.properties = properties
        self.category = category
        self.timestamp = timestamp
    }
}

extension AnalyticsEvent {
    public static func screenView(_ screenName: String, properties: [String: AnalyticsValue] = [:]) -> AnalyticsEvent {
        AnalyticsEvent("screen_view", properties: properties.merging(["screen_name": .string(screenName)]) { $1 })
    }
}
