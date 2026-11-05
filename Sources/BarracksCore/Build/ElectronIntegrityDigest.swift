import CryptoKit
import Foundation

public enum ElectronIntegrityDigest {
    static let sentinel = Data("AGbevlPCksUGKNL8TSn7wGmJEuJsXb2A".utf8)
    static let supportedVersion: UInt8 = 1
    static let digestLength = 32
    static let slotLength = 32 + 1 + 1 + 32
    static let frameworkBinaryPath = "Contents/Frameworks/Electron Framework.framework/Electron Framework"
    static let integrityKey = "ElectronAsarIntegrity"

    public enum Outcome: String, Sendable {
        case notPresent = "not_present"
        case unused
        case unchanged
        case updated
    }

    struct Slot: Equatable {
        var offset: Int
        var used: Bool
        var version: UInt8
        var digest: Data

        var digestOffset: Int { offset + 34 }
    }

    static func digest(of integrity: [String: Any]) throws -> Data {
        var hasher = SHA256()
        let keys = integrity.keys.sorted { $0.compare($1, options: .literal) == .orderedAscending }
        for key in keys {
            guard let entry = integrity[key] as? [String: Any], let algorithm = entry["algorithm"] as? String, let hash = entry["hash"] as? String else {
                throw BarracksError.electronIntegrity("Info.plist \(integrityKey) entry \(key) has no algorithm or hash")
            }
            hasher.update(data: Data(key.utf8))
            hasher.update(data: Data(algorithm.utf8))
            hasher.update(data: Data(hash.utf8))
        }
        return Data(hasher.finalize())
    }

    static func integrity(ofApp appURL: URL) throws -> [String: Any]? {
        try PlistDocument.read(appURL.appending(path: "Contents/Info.plist")).values[integrityKey] as? [String: Any]
    }

    static func binary(in appURL: URL) throws -> URL? {
        let link = appURL.appending(path: frameworkBinaryPath)
        guard FileManager.default.fileExists(atPath: link.path) else { return nil }
        let resolved = link.resolvingSymlinksInPath()
        guard resolved.isSameOrDescendant(of: appURL.resolvingSymlinksInPath()) else {
            throw BarracksError.electronIntegrity("\(link.path) resolves outside the app (\(resolved.path))")
        }
        return resolved
    }

    static func slots(in data: Data) -> [Slot] {
        var slots: [Slot] = []
        var cursor = data.startIndex
        while let range = data.range(of: sentinel, in: cursor..<data.endIndex) {
            let start = range.lowerBound
            cursor = range.upperBound
            guard start + slotLength <= data.endIndex else { break }
            slots.append(Slot(
                offset: start - data.startIndex,
                used: data[start + 32] != 0,
                version: data[start + 33],
                digest: data.subdata(in: (start + 34)..<(start + slotLength))
            ))
        }
        return slots
    }

    static func slots(inBinary url: URL) throws -> [Slot] {
        slots(in: try Data(contentsOf: url, options: .alwaysMapped))
    }

    @discardableResult
    public static func update(appURL: URL, sourceAppURL: URL) throws -> Outcome {
        guard let binary = try binary(in: appURL) else {
            Log.info("electron_integrity.skipped", ["reason": "no_framework", "app": appURL.lastPathComponent])
            return .notPresent
        }
        let found = try slots(inBinary: binary)
        let used = found.filter(\.used)
        guard !found.isEmpty else {
            Log.info("electron_integrity.skipped", ["reason": "no_slot", "app": appURL.lastPathComponent])
            return .notPresent
        }
        guard !used.isEmpty else {
            Log.info("electron_integrity.skipped", ["reason": "slot_unused", "app": appURL.lastPathComponent, "slots": String(found.count)])
            return .unused
        }
        if let unknown = used.first(where: { $0.version != supportedVersion }) {
            throw BarracksError.electronIntegrity("Electron uses archive digest version \(unknown.version); Barracks supports \(supportedVersion)")
        }
        guard let sourceIntegrity = try integrity(ofApp: sourceAppURL) else {
            throw BarracksError.electronIntegrity("the original app has an Electron archive digest but no \(integrityKey) in Info.plist")
        }
        let expectedSource = try digest(of: sourceIntegrity)
        guard used.allSatisfy({ $0.digest == expectedSource }) else {
            throw BarracksError.electronIntegrity("the original app's archive digest doesn't match its Info.plist, so the digest format changed")
        }
        guard let stagedIntegrity = try integrity(ofApp: appURL) else {
            throw BarracksError.electronIntegrity("the profile app lost \(integrityKey) from Info.plist")
        }
        let target = try digest(of: stagedIntegrity)
        if target == expectedSource {
            Log.info("electron_integrity.unchanged", ["app": appURL.lastPathComponent, "slots": String(used.count)])
            return .unchanged
        }
        try write(target, into: used, of: binary)
        let written = try slots(inBinary: binary).filter(\.used)
        guard written.count == used.count, written.allSatisfy({ $0.digest == target }) else {
            throw BarracksError.electronIntegrity("the archive digest did not read back after writing \(binary.lastPathComponent)")
        }
        Log.info("electron_integrity.updated", [
            "app": appURL.lastPathComponent,
            "slots": String(used.count),
            "from": expectedSource.prefix(6).map { String(format: "%02x", $0) }.joined(),
            "to": target.prefix(6).map { String(format: "%02x", $0) }.joined(),
        ])
        return .updated
    }

    static func write(_ digest: Data, into slots: [Slot], of binary: URL) throws {
        let fm = FileManager.default
        let original = (try fm.attributesOfItem(atPath: binary.path)[.posixPermissions] as? NSNumber)?.intValue
        let writable = fm.isWritableFile(atPath: binary.path)
        if !writable, let original {
            try fm.setAttributes([.posixPermissions: original | 0o200], ofItemAtPath: binary.path)
        }
        defer {
            if !writable, let original { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: binary.path) }
        }
        let handle = try FileHandle(forUpdating: binary)
        defer { try? handle.close() }
        for slot in slots {
            try handle.seek(toOffset: UInt64(slot.digestOffset))
            try handle.write(contentsOf: digest)
        }
        try handle.synchronize()
    }

    public static func matches(appURL: URL) throws -> Bool? {
        guard let binary = try binary(in: appURL) else { return nil }
        let used = try slots(inBinary: binary).filter(\.used)
        guard !used.isEmpty else { return nil }
        guard used.allSatisfy({ $0.version == supportedVersion }), let integrity = try integrity(ofApp: appURL) else { return false }
        let expected = try digest(of: integrity)
        return used.allSatisfy { $0.digest == expected }
    }
}
