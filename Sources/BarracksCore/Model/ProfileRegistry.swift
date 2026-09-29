import Foundation

struct ProfileRegistryFile: Codable {
    var schemaVersion: Int
    var profiles: [Profile]
}

public struct BarracksSettings: Codable, Sendable, Equatable {
    public var appPathOverrides: [String: String]

    public init(appPathOverrides: [String: String] = [:]) {
        self.appPathOverrides = appPathOverrides
    }

    public func override(for provider: AppProvider) -> String? {
        appPathOverrides[provider.rawValue]
    }
}

public final class ProfileRegistry: @unchecked Sendable {
    public static let schemaVersion = 1

    private let paths: BarracksPaths
    private let memoryLock = NSLock()

    public init(paths: BarracksPaths) {
        self.paths = paths
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func load() throws -> [Profile] {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        return try FileLock.withLock(at: paths.lockURL) { try readUnlocked() }
    }

    @discardableResult
    public func mutate<T>(_ body: (inout [Profile]) throws -> T) throws -> T {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        return try FileLock.withLock(at: paths.lockURL) {
            var profiles = try readUnlocked()
            let before = profiles
            let result = try body(&profiles)
            if profiles != before {
                try writeUnlocked(profiles)
            }
            return result
        }
    }

    private func readUnlocked() throws -> [Profile] {
        let url = paths.registryURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let file: ProfileRegistryFile
        do {
            file = try Self.makeDecoder().decode(ProfileRegistryFile.self, from: data)
        } catch {
            Log.error("registry.decode_failed", ["path": url.path, "error": String(describing: error)])
            throw BarracksError.registryCorrupt(error.localizedDescription)
        }
        guard file.schemaVersion <= Self.schemaVersion else {
            throw BarracksError.registryCorrupt("written by a newer Barracks (schema \(file.schemaVersion))")
        }
        Self.auditConsistency(file.profiles)
        return file.profiles
    }

    private func writeUnlocked(_ profiles: [Profile]) throws {
        let url = paths.registryURL
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        let data = try Self.makeEncoder().encode(ProfileRegistryFile(schemaVersion: Self.schemaVersion, profiles: profiles))
        try FileOps.writeAtomically(data, to: url)
        Log.info("registry.saved", ["profiles": String(profiles.count)])
    }

    static func auditConsistency(_ profiles: [Profile]) {
        func duplicates(_ values: [String]) -> [String] {
            Dictionary(grouping: values, by: { $0 }).filter { $0.value.count > 1 }.map(\.key)
        }
        let dupIDs = duplicates(profiles.map(\.id.uuidString))
        let dupData = duplicates(profiles.map { URL(filePath: $0.dataDirectory).standardizedPath })
        let dupBundles = duplicates(profiles.map(\.bundleIdentifier))
        if !dupIDs.isEmpty || !dupData.isEmpty || !dupBundles.isEmpty {
            Log.error("registry.inconsistent", [
                "duplicate_ids": dupIDs.joined(separator: ","),
                "duplicate_data_dirs": dupData.joined(separator: ","),
                "duplicate_bundle_ids": dupBundles.joined(separator: ","),
            ])
        }
    }

    public func loadSettings() -> BarracksSettings {
        guard let data = try? Data(contentsOf: paths.settingsURL),
              let settings = try? Self.makeDecoder().decode(BarracksSettings.self, from: data)
        else { return BarracksSettings() }
        return settings
    }

    public func saveSettings(_ settings: BarracksSettings) throws {
        let data = try Self.makeEncoder().encode(settings)
        try FileOps.writeAtomically(data, to: paths.settingsURL)
        Log.info("settings.saved", ["overrides": settings.appPathOverrides.keys.sorted().joined(separator: ",")])
    }
}
