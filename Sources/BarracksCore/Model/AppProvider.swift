import Foundation

public enum AppProvider: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case claude
    case chatgpt

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        }
    }

    public var officialBundleIdentifier: String {
        switch self {
        case .claude: "com.anthropic.claudefordesktop"
        case .chatgpt: "com.openai.codex"
        }
    }

    public var appBundleName: String { "\(displayName).app" }

    public var cloneBundleIdentifierPrefix: String {
        "\(officialBundleIdentifier).barracks"
    }

    public var officialDataFolderName: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "Codex"
        }
    }

    public var dataDirectoryEnvironmentKey: String {
        switch self {
        case .claude: "CLAUDE_USER_DATA_DIR"
        case .chatgpt: "CODEX_ELECTRON_USER_DATA_PATH"
        }
    }

    public var toolConfigEnvironmentKey: String {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .chatgpt: "CODEX_HOME"
        }
    }

    public var toolConfigFolderName: String {
        switch self {
        case .claude: "claude-code-config"
        case .chatgpt: "codex-home"
        }
    }

    public var toolName: String {
        switch self {
        case .claude: "Claude Code"
        case .chatgpt: "Codex"
        }
    }

    public var officialToolHomeRelativePath: String {
        switch self {
        case .claude: ".claude"
        case .chatgpt: ".codex"
        }
    }

    public var toolConfigAlwaysIsolated: Bool {
        switch self {
        case .claude: false
        case .chatgpt: true
        }
    }

    public var seedableToolConfigFiles: [String] {
        switch self {
        case .claude: []
        case .chatgpt: ["config.toml", "AGENTS.md"]
        }
    }

    public var extraLaunchEnvironment: [String: String] {
        switch self {
        case .claude: [:]
        case .chatgpt: ["CODEX_SPARKLE_ENABLED": "false"]
        }
    }

    public var infoPlistKeysToRemove: [String] {
        switch self {
        case .claude: []
        case .chatgpt: ["NSDockTilePlugIn", "SUFeedURL"]
        }
    }

    public var infoPlistBooleansToSet: [String: Bool] {
        switch self {
        case .claude: [:]
        case .chatgpt: ["SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false, "SUAllowsAutomaticUpdates": false]
        }
    }

    public var supportFoldersExcludedFromDetection: [String] {
        switch self {
        case .claude: ["Claude-Work-Patcher"]
        case .chatgpt: []
        }
    }

    public var hooksAppArchive: Bool {
        switch self {
        case .claude: true
        case .chatgpt: false
        }
    }

    public var usesLaunchWrapper: Bool {
        switch self {
        case .claude: false
        case .chatgpt: true
        }
    }

    public static let launchWrapperName = "barracks-launch"

    public var renamesBundleName: Bool {
        switch self {
        case .claude: false
        case .chatgpt: true
        }
    }

    public var supportsComputerUseMode: Bool {
        switch self {
        case .claude: false
        case .chatgpt: true
        }
    }

    public var vendorTeamIdentifier: String {
        switch self {
        case .claude: SignatureInfo.anthropicTeamIdentifier
        case .chatgpt: SignatureInfo.openAITeamIdentifier
        }
    }

    public var cloneMarkerEnvironmentKeys: [String] {
        switch self {
        case .claude: ["CLAUDE_USER_DATA_DIR", "CLAUDE_CONFIG_DIR", "CLAUDE_PROFILE"]
        case .chatgpt: ["CODEX_ELECTRON_USER_DATA_PATH"]
        }
    }
}
