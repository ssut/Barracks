import Foundation

public struct BarracksPaths: Sendable, Equatable {
    public var home: URL
    public var supportRoot: URL
    public var appsRoot: URL
    public var logsRoot: URL
    public var registersWithLaunchServices: Bool

    public init(home: URL, supportRoot: URL, appsRoot: URL, logsRoot: URL, registersWithLaunchServices: Bool) {
        self.home = home
        self.supportRoot = supportRoot
        self.appsRoot = appsRoot
        self.logsRoot = logsRoot
        self.registersWithLaunchServices = registersWithLaunchServices
    }

    public func officialDataDirectory(for provider: AppProvider) -> URL {
        applicationSupportDirectory.appending(path: provider.officialDataFolderName, directoryHint: .isDirectory)
    }

    public func officialToolHome(for provider: AppProvider) -> URL {
        home.appending(path: provider.officialToolHomeRelativePath, directoryHint: .isDirectory)
    }

    public var allOfficialDataDirectories: [URL] {
        AppProvider.allCases.map { officialDataDirectory(for: $0) }
    }

    public static func standard() -> BarracksPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return BarracksPaths(
            home: home,
            supportRoot: appSupport.appending(path: "Barracks", directoryHint: .isDirectory),
            appsRoot: home.appending(path: "Applications/Barracks", directoryHint: .isDirectory),
            logsRoot: home.appending(path: "Library/Logs/Barracks", directoryHint: .isDirectory),
            registersWithLaunchServices: true
        )
    }

    public static func sandboxed(root: URL) -> BarracksPaths {
        let standard = BarracksPaths.standard()
        return BarracksPaths(
            home: standard.home,
            supportRoot: root.appending(path: "Support", directoryHint: .isDirectory),
            appsRoot: root.appending(path: "Applications", directoryHint: .isDirectory),
            logsRoot: root.appending(path: "Logs", directoryHint: .isDirectory),
            registersWithLaunchServices: false
        )
    }

    public var applicationSupportDirectory: URL {
        home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }

    public var registryURL: URL { supportRoot.appending(path: "profiles.json") }
    public var settingsURL: URL { supportRoot.appending(path: "settings.json") }
    public var lockURL: URL { supportRoot.appending(path: ".registry.lock") }
    public var profilesDataRoot: URL { supportRoot.appending(path: "Profiles", directoryHint: .isDirectory) }
    public var stagingRoot: URL { supportRoot.appending(path: "Staging", directoryHint: .isDirectory) }
    public var computerUseAppsRoot: URL { supportRoot.appending(path: "Apps.noindex", directoryHint: .isDirectory) }
    public var logFileURL: URL { logsRoot.appending(path: "barracks.jsonl") }

    public func ensureBaseDirectories() throws {
        let fm = FileManager.default
        for url in [supportRoot, profilesDataRoot, stagingRoot, logsRoot] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.createDirectory(at: appsRoot, withIntermediateDirectories: true)
    }
}

extension URL {
    var standardizedPath: String { standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false) }

    func isSameOrDescendant(of other: URL) -> Bool {
        let me = standardizedPath
        let parent = other.standardizedPath
        if me == parent { return true }
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        return me.hasPrefix(prefix)
    }
}
