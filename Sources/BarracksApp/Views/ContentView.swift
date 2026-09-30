import BarracksCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            } detail: {
                Group {
                    if let row = model.selectedRow {
                        ProfileDetailView(row: row)
                    } else if case .official(let provider) = model.selection {
                        OfficialDetailView(provider: provider)
                    } else {
                        ContentUnavailableView("Select a profile", systemImage: "person.crop.square")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            FooterView()
        }
        .overlay {
            if let message = model.busyMessage {
                BusyOverlay(message: message)
            }
        }
        .sheet(isPresented: $model.showingNewProfile) {
            NewProfileSheet()
        }
        .sheet(item: $model.editingProfile) { profile in
            EditProfileSheet(profile: profile)
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { model.verification != nil }, set: { if !$0 { model.verification = nil } })) {
            if let verification = model.verification {
                VerificationSheet(title: verification.title, bundle: verification.bundle, runtime: verification.runtime)
            }
        }
    }
}

struct BusyOverlay: View {
    var message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(minWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct FooterView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            ForEach(AppProvider.allCases) { provider in
                if let installation = model.officials[provider]?.official.installation {
                    HStack(spacing: 5) {
                        ProviderGlyph(provider: provider, size: 12)
                            .foregroundStyle(.secondary)
                        Text("\(provider.displayName) \(installation.version)")
                            .monospacedDigit()
                    }
                    .help("\(installation.signatureSummary) · \(installation.appURL.path)")
                }
            }
            let stale = model.rows.filter { $0.staleness.needsRebuild }.count
            if stale > 0 {
                Button("Rebuild \(stale) outdated") { model.rebuildAllStale() }
                    .buttonStyle(.link)
                    .disabled(model.isBusy)
            }
            Spacer()
            Text("Barracks \(AppInfo.version)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
