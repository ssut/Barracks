import AppKit
import BarracksCore
import SwiftUI

@MainActor
enum IconCache {
    static var images: [String: NSImage] = [:]

    static func profile(tint: ProfileTint, name: String, provider: AppProvider, points: Int) -> NSImage {
        let key = "\(provider.rawValue)|\(tint.cacheKey)|\(IconComposer.initial(of: name))|\(points)"
        if let cached = images[key] { return cached }
        if images.count > 400 { images.removeAll() }
        let image = IconComposer.profileImage(tint: tint, name: name, provider: provider, points: points)
        images[key] = image
        return image
    }

    static func app(points: Int) -> NSImage {
        let key = "app|\(points)"
        if let cached = images[key] { return cached }
        let image = IconComposer.appImage(points: points)
        images[key] = image
        return image
    }
}

struct ProfileIconView: View {
    var tint: ProfileTint
    var name: String
    var provider: AppProvider = .claude
    var size: CGFloat

    var body: some View {
        Image(nsImage: IconCache.profile(tint: tint, name: name, provider: provider, points: Int(max(size, 16))))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: IconCache.app(points: Int(max(size, 16))))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    var state: RuntimeState
    var columnWidth: CGFloat?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .frame(width: columnWidth)
            .help(state.summary)
    }

    var color: Color {
        switch state {
        case .running: .green
        case .notRunning: .clear
        case .dataInUseElsewhere: .orange
        }
    }
}

struct StarburstShape: Shape {
    var rays = 10

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for index in 0..<rays {
            let angle = Double(index) / Double(rays) * 2 * .pi - .pi / 2
            let inner = 2.6 * unit
            let outer = (index.isMultiple(of: 2) ? 10.2 : 8.2) * unit
            path.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
            path.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
        }
        return path
    }
}

struct ApertureShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * unit, y: rect.midY - 12 * unit)
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }
        var path = Path()
        path.addEllipse(in: CGRect(origin: point(2, 2), size: CGSize(width: 20 * unit, height: 20 * unit)))
        let segments: [((Double, Double), (Double, Double))] = [
            ((14.31, 8), (20.05, 17.94)),
            ((9.69, 8), (21.17, 8)),
            ((7.38, 12), (13.12, 2.06)),
            ((9.69, 16), (3.95, 6.06)),
            ((14.31, 16), (2.83, 16)),
            ((16.62, 12), (10.88, 21.94)),
        ]
        for (start, end) in segments {
            path.move(to: point(start.0, start.1))
            path.addLine(to: point(end.0, end.1))
        }
        return path
    }
}

struct ProviderGlyph: View {
    var provider: AppProvider
    var size: CGFloat = 13

    var body: some View {
        let style = StrokeStyle(lineWidth: max(1, size / 24 * 2), lineCap: .round, lineJoin: .round)
        Group {
            switch provider {
            case .claude: StarburstShape().stroke(style: style)
            case .chatgpt: ApertureShape().stroke(style: style)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension AppProvider {
    var officialIconName: String { "Default" }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(Array(model.visibleProviders.enumerated()), id: \.element) { index, provider in
                SidebarSectionHeader(provider: provider)
                    .padding(.top, index == 0 ? 0 : 8)
                    .selectionDisabled()
                if let official = model.officials[provider] {
                    HStack(spacing: 10) {
                        ProfileIconView(tint: .preset(.slate), name: provider.officialIconName, provider: provider, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Default")
                            if let account = model.accounts[official.dataPath]?.headline {
                                Text(account)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        StatusDot(state: official.state, columnWidth: 14)
                    }
                    .tag(SidebarSelection.official(provider))
                }
                ForEach(model.filteredRows(for: provider)) { row in
                    ProfileSidebarRow(row: row)
                        .tag(SidebarSelection.profile(row.id))
                }
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search")
    }
}

struct SidebarSectionHeader: View {
    @Environment(AppModel.self) private var model
    var provider: AppProvider

    var body: some View {
        HStack(spacing: 6) {
            ProviderGlyph(provider: provider, size: 13)
            Text(provider.displayName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                model.beginNewProfile(provider, locked: true)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New \(provider.displayName) profile")
            .disabled(model.isBusy || model.officials[provider] == nil)
        }
        .foregroundStyle(.secondary)
    }
}

struct ProfileSidebarRow: View {
    @Environment(AppModel.self) private var model
    var row: ProfileRow

    var body: some View {
        HStack(spacing: 10) {
            ProfileIconView(tint: row.profile.tint, name: row.profile.name, provider: row.profile.provider, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.profile.name)
                if let account = model.accounts[row.profile.dataDirectory]?.headline {
                    Text(account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.middle)
                }
                if row.staleness.needsRebuild {
                    Text("Needs rebuild")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            StatusDot(state: row.state, columnWidth: 14)
        }
        .contextMenu {
            Button(row.state.isRunning ? "Switch To" : "Launch") { model.launch(row) }
            Button("Edit…") { model.editingProfile = row.profile }
            Button("Rebuild") { model.rebuild(row.profile) }
            Button("Show Data in Finder") { model.reveal(row.profile.dataDirectory) }
            Divider()
            Button("Delete…", role: .destructive) { model.deletingProfile = row.profile }
        }
    }
}
