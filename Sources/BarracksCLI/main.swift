import BarracksCore
import Foundation

struct CLI {
    var arguments: [String]
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []

    init(_ raw: [String]) {
        arguments = raw
        var index = 0
        while index < raw.count {
            let arg = raw[index]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if let eq = key.firstIndex(of: "=") {
                    options[String(key[..<eq])] = String(key[key.index(after: eq)...])
                } else if ["color", "adopt", "root", "name", "out", "provider", "computer-use"].contains(key), index + 1 < raw.count {
                    options[key] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(key)
                }
            } else {
                positionals.append(arg)
            }
            index += 1
        }
    }
}

func printLine(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

func emitJSON(_ object: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
        printLine(String(decoding: data, as: UTF8.self))
    }
}

func printReport(_ title: String, _ report: VerificationReport) {
    printLine("\(title): \(report.passed ? "PASS" : "FAIL")")
    report.checks.forEach { printLine("  ok    \($0)") }
    report.warnings.forEach { printLine("  warn  \($0)") }
    report.failures.forEach { printLine("  FAIL  \($0)") }
}

let usage = """
usage: barracks <command> [options]
  detect                                 show the installed apps profiles are built from
  list                                   list profiles with status, version and account
  create <name> [--provider claude|chatgpt] [--color c] [--adopt <dir>] [--share-tool-config] [--seed-tool-config] [--computer-use on]
  rebuild <profile> | --all
  edit <profile> [--name n] [--color c] [--computer-use on|off]
  launch <profile> | --official [--provider p]
  stop <profile> [--force] | --official [--provider p]
  delete <profile> [--delete-data]
  verify <profile>
  account <profile> | --official [--provider p]
  discover
  icon <out.icns> [--barracks | --color c --name n --provider p] [--png]
global: --root <dir> keeps apps/data/logs under <dir> (for testing), --verbose
colors: \(ProfileColor.allCases.map(\.rawValue).joined(separator: ", ")) or #RRGGBB
"""

let cli = CLI(Array(CommandLine.arguments.dropFirst()))
let paths = cli.options["root"].map { BarracksPaths.sandboxed(root: URL(filePath: $0, directoryHint: .isDirectory)) } ?? .standard()
BarracksLogger.shared.configure(fileURL: paths.logFileURL, minimumLevel: cli.flags.contains("verbose") ? .debug : .info, mirrorToStderr: cli.flags.contains("verbose"))
let manager = ProfileManager(paths: paths)
let progress: @Sendable (BuildStep) -> Void = { step in FileHandle.standardError.write(Data("… \(step.rawValue)\n".utf8)) }

func parseProvider(_ raw: String?) throws -> AppProvider {
    guard let raw else { return .claude }
    guard let provider = AppProvider(rawValue: raw.lowercased()) else {
        throw BarracksError.invalidProfileName("unknown provider \(raw); use \(AppProvider.allCases.map(\.rawValue).joined(separator: " or "))")
    }
    return provider
}

func parseTint(_ raw: String?, default fallback: ProfileTint?) throws -> ProfileTint? {
    guard let raw else { return fallback }
    guard let tint = ProfileTint.parse(raw) else {
        throw BarracksError.invalidProfileName("unknown color \(raw); use a preset or #RRGGBB")
    }
    return tint
}

func run() throws -> Int32 {
    guard let command = cli.positionals.first else {
        printLine(usage)
        return 64
    }
    let rest = Array(cli.positionals.dropFirst())
    Log.info("cli.command", ["command": command])
    switch command {
    case "detect":
        var rows: [[String: String]] = []
        for provider in AppProvider.allCases {
            do {
                let installation = try manager.installation(for: provider)
                rows.append([
                    "provider": provider.rawValue,
                    "path": installation.appURL.path,
                    "bundleIdentifier": installation.bundleIdentifier,
                    "version": installation.version,
                    "build": installation.build,
                    "signature": installation.signatureSummary,
                    "teamIdentifier": installation.signature.teamIdentifier ?? "",
                    "asarSHA256": try FingerprintCache.shared.sha256(for: installation),
                ])
            } catch {
                rows.append(["provider": provider.rawValue, "error": error.localizedDescription])
            }
        }
        emitJSON(rows)
    case "list":
        let profiles = try manager.listProfiles()
        for provider in AppProvider.allCases {
            let official = try? manager.official(for: provider)
            printLine("\(provider.displayName)")
            if let official {
                printLine("  [official] \(official.installation.version) — \(official.installation.signatureSummary) — \(manager.officialState(official).summary) — \(manager.officialAccount(for: provider).headline ?? "not signed in")")
            } else {
                printLine("  [official] not installed")
            }
            for profile in profiles where profile.provider == provider {
                let version = profile.build?.appVersion ?? "-"
                printLine("  \(profile.name) [\(profile.token)] — \(manager.state(of: profile).summary) — \(version) — \(manager.staleness(of: profile, installation: official?.installation).summary) — \(manager.account(of: profile).headline ?? "not signed in")")
                printLine("      data: \(profile.dataDirectory)")
                printLine("      app:  \(profile.appBundlePath ?? "-")")
            }
        }
    case "create":
        guard let name = rest.first else { printLine(usage); return 64 }
        let profile = try manager.createProfile(CreateProfileRequest(
            provider: try parseProvider(cli.options["provider"]),
            name: name,
            tint: try parseTint(cli.options["color"], default: .preset(.clay)) ?? .preset(.clay),
            adoptDataDirectory: cli.options["adopt"],
            isolateToolConfig: !cli.flags.contains("share-tool-config"),
            seedToolConfig: cli.flags.contains("seed-tool-config"),
            computerUseMode: cli.options["computer-use"] == "on"
        ), progress: progress)
        printLine("created \(profile.displayName) → \(profile.appBundlePath ?? "")")
    case "rebuild":
        let targets = cli.flags.contains("all") ? try manager.listProfiles() : [try manager.resolve(rest.first ?? "")]
        var failures: Int32 = 0
        for profile in targets {
            do {
                let rebuilt = try manager.rebuild(id: profile.id, progress: progress)
                printLine("rebuilt \(rebuilt.displayName) from \(rebuilt.build?.appVersion ?? "?")")
            } catch {
                failures += 1
                printLine("failed \(profile.name): \(error.localizedDescription)")
            }
        }
        return failures == 0 ? 0 : 1
    case "edit":
        let profile = try manager.resolve(rest.first ?? "")
        let updated = try manager.editProfile(id: profile.id, name: cli.options["name"], tint: try parseTint(cli.options["color"], default: nil), computerUseMode: cli.options["computer-use"].map { $0 == "on" }, progress: progress)
        printLine("updated \(updated.name)")
    case "launch":
        if cli.flags.contains("official") {
            printLine("launched pid \(try manager.launchOfficial(try manager.official(for: try parseProvider(cli.options["provider"]))))")
        } else {
            let profile = try manager.resolve(rest.first ?? "")
            printLine("launched \(profile.name) pid \(try manager.launch(id: profile.id))")
        }
    case "stop":
        if cli.flags.contains("official") {
            try manager.stopOfficial(try manager.official(for: try parseProvider(cli.options["provider"])), force: cli.flags.contains("force"))
        } else {
            let profile = try manager.resolve(rest.first ?? "")
            try manager.stop(id: profile.id, force: cli.flags.contains("force"))
        }
        printLine("stopped")
    case "delete":
        let profile = try manager.resolve(rest.first ?? "")
        try manager.deleteProfile(id: profile.id, data: cli.flags.contains("delete-data") ? .moveDataToTrash : .keepData)
        printLine("deleted \(profile.name)\(cli.flags.contains("delete-data") ? " (data moved to Trash)" : " (data kept at \(profile.dataDirectory))")")
    case "verify":
        let profile = try manager.resolve(rest.first ?? "")
        let (bundle, runtime) = try manager.verify(id: profile.id)
        printReport("bundle", bundle)
        printReport("runtime", runtime)
        return bundle.passed && runtime.passed ? 0 : 1
    case "account":
        let info = cli.flags.contains("official") ? manager.officialAccount(for: try parseProvider(cli.options["provider"])) : manager.account(of: try manager.resolve(rest.first ?? ""))
        emitJSON([
            "accountUUID": info.accountUUID ?? "",
            "email": info.email ?? "",
            "fullName": info.fullName ?? "",
            "displayName": info.displayName ?? "",
            "plan": info.plan ?? "",
            "toolEmail": info.toolEmail ?? "",
        ])
    case "discover":
        for clone in manager.unmanagedClones() {
            printLine("unmanaged app: \(clone.displayName) — \(clone.appPath) — data \(clone.dataDirectory ?? "unknown")")
        }
        for dir in manager.adoptableDataDirectories() {
            let users = dir.usedBy.isEmpty ? "" : " — used by \(dir.usedBy.joined(separator: ", "))"
            printLine("adoptable data: \(dir.path) (suggested name \(dir.suggestedName))\(users)")
        }
    case "icon":
        guard let out = rest.first else { printLine(usage); return 64 }
        let url = URL(filePath: out)
        if cli.flags.contains("png") {
            let image = cli.flags.contains("barracks")
                ? IconComposer.renderAppIcon(size: 1024)
                : IconComposer.renderProfileIcon(tint: try parseTint(cli.options["color"], default: .preset(.clay)) ?? .preset(.clay), name: cli.options["name"] ?? "P", provider: try parseProvider(cli.options["provider"]), size: 1024)
            guard let image else { return 1 }
            try IconComposer.writePNG(image, to: url)
        } else if cli.flags.contains("barracks") {
            try IconComposer.writeAppIcns(to: url)
        } else {
            try IconComposer.writeProfileIcns(tint: try parseTint(cli.options["color"], default: .preset(.clay)) ?? .preset(.clay), name: cli.options["name"] ?? "P", provider: try parseProvider(cli.options["provider"]), to: url)
        }
        printLine("wrote \(url.path)")
    default:
        printLine(usage)
        return 64
    }
    return 0
}

do {
    exit(try run())
} catch {
    Log.error("cli.failed", ["error": error.localizedDescription])
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
