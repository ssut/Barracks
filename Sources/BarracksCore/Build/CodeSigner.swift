import Foundation

public enum CodeSigner {
    static let codesign = "/usr/bin/codesign"

    static let strippedEntitlementPrefixes = [
        "com.apple.application-identifier",
        "com.apple.developer.",
        "keychain-access-groups",
        "com.apple.security.application-groups",
    ]

    public static func sanitizedEntitlements(of appURL: URL) throws -> [String: Any]? {
        let result = try ProcessRunner.run(codesign, ["-d", "--entitlements", "-", "--xml", appURL.path], allowFailure: true)
        guard result.status == 0, !result.stdout.isEmpty else { return nil }
        guard let plist = try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any] else { return nil }
        var kept: [String: Any] = [:]
        var dropped: [String] = []
        for (key, value) in plist {
            if strippedEntitlementPrefixes.contains(where: { key.hasPrefix($0) }) {
                dropped.append(key)
            } else {
                kept[key] = value
            }
        }
        Log.info("codesign.entitlements", ["kept": kept.keys.sorted().joined(separator: ","), "dropped": dropped.sorted().joined(separator: ",")])
        return kept
    }

    public static func adhocSign(appURL: URL, entitlements: [String: Any]?, scratch: URL, secondaryExecutable: String? = nil) throws {
        var entitlementArgs: [String] = []
        if let entitlements, !entitlements.isEmpty {
            let file = scratch.appending(path: "entitlements.plist")
            let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
            try data.write(to: file)
            entitlementArgs = ["--entitlements", file.path]
        }
        try ProcessRunner.run(codesign, ["--force", "--deep", "--sign", "-"] + entitlementArgs + [appURL.path])
        if let secondaryExecutable {
            let binary = appURL.appending(path: "Contents/MacOS/\(secondaryExecutable)")
            try ProcessRunner.run(codesign, ["--force", "--sign", "-"] + entitlementArgs + [binary.path])
            try ProcessRunner.run(codesign, ["--force", "--sign", "-"] + entitlementArgs + [appURL.path])
        }
        Log.info("codesign.signed", ["app": appURL.lastPathComponent, "secondary": secondaryExecutable ?? ""])
    }

    public static func verify(appURL: URL) throws {
        let result = try ProcessRunner.run(codesign, ["--verify", "--deep", "--strict", appURL.path], allowFailure: true)
        guard result.status == 0 else {
            throw BarracksError.signatureInvalid(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        Log.info("codesign.verified", ["app": appURL.lastPathComponent])
    }

    public static func verifyNestedBundles(appURL: URL) throws {
        let contents = appURL.appending(path: "Contents")
        guard let enumerator = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        var failures: [String] = []
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "app" {
            checked += 1
            let result = try ProcessRunner.run(codesign, ["--verify", "--strict", url.path], allowFailure: true)
            if result.status != 0 {
                failures.append(url.path.replacingOccurrences(of: appURL.path, with: ""))
            }
        }
        Log.info("codesign.nested_verified", ["app": appURL.lastPathComponent, "checked": String(checked), "failed": String(failures.count)])
        if !failures.isEmpty {
            throw BarracksError.signatureInvalid("nested apps with broken signatures: \(failures.joined(separator: ", "))")
        }
    }

    public static func removeQuarantine(appURL: URL) {
        _ = try? ProcessRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path], allowFailure: true)
    }
}
