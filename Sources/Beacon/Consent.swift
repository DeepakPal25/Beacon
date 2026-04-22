import Foundation

/// A purpose the user can grant or refuse consent for (GDPR, CCPA, App Tracking Transparency).
///
/// Modelled as an extensible struct so apps can add their own categories.
public struct ConsentCategory: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// Always allowed. Use sparingly, e.g. for crash or security signals the app needs to function.
    public static let necessary: ConsentCategory = "necessary"
    /// Product analytics.
    public static let analytics: ConsentCategory = "analytics"
    /// Advertising and attribution.
    public static let marketing: ConsentCategory = "marketing"
    /// Performance monitoring.
    public static let performance: ConsentCategory = "performance"

    /// Every built-in optional category.
    public static let allOptional: Set<ConsentCategory> = [.analytics, .marketing, .performance]

    func isAllowed(by granted: Set<ConsentCategory>) -> Bool {
        self == .necessary || granted.contains(self)
    }
}

/// The user's consent decision.
public enum ConsentState: Sendable, Hashable, Codable {
    /// The user hasn't answered yet. Events are held in memory (not sent, not
    /// written to disk) until they decide.
    case undecided
    /// The categories the user agreed to. Anything else is dropped.
    case decided(granted: Set<ConsentCategory>)
}

/// Persists the consent decision across launches.
public protocol ConsentStorage: Sendable {
    func load() -> ConsentState?
    func save(_ state: ConsentState)
}

/// Stores consent in `UserDefaults`.
public struct UserDefaultsConsentStorage: ConsentStorage {
    private let suiteName: String?
    private let key: String

    public init(suiteName: String? = nil, key: String = "beacon.consent") {
        self.suiteName = suiteName
        self.key = key
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() -> ConsentState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ConsentState.self, from: data)
    }

    public func save(_ state: ConsentState) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }
}
