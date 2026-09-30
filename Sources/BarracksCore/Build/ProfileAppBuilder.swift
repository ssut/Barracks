import Foundation

public enum BuildStep: String, Sendable, CaseIterable {
    case preflight = "Checking app"
    case copying = "Copying app"
    case extra = "Applying Extra"
    case hooking = "Adding profile startup hook"
    case identity = "Setting app identity"
    case icon = "Drawing icon"
    case signing = "Signing"
    case verifying = "Verifying"
    case installing = "Installing"
}

public struct BuildRequest: Sendable {
    public var profile: Profile
    public var installation: AppInstallation
    public var targetAppURL: URL
    public var previousAppURL: URL?
}

public struct BuildOutcome: Sendable {
    public var appURL: URL
    public var record: ProfileBuildRecord
}

public final class ProfileAppBuilder: Sendable {
    public static let builderVersion = 6

    let paths: BarracksPaths

    public init(paths: BarracksPaths) {
        self.paths = paths
    }

    public func build(_ request: BuildRequest, progress: @Sendable (BuildStep) -> Void = { _ in }) throws -> BuildOutcome {
        let profile = request.profile
        let installation = request.installation
        if profile.usesComputerUseMode {
            return try buildComputerUseCopy(request, progress: progress)
        }
        let fields = ["profile": profile.id.uuidString, "provider": profile.provider.rawValue, "name": profile.name, "source": installation.appURL.path, "version": installation.version]
        Log.info("build.start", fields)
        let started = Date()

        progress(.preflight)
        guard installation.provider == profile.provider else {
            throw BarracksError.appInvalid(path: installation.appURL.path, reason: "it is \(installation.provider.displayName), profile is \(profile.provider.displayName)")
        }
        try paths.ensureBaseDirectories()
        let sourceSHA = try FingerprintCache.shared.sha256(for: installation)
        try checkDiskSpace(installation: installation)
        try guardTarget(request.targetAppURL, profile: profile)

        let workDir = paths.stagingRoot.appending(path: "\(profile.token)-\(Int(Date().timeIntervalSince1970))-\(getpid())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.removeItem(at: workDir)
            Log.debug("build.cleanup", ["work_dir": workDir.lastPathComponent])
        }
        let staged = workDir.appending(path: request.targetAppURL.lastPathComponent, directoryHint: .isDirectory)

        progress(.copying)
        let copyMethod = try FileOps.cloneOrCopyTree(from: installation.appURL, to: staged)
        let after = try AppLocator.inspect(installation.appURL, provider: installation.provider)
        guard after.version == installation.version, after.asarSize == installation.asarSize, after.asarModified == installation.asarModified else {
            throw BarracksError.sourceChangedDuringCopy
        }
        let stagedAsar = staged.appending(path: "Contents/Resources/app.asar")
        let stagedSHA = try Hashing.sha256Hex(fileAt: stagedAsar)
        guard stagedSHA == sourceSHA else { throw BarracksError.sourceChangedDuringCopy }
        Log.info("build.copied", ["method": copyMethod, "asar_sha256": sourceSHA])

        var extraSignature: String?
        if profile.usesExtras {
            progress(.extra)
            let base = try ExtraBuilder.base(for: installation, sourceSHA256: sourceSHA, paths: paths)
            try FileManager.default.removeItem(at: stagedAsar)
            try FileManager.default.copyItem(at: base, to: stagedAsar)
            extraSignature = try ExtraBuilder.signature(sourceSHA256: sourceSHA)
            Log.info("build.extra_applied", ["profile": profile.id.uuidString, "signature": extraSignature ?? ""])
        }

        progress(.hooking)
        let hooked: AsarWriteResult?
        if profile.provider.hooksAppArchive {
            hooked = try hookArchive(at: stagedAsar, config: ProfileBootstrapConfig(profile: profile), workDir: workDir)
        } else {
            hooked = nil
            Log.info("build.archive_untouched", ["profile": profile.id.uuidString, "provider": profile.provider.rawValue])
        }

        progress(.identity)
        try InfoPlistEditor.rewriteNestedBundleIdentifiers(appURL: staged, from: installation.bundleIdentifier, to: profile.bundleIdentifier)

        progress(.icon)
        var iconFile: String?
        IconRecolor.invalidate()
        do {
            let iconURL = staged.appending(path: "Contents/Resources/\(InfoPlistKeys.profileIconFile)")
            try IconComposer.writeProfileIcns(tint: profile.tint, name: profile.name, provider: profile.provider, sourceApp: installation.appURL, to: iconURL)
            iconFile = InfoPlistKeys.profileIconFile
        } catch {
            Log.warning("build.icon_failed", ["error": error.localizedDescription])
        }

        try InfoPlistEditor.applyMain(MainPlistEdit(
            bundleIdentifier: profile.bundleIdentifier,
            displayName: profile.displayName,
            environment: profile.launchEnvironment,
            asarHeaderSHA256: hooked?.headerSHA256,
            iconFile: iconFile,
            profileID: profile.id.uuidString,
            dataDirectory: profile.dataDirectory,
            builderVersion: Self.builderVersion,
            keysToRemove: profile.provider.infoPlistKeysToRemove,
            booleansToSet: profile.provider.infoPlistBooleansToSet,
            renameBundle: profile.provider.renamesBundleName
        ), appURL: staged)

        var realExecutable: String?
        if profile.provider.usesLaunchWrapper {
            realExecutable = try LaunchWrapper.install(appURL: staged, profile: profile)
        }

        progress(.signing)
        let entitlements = try CodeSigner.sanitizedEntitlements(of: installation.appURL)
        try CodeSigner.adhocSign(appURL: staged, entitlements: entitlements, scratch: workDir, secondaryExecutable: realExecutable)
        CodeSigner.removeQuarantine(appURL: staged)

        progress(.verifying)
        try CodeSigner.verify(appURL: staged)
        try CodeSigner.verifyNestedBundles(appURL: staged)
        let report = ProfileVerifier.verifyBundle(appURL: staged, profile: profile)
        guard report.passed else {
            throw BarracksError.verificationFailed(report.failures.joined(separator: "; "))
        }

        let appAsarSHA256 = try hooked?.fileSHA256 ?? Hashing.sha256Hex(fileAt: stagedAsar)

        progress(.installing)
        try install(staged: staged, request: request)
        try ensureDataDirectories(profile)

        let record = ProfileBuildRecord(
            appVersion: installation.version,
            appBuild: installation.build,
            sourceAppPath: installation.appURL.path,
            sourceAsarSHA256: sourceSHA,
            sourceSignature: installation.signature.kind.rawValue,
            builderVersion: Self.builderVersion,
            builtAt: Date(),
            appAsarSHA256: appAsarSHA256,
            copyMethod: copyMethod,
            extraSignature: extraSignature
        )
        var done = fields
        done["seconds"] = String(format: "%.1f", Date().timeIntervalSince(started))
        done["app"] = request.targetAppURL.path
        Log.notice("build.finished", done)
        return BuildOutcome(appURL: request.targetAppURL, record: record)
    }

    func buildComputerUseCopy(_ request: BuildRequest, progress: @Sendable (BuildStep) -> Void) throws -> BuildOutcome {
        let profile = request.profile
        let installation = request.installation
        let fields = ["profile": profile.id.uuidString, "provider": profile.provider.rawValue, "name": profile.name, "mode": "computer_use"]
        Log.info("build.start", fields)
        let started = Date()

        progress(.preflight)
        guard installation.provider == profile.provider else {
            throw BarracksError.appInvalid(path: installation.appURL.path, reason: "it is \(installation.provider.displayName), profile is \(profile.provider.displayName)")
        }
        guard installation.signature.teamIdentifier == profile.provider.vendorTeamIdentifier, installation.signature.kind != .adhoc else {
            throw BarracksError.appInvalid(path: installation.appURL.path, reason: "Computer Use mode needs the official, unmodified \(profile.provider.displayName)")
        }
        try paths.ensureBaseDirectories()
        let sourceSHA = try FingerprintCache.shared.sha256(for: installation)
        try checkDiskSpace(installation: installation)
        try guardTarget(request.targetAppURL, profile: profile)

        let workDir = paths.stagingRoot.appending(path: "\(profile.token)-\(Int(Date().timeIntervalSince1970))-\(getpid())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workDir) }
        let staged = workDir.appending(path: request.targetAppURL.lastPathComponent, directoryHint: .isDirectory)

        progress(.copying)
        let copyMethod = try FileOps.cloneOrCopyTree(from: installation.appURL, to: staged)
        let after = try AppLocator.inspect(installation.appURL, provider: installation.provider)
        guard after.version == installation.version, after.asarSize == installation.asarSize, after.asarModified == installation.asarModified else {
            throw BarracksError.sourceChangedDuringCopy
        }
        let stagedAsar = staged.appending(path: "Contents/Resources/app.asar")
        guard try Hashing.sha256Hex(fileAt: stagedAsar) == sourceSHA else { throw BarracksError.sourceChangedDuringCopy }
        CodeSigner.removeQuarantine(appURL: staged)

        progress(.verifying)
        try CodeSigner.verify(appURL: staged)
        let signature = SignatureInfo.inspect(staged)
        guard signature.teamIdentifier == profile.provider.vendorTeamIdentifier else {
            throw BarracksError.signatureInvalid("the copy is not signed by \(profile.provider.displayName)'s publisher")
        }

        progress(.installing)
        try guardTarget(request.targetAppURL, profile: profile)
        try FileOps.swapOrMove(staged: staged, target: request.targetAppURL)
        if FileManager.default.fileExists(atPath: staged.path) { try? FileManager.default.removeItem(at: staged) }
        try ProfileOwnership.writeSidecar(for: request.targetAppURL, profileID: profile.id)
        removePrevious(request)
        try ensureDataDirectories(profile)

        let record = ProfileBuildRecord(
            appVersion: installation.version,
            appBuild: installation.build,
            sourceAppPath: installation.appURL.path,
            sourceAsarSHA256: sourceSHA,
            sourceSignature: installation.signature.kind.rawValue,
            builderVersion: Self.builderVersion,
            builtAt: Date(),
            appAsarSHA256: sourceSHA,
            copyMethod: copyMethod
        )
        var done = fields
        done["seconds"] = String(format: "%.1f", Date().timeIntervalSince(started))
        done["app"] = request.targetAppURL.path
        Log.notice("build.finished", done)
        return BuildOutcome(appURL: request.targetAppURL, record: record)
    }

    func removePrevious(_ request: BuildRequest) {
        guard let previous = request.previousAppURL, previous.standardizedPath != request.targetAppURL.standardizedPath,
              FileManager.default.fileExists(atPath: previous.path) else { return }
        guard ProfileOwnership.isOwned(previous, by: request.profile.id) else {
            Log.warning("build.previous_not_owned", ["path": previous.path])
            return
        }
        LaunchServices.unregister(previous, enabled: paths.registersWithLaunchServices)
        try? FileManager.default.removeItem(at: previous)
        let parent = previous.deletingLastPathComponent()
        if parent.isSameOrDescendant(of: paths.computerUseAppsRoot), parent.standardizedPath != request.targetAppURL.deletingLastPathComponent().standardizedPath {
            try? FileManager.default.removeItem(at: parent)
        }
        Log.info("build.previous_removed", ["path": previous.path])
    }

    func hookArchive(at asarURL: URL, config: ProfileBootstrapConfig, workDir: URL) throws -> AsarWriteResult {
        let archive = try AsarArchive.open(asarURL)
        let packageData = try archive.readFile("package.json")
        guard let package = try JSONSerialization.jsonObject(with: packageData) as? [String: Any] else {
            throw BarracksError.mainEntryUnsupported("package.json is not an object")
        }
        if (package["type"] as? String) == "module" {
            throw BarracksError.mainEntryUnsupported("the app is an ES module package")
        }
        let main = (package["main"] as? String) ?? "index.js"
        let mainPath = main.hasPrefix("./") ? String(main.dropFirst(2)) : main
        let original = try archive.readFile(mainPath)
        guard try archive.verifyIntegrity(of: mainPath) else {
            throw BarracksError.asarMalformed("\(mainPath) does not match its recorded hash")
        }

        var baselineChecked = true
        do {
            try ProfileBootstrap.checkSyntax(original, label: mainPath)
        } catch {
            baselineChecked = false
            Log.warning("build.syntax_baseline_unsupported", ["entry": mainPath, "error": error.localizedDescription])
        }
        let hookedSource = try ProfileBootstrap.inject(into: original, config: config)
        if baselineChecked {
            try ProfileBootstrap.checkSyntax(hookedSource, label: mainPath)
        } else {
            try ProfileBootstrap.checkSyntax(Data(ProfileBootstrap.script(for: config).utf8), label: "bootstrap")
        }

        let output = workDir.appending(path: "app.asar")
        let result = try archive.write(to: output, replacing: [mainPath: hookedSource])
        let reopened = try AsarArchive.open(output)
        guard reopened.headerSHA256 == result.headerSHA256,
              try reopened.readFile(mainPath) == hookedSource,
              try reopened.verifyIntegrity(of: mainPath),
              try reopened.readFile("package.json") == packageData
        else {
            throw BarracksError.verificationFailed("rewritten app archive did not read back correctly")
        }
        try FileManager.default.removeItem(at: asarURL)
        try FileManager.default.moveItem(at: output, to: asarURL)
        Log.info("build.hooked", ["entry": mainPath, "syntax_checked": String(baselineChecked)])
        return result
    }

    func checkDiskSpace(installation: AppInstallation) throws {
        guard let available = FileOps.availableCapacity(at: paths.stagingRoot) else { return }
        let required = installation.asarSize * 3 + 512 * 1024 * 1024
        if available < required {
            throw BarracksError.insufficientDiskSpace(requiredBytes: required, availableBytes: available)
        }
    }

    func guardTarget(_ target: URL, profile: Profile) throws {
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard ProfileOwnership.isOwned(target, by: profile.id) else {
            throw BarracksError.foreignBundleAtTarget(target.path)
        }
    }

    func install(staged: URL, request: BuildRequest) throws {
        let target = request.targetAppURL
        try guardTarget(target, profile: request.profile)
        try FileOps.swapOrMove(staged: staged, target: target)
        if FileManager.default.fileExists(atPath: staged.path) {
            try? FileManager.default.removeItem(at: staged)
        }
        removePrevious(request)
        LaunchServices.register(target, enabled: paths.registersWithLaunchServices)
        Log.info("build.installed", ["path": target.path])
    }

    func ensureDataDirectories(_ profile: Profile) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: profile.dataDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let tool = profile.toolConfigDirectory {
            try fm.createDirectory(atPath: tool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}
