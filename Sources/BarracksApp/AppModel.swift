import AppKit
import BarracksCore
import Foundation
import Observation

enum SidebarSelection: Hashable {
    case official(AppProvider)
    case profile(UUID)
}

struct ProfileRow: Identifiable, Equatable {
    var profile: Profile
    var state: RuntimeState
    var staleness: Staleness
    var id: UUID { profile.id }
}

enum LegacyAction {
    case restoreDefault
    case importWork
}

struct QuitRequest {
    var target: QuitTarget
    var force: Bool
}

enum QuitTarget {
    case profile(ProfileRow)
    case official(OfficialRow)

    var title: String {
        switch self {
        case .profile(let row): row.profile.displayName
        case .official(let row): "\(row.provider.displayName) Default"
        }
    }

    var profileID: UUID? {
        if case .profile(let row) = self { return row.profile.id }
        return nil
    }

    var officialProvider: AppProvider? {
        if case .official(let row) = self { return row.provider }
        return nil
    }
}

struct OfficialRow: Equatable {
    var official: OfficialProfile
    var state: RuntimeState

    var provider: AppProvider { official.provider }
    var dataPath: String { official.dataDirectory.path(percentEncoded: false) }
}

@MainActor
@Observable
final class AppModel {
    let manager: ProfileManager
    var officials: [AppProvider: OfficialRow] = [:]
    var installationErrors: [AppProvider: String] = [:]
    var rows: [ProfileRow] = []
    var selection: SidebarSelection? = .official(.claude)
    var search = ""
    var busyMessage: String?
    var errorMessage: String?
    var storage: [String: Int64] = [:]
    var lastActivity: [String: Date] = [:]
    var accounts: [String: AccountInfo] = [:]
    var unmanagedClones: [UnmanagedClone] = []
    var extraStatus: ExtraPatchStatus = .ready
    var legacy = LegacyClaudeWorkState()
    var showingNewProfile = false
    var newProfileProvider: AppProvider = .claude
    var newProfileProviderLocked = false
    var editingProfile: Profile?
    var deletingProfile: Profile?
    var quitting: QuitRequest?
    var legacyAction: LegacyAction?
    var verification: (title: String, bundle: VerificationReport, runtime: VerificationReport)?

    private var timer: Timer?
    private var storageTask: Task<Void, Never>?

    init(manager: ProfileManager = ProfileManager()) {
        self.manager = manager
    }

    var installedProviders: [AppProvider] {
        AppProvider.allCases.filter { officials[$0] != nil }
    }

    var visibleProviders: [AppProvider] {
        AppProvider.allCases.filter { provider in officials[provider] != nil || rows.contains { $0.profile.provider == provider } }
    }

    func filteredRows(for provider: AppProvider) -> [ProfileRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let scoped = rows.filter { $0.profile.provider == provider }
        guard !query.isEmpty else { return scoped }
        return scoped.filter { row in
            row.profile.name.localizedCaseInsensitiveContains(query)
                || (accounts[row.profile.dataDirectory]?.headline?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var selectedRow: ProfileRow? {
        guard case .profile(let id) = selection else { return nil }
        return rows.first { $0.id == id }
    }

    var selectedOfficial: OfficialRow? {
        guard case .official(let provider) = selection else { return nil }
        return officials[provider]
    }

    var selectedProvider: AppProvider? {
        switch selection {
        case .official(let provider): provider
        case .profile: selectedRow?.profile.provider
        case nil: nil
        }
    }

    var isBusy: Bool { busyMessage != nil }

    func start() {
        Log.info("app.start", ["version": AppInfo.version])
        reloadAll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRuntime() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRuntime() }
            }
        }
    }

    func beginNewProfile(_ provider: AppProvider? = nil, locked: Bool = false) {
        newProfileProvider = provider ?? selectedProvider.flatMap { officials[$0] != nil ? $0 : nil } ?? installedProviders.first ?? .claude
        newProfileProviderLocked = locked && provider != nil
        showingNewProfile = true
    }

    func reloadAll() {
        let manager = manager
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> ([AppProvider: OfficialRow], [AppProvider: String], [ProfileRow], [UnmanagedClone], String?) in
                var officials: [AppProvider: OfficialRow] = [:]
                var errors: [AppProvider: String] = [:]
                for provider in AppProvider.allCases {
                    do {
                        let official = try manager.official(for: provider)
                        officials[provider] = OfficialRow(official: official, state: manager.officialState(official))
                    } catch {
                        errors[provider] = error.localizedDescription
                    }
                }
                var rows: [ProfileRow] = []
                var loadError: String?
                do {
                    rows = try manager.listProfiles().map { profile in
                        ProfileRow(profile: profile, state: manager.state(of: profile), staleness: manager.staleness(of: profile, installation: officials[profile.provider]?.official.installation))
                    }
                } catch {
                    loadError = error.localizedDescription
                }
                return (officials, errors, rows, manager.unmanagedClones(), loadError)
            }.value
            officials = loaded.0
            IconCache.updateSources(loaded.0.mapValues { $0.official.installation.appURL })
            installationErrors = loaded.1
            rows = loaded.2.sorted { $0.profile.name.localizedStandardCompare($1.profile.name) == .orderedAscending }
            unmanagedClones = loaded.3
            let extraInfo = await Task.detached(priority: .utility) { (manager.extraStatus(), manager.legacyState()) }.value
            extraStatus = extraInfo.0
            legacy = extraInfo.1
            if let loadError = loaded.4 { errorMessage = loadError }
            switch selection {
            case .profile(let id) where !rows.contains(where: { $0.id == id }):
                selection = installedProviders.first.map { .official($0) }
            case .official(let provider) where officials[provider] == nil:
                selection = installedProviders.first.map { .official($0) } ?? selection
            case nil:
                selection = installedProviders.first.map { .official($0) }
            default:
                break
            }
            refreshStorage()
        }
    }

    func refreshRuntime() {
        for index in rows.indices {
            let state = manager.state(of: rows[index].profile)
            if state != rows[index].state { rows[index].state = state }
        }
        for provider in Array(officials.keys) {
            guard let row = officials[provider] else { continue }
            let state = manager.officialState(row.official)
            if state != row.state { officials[provider]?.state = state }
        }
    }

    func refreshStorage() {
        storageTask?.cancel()
        let officialTargets: [(path: String, profile: Profile?, provider: AppProvider)] = officials.values.map { ($0.dataPath, nil, $0.provider) }
        let targets = rows.map { (path: $0.profile.dataDirectory, profile: Optional($0.profile), provider: $0.profile.provider) } + officialTargets
        let manager = manager
        storageTask = Task {
            for target in targets {
                if Task.isCancelled { return }
                let account = await Task.detached(priority: .utility) { () -> AccountInfo in
                    target.profile.map { manager.account(of: $0) } ?? manager.officialAccount(for: target.provider)
                }.value
                accounts[target.path] = account
            }
            for target in targets {
                if Task.isCancelled { return }
                let result = await Task.detached(priority: .utility) { () -> (Int64, Date?) in
                    let url = URL(filePath: target.path, directoryHint: .isDirectory)
                    return (FileOps.allocatedSize(of: url), ProfileRuntime.lastActivity(dataDirectory: url))
                }.value
                storage[target.path] = result.0
                if let date = result.1 { lastActivity[target.path] = date }
            }
        }
    }

    private func perform(_ message: String, _ work: @escaping @Sendable (ProfileManager, @escaping @Sendable (BuildStep) -> Void) throws -> Void) {
        guard !isBusy else { return }
        busyMessage = message
        let manager = manager
        let progress: @Sendable (BuildStep) -> Void = { step in
            Task { @MainActor [weak self] in self?.busyMessage = "\(message) — \(step.rawValue)…" }
        }
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try work(manager, progress)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            busyMessage = nil
            if let failure {
                Log.error("app.operation_failed", ["operation": message, "error": failure])
                errorMessage = failure
            }
            reloadAll()
        }
    }

    func create(_ request: CreateProfileRequest) {
        perform("Creating “\(request.provider.displayName) \(request.name)”") { manager, progress in
            let profile = try manager.createProfile(request, progress: progress)
            Task { @MainActor [weak self] in self?.selection = .profile(profile.id) }
        }
    }

    func edit(_ profile: Profile, name: String, tint: ProfileTint, computerUseMode: Bool, applyExtras: Bool) {
        perform("Updating “\(profile.displayName)”") { manager, progress in
            _ = try manager.editProfile(id: profile.id, name: name, tint: tint, computerUseMode: computerUseMode, applyExtras: applyExtras, progress: progress)
        }
    }

    func rebuild(_ profile: Profile) {
        perform("Rebuilding “\(profile.displayName)”") { manager, progress in
            _ = try manager.rebuild(id: profile.id, progress: progress)
        }
    }

    func rebuildAndLaunch(_ row: ProfileRow) {
        perform("Rebuilding “\(row.profile.displayName)”") { manager, progress in
            _ = try manager.rebuild(id: row.profile.id, progress: progress)
            try manager.launch(id: row.profile.id)
        }
    }

    func rebuildAllStale() {
        let stale = rows.filter { $0.staleness.needsRebuild && !$0.state.isRunning }.map(\.profile)
        guard !stale.isEmpty else { return }
        perform("Rebuilding \(stale.count) profile(s)") { manager, progress in
            var failures: [String] = []
            for profile in stale {
                do { _ = try manager.rebuild(id: profile.id, progress: progress) } catch { failures.append("\(profile.name): \(error.localizedDescription)") }
            }
            if !failures.isEmpty { throw BarracksError.installFailed(failures.joined(separator: "\n")) }
        }
    }

    func delete(_ profile: Profile, policy: DeleteDataPolicy) {
        perform("Deleting “\(profile.displayName)”") { manager, _ in
            try manager.deleteProfile(id: profile.id, data: policy)
        }
    }

    func launch(_ row: ProfileRow) {
        if row.state.isRunning, let app = row.profile.appBundleURL {
            activate(bundleIdentifier: row.profile.bundleIdentifier, appURL: app)
            return
        }
        perform("Launching “\(row.profile.displayName)”") { manager, _ in
            try manager.launch(id: row.profile.id)
        }
    }

    func requestQuit(_ target: QuitTarget, force: Bool = false) {
        Task { @MainActor in
            deletingProfile = nil
            quitting = QuitRequest(target: target, force: force)
        }
    }

    func requestDelete(_ profile: Profile) {
        selection = .profile(profile.id)
        Task { @MainActor in
            quitting = nil
            deletingProfile = profile
        }
    }

    func confirmDelete(policy: DeleteDataPolicy) {
        guard let profile = deletingProfile else { return }
        deletingProfile = nil
        Log.notice("app.delete_confirmed", ["profile": profile.id.uuidString, "policy": String(describing: policy)])
        delete(profile, policy: policy)
    }

    func dismissConfirmations() {
        quitting = nil
        deletingProfile = nil
        legacyAction = nil
    }

    func requestLegacy(_ action: LegacyAction) {
        Task { @MainActor in
            quitting = nil
            deletingProfile = nil
            legacyAction = action
        }
    }

    func confirmLegacy() {
        guard let action = legacyAction else { return }
        legacyAction = nil
        Log.notice("app.legacy_confirmed", ["action": String(describing: action)])
        switch action {
        case .restoreDefault:
            guard let official = officials[.claude]?.official else { return }
            perform("Restoring original Claude") { manager, _ in
                if manager.officialState(official).isRunning {
                    try manager.stopOfficial(official, force: false)
                }
                try manager.restoreDefaultClaude()
                _ = try manager.launchOfficial(try manager.official(for: .claude))
            }
        case .importWork:
            let workApp = legacy.workApp
            perform("Importing Claude Work") { manager, progress in
                if let workApp, LegacyClaudeWork.workAppRunning(workApp) {
                    try ProfileRuntime.stop(appURL: workApp, bundleIdentifier: LegacyClaudeWork.workBundleIdentifier, name: "Claude Work", force: false)
                }
                let profile = try manager.importClaudeWork(progress: progress)
                Task { @MainActor [weak self] in self?.selection = .profile(profile.id) }
            }
        }
    }

    func confirmQuit() {
        guard let request = quitting else { return }
        quitting = nil
        Log.notice("app.quit_confirmed", ["target": request.target.title, "force": String(request.force)])
        switch request.target {
        case .profile(let row): stop(row, force: request.force)
        case .official(let row): stopOfficial(row, force: request.force)
        }
    }

    func stop(_ row: ProfileRow, force: Bool = false) {
        perform("Quitting “\(row.profile.displayName)”") { manager, _ in
            try manager.stop(id: row.profile.id, force: force)
        }
    }

    func launchOfficial(_ row: OfficialRow) {
        if row.state.isRunning {
            activate(bundleIdentifier: row.official.installation.bundleIdentifier, appURL: row.official.installation.appURL)
            return
        }
        let official = row.official
        perform("Launching \(row.provider.displayName)") { manager, _ in
            try manager.launchOfficial(official)
        }
    }

    func stopOfficial(_ row: OfficialRow, force: Bool = false) {
        let official = row.official
        perform("Quitting \(row.provider.displayName)") { manager, _ in
            try manager.stopOfficial(official, force: force)
        }
    }

    func verify(_ profile: Profile) {
        let manager = manager
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(VerificationReport, VerificationReport), Error> in
                Result { try manager.verify(id: profile.id) }
            }.value
            switch outcome {
            case .success(let reports): verification = (profile.displayName, reports.0, reports.1)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    func chooseApp(for provider: AppProvider) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.message = provider.appBundleName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try manager.setAppOverride(url.path(percentEncoded: false), for: provider)
            reloadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func activate(bundleIdentifier: String, appURL: URL) {
        let match = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            $0.bundleURL?.standardizedFileURL.path == appURL.standardizedFileURL.path
        }
        match?.activate()
        Log.info("app.activate", ["bundle_id": bundleIdentifier, "found": String(match != nil)])
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    func openLogs() {
        NSWorkspace.shared.open(manager.paths.logsRoot)
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0-dev"
    }
}
