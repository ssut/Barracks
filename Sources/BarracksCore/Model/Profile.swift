import Foundation

public enum ProfileColor: String, Codable, CaseIterable, Sendable, Hashable {
    case clay, teal, indigo, violet, rose, amber, green, slate

    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .clay: (0.80, 0.42, 0.30)
        case .teal: (0.22, 0.66, 0.64)
        case .indigo: (0.36, 0.42, 0.86)
        case .violet: (0.60, 0.40, 0.84)
        case .rose: (0.86, 0.34, 0.48)
        case .amber: (0.90, 0.64, 0.20)
        case .green: (0.34, 0.66, 0.36)
        case .slate: (0.46, 0.52, 0.60)
        }
    }

    public var displayName: String { rawValue.capitalized }

    public var tint: RGBColor { RGBColor(red: rgb.red, green: rgb.green, blue: rgb.blue) }
}

public struct RGBColor: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public init?(hex raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

public enum ProfileTint: Sendable, Equatable, Hashable {
    case preset(ProfileColor)
    case custom(RGBColor)

    public var rgb: RGBColor {
        switch self {
        case .preset(let color): color.tint
        case .custom(let color): color
        }
    }

    public var cacheKey: String {
        switch self {
        case .preset(let color): color.rawValue
        case .custom(let color): color.hex
        }
    }

    public static func parse(_ raw: String) -> ProfileTint? {
        if let preset = ProfileColor(rawValue: raw.lowercased()) { return .preset(preset) }
        return RGBColor(hex: raw).map { .custom($0) }
    }
}

public struct ProfileBuildRecord: Codable, Sendable, Hashable {
    public var appVersion: String
    public var appBuild: String
    public var sourceAppPath: String
    public var sourceAsarSHA256: String
    public var sourceSignature: String
    public var builderVersion: Int
    public var builtAt: Date
    public var appAsarSHA256: String
    public var copyMethod: String
}

public struct Profile: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var provider: AppProvider
    public var token: String
    public var name: String
    public var color: ProfileColor
    public var customColor: String?
    public var createdAt: Date
    public var lastLaunchedAt: Date?
    public var dataDirectory: String
    public var dataDirectoryAdopted: Bool
    public var isolateToolConfig: Bool
    public var bundleIdentifier: String
    public var appBundlePath: String?
    public var build: ProfileBuildRecord?
    public var computerUseMode: Bool? = nil

    public var usesComputerUseMode: Bool {
        provider.supportsComputerUseMode && computerUseMode == true
    }

    public var tint: ProfileTint {
        if let customColor, let rgb = RGBColor(hex: customColor) { return .custom(rgb) }
        return .preset(color)
    }

    public mutating func apply(_ tint: ProfileTint) {
        switch tint {
        case .preset(let preset):
            color = preset
            customColor = nil
        case .custom(let rgb):
            customColor = rgb.hex
        }
    }

    public var dataDirectoryURL: URL { URL(filePath: dataDirectory, directoryHint: .isDirectory) }
    public var appBundleURL: URL? { appBundlePath.map { URL(filePath: $0, directoryHint: .isDirectory) } }
    public var displayName: String { "\(provider.displayName) \(name)" }

    public var toolConfigDirectory: String? {
        guard isolateToolConfig || provider.toolConfigAlwaysIsolated else { return nil }
        return dataDirectoryURL.appending(path: provider.toolConfigFolderName).path(percentEncoded: false)
    }

    public var launchEnvironment: [String: String] {
        var env = provider.extraLaunchEnvironment
        env[provider.dataDirectoryEnvironmentKey] = dataDirectory
        if let tool = toolConfigDirectory { env[provider.toolConfigEnvironmentKey] = tool }
        env["BARRACKS_PROFILE"] = id.uuidString
        return env
    }

    public static func makeToken(from id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
    }

    public static func bundleIdentifier(forToken token: String, provider: AppProvider) -> String {
        "\(provider.cloneBundleIdentifierPrefix).p\(token)"
    }
}

public enum ProfileNameRules {
    public static let maximumLength = 40

    public static func normalize(_ raw: String) throws -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        guard !collapsed.isEmpty else { throw BarracksError.invalidProfileName("the name is empty") }
        guard collapsed.count <= maximumLength else {
            throw BarracksError.invalidProfileName("keep it at \(maximumLength) characters or fewer")
        }
        if collapsed.hasPrefix(".") { throw BarracksError.invalidProfileName("it cannot start with a dot") }
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.illegalCharacters)
        if collapsed.unicodeScalars.contains(where: { forbidden.contains($0) }) {
            throw BarracksError.invalidProfileName("slashes, colons and control characters are not allowed")
        }
        return collapsed
    }

    public static func appBundleFileName(for name: String, provider: AppProvider = .claude) -> String {
        "\(provider.displayName) \(name).app"
    }

    public static func isSameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }
}
