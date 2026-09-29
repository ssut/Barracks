import AppKit
import Foundation

public enum RuntimeState: Sendable, Equatable {
    case notRunning
    case running(pid: Int32, since: Date?)
    case dataInUseElsewhere(pid: Int32, executable: String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .notRunning: "Not running"
        case .running: "Running"
        case .dataInUseElsewhere(let pid, let executable): "Data folder in use by \(URL(filePath: executable).lastPathComponent) (pid \(pid))"
        }
    }
}

public enum ProfileRuntime {
    public static func state(appURL: URL?, bundleIdentifier: String, dataDirectory: URL) -> RuntimeState {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { app in
            guard let appURL, let bundleURL = app.bundleURL else { return appURL == nil }
            return bundleURL.standardizedPath == appURL.standardizedPath
        }
        if let app = apps.first(where: { !$0.isTerminated }) {
            return .running(pid: app.processIdentifier, since: app.launchDate)
        }
        if let owner = ProcessInspector.singletonLockOwner(dataDirectory: dataDirectory) {
            if let appURL, URL(filePath: owner.executablePath).isSameOrDescendant(of: appURL) {
                return .running(pid: owner.pid, since: nil)
            }
            return .dataInUseElsewhere(pid: owner.pid, executable: owner.executablePath)
        }
        return .notRunning
    }

    public static func launch(appURL: URL, environment: [String: String], dataDirectory: URL, arguments: [String] = [], newInstance: Bool = false) throws -> Int32 {
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw BarracksError.appBundleMissing(appURL.path)
        }
        if let owner = ProcessInspector.singletonLockOwner(dataDirectory: dataDirectory),
           !URL(filePath: owner.executablePath).isSameOrDescendant(of: appURL) {
            throw BarracksError.profileDataInUse(path: dataDirectory.path, pid: owner.pid, executable: owner.executablePath)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = newInstance
        configuration.environment = environment
        configuration.arguments = arguments
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var launchedPID: Int32 = 0
        nonisolated(unsafe) var launchError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            launchedPID = app?.processIdentifier ?? 0
            launchError = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 60) == .timedOut {
            throw BarracksError.launchFailed("Launch Services did not respond within 60 seconds")
        }
        if let launchError {
            Log.error("runtime.launch_failed", ["app": appURL.path, "error": launchError.localizedDescription])
            throw BarracksError.launchFailed(launchError.localizedDescription)
        }
        if launchedPID <= 0 {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let first = ProcessInspector.processes(inside: appURL).map(\.pid).min() {
                    launchedPID = first
                    break
                }
                usleep(200_000)
            }
        }
        Log.notice("runtime.launched", ["app": appURL.path, "pid": String(launchedPID)])
        return launchedPID
    }

    public static func stop(appURL: URL?, bundleIdentifier: String, name: String, force: Bool, timeout: TimeInterval = 15) throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { app in
            guard let appURL, let bundleURL = app.bundleURL else { return appURL == nil }
            return bundleURL.standardizedPath == appURL.standardizedPath
        }
        guard !apps.isEmpty else { return }
        for app in apps {
            let sent = force ? app.forceTerminate() : app.terminate()
            Log.info("runtime.stop_requested", ["name": name, "pid": String(app.processIdentifier), "force": String(force), "sent": String(sent)])
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if apps.allSatisfy(\.isTerminated) || apps.allSatisfy({ !ProcessInspector.isAlive($0.processIdentifier) }) {
                Log.notice("runtime.stopped", ["name": name])
                return
            }
            usleep(200_000)
        }
        throw BarracksError.stopTimedOut(name)
    }

    public static func lastActivity(dataDirectory: URL) -> Date? {
        let candidates = ["Local State", "Preferences", "config.json"].map { dataDirectory.appending(path: $0) }
        return candidates.compactMap { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }.max()
    }
}
