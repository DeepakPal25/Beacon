import Foundation

/// Transforms or drops events before they're queued: enrichment, PII scrubbing, filtering, sampling.
///
/// Processors run in order. Returning `nil` drops the event.
public protocol EventProcessor: Sendable {
    func process(_ event: AnalyticsEvent) -> AnalyticsEvent?
}

/// Wraps a closure as a processor.
public struct ClosureProcessor: EventProcessor {
    private let body: @Sendable (AnalyticsEvent) -> AnalyticsEvent?

    public init(_ body: @escaping @Sendable (AnalyticsEvent) -> AnalyticsEvent?) {
        self.body = body
    }

    public func process(_ event: AnalyticsEvent) -> AnalyticsEvent? {
        body(event)
    }
}

/// Adds properties to every event (app version, OS, build flavour…) without overwriting event-specific values.
public struct PropertyEnricher: EventProcessor {
    private let properties: @Sendable () -> [String: AnalyticsValue]

    /// - Parameter properties: Evaluated per event, so values like "is logged in" stay current.
    public init(_ properties: @escaping @Sendable () -> [String: AnalyticsValue]) {
        self.properties = properties
    }

    public init(static properties: [String: AnalyticsValue]) {
        self.properties = { properties }
    }

    public func process(_ event: AnalyticsEvent) -> AnalyticsEvent? {
        var event = event
        event.properties.merge(properties()) { existing, _ in existing }
        return event
    }
}

/// Removes personal data that shouldn't reach third parties.
///
/// - Values under sensitive keys (`email`, `password`, …) are replaced entirely.
/// - Email addresses and phone numbers inside any other string value are masked.
public struct PIIRedactor: EventProcessor {
    public var sensitiveKeys: Set<String>
    public var redactsEmails: Bool
    public var redactsPhoneNumbers: Bool

    public init(
        sensitiveKeys: Set<String> = ["email", "phone", "password", "token", "ssn", "address", "full_name"],
        redactsEmails: Bool = true,
        redactsPhoneNumbers: Bool = true
    ) {
        self.sensitiveKeys = Set(sensitiveKeys.map { $0.lowercased() })
        self.redactsEmails = redactsEmails
        self.redactsPhoneNumbers = redactsPhoneNumbers
    }

    public func process(_ event: AnalyticsEvent) -> AnalyticsEvent? {
        var event = event
        for (key, value) in event.properties {
            if sensitiveKeys.contains(key.lowercased()) {
                event.properties[key] = .string("[redacted]")
            } else if case .string(let text) = value {
                event.properties[key] = .string(redact(text))
            }
        }
        return event
    }

    func redact(_ text: String) -> String {
        var result = text
        if redactsEmails {
            result = result.replacing(#/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#, with: "[email]")
        }
        if redactsPhoneNumbers {
            // International numbers with a leading "+", or the (555) 555-5555 shape.
            // Deliberately doesn't match dates or plain IDs.
            result = result.replacing(#/\+\d[\d\s().\-]{7,}\d|\(?\d{3}\)?[\s.\-]\d{3}[\s.\-]\d{4}/#, with: "[phone]")
        }
        return result
    }
}

/// Drops events by name, e.g. to silence a noisy event without an app release.
public struct EventFilter: EventProcessor {
    public var blockedNames: Set<String>

    public init(blocking blockedNames: Set<String>) {
        self.blockedNames = blockedNames
    }

    public func process(_ event: AnalyticsEvent) -> AnalyticsEvent? {
        blockedNames.contains(event.name) ? nil : event
    }
}
