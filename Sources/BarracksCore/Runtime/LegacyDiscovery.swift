import Foundation

public struct UnmanagedClone: Sendable, Equatable, Identifiable {
    public var id: String { appPath }
    public var provider: AppProvider
    public var appPath: String
    public var bundleIdentifier: String
    public var displayName: String
    public var dataDirectory: String?
}

public struct AdoptableDataDirectory: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var suggestedName: String
    public var usedBy: [String]
    public var lastActivity: Date?
}

public enum LegacyDiscovery {
    static let ignoredFolders: Set<String> = ["Claude", "Claude-Work-Patcher", "Barracks"]
    static let chromiumMarkers = ["Local State", "Preferences", "Cookies", "config.json"]

    public static func unmanagedClones(paths: BarracksPaths) -> [UnmanagedClone] {
        let roots = [URL(filePath: "/Applications"), paths.home.appending(path: "Applications")]
        var found: [UnmanagedClone] = []
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for app in items where app.pathExtension == "app" {
                guard let values = try? PlistDocument.read(app.appending(path: "Contents/Info.plist")).values,
                      let bundleID = values["CFBundleIdentifier"] as? String,
                      values[InfoPlistKeys.profileID] == nil,
                      let provider = AppProvider.allCases.first(where: { bundleID.hasPrefix($0.officialBundleIdentifier + ".") })
                else { continue }
                let env = values["LSEnvironment"] as? [String: Any] ?? [:]
                guard provider.cloneMarkerEnvironmentKeys.contains(where: { env[$0] != nil }) else { continue }
                var dataDir = env[provider.dataDirectoryEnvironmentKey] as? String
                if dataDir == nil, let tool = env[provider.toolConfigEnvironmentKey] as? String, URL(filePath: tool).lastPathComponent == provider.toolConfigFolderName {
                    dataDir = URL(filePath: tool).deletingLastPathComponent().path(percentEncoded: false)
                }
                found.append(UnmanagedClone(
                    provider: provider,
                    appPath: app.path,
                    bundleIdentifier: bundleID,
                    displayName: values["CFBundleDisplayName"] as? String ?? app.deletingPathExtension().lastPathComponent,
                    dataDirectory: dataDir.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
                ))
            }
        }
        Log.info("discovery.unmanaged_clones", ["count": String(found.count)])
        return found
    }

    public static func adoptableDataDirectories(paths: BarracksPaths, profiles: [Profile]) -> [AdoptableDataDirectory] {
        let root = paths.applicationSupportDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let claimed = Set(profiles.map { URL(filePath: $0.dataDirectory).standardizedPath })
        let clones = unmanagedClones(paths: paths)
        var result: [AdoptableDataDirectory] = []
        for dir in items {
            let name = dir.lastPathComponent
            guard name.hasPrefix("Claude-"), !ignoredFolders.contains(name) else { continue }
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard !claimed.contains(dir.standardizedPath) else { continue }
            guard chromiumMarkers.contains(where: { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) }) else { continue }
            let users = clones.filter { clone in
                clone.dataDirectory.map { URL(filePath: $0).standardizedPath == dir.standardizedPath } ?? false
            }.map(\.displayName)
            result.append(AdoptableDataDirectory(
                path: dir.path(percentEncoded: false).hasSuffix("/") ? String(dir.path(percentEncoded: false).dropLast()) : dir.path(percentEncoded: false),
                suggestedName: String(name.dropFirst("Claude-".count)),
                usedBy: users,
                lastActivity: ProfileRuntime.lastActivity(dataDirectory: dir)
            ))
        }
        Log.info("discovery.adoptable", ["count": String(result.count)])
        return result.sorted { $0.path < $1.path }
    }
}
