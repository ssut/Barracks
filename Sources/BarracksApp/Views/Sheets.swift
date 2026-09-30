import AppKit
import BarracksCore
import SwiftUI

struct ColorPickerRow: View {
    @Binding var selection: ProfileTint
    var name: String
    var provider: AppProvider

    var customBinding: Binding<Color> {
        Binding(
            get: {
                let rgb = selection.rgb
                return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
            },
            set: { newValue in
                guard let converted = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                selection = .custom(RGBColor(red: Double(converted.redComponent), green: Double(converted.greenComponent), blue: Double(converted.blueComponent)))
            }
        )
    }

    var isCustom: Bool {
        if case .custom = selection { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProfileColor.allCases, id: \.self) { color in
                Button {
                    selection = .preset(color)
                } label: {
                    ProfileIconView(tint: .preset(color), name: name.isEmpty ? "?" : name, provider: provider, size: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selection == .preset(color) ? Color.primary : Color.clear, lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName)
            }
            ColorPicker("Custom", selection: customBinding, supportsOpacity: false)
                .labelsHidden()
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isCustom ? Color.primary : Color.clear, lineWidth: 2).padding(-3))
                .help(isCustom ? selection.cacheKey : "Custom")
        }
    }
}

enum DataChoice: Hashable {
    case fresh
    case adopt(String)
    case choose
}

extension ExtraPatchStatus {
    func canToggle(from isOn: Bool) -> Bool {
        isAvailable || isOn
    }
}

struct ExtraToggle: View {
    @Binding var isOn: Bool
    var status: ExtraPatchStatus

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                Text("Apply Extra plugins")
                InfoButton {
                    ExtraInfo(status: status)
                }
            }
        }
        .disabled(!status.canToggle(from: isOn))
    }
}

struct ExtraInfo: View {
    var status: ExtraPatchStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apply Extra plugins")
                .font(.headline)
            Text("Adds claude-desktop-extra features (themes, panels, fonts and more) to this profile. The Default Claude stays untouched.")
                .fixedSize(horizontal: false, vertical: true)
            if let reason = status.reason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }
}

struct NewProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AppProvider = .claude
    @State private var name = ""
    @State private var tint: ProfileTint = .preset(.clay)
    @State private var dataChoice: DataChoice = .fresh
    @State private var applyExtras = true
    @State private var seedToolConfig = true
    @State private var computerUseMode = false
    @State private var candidates: [AdoptableDataDirectory] = []
    @State private var customFolder: String?

    var validation: String? {
        do {
            let normalized = try ProfileNameRules.normalize(name)
            if model.rows.contains(where: { $0.profile.provider == provider && ProfileNameRules.isSameName($0.profile.name, normalized) }) {
                return "A profile with this name already exists."
            }
            return nil
        } catch {
            return name.isEmpty ? nil : error.localizedDescription
        }
    }

    var adoptedPath: String? {
        if case .adopt(let path) = dataChoice { return path }
        return nil
    }

    var adoptedUsers: [String] {
        guard let path = adoptedPath else { return [] }
        return candidates.first { $0.path == path }?.usedBy ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ProfileIconView(tint: tint, name: name.isEmpty ? "?" : name, provider: provider, size: 56)
                Text(model.newProfileProviderLocked ? "New \(provider.displayName) profile" : "New profile").font(.title2.weight(.semibold))
            }
            Form {
                if model.installedProviders.count > 1 && !model.newProfileProviderLocked {
                    Picker("App", selection: $provider) {
                        ForEach(model.installedProviders) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                TextField("Name", text: $name, prompt: Text("Work"))
                if let validation {
                    Text(validation).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Color") { ColorPickerRow(selection: $tint, name: name, provider: provider) }
                if provider == .claude {
                    Picker("Data", selection: $dataChoice) {
                        Text("New").tag(DataChoice.fresh)
                        ForEach(candidates) { candidate in
                            Text("\(candidate.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))").tag(DataChoice.adopt(candidate.path))
                        }
                        if let customFolder, !candidates.contains(where: { $0.path == customFolder }) {
                            Text("\(customFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))").tag(DataChoice.adopt(customFolder))
                        }
                        Divider()
                        Text("Choose Folder…").tag(DataChoice.choose)
                    }
                    if !adoptedUsers.isEmpty {
                        Label("Also used by \(adoptedUsers.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ExtraToggle(isOn: $applyExtras, status: model.extraStatus)
                } else {
                    Toggle("Copy Codex settings", isOn: $seedToolConfig)
                    Toggle(isOn: $computerUseMode) {
                        HStack(spacing: 6) {
                            Text("Computer Use mode")
                            InfoButton {
                                ComputerUseModeInfo()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.create(CreateProfileRequest(
                        provider: provider,
                        name: name,
                        tint: tint,
                        adoptDataDirectory: provider == .claude ? adoptedPath : nil,
                        isolateToolConfig: true,
                        seedToolConfig: provider == .chatgpt && seedToolConfig,
                        computerUseMode: provider.supportsComputerUseMode && computerUseMode,
                        applyExtras: provider == .claude && applyExtras
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || validation != nil)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task {
            let manager = model.manager
            candidates = await Task.detached { manager.adoptableDataDirectories() }.value
            provider = model.newProfileProvider
            applyExtras = model.extraStatus.isAvailable
            let used = Set(model.rows.map { $0.profile.tint })
            tint = ProfileColor.allCases.map { ProfileTint.preset($0) }.first { !used.contains($0) } ?? .preset(.clay)
        }
        .onChange(of: dataChoice) { previous, choice in
            if choice == .choose {
                dataChoice = previous
                DispatchQueue.main.async { chooseFolder() }
                return
            }
            guard name.isEmpty, case .adopt(let path) = choice else { return }
            if let suggestion = candidates.first(where: { $0.path == path })?.suggestedName {
                name = suggestion
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.manager.paths.applicationSupportDirectory
        panel.message = "Choose an existing Claude data folder to adopt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        customFolder = trimmed
        dataChoice = .adopt(trimmed)
    }
}

struct EditProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    @State private var name: String
    @State private var tint: ProfileTint
    @State private var computerUseMode: Bool
    @State private var applyExtras: Bool

    init(profile: Profile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _tint = State(initialValue: profile.tint)
        _computerUseMode = State(initialValue: profile.usesComputerUseMode)
        _applyExtras = State(initialValue: profile.usesExtras)
    }

    var running: Bool {
        model.rows.first { $0.id == profile.id }?.state.isRunning ?? false
    }

    var validation: String? {
        do {
            let normalized = try ProfileNameRules.normalize(name)
            if model.rows.contains(where: { $0.id != profile.id && $0.profile.provider == profile.provider && ProfileNameRules.isSameName($0.profile.name, normalized) }) {
                return "A profile with this name already exists."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ProfileIconView(tint: tint, name: name.isEmpty ? "?" : name, provider: profile.provider, size: 56)
                Text("Edit profile").font(.title2.weight(.semibold))
            }
            Form {
                TextField("Name", text: $name)
                if let validation {
                    Text(validation).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Color") { ColorPickerRow(selection: $tint, name: name, provider: profile.provider) }
                if profile.provider.supportsComputerUseMode {
                    Toggle(isOn: $computerUseMode) {
                        HStack(spacing: 6) {
                            Text("Computer Use mode")
                            InfoButton {
                                ComputerUseModeInfo()
                            }
                        }
                    }
                }
                if profile.provider == .claude {
                    ExtraToggle(isOn: $applyExtras, status: model.extraStatus)
                }
                if running {
                    Label("Running", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.edit(profile, name: name, tint: tint, computerUseMode: computerUseMode, applyExtras: applyExtras)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(validation != nil || running || (name == profile.name && tint == profile.tint && computerUseMode == profile.usesComputerUseMode && applyExtras == profile.usesExtras))
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

struct VerificationSheet: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var bundle: VerificationReport
    var runtime: VerificationReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("App bundle", bundle)
                    section("While running", runtime)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 460)
    }

    func section(_ heading: String, _ report: VerificationReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(heading, systemImage: report.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(report.passed ? .green : .red)
                .font(.headline)
            ForEach(report.checks, id: \.self) { Label($0, systemImage: "checkmark").font(.callout) }
            ForEach(report.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            ForEach(report.failures, id: \.self) { Label($0, systemImage: "xmark").font(.callout).foregroundStyle(.red) }
        }
    }
}

struct InfoButton<Content: View>: View {
    @State private var showing = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More info")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            content()
                .padding(14)
                .frame(width: 300, alignment: .leading)
        }
    }
}

struct ComputerUseModeInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Computer Use mode")
                .font(.headline)
            Text("Uses an unmodified copy of ChatGPT so Computer Use keeps working. Sign-in and data stay separate.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("Dock shows the original ChatGPT icon and name", systemImage: "dock.rectangle")
                Label("Launch it from Barracks only", systemImage: "play.circle")
                Label("Shares Accessibility and Screen Recording permissions with ChatGPT", systemImage: "lock.shield")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
