import AppKit
import BarracksCore
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics

struct TelemetryEvent: Sendable {
    var name: String
    var parameters: [String: String] = [:]
}

@MainActor
enum Telemetry {
    static let enabledKey = "telemetryEnabled"
    static let askedKey = "telemetryAsked"

    private static var configured = false
    private static var collecting = false

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            UserDefaults.standard.set(true, forKey: askedKey)
            apply(reason: "menu")
        }
    }

    static var isAvailable: Bool { configured }

    static func start() {
        guard !configured, FirebaseApp.app() == nil else { return }
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Log.info("telemetry.skipped", ["reason": "not_bundled"])
            return
        }
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path), !options.googleAppID.isEmpty
        else {
            Log.info("telemetry.skipped", ["reason": "config_absent"])
            return
        }
        guard options.bundleID == Bundle.main.bundleIdentifier else {
            Log.warning("telemetry.skipped", ["reason": "bundle_id_mismatch", "expected": options.bundleID])
            return
        }
        FirebaseApp.configure(options: options)
        guard FirebaseApp.app() != nil else {
            Log.error("telemetry.configure_failed", [:])
            return
        }
        Analytics.setUserID(nil)
        configured = true
        apply(reason: "start")
        Log.info("telemetry.started", ["project": options.projectID ?? "unknown", "collecting": String(collecting)])
    }

    static func askIfNeeded() {
        guard configured, !UserDefaults.standard.bool(forKey: askedKey) else { return }
        let alert = NSAlert()
        alert.messageText = "Share anonymous usage data?"
        alert.informativeText = "Crash reports and basic usage stats help improve Barracks. Account info is never sent."
        alert.addButton(withTitle: "Share")
        alert.addButton(withTitle: "Don't Share")
        let share = alert.runModal() == .alertFirstButtonReturn
        Log.notice("telemetry.consent", ["share": String(share)])
        isEnabled = share
    }

    private static func apply(reason: String) {
        guard configured else { return }
        let enabled = isEnabled
        let was = collecting
        collecting = enabled
        Analytics.setConsent([
            .analyticsStorage: enabled ? .granted : .denied,
            .adStorage: .denied,
            .adUserData: .denied,
            .adPersonalization: .denied,
        ])
        Analytics.setAnalyticsCollectionEnabled(enabled)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
        if was && !enabled { Analytics.resetAnalyticsData() }
        Log.info("telemetry.collection", ["enabled": String(enabled), "reason": reason])
    }

    static func log(_ event: TelemetryEvent) {
        guard collecting else { return }
        Analytics.logEvent(event.name, parameters: event.parameters.isEmpty ? nil : event.parameters)
        Log.debug("telemetry.event", ["name": event.name])
    }

    static func recordFailure(operation: String, kind: String) {
        guard collecting else { return }
        Analytics.logEvent("operation_failed", parameters: ["operation": operation, "kind": kind])
        let error = NSError(domain: "com.suhunhan.barracks.\(operation)", code: 1, userInfo: [NSLocalizedDescriptionKey: kind])
        Crashlytics.crashlytics().record(error: error)
        Log.debug("telemetry.failure", ["operation": operation, "kind": kind])
    }

    nonisolated static func kind(of error: Error) -> String {
        if let label = Mirror(reflecting: error).children.first?.label { return label }
        let text = String(describing: error)
        return text.count <= 40 && !text.contains("/") && !text.contains("@") ? text : String(describing: type(of: error))
    }

    nonisolated static func bucket(_ value: Int) -> String {
        switch value {
        case ..<1: "0"
        case 1: "1"
        case 2...3: "2_3"
        case 4...6: "4_6"
        case 7...10: "7_10"
        default: "11_plus"
        }
    }
}
