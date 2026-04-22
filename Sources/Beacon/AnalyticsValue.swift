import Foundation

/// A property value attached to an event.
///
/// Literal-expressible, so properties read naturally at call sites:
///
/// ```swift
/// analytics.track("checkout_completed", properties: ["plan": "pro", "seats": 3, "trial": false])
/// ```
public enum AnalyticsValue: Sendable, Hashable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)

    /// The value as a Foundation type, for SDKs that take `[String: Any]`.
    /// Dates become ISO 8601 strings.
    public var anyValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        case .date(let value): value.formatted(.iso8601)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

extension AnalyticsValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension Dictionary where Key == String, Value == AnalyticsValue {
    /// The properties as `[String: Any]`, for SDKs such as Firebase and Mixpanel.
    public var anyValues: [String: Any] {
        mapValues(\.anyValue)
    }
}
