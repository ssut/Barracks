import Darwin
import Foundation

public struct ProcessSnapshot: Sendable, Equatable {
    public var pid: Int32
    public var executablePath: String
}

public enum ProcessInspector {
    public static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    public static func processes(inside bundle: URL) -> [ProcessSnapshot] {
        let root = bundle.standardizedPath
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return allPIDs().compactMap { pid in
            guard let path = executablePath(of: pid) else { return nil }
            let normalized = URL(filePath: path).standardizedPath
            guard normalized.hasPrefix(prefix) else { return nil }
            return ProcessSnapshot(pid: pid, executablePath: path)
        }
    }

    public static func singletonLockOwner(dataDirectory: URL) -> ProcessSnapshot? {
        let lock = dataDirectory.appending(path: "SingletonLock").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock) else { return nil }
        guard let dash = target.lastIndex(of: "-"), let pid = Int32(target[target.index(after: dash)...]) else { return nil }
        guard isAlive(pid) else { return nil }
        return ProcessSnapshot(pid: pid, executablePath: executablePath(of: pid) ?? "unknown")
    }

    public static func openFiles(pids: [Int32]) -> [String] {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let result = try? ProcessRunner.run("/usr/sbin/lsof", ["-n", "-P", "-F", "n", "-p", list], allowFailure: true) else { return [] }
        return result.stdoutString
            .split(separator: "\n")
            .filter { $0.hasPrefix("n/") }
            .map { String($0.dropFirst()) }
    }
}
