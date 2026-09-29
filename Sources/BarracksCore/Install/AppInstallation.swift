import AppKit
import Foundation
import Security

public enum SignatureKind: String, Codable, Sendable {
    case anthropic
    case adhoc
    case otherTeam
    case unsigned
}

public struct SignatureInfo: Sendable, Equatable {
    public var kind: SignatureKind
    public var teamIdentifier: String?
    public var identifier: String?

    public static let anthropicTeamIdentifier = "Q6L2SF6YDW"
    public static let openAITeamIdentifier = "2DC432GLL2"

    public var summary: String {
        switch kind {
        case .anthropic: "Official"
        case .adhoc: "Locally modified (ad-hoc signed)"
        case .otherTeam: "Signed by team \(teamIdentifier ?? "?")"
        case .unsigned: "Unsigned"
        }
    }

    public static func inspect(_ url: URL) -> SignatureInfo {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return SignatureInfo(kind: .unsigned, teamIdentifier: nil, identifier: nil)
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else {
            return SignatureInfo(kind: .unsigned, teamIdentifier: nil, identifier: nil)
        }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdhoc = flags & 0x2 != 0
        let kind: SignatureKind
        if identifier == nil && team == nil && !isAdhoc {
            kind = .unsigned
        } else if isAdhoc {
            kind = .adhoc
        } else if team == anthropicTeamIdentifier {
            kind = .anthropic
        } else {
            kind = .otherTeam
        }
        return SignatureInfo(kind: kind, teamIdentifier: team, identifier: identifier)
    }
}

public struct AppInstallation: Sendable, Equatable {
    public var provider: AppProvider
    public var appURL: URL
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    public var signature: SignatureInfo
    public var asarURL: URL
    public var asarSize: Int64
    public var asarModified: Date

    public var asarFingerprintKey: String {
        "\(asarURL.path)|\(asarSize)|\(asarModified.timeIntervalSince1970)"
    }

    public var isOfficiallySigned: Bool {
        switch provider {
        case .claude: signature.kind == .anthropic
        case .chatgpt: signature.kind == .otherTeam && signature.teamIdentifier == SignatureInfo.openAITeamIdentifier
        }
    }

    public var signatureSummary: String {
        isOfficiallySigned ? "Official" : signature.summary
    }
}

public enum AppLocator {
    public static func candidateURLs(provider: AppProvider, paths: BarracksPaths, override: String?) -> [URL] {
        var ordered: [URL] = []
        if let override, !override.isEmpty { ordered.append(URL(filePath: override, directoryHint: .isDirectory)) }
        ordered.append(URL(filePath: "/Applications/\(provider.appBundleName)", directoryHint: .isDirectory))
        ordered.append(paths.home.appending(path: "Applications/\(provider.appBundleName)", directoryHint: .isDirectory))
        var excluded = [paths.supportRoot, paths.appsRoot, paths.home.appending(path: ".Trash")]
        excluded += provider.supportFoldersExcludedFromDetection.map { paths.applicationSupportDirectory.appending(path: $0) }
        for url in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: provider.officialBundleIdentifier) {
            if excluded.contains(where: { url.isSameOrDescendant(of: $0) }) { continue }
            if url.path.hasPrefix("/Volumes/") || url.path.contains("/AppTranslocation/") { continue }
            ordered.append(url)
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.standardizedPath).inserted }
    }

    public static func locate(provider: AppProvider, paths: BarracksPaths, override: String?) throws -> AppInstallation {
        let candidates = candidateURLs(provider: provider, paths: paths, override: override)
        var lastError: Error?
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                let installation = try inspect(url, provider: provider)
                Log.info("app.located", [
                    "provider": provider.rawValue,
                    "path": installation.appURL.path,
                    "version": installation.version,
                    "signature": installation.signature.kind.rawValue,
                ])
                return installation
            } catch {
                lastError = error
                Log.warning("app.candidate_rejected", ["provider": provider.rawValue, "path": url.path, "reason": error.localizedDescription])
                if let override, url.standardizedPath == URL(filePath: override).standardizedPath { throw error }
            }
        }
        if let lastError { throw lastError }
        throw BarracksError.appNotFound(provider: provider.displayName, searched: candidates.map(\.path))
    }

    public static func inspect(_ url: URL, provider: AppProvider) throws -> AppInstallation {
        let infoURL = url.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw BarracksError.appInvalid(path: url.path, reason: "Info.plist is unreadable")
        }
        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        guard bundleID == provider.officialBundleIdentifier else {
            throw BarracksError.appInvalid(path: url.path, reason: "bundle identifier is \(bundleID), expected \(provider.officialBundleIdentifier)")
        }
        if plist[InfoPlistKeys.profileID] != nil {
            throw BarracksError.sourceIsProfileClone(path: url.path, marker: InfoPlistKeys.profileID)
        }
        let asarURL = url.appending(path: "Contents/Resources/app.asar")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: asarURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date
        else {
            throw BarracksError.appInvalid(path: url.path, reason: "Contents/Resources/app.asar is missing")
        }
        let shortVersion = plist["CFBundleShortVersionString"] as? String
        let bundleVersion = plist["CFBundleVersion"] as? String
        return AppInstallation(
            provider: provider,
            appURL: url,
            bundleIdentifier: bundleID,
            version: shortVersion ?? bundleVersion ?? "unknown",
            build: bundleVersion ?? shortVersion ?? "unknown",
            signature: SignatureInfo.inspect(url),
            asarURL: asarURL,
            asarSize: size,
            asarModified: modified
        )
    }
}

public final class FingerprintCache: @unchecked Sendable {
    public static let shared = FingerprintCache()
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public func sha256(for installation: AppInstallation) throws -> String {
        let key = installation.asarFingerprintKey
        lock.lock()
        if let cached = values[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let digest = try Hashing.sha256Hex(fileAt: installation.asarURL)
        lock.lock()
        values[key] = digest
        lock.unlock()
        return digest
    }
}
