import AppKit
import Foundation

public struct CreateProfileRequest: Sendable {
    public var provider: AppProvider
    public var name: String
    public var tint: ProfileTint
    public var adoptDataDirectory: String?
    public var isolateToolConfig: Bool
    public var seedToolConfig: Bool
    public var computerUseMode: Bool

    public init(provider: AppProvider = .claude, name: String, tint: ProfileTint, adoptDataDirectory: String? = nil, isolateToolConfig: Bool = true, seedToolConfig: Bool = false, computerUseMode: Bool = false) {
        self.computerUseMode = computerUseMode
        self.provider = provider
        self.name = name
        self.tint = tint
        self.adoptDataDirectory = adoptDataDirectory
        self.isolateToolConfig = isolateToolConfig
        self.seedToolConfig = seedToolConfig
    }
}

public enum Staleness: Sendable, Equatable {
    case current
    case neverBuilt
    case appMissing
    case builderUpdated
    case appUpdated(from: String, to: String)
    case sourceChanged

    public var needsRebuild: Bool { self != .current }

    public var summary: String {
        switch self {
        case .current: "Up to date"
        case .neverBuilt: "Not built yet"
        case .appMissing: "App missing"
        case .builderUpdated: "Rebuild needed"
        case .appUpdated(let from, let to): "\(from) → \(to)"
        case .sourceChanged: "Source app changed"
        }
    }
}

public enum DeleteDataPolicy: Sendable {
    case keepData
    case moveDataToTrash
}

public struct OfficialProfile: Sendable, Equatable {
    public var provider: AppProvider
    public var installation: AppInstallation
    public var dataDirectory: URL
    public var toolHome: URL
}

public final class ProfileManager: Sendable {
    public let paths: BarracksPaths
    public let registry: ProfileRegistry
    let builder: ProfileAppBuilder

    public init(paths: BarracksPaths = .standard()) {
        self.paths = paths
        self.registry = ProfileRegistry(paths: paths)
        self.builder = ProfileAppBuilder(paths: paths)
    }

    var operationLockURL: URL { paths.supportRoot.appending(path: ".operation.lock") }

    func exclusiveOperation<T>(_ name: String, _ body: () throws -> T) throws -> T {
        try paths.ensureBaseDirectories()
        do {
            return try FileLock.withLock(at: operationLockURL, timeout: 1) {
                Log.debug("operation.begin", ["operation": name])
                defer { Log.debug("operation.end", ["operation": name]) }
                return try body()
            }
        } catch let error as BarracksError {
            if case .lockUnavailable = error {
                throw BarracksError.lockUnavailable("another profile build or delete is running")
            }
            throw error
        }
    }

    public func settings() -> BarracksSettings { registry.loadSettings() }

    public func setAppOverride(_ path: String?, for provider: AppProvider) throws {
        if let path { _ = try AppLocator.inspect(URL(filePath: path, directoryHint: .isDirectory), provider: provider) }
        var settings = registry.loadSettings()
        settings.appPathOverrides[provider.rawValue] = path
        try registry.saveSettings(settings)
    }

    public func installation(for provider: AppProvider) throws -> AppInstallation {
        try AppLocator.locate(provider: provider, paths: paths, override: settings().override(for: provider))
    }

    public func official(for provider: AppProvider) throws -> OfficialProfile {
        OfficialProfile(
            provider: provider,
            installation: try installation(for: provider),
            dataDirectory: paths.officialDataDirectory(for: provider),
            toolHome: paths.officialToolHome(for: provider)
        )
    }

    public func listProfiles() throws -> [Profile] {
        try registry.load()
    }

    public func resolve(_ key: String, provider: AppProvider? = nil) throws -> Profile {
        let all = try registry.load()
        let profiles = provider.map { p in all.filter { $0.provider == p } } ?? all
        if let uuid = UUID(uuidString: key), let match = profiles.first(where: { $0.id == uuid }) { return match }
        if let match = profiles.first(where: { $0.token == key.lowercased() }) { return match }
        let byName = profiles.filter { ProfileNameRules.isSameName($0.name, key) || ProfileNameRules.isSameName($0.displayName, key) }
        if byName.count == 1 { return byName[0] }
        throw BarracksError.profileNotFound(key)
    }

    public func targetAppURL(forName name: String, provider: AppProvider) -> URL {
        paths.appsRoot.appending(path: ProfileNameRules.appBundleFileName(for: name, provider: provider), directoryHint: .isDirectory)
    }

    public func targetAppURL(for profile: Profile) -> URL {
        let fileName = ProfileNameRules.appBundleFileName(for: profile.name, provider: profile.provider)
        if profile.usesComputerUseMode {
            return paths.computerUseAppsRoot.appending(path: profile.token, directoryHint: .isDirectory).appending(path: fileName, directoryHint: .isDirectory)
        }
        return paths.appsRoot.appending(path: fileName, directoryHint: .isDirectory)
    }

    static func nameTaken(_ name: String, provider: AppProvider, in profiles: [Profile], excluding id: UUID? = nil) -> Bool {
        profiles.contains { $0.id != id && $0.provider == provider && ProfileNameRules.isSameName($0.name, name) }
    }

    public func createProfile(_ request: CreateProfileRequest, progress: @Sendable (BuildStep) -> Void = { _ in }) throws -> Profile {
        try exclusiveOperation("create") {
            let provider = request.provider
            let name = try ProfileNameRules.normalize(request.name)
            let existing = try registry.load()
            if Self.nameTaken(name, provider: provider, in: existing) {
                throw BarracksError.duplicateProfileName(name)
            }
            var id = UUID()
            while existing.contains(where: { $0.token == Profile.makeToken(from: id) }) { id = UUID() }
            let token = Profile.makeToken(from: id)

            let dataDirectory: String
            let adopted: Bool
            if let adopt = request.adoptDataDirectory {
                dataDirectory = try validateAdoption(adopt, existing: existing)
                adopted = true
            } else {
                dataDirectory = paths.profilesDataRoot.appending(path: token, directoryHint: .isDirectory).path(percentEncoded: false).trimmingTrailingSlash
                adopted = false
            }

            var profile = Profile(
                id: id,
                provider: provider,
                token: token,
                name: name,
                color: .clay,
                customColor: nil,
                createdAt: Date(),
                lastLaunchedAt: nil,
                dataDirectory: dataDirectory,
                dataDirectoryAdopted: adopted,
                isolateToolConfig: request.isolateToolConfig || provider.toolConfigAlwaysIsolated,
                bundleIdentifier: Profile.bundleIdentifier(forToken: token, provider: provider),
                appBundlePath: nil,
                build: nil
            )
            profile.apply(request.tint)
            if request.computerUseMode {
                guard provider.supportsComputerUseMode else {
                    throw BarracksError.appInvalid(path: provider.appBundleName, reason: "Computer Use mode is only available for ChatGPT")
                }
                profile.computerUseMode = true
                profile.bundleIdentifier = provider.officialBundleIdentifier
            }
            Log.notice("profile.create", ["profile": id.uuidString, "provider": provider.rawValue, "name": name, "adopted": String(adopted), "data": dataDirectory])

            let installation = try installation(for: provider)
            let target = targetAppURL(for: profile)
            let outcome = try builder.build(BuildRequest(profile: profile, installation: installation, targetAppURL: target, previousAppURL: nil), progress: progress)
            profile.appBundlePath = outcome.appURL.path(percentEncoded: false).trimmingTrailingSlash
            profile.build = outcome.record

            if request.seedToolConfig {
                seedToolConfig(for: profile)
            }

            do {
                let snapshot = profile
                try registry.mutate { profiles in
                    if Self.nameTaken(snapshot.name, provider: snapshot.provider, in: profiles) {
                        throw BarracksError.duplicateProfileName(snapshot.name)
                    }
                    profiles.append(snapshot)
                }
            } catch {
                Log.error("profile.register_failed", ["profile": id.uuidString, "error": error.localizedDescription])
                LaunchServices.unregister(outcome.appURL, enabled: paths.registersWithLaunchServices)
                try? FileManager.default.removeItem(at: outcome.appURL)
                throw error
            }
            return profile
        }
    }

    func seedToolConfig(for profile: Profile) {
        guard let destination = profile.toolConfigDirectory else { return }
        let source = paths.officialToolHome(for: profile.provider)
        let fm = FileManager.default
        var copied: [String] = []
        for file in profile.provider.seedableToolConfigFiles {
            let from = source.appending(path: file)
            let to = URL(filePath: destination, directoryHint: .isDirectory).appending(path: file)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.copyItem(at: from, to: to)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
                copied.append(file)
            } catch {
                Log.warning("profile.seed_failed", ["profile": profile.id.uuidString, "file": file, "error": error.localizedDescription])
            }
        }
        Log.info("profile.seeded", ["profile": profile.id.uuidString, "files": copied.joined(separator: ",")])
    }

    func validateAdoption(_ raw: String, existing: [Profile]) throws -> String {
        let url = URL(filePath: raw, directoryHint: .isDirectory).standardizedFileURL
        let path = url.path(percentEncoded: false).trimmingTrailingSlash
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BarracksError.dataDirectoryInvalid(path: path, reason: "it is not an existing folder")
        }
        for official in paths.allOfficialDataDirectories {
            if url.isSameOrDescendant(of: official) || official.isSameOrDescendant(of: url) {
                throw BarracksError.dataDirectoryInvalid(path: path, reason: "it is an official app's own data folder")
            }
        }
        if url.isSameOrDescendant(of: paths.appsRoot) || url.path.hasSuffix(".app") {
            throw BarracksError.dataDirectoryInvalid(path: path, reason: "it is inside an app bundle")
        }
        for profile in existing {
            let other = profile.dataDirectoryURL
            if url.isSameOrDescendant(of: other) || other.isSameOrDescendant(of: url) {
                throw BarracksError.dataDirectoryClaimed(path: path, profile: profile.displayName)
            }
        }
        if let owner = ProcessInspector.singletonLockOwner(dataDirectory: url) {
            throw BarracksError.profileDataInUse(path: path, pid: owner.pid, executable: owner.executablePath)
        }
        guard FileManager.default.isWritableFile(atPath: path) else {
            throw BarracksError.dataDirectoryInvalid(path: path, reason: "it is not writable")
        }
        return path
    }

    public func editProfile(id: UUID, name newName: String?, tint newTint: ProfileTint?, computerUseMode newMode: Bool? = nil, progress: @Sendable (BuildStep) -> Void = { _ in }) throws -> Profile {
        try exclusiveOperation("edit") {
            let profiles = try registry.load()
            guard var profile = profiles.first(where: { $0.id == id }) else { throw BarracksError.profileNotFound(id.uuidString) }
            var changed = false
            if let newName {
                let normalized = try ProfileNameRules.normalize(newName)
                if normalized != profile.name {
                    if Self.nameTaken(normalized, provider: profile.provider, in: profiles, excluding: id) {
                        throw BarracksError.duplicateProfileName(normalized)
                    }
                    profile.name = normalized
                    changed = true
                }
            }
            if let newTint, newTint != profile.tint {
                profile.apply(newTint)
                changed = true
            }
            if let newMode, newMode != profile.usesComputerUseMode {
                guard profile.provider.supportsComputerUseMode else {
                    throw BarracksError.appInvalid(path: profile.provider.appBundleName, reason: "Computer Use mode is only available for ChatGPT")
                }
                profile.computerUseMode = newMode
                profile.bundleIdentifier = newMode ? profile.provider.officialBundleIdentifier : Profile.bundleIdentifier(forToken: profile.token, provider: profile.provider)
                changed = true
            }
            guard changed else { return profile }
            Log.notice("profile.edit", ["profile": id.uuidString, "name": profile.name, "color": profile.tint.cacheKey])
            return try rebuildUnlocked(profile, progress: progress)
        }
    }

    public func rebuild(id: UUID, progress: @Sendable (BuildStep) -> Void = { _ in }) throws -> Profile {
        try exclusiveOperation("rebuild") {
            guard let profile = try registry.load().first(where: { $0.id == id }) else { throw BarracksError.profileNotFound(id.uuidString) }
            return try rebuildUnlocked(profile, progress: progress)
        }
    }

    func rebuildUnlocked(_ input: Profile, progress: @Sendable (BuildStep) -> Void = { _ in }) throws -> Profile {
        var profile = input
        let current = try registry.load().first(where: { $0.id == profile.id })
        let previousURL = current?.appBundleURL
        if state(of: current ?? profile).isRunning {
            throw BarracksError.profileRunning(profile.displayName)
        }
        let installation = try installation(for: profile.provider)
        let target = targetAppURL(for: profile)
        let outcome = try builder.build(BuildRequest(profile: profile, installation: installation, targetAppURL: target, previousAppURL: previousURL), progress: progress)
        profile.appBundlePath = outcome.appURL.path(percentEncoded: false).trimmingTrailingSlash
        profile.build = outcome.record
        let snapshot = profile
        try registry.mutate { profiles in
            guard let index = profiles.firstIndex(where: { $0.id == snapshot.id }) else { throw BarracksError.profileNotFound(snapshot.id.uuidString) }
            var merged = snapshot
            merged.lastLaunchedAt = profiles[index].lastLaunchedAt
            profiles[index] = merged
        }
        return profile
    }

    public func deleteProfile(id: UUID, data policy: DeleteDataPolicy) throws {
        try exclusiveOperation("delete") {
            guard let profile = try registry.load().first(where: { $0.id == id }) else { throw BarracksError.profileNotFound(id.uuidString) }
            if state(of: profile).isRunning { throw BarracksError.profileRunning(profile.displayName) }
            Log.notice("profile.delete", ["profile": id.uuidString, "name": profile.name, "data_policy": String(describing: policy)])
            if let app = profile.appBundleURL, FileManager.default.fileExists(atPath: app.path) {
                if ProfileOwnership.isOwned(app, by: profile.id) {
                    LaunchServices.unregister(app, enabled: paths.registersWithLaunchServices)
                    try FileManager.default.trashItem(at: app, resultingItemURL: nil)
                    let parent = app.deletingLastPathComponent()
                    if parent.isSameOrDescendant(of: paths.computerUseAppsRoot), parent.standardizedPath != paths.computerUseAppsRoot.standardizedPath {
                        try? FileManager.default.removeItem(at: parent)
                    }
                    Log.info("profile.app_trashed", ["path": app.path])
                } else {
                    Log.warning("profile.app_not_owned", ["path": app.path])
                }
            }
            if case .moveDataToTrash = policy, FileManager.default.fileExists(atPath: profile.dataDirectory) {
                if paths.allOfficialDataDirectories.contains(where: { $0.standardizedPath == profile.dataDirectoryURL.standardizedPath }) {
                    throw BarracksError.dataDirectoryInvalid(path: profile.dataDirectory, reason: "refusing to remove an official app's data folder")
                }
                try FileManager.default.trashItem(at: profile.dataDirectoryURL, resultingItemURL: nil)
                Log.info("profile.data_trashed", ["path": profile.dataDirectory])
            }
            try registry.mutate { profiles in profiles.removeAll { $0.id == id } }
        }
    }

    @discardableResult
    public func launch(id: UUID) throws -> Int32 {
        guard let profile = try registry.load().first(where: { $0.id == id }) else { throw BarracksError.profileNotFound(id.uuidString) }
        guard let app = profile.appBundleURL, profile.build != nil else { throw BarracksError.appBundleMissing(profile.appBundlePath ?? profile.displayName) }
        let report = ProfileVerifier.verifyBundle(appURL: app, profile: profile)
        guard report.passed else { throw BarracksError.verificationFailed(report.failures.joined(separator: "; ")) }
        let pid: Int32
        if profile.usesComputerUseMode {
            pid = try ProfileRuntime.launch(appURL: app, environment: profile.launchEnvironment, dataDirectory: profile.dataDirectoryURL, arguments: LaunchWrapper.launchArguments(for: profile), newInstance: true)
        } else {
            pid = try ProfileRuntime.launch(appURL: app, environment: profile.launchEnvironment, dataDirectory: profile.dataDirectoryURL)
        }
        try registry.mutate { profiles in
            if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index].lastLaunchedAt = Date() }
        }
        return pid
    }

    public func stop(id: UUID, force: Bool) throws {
        guard let profile = try registry.load().first(where: { $0.id == id }) else { throw BarracksError.profileNotFound(id.uuidString) }
        try ProfileRuntime.stop(appURL: profile.appBundleURL, bundleIdentifier: profile.bundleIdentifier, name: profile.displayName, force: force)
    }

    public func state(of profile: Profile) -> RuntimeState {
        ProfileRuntime.state(appURL: profile.appBundleURL, bundleIdentifier: profile.bundleIdentifier, dataDirectory: profile.dataDirectoryURL)
    }

    public func staleness(of profile: Profile, installation: AppInstallation?) -> Staleness {
        guard let build = profile.build else { return .neverBuilt }
        guard let app = profile.appBundleURL, FileManager.default.fileExists(atPath: app.path) else { return .appMissing }
        if build.builderVersion < ProfileAppBuilder.builderVersion { return .builderUpdated }
        guard let installation, installation.provider == profile.provider else { return .current }
        if installation.version != build.appVersion || installation.build != build.appBuild {
            return .appUpdated(from: build.appVersion, to: installation.version)
        }
        if let sha = try? FingerprintCache.shared.sha256(for: installation), sha != build.sourceAsarSHA256 { return .sourceChanged }
        return .current
    }

    public func officialState(_ official: OfficialProfile) -> RuntimeState {
        ProfileRuntime.state(appURL: official.installation.appURL, bundleIdentifier: official.installation.bundleIdentifier, dataDirectory: official.dataDirectory)
    }

    @discardableResult
    public func launchOfficial(_ official: OfficialProfile) throws -> Int32 {
        try ProfileRuntime.launch(appURL: official.installation.appURL, environment: [:], dataDirectory: official.dataDirectory)
    }

    public func stopOfficial(_ official: OfficialProfile, force: Bool) throws {
        try ProfileRuntime.stop(appURL: official.installation.appURL, bundleIdentifier: official.installation.bundleIdentifier, name: official.provider.displayName, force: force)
    }

    public func verify(id: UUID) throws -> (bundle: VerificationReport, runtime: VerificationReport) {
        let profiles = try registry.load()
        guard let profile = profiles.first(where: { $0.id == id }) else { throw BarracksError.profileNotFound(id.uuidString) }
        guard let app = profile.appBundleURL else { throw BarracksError.appBundleMissing(profile.displayName) }
        var bundle = ProfileVerifier.verifyBundle(appURL: app, profile: profile)
        do {
            try CodeSigner.verify(appURL: app)
            bundle.checks.append("code signature")
        } catch {
            bundle.failures.append(error.localizedDescription)
        }
        let sharedToolHomes = AppProvider.allCases.filter { !($0 == profile.provider && profile.toolConfigDirectory == nil) }
        let officialDirectories = paths.allOfficialDataDirectories + sharedToolHomes.map { paths.officialToolHome(for: $0) }
        let runtime = ProfileVerifier.verifyRunningIsolation(profile: profile, others: profiles, officialDirectories: officialDirectories)
        return (bundle, runtime)
    }

    public func account(of profile: Profile) -> AccountInfo {
        AccountInspector.inspect(
            provider: profile.provider,
            dataDirectory: profile.dataDirectoryURL,
            toolConfigDirectory: profile.toolConfigDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) },
            home: paths.home
        )
    }

    public func officialAccount(for provider: AppProvider) -> AccountInfo {
        AccountInspector.inspect(
            provider: provider,
            dataDirectory: paths.officialDataDirectory(for: provider),
            toolConfigDirectory: nil,
            home: paths.home
        )
    }

    public func unmanagedClones() -> [UnmanagedClone] {
        LegacyDiscovery.unmanagedClones(paths: paths)
    }

    public func adoptableDataDirectories() -> [AdoptableDataDirectory] {
        LegacyDiscovery.adoptableDataDirectories(paths: paths, profiles: (try? registry.load()) ?? [])
    }
}

extension String {
    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
