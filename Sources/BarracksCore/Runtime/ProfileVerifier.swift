import Foundation

public struct VerificationReport: Sendable {
    public var checks: [String]
    public var failures: [String]
    public var warnings: [String]

    public var passed: Bool { failures.isEmpty }
}

public enum ProfileVerifier {
    public static func verifyBundle(appURL: URL, profile: Profile) -> VerificationReport {
        var report = VerificationReport(checks: [], failures: [], warnings: [])
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                report.checks.append(label)
            } else {
                report.failures.append(detail.isEmpty ? label : "\(label): \(detail)")
            }
        }
        guard let plist = try? PlistDocument.read(appURL.appending(path: "Contents/Info.plist")).values else {
            report.failures.append("Info.plist unreadable")
            return report
        }
        if profile.usesComputerUseMode {
            check("bundle identifier", plist["CFBundleIdentifier"] as? String == profile.provider.officialBundleIdentifier)
            check("profile marker", ProfileOwnership.isOwned(appURL, by: profile.id))
            let signature = SignatureInfo.inspect(appURL)
            check("publisher signature kept", signature.teamIdentifier == profile.provider.vendorTeamIdentifier && signature.kind != .adhoc, signature.teamIdentifier ?? "none")
            check("hidden from Spotlight", appURL.path.contains(".noindex/"))
            Log.info("verify.bundle", ["profile": profile.id.uuidString, "mode": "computer_use", "passed": String(report.passed), "failures": report.failures.joined(separator: " | ")])
            return report
        }
        check("bundle identifier", plist["CFBundleIdentifier"] as? String == profile.bundleIdentifier, String(describing: plist["CFBundleIdentifier"]))
        check("profile marker", plist[InfoPlistKeys.profileID] as? String == profile.id.uuidString)
        let env = plist["LSEnvironment"] as? [String: Any] ?? [:]
        for (key, value) in profile.launchEnvironment.sorted(by: { $0.key < $1.key }) {
            check("launch environment \(key)", env[key] as? String == value)
        }
        if profile.toolConfigDirectory == nil {
            check("launch environment shares \(profile.provider.toolName) config", env[profile.provider.toolConfigEnvironmentKey] == nil)
        }
        for key in profile.provider.infoPlistKeysToRemove {
            check("removed \(key)", plist[key] == nil)
        }

        do {
            let archive = try AsarArchive.open(appURL.appending(path: "Contents/Resources/app.asar"))
            let integrity = (plist["ElectronAsarIntegrity"] as? [String: Any])?["Resources/app.asar"] as? [String: Any]
            if let expected = integrity?["hash"] as? String {
                check("archive integrity hash", expected == archive.headerSHA256, "Info.plist \(expected.prefix(12)) vs archive \(archive.headerSHA256.prefix(12))")
            } else {
                report.warnings.append("Info.plist has no ElectronAsarIntegrity entry")
            }
            let packageData = try archive.readFile("package.json")
            let package = try JSONSerialization.jsonObject(with: packageData) as? [String: Any] ?? [:]
            let main = ((package["main"] as? String) ?? "index.js").replacingOccurrences(of: "./", with: "")
            let source = try archive.readFile(main)
            if profile.provider.hooksAppArchive {
                check("startup hook present", ProfileBootstrap.containsHook(source, profileID: profile.id.uuidString))
                check("startup hook pins data folder", String(decoding: source.prefix(4096), as: UTF8.self).contains(ProfileBootstrap.jsString(profile.dataDirectory)))
            } else {
                check("app archive untouched", !ProfileBootstrap.containsHook(source, profileID: profile.id.uuidString))
            }
            check("startup script integrity", (try? archive.verifyIntegrity(of: main)) == true)
        } catch {
            report.failures.append("archive: \(error.localizedDescription)")
        }

        if profile.provider.usesLaunchWrapper {
            let wrapper = appURL.appending(path: "Contents/MacOS/\(AppProvider.launchWrapperName)")
            let magic = (try? FileHandle(forReadingFrom: wrapper).read(upToCount: 4)) ?? nil
            check("launcher is the app entry", plist["CFBundleExecutable"] as? String == AppProvider.launchWrapperName)
            check("launcher is a native binary", magic.map { [0xCF, 0xFA, 0xED, 0xFE].elementsEqual($0) || [0xCA, 0xFE, 0xBA, 0xBE].elementsEqual($0) } ?? false)
            check("launcher pins data folder", (plist[LaunchWrapper.argumentsKey] as? [String]) == LaunchWrapper.launchArguments(for: profile))
            if let real = plist[InfoPlistKeys.realExecutable] as? String {
                check("real executable present", FileManager.default.isExecutableFile(atPath: appURL.appending(path: "Contents/MacOS/\(real)").path))
            } else {
                report.failures.append("real executable name missing")
            }
        }

        let enumerator = FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: nil)
        var leaked: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == "Info.plist", url.standardizedPath != appURL.appending(path: "Contents/Info.plist").standardizedPath else { continue }
            guard InfoPlistEditor.isInSignedNestedRoot(url, appURL: appURL) else { continue }
            if let id = (try? PlistDocument.read(url))?.values["CFBundleIdentifier"] as? String,
               id == profile.provider.officialBundleIdentifier || id.hasPrefix(profile.provider.officialBundleIdentifier + ".") && !id.hasPrefix(profile.bundleIdentifier) {
                leaked.append(url.path.replacingOccurrences(of: appURL.path, with: ""))
            }
        }
        check("nested bundle identifiers", leaked.isEmpty, leaked.joined(separator: ", "))

        Log.info("verify.bundle", ["profile": profile.id.uuidString, "passed": String(report.passed), "failures": report.failures.joined(separator: " | ")])
        return report
    }

    public static func verifyRunningIsolation(profile: Profile, others: [Profile], officialDirectories: [URL]) -> VerificationReport {
        var report = VerificationReport(checks: [], failures: [], warnings: [])
        guard let app = profile.appBundleURL else {
            report.failures.append("no app bundle")
            return report
        }
        let processes = ProcessInspector.processes(inside: app)
        guard !processes.isEmpty else {
            report.warnings.append("profile is not running; launch it to check live file access")
            return report
        }
        report.checks.append("\(processes.count) processes running from the profile app")
        let files = ProcessInspector.openFiles(pids: processes.map(\.pid))
        let own = profile.dataDirectoryURL
        let foreignRoots = officialDirectories + others.filter { $0.id != profile.id }.map(\.dataDirectoryURL)
        var touchesOwn = false
        var foreignHits: [String] = []
        for path in files {
            let url = URL(filePath: path)
            if url.isSameOrDescendant(of: own) { touchesOwn = true; continue }
            if foreignRoots.contains(where: { url.isSameOrDescendant(of: $0) }) { foreignHits.append(path) }
        }
        if touchesOwn {
            report.checks.append("uses its own data folder")
        } else {
            report.failures.append("no open files inside \(own.path)")
        }
        if foreignHits.isEmpty {
            report.checks.append("no files open in other profiles' folders")
        } else {
            report.failures.append("files open in other profiles' folders: \(foreignHits.prefix(5).joined(separator: ", "))")
        }
        if let owner = ProcessInspector.singletonLockOwner(dataDirectory: own) {
            if processes.contains(where: { $0.pid == owner.pid }) {
                report.checks.append("profile lock held by this app (pid \(owner.pid))")
            } else {
                report.failures.append("profile lock held by another process \(owner.pid) \(owner.executablePath)")
            }
        }
        Log.info("verify.runtime", ["profile": profile.id.uuidString, "passed": String(report.passed), "open_files": String(files.count), "foreign_hits": String(foreignHits.count)])
        return report
    }
}
