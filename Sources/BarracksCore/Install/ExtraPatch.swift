import AppKit
import Foundation

public enum ExtraPatchStatus: Sendable, Equatable {
    case ready
    case unavailable(String)

    public var isAvailable: Bool { self == .ready }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    public static func current() -> ExtraPatchStatus {
        ExtraBundle.locate() == nil ? .unavailable("This Barracks build doesn't include Extra.") : .ready
    }
}

public struct LegacyClaudeWorkState: Sendable, Equatable {
    public var defaultPatched: Bool
    public var pristine: URL?
    public var workApp: URL?
    public var workData: URL?

    public init(defaultPatched: Bool = false, pristine: URL? = nil, workApp: URL? = nil, workData: URL? = nil) {
        self.defaultPatched = defaultPatched
        self.pristine = pristine
        self.workApp = workApp
        self.workData = workData
    }

    public var canRestoreDefault: Bool { defaultPatched && pristine != nil }
    public var canImportWork: Bool { workData != nil }
    public var isEmpty: Bool { !defaultPatched && workApp == nil && workData == nil }
}

public enum LegacyClaudeWork {
    public static let folderName = "Claude-Work-Patcher"
    public static let workBundleIdentifier = "com.anthropic.claudefordesktop.work"
    public static let workDataFolderName = "Claude-Work"

    public enum MainState: Sendable, Equatable {
        case clean
        case patched(pristine: URL?)
    }

    struct MainRecord: Equatable {
        var version: String
        var sourceSHA256: String
        var patchedSHA256: String
    }

    public static func root(paths: BarracksPaths) -> URL {
        paths.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    static func mainRecord(root: URL) -> MainRecord? {
        guard let text = try? String(contentsOf: root.appending(path: "main-source"), encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3, isSHA256(lines[1]), isSHA256(lines[2]) else { return nil }
        return MainRecord(version: lines[0], sourceSHA256: lines[1], patchedSHA256: lines[2])
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    public static func mainState(of main: AppInstallation, paths: BarracksPaths) -> MainState {
        guard main.provider == .claude, let record = mainRecord(root: root(paths: paths)) else { return .clean }
        guard let mainSHA = try? FingerprintCache.shared.sha256(for: main), mainSHA == record.patchedSHA256 else { return .clean }
        let pristine = root(paths: paths).appending(path: "pristine/Claude-\(record.sourceSHA256).app", directoryHint: .isDirectory)
        return .patched(pristine: FileManager.default.fileExists(atPath: pristine.path) ? pristine : nil)
    }

    public static func pristineInstallation(_ url: URL) throws -> AppInstallation {
        let installation = try AppLocator.inspect(url, provider: .claude)
        let sha = try FingerprintCache.shared.sha256(for: installation)
        let expected = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Claude-", with: "")
        guard sha == expected else {
            Log.error("legacy.pristine_mismatch", ["path": url.path])
            throw BarracksError.appInvalid(path: url.path, reason: "the original Claude backup does not match its recorded hash")
        }
        guard installation.signature.kind == .anthropic else {
            throw BarracksError.appInvalid(path: url.path, reason: "the original Claude backup is not signed by Anthropic")
        }
        return installation
    }

    public static func state(main: AppInstallation?, paths: BarracksPaths) -> LegacyClaudeWorkState {
        var state = LegacyClaudeWorkState(defaultPatched: false, pristine: nil, workApp: nil, workData: nil)
        if let main, case .patched(let pristine) = mainState(of: main, paths: paths) {
            state.defaultPatched = true
            state.pristine = pristine
        }
        let app = paths.home.appending(path: "Applications/Claude Work.app", directoryHint: .isDirectory)
        if let values = try? PlistDocument.read(app.appending(path: "Contents/Info.plist")).values,
           values["CFBundleIdentifier"] as? String == workBundleIdentifier {
            state.workApp = app
        }
        let data = paths.applicationSupportDirectory.appending(path: workDataFolderName, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: data.appending(path: "config.json").path) || FileManager.default.fileExists(atPath: data.appending(path: "Local State").path) {
            state.workData = data
        }
        return state
    }

    public static func workAppRunning(_ app: URL) -> Bool {
        !ProcessInspector.processes(inside: app).isEmpty
    }

    public static func restoreDefault(main: AppInstallation, paths: BarracksPaths) throws {
        guard case .patched(let pristineURL) = mainState(of: main, paths: paths) else {
            Log.info("legacy.restore_skipped", ["reason": "default Claude is not patched"])
            return
        }
        guard let pristineURL else {
            throw BarracksError.extraUnavailable("The original Claude backup is missing. Reinstall Claude from claude.ai/download instead.")
        }
        let pristine = try pristineInstallation(pristineURL)
        let target = main.appURL
        let staged = target.deletingLastPathComponent().appending(path: ".Claude restore-\(getpid()).app", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staged)
        Log.notice("legacy.restore_start", ["target": target.path, "version": pristine.version])
        let method = try FileOps.cloneOrCopyTree(from: pristine.appURL, to: staged)
        do {
            try CodeSigner.verify(appURL: staged)
            let stagedInstall = try AppLocator.inspect(staged, provider: .claude)
            guard stagedInstall.signature.kind == .anthropic else {
                throw BarracksError.signatureInvalid("the restored copy of Claude is not signed by Anthropic")
            }
            try FileOps.swapOrMove(staged: staged, target: target)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        do {
            try FileManager.default.trashItem(at: staged, resultingItemURL: nil)
        } catch {
            Log.warning("legacy.restore_trash_failed", ["error": error.localizedDescription])
            try? FileManager.default.removeItem(at: staged)
        }
        LaunchServices.register(target, enabled: paths.registersWithLaunchServices)
        Log.notice("legacy.restored_default", ["target": target.path, "method": method, "version": pristine.version])
    }

    public static func retireWorkApp(_ app: URL, paths: BarracksPaths) throws {
        guard let values = try? PlistDocument.read(app.appending(path: "Contents/Info.plist")).values,
              values["CFBundleIdentifier"] as? String == workBundleIdentifier
        else { throw BarracksError.foreignBundleAtTarget(app.path) }
        guard !workAppRunning(app) else { throw BarracksError.profileRunning("Claude Work") }
        LaunchServices.unregister(app, enabled: paths.registersWithLaunchServices)
        try FileManager.default.trashItem(at: app, resultingItemURL: nil)
        let applications = app.deletingLastPathComponent()
        let metadata = applications.appending(path: ".Claude-Work.source")
        if FileManager.default.fileExists(atPath: metadata.path) { try? FileManager.default.trashItem(at: metadata, resultingItemURL: nil) }
        let lock = applications.appending(path: ".Claude-Work.lock", directoryHint: .isDirectory)
        if (try? FileManager.default.contentsOfDirectory(atPath: lock.path))?.isEmpty == true { try? FileManager.default.removeItem(at: lock) }
        Log.notice("legacy.work_app_retired", ["app": app.path])
    }
}
