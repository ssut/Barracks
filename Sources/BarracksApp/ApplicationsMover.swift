import AppKit
import BarracksCore

@MainActor
enum ApplicationsMover {
    static let suppressKey = "moveToApplicationsSuppressed"

    static func installFolders() -> [URL] {
        [URL(filePath: "/Applications", directoryHint: .isDirectory),
         FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    static func isInstalled(_ bundle: URL) -> Bool {
        let path = bundle.resolvingSymlinksInPath().path
        return installFolders().contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
    }

    static func promptIfNeeded() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        guard !isInstalled(bundle) else { return }
        guard SignatureInfo.inspect(bundle).kind != .adhoc else {
            Log.debug("mover.skipped", ["reason": "development_build"])
            return
        }
        guard !UserDefaults.standard.bool(forKey: suppressKey) else {
            Log.info("mover.skipped", ["reason": "suppressed"])
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move Barracks to Applications?"
        alert.informativeText = "Updates only work from the Applications folder."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressKey) }
        guard response == .alertFirstButtonReturn else {
            Log.info("mover.declined", ["suppressed": String(alert.suppressionButton?.state == .on)])
            return
        }
        do {
            let destination = try move(bundle)
            relaunch(from: destination)
        } catch {
            Log.error("mover.failed", ["error": error.localizedDescription])
            let failure = NSAlert()
            failure.messageText = "Couldn't move Barracks"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    static func move(_ bundle: URL) throws -> URL {
        let fm = FileManager.default
        let system = installFolders()[0]
        let folder = fm.isWritableFile(atPath: system.path) ? system : installFolders()[1]
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: "Barracks.app", directoryHint: .isDirectory)
        if fm.fileExists(atPath: destination.path) {
            let existing = Bundle(url: destination)?.bundleIdentifier
            guard existing == Bundle.main.bundleIdentifier else {
                throw BarracksError.foreignBundleAtTarget(destination.path)
            }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: existing ?? "")
                .contains { $0.bundleURL?.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path }
            guard !running else { throw BarracksError.profileRunning("Barracks in \(folder.lastPathComponent)") }
            try fm.trashItem(at: destination, resultingItemURL: nil)
            Log.info("mover.replaced_previous", ["path": destination.path])
        }
        try ProcessRunner.run("/usr/bin/ditto", [bundle.path, destination.path])
        Log.notice("mover.copied", ["from": bundle.path, "to": destination.path])
        return destination
    }

    static func relaunch(from destination: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    Log.error("mover.relaunch_failed", ["error": error.localizedDescription])
                    return
                }
                Log.notice("mover.relaunched", ["path": destination.path])
                NSApp.terminate(nil)
            }
        }
    }
}
