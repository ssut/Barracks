import CryptoKit
import Darwin
import Foundation

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(fileAt url: URL, chunkSize: Int = 8 * 1024 * 1024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public final class FileLock {
    private let url: URL
    private var descriptor: Int32 = -1

    public init(url: URL) {
        self.url = url
    }

    public func acquire(timeout: TimeInterval = 10) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BarracksError.lockUnavailable("cannot open \(url.lastPathComponent): errno \(errno)") }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline {
                close(fd)
                throw BarracksError.lockUnavailable("\(url.lastPathComponent) is held by another process")
            }
            usleep(100_000)
        }
        descriptor = fd
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }

    public static func withLock<T>(at url: URL, timeout: TimeInterval = 10, _ body: () throws -> T) throws -> T {
        let lock = FileLock(url: url)
        try lock.acquire(timeout: timeout)
        defer { lock.release() }
        return try body()
    }
}

public enum FileOps {
    public static func cloneOrCopyTree(from source: URL, to destination: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 {
            return "clonefile"
        }
        let cloneErrno = errno
        Log.notice("copy.clonefile_unavailable", ["errno": String(cloneErrno), "source": source.path])
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try ProcessRunner.run("/usr/bin/ditto", [source.path, destination.path])
        return "ditto"
    }

    public static func swapOrMove(staged: URL, target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            if renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 {
                return
            }
            let swapErrno = errno
            Log.warning("install.swap_unavailable", ["errno": String(swapErrno), "target": target.path])
            let backup = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).backup-\(getpid())")
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: target, to: backup)
            do {
                try fm.moveItem(at: staged, to: target)
            } catch {
                try? fm.moveItem(at: backup, to: target)
                throw BarracksError.installFailed(error.localizedDescription)
            }
            try fm.moveItem(at: backup, to: staged)
        } else {
            try fm.moveItem(at: staged, to: target)
        }
    }

    public static func availableCapacity(at url: URL) -> Int64? {
        var probe = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    public static func writeAtomically(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp-\(getpid())")
        try data.write(to: temp)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        if rename(temp.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "rename failed with errno \(code)"])
        }
    }
}
