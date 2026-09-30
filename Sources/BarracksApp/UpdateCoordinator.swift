import AppKit
import BarracksCore
import Sparkle

@MainActor
final class UpdateCoordinator: NSObject {
    enum Availability: Equatable {
        case ready
        case notBundled
        case feedMissing
        case keyMissing
        case startFailed(String)

        var reason: String {
            switch self {
            case .ready: "ready"
            case .notBundled: "not_bundled"
            case .feedMissing: "feed_url_missing"
            case .keyMissing: "public_key_missing"
            case .startFailed: "start_failed"
            }
        }

        var explanation: String {
            switch self {
            case .ready: ""
            case .notBundled: "Updates work only in the packaged Barracks.app."
            case .feedMissing, .keyMissing: "This build isn't set up for updates."
            case .startFailed(let detail): "The updater couldn't start: \(detail)"
            }
        }
    }

    static let shared = UpdateCoordinator()

    private var controller: SPUStandardUpdaterController?
    private(set) var availability: Availability = .notBundled

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    func start() {
        guard controller == nil else { return }
        availability = Self.resolveConfiguration()
        guard availability == .ready else {
            Log.notice("update.inactive", ["reason": availability.reason])
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
        } catch {
            availability = .startFailed(error.localizedDescription)
            Log.error("update.start_failed", ["error": error.localizedDescription])
            return
        }
        self.controller = controller
        Log.info("update.started", [
            "version": currentVersion,
            "automatic": String(controller.updater.automaticallyChecksForUpdates),
            "interval": String(Int(controller.updater.updateCheckInterval)),
        ])
    }

    func checkForUpdates() {
        guard let updater = controller?.updater else {
            Log.notice("update.manual_refused", ["reason": availability.reason])
            let alert = NSAlert()
            alert.messageText = "Updates unavailable"
            alert.informativeText = availability.explanation
            alert.runModal()
            return
        }
        guard updater.canCheckForUpdates else {
            Log.notice("update.manual_refused", ["reason": "check_in_progress"])
            return
        }
        Log.info("update.manual_check", ["version": currentVersion])
        updater.checkForUpdates()
    }

    private static func resolveConfiguration() -> Availability {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .notBundled }
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard !feed.isEmpty, URL(string: feed) != nil else { return .feedMissing }
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, !key.hasPrefix("__") else { return .keyMissing }
        return .ready
    }
}

extension UpdateCoordinator: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.info("update.found", ["version": item.displayVersionString, "build": item.versionString])
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.info("update.none", [:])
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        guard code != Int(SUError.noUpdateError.rawValue) else { return }
        Log.error("update.aborted", ["code": String(code), "error": error.localizedDescription])
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Log.notice("update.installing", ["version": item.displayVersionString, "build": item.versionString])
    }
}
