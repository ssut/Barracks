import Foundation
import os

public enum LogLevel: String, Sendable, Comparable {
    case debug, info, notice, warning, error

    var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .warning: 3
        case .error: 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }

    var osType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .error
        case .error: .fault
        }
    }
}

public final class BarracksLogger: @unchecked Sendable {
    public static let shared = BarracksLogger()

    private let lock = NSLock()
    private let osLogger = Logger(subsystem: "com.suhunhan.barracks", category: "barracks")
    private var fileURL: URL?
    private var mirrorToStderr = false
    private var minimumLevel: LogLevel = .info
    private let maxFileBytes: UInt64 = 5 * 1024 * 1024
    private let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func configure(fileURL: URL?, minimumLevel: LogLevel = .info, mirrorToStderr: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        self.fileURL = fileURL
        self.minimumLevel = minimumLevel
        self.mirrorToStderr = mirrorToStderr
        if let fileURL {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    public var currentFileURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return fileURL
    }

    public func log(_ level: LogLevel, _ event: String, _ fields: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        guard level >= minimumLevel else { return }
        let timestamp = timestampFormatter.string(from: Date())
        var record: [String: Any] = ["ts": timestamp, "level": level.rawValue, "event": event]
        if !fields.isEmpty { record["fields"] = fields }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8)
        else { return }
        osLogger.log(level: level.osType, "\(line, privacy: .public)")
        if mirrorToStderr {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        if let fileURL { append(line: line, to: fileURL) }
    }

    private func append(line: String, to url: URL) {
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? UInt64, size > maxFileBytes {
            let rotated = url.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

public enum Log {
    public static func debug(_ event: String, _ fields: [String: String] = [:]) { BarracksLogger.shared.log(.debug, event, fields) }
    public static func info(_ event: String, _ fields: [String: String] = [:]) { BarracksLogger.shared.log(.info, event, fields) }
    public static func notice(_ event: String, _ fields: [String: String] = [:]) { BarracksLogger.shared.log(.notice, event, fields) }
    public static func warning(_ event: String, _ fields: [String: String] = [:]) { BarracksLogger.shared.log(.warning, event, fields) }
    public static func error(_ event: String, _ fields: [String: String] = [:]) { BarracksLogger.shared.log(.error, event, fields) }
}
