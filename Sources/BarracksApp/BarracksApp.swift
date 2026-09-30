import AppKit
import BarracksCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.applicationIconImage = IconComposer.appImage(points: 256)
        }
        Telemetry.start()
        NSApp.activate()
        ApplicationsMover.promptIfNeeded()
        Telemetry.askIfNeeded()
        UpdateCoordinator.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BarracksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model: AppModel

    init() {
        let root = ProcessInfo.processInfo.environment["BARRACKS_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
        let paths = root.map { BarracksPaths.sandboxed(root: URL(filePath: $0, directoryHint: .isDirectory)) } ?? .standard()
        BarracksLogger.shared.configure(fileURL: paths.logFileURL, minimumLevel: .info)
        Log.info("app.paths", ["sandboxed": String(root != nil), "support": paths.supportRoot.path])
        _model = State(initialValue: AppModel(manager: ProfileManager(paths: paths)))
    }

    var body: some Scene {
        Window("Barracks", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateCoordinator.shared.checkForUpdates() }
                if Telemetry.isAvailable {
                    Toggle("Share Usage Data", isOn: Binding(get: { Telemetry.isEnabled }, set: { Telemetry.isEnabled = $0 }))
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Profile…") { model.beginNewProfile() }
                    .keyboardShortcut("n")
                    .disabled(model.isBusy || model.installedProviders.isEmpty)
            }
            CommandMenu("Profile") {
                Button("Launch or Switch") {
                    if let row = model.selectedRow { model.launch(row) } else if let official = model.selectedOfficial { model.launchOfficial(official) }
                }
                .keyboardShortcut("l")
                .disabled(model.isBusy)
                Button("Edit…") { model.editingProfile = model.selectedRow?.profile }
                    .keyboardShortcut("e")
                    .disabled(model.selectedRow == nil || model.isBusy)
                Button("Rebuild") { if let row = model.selectedRow { model.rebuild(row.profile) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selectedRow == nil || model.isBusy)
                Divider()
                Button("Delete…") { if let profile = model.selectedRow?.profile { model.requestDelete(profile) } }
                    .keyboardShortcut(.delete)
                    .disabled(model.selectedRow == nil || model.isBusy)
                Divider()
                Button("Refresh") { model.reloadAll() }
                    .keyboardShortcut("r")
                Button("Open Logs Folder") { model.openLogs() }
            }
        }
    }
}
