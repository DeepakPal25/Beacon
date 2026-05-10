import Foundation

/// Persists each provider's queue so events survive app termination and offline periods.
public protocol EventStore: Sendable {
    func load(providerID: String) -> [AnalyticsEvent]
    func append(_ events: [AnalyticsEvent], providerID: String)
    func replace(with events: [AnalyticsEvent], providerID: String)
}

/// Stores each queue as a JSON Lines file in Application Support.
///
/// Appending a line is cheap and doesn't rewrite the queue. If the app is
/// killed mid-write, only the last partial line is lost: unreadable lines are
/// skipped on load instead of corrupting the whole queue.
public struct FileEventStore: EventStore {
    public let directory: URL

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "Beacon", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    public func load(providerID: String) -> [AnalyticsEvent] {
        guard let data = try? Data(contentsOf: fileURL(for: providerID)) else { return [] }
        let decoder = JSONDecoder()
        return data
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(AnalyticsEvent.self, from: Data($0)) }
    }

    public func append(_ events: [AnalyticsEvent], providerID: String) {
        guard !events.isEmpty, let lines = Self.encode(events) else { return }
        let url = fileURL(for: providerID)
        do {
            if FileManager.default.fileExists(atPath: url.path()) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lines)
            } else {
                try createDirectory()
                try lines.write(to: url, options: .atomic)
            }
        } catch {
            // Losing persistence degrades to in-memory delivery; never crash the host app.
        }
    }

    public func replace(with events: [AnalyticsEvent], providerID: String) {
        let url = fileURL(for: providerID)
        do {
            if events.isEmpty {
                if FileManager.default.fileExists(atPath: url.path()) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            guard let lines = Self.encode(events) else { return }
            try createDirectory()
            try lines.write(to: url, options: .atomic)
        } catch {
            // See append(_:providerID:).
        }
    }

    func fileURL(for providerID: String) -> URL {
        let safeName = providerID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appending(path: String(safeName) + ".jsonl")
    }

    private func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func encode(_ events: [AnalyticsEvent]) -> Data? {
        let encoder = JSONEncoder()
        var data = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        return data.isEmpty ? nil : data
    }
}

/// An in-memory store for tests and previews.
public final class InMemoryEventStore: EventStore, @unchecked Sendable {
    // Guarded by `lock`.
    private var queues: [String: [AnalyticsEvent]] = [:]
    private let lock = NSLock()

    public init() {}

    public func load(providerID: String) -> [AnalyticsEvent] {
        lock.withLock { queues[providerID] ?? [] }
    }

    public func append(_ events: [AnalyticsEvent], providerID: String) {
        lock.withLock { queues[providerID, default: []].append(contentsOf: events) }
    }

    public func replace(with events: [AnalyticsEvent], providerID: String) {
        lock.withLock { queues[providerID] = events }
    }
}

/// In-memory consent storage for tests and previews.
public final class InMemoryConsentStorage: ConsentStorage, @unchecked Sendable {
    // Guarded by `lock`.
    private var state: ConsentState?
    private let lock = NSLock()

    public init(_ state: ConsentState? = nil) {
        self.state = state
    }

    public func load() -> ConsentState? {
        lock.withLock { state }
    }

    public func save(_ state: ConsentState) {
        lock.withLock { self.state = state }
    }
}
