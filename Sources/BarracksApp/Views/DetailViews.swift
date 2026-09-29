import BarracksCore
import SwiftUI

struct StatCard: View {
    var title: String
    var value: String
    var detail: String?
    var tint: Color?
    var minHeight: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(tint ?? .secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

struct PathRow: View {
    @Environment(AppModel.self) private var model
    var title: String
    var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(path.trimmingSlash)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    model.reveal(path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy path")
            }
        }
    }
}

struct AccountCard: View {
    var info: AccountInfo?
    var provider: AppProvider

    var body: some View {
        if let info, let headline = info.headline {
            StatCard(title: "Account", value: headline, detail: detail(info), minHeight: 0)
        } else {
            StatCard(title: "Account", value: info == nil ? "…" : "Not signed in", detail: info?.toolEmail.map { "\(provider.toolName): \($0)" }, minHeight: 0)
        }
    }

    func detail(_ info: AccountInfo) -> String? {
        var parts: [String] = []
        if let name = info.personName { parts.append(name) }
        if let plan = info.plan { parts.append(plan) }
        if let tool = info.toolEmail, tool != info.email { parts.append("\(provider.toolName): \(tool)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum Formatting {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "…" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        if abs(date.timeIntervalSinceNow) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .named))
    }

    static func day(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "Today" : date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 38, height: 38)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(.quaternary))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

struct RunControls<MenuItems: View>: View {
    var running: Bool
    var tint: Color
    var canLaunch: Bool
    var busy: Bool
    var rebuildHint: String?
    var onStart: () -> Void
    var onStop: () -> Void
    var onFront: () -> Void
    var onRebuild: () -> Void
    @ViewBuilder var menuItems: () -> MenuItems

    var body: some View {
        HStack(spacing: 10) {
            if let rebuildHint, !running {
                Button("Rebuild", action: onRebuild)
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .help(rebuildHint)
                    .disabled(busy)
            }
            if running {
                Button(action: onFront) {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(CircleIconButtonStyle(fill: Color.secondary.opacity(0.12), foreground: .primary))
                .help("Bring to Front")
                .disabled(busy)
            }
            Button(action: running ? onStop : onStart) {
                Image(systemName: running ? "stop.fill" : "play.fill")
            }
            .buttonStyle(CircleIconButtonStyle(fill: running ? Color.secondary.opacity(0.12) : tint, foreground: running ? .primary : .white))
            .help(running ? "Quit" : "Launch")
            .disabled(busy || (!running && !canLaunch))
            ZStack {
                Circle().fill(Color.secondary.opacity(0.12))
                Circle().strokeBorder(.quaternary)
                Menu {
                    menuItems()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .frame(width: 38, height: 38)
            .help("More")
        }
    }
}

struct DetailHeader<Controls: View>: View {
    var tint: ProfileTint
    var iconName: String
    var provider: AppProvider
    var title: String
    var state: RuntimeState
    var badge: String? = nil
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(spacing: 18) {
            ProfileIconView(tint: tint, name: iconName, provider: provider, size: 88)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusDot(state: state)
                    Text(state.summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 12)
            controls()
        }
    }
}

extension ProfileTint {
    var color: Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1) }
}

struct ProfileDetailView: View {
    @Environment(AppModel.self) private var model
    var row: ProfileRow

    var profile: Profile { row.profile }

    var lastActive: String {
        if row.state.isRunning { return "Running now" }
        let candidates = [profile.lastLaunchedAt, model.lastActivity[profile.dataDirectory]].compactMap { $0 }
        return Formatting.relative(candidates.max())
    }

    var versionDetail: (String, Color?) {
        switch row.staleness {
        case .current: ("Up to date", nil)
        case .appUpdated(_, let to): ("→ \(to)", .orange)
        default: ("Rebuild needed", .orange)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailHeader(tint: profile.tint, iconName: profile.name, provider: profile.provider, title: profile.name, state: row.state, badge: profile.usesComputerUseMode ? "Computer Use" : nil) {
                    RunControls(
                        running: row.state.isRunning,
                        tint: profile.tint.color,
                        canLaunch: row.staleness != .appMissing && row.staleness != .neverBuilt,
                        busy: model.isBusy,
                        rebuildHint: row.staleness.needsRebuild ? row.staleness.summary : nil,
                        onStart: { model.launch(row) },
                        onStop: { model.stop(row) },
                        onFront: { model.launch(row) },
                        onRebuild: { model.rebuild(profile) }
                    ) {
                        Button("Edit…") { model.editingProfile = profile }
                            .disabled(model.isBusy)
                        Button("Rebuild") { model.rebuild(profile) }
                            .disabled(model.isBusy || row.state.isRunning)
                        Button("Verify Isolation") { model.verify(profile) }
                        if let app = profile.appBundlePath {
                            Button("Show App in Finder") { model.reveal(app) }
                        }
                        if row.state.isRunning {
                            Divider()
                            Button("Force Quit") { model.stop(row, force: true) }
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { model.deletingProfile = profile }
                            .disabled(model.isBusy || row.state.isRunning)
                    }
                }
                AccountCard(info: model.accounts[profile.dataDirectory], provider: profile.provider)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    StatCard(title: "Storage", value: Formatting.bytes(model.storage[profile.dataDirectory]))
                    StatCard(title: "Last active", value: lastActive)
                    StatCard(title: "Created", value: Formatting.day(profile.createdAt))
                    StatCard(title: "\(profile.provider.displayName) version", value: profile.build?.appVersion ?? "—", detail: versionDetail.0, tint: versionDetail.1)
                }
                PathRow(title: "Data directory", path: profile.dataDirectory)
                PathRow(title: "\(profile.provider.toolName) config", path: profile.toolConfigDirectory ?? "~/\(profile.provider.officialToolHomeRelativePath)")
                if let app = profile.appBundlePath {
                    PathRow(title: "App", path: app)
                }
                if case .dataInUseElsewhere(let pid, let executable) = row.state {
                    Label("In use by \(URL(filePath: executable).lastPathComponent) (\(pid))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .padding(28)
        }
    }
}

struct OfficialDetailView: View {
    @Environment(AppModel.self) private var model
    var provider: AppProvider

    var body: some View {
        if let row = model.officials[provider] {
            let installation = row.official.installation
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DetailHeader(tint: .preset(.slate), iconName: provider.officialIconName, provider: provider, title: "Default", state: row.state) {
                        RunControls(
                            running: row.state.isRunning,
                            tint: .accentColor,
                            canLaunch: true,
                            busy: model.isBusy,
                            rebuildHint: nil,
                            onStart: { model.launchOfficial(row) },
                            onStop: { model.stopOfficial(row) },
                            onFront: { model.launchOfficial(row) },
                            onRebuild: {}
                        ) {
                            Button("Change \(provider.appBundleName)…") { model.chooseApp(for: provider) }
                            Button("Show App in Finder") { model.reveal(installation.appURL.path(percentEncoded: false)) }
                            Button("Show Data in Finder") { model.reveal(row.dataPath) }
                            if row.state.isRunning {
                                Divider()
                                Button("Force Quit") { model.stopOfficial(row, force: true) }
                            }
                        }
                    }
                    AccountCard(info: model.accounts[row.dataPath], provider: provider)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                        StatCard(title: "Storage", value: Formatting.bytes(model.storage[row.dataPath]))
                        StatCard(title: "Last active", value: row.state.isRunning ? "Running now" : Formatting.relative(model.lastActivity[row.dataPath]))
                        StatCard(title: "\(provider.displayName) version", value: installation.version, detail: installation.signatureSummary, tint: installation.isOfficiallySigned ? nil : .orange)
                    }
                    PathRow(title: "Data directory", path: row.dataPath)
                    PathRow(title: "\(provider.toolName) config", path: row.official.toolHome.path(percentEncoded: false))
                    PathRow(title: "App", path: installation.appURL.path(percentEncoded: false))
                }
                .padding(28)
            }
        } else {
            ContentUnavailableView {
                Label("\(provider.displayName) not found", systemImage: "questionmark.app.dashed")
            } actions: {
                Button("Choose \(provider.appBundleName)…") { model.chooseApp(for: provider) }
                Button("Refresh") { model.reloadAll() }
            }
        }
    }
}

extension String {
    var trimmingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
