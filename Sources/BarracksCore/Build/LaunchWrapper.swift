import Foundation

public enum LaunchWrapper {
    public static let binaryName = "barracks-launcher"
    public static let argumentsKey = "BarracksLaunchArguments"

    public static func locateBinary() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appending(path: binaryName)) }
        let executable = URL(filePath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        candidates.append(executable.deletingLastPathComponent().appending(path: binaryName))
        if let override = ProcessInfo.processInfo.environment["BARRACKS_LAUNCHER"], !override.isEmpty {
            candidates.insert(URL(filePath: override), at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func launchArguments(for profile: Profile) -> [String] {
        ["--user-data-dir=\(profile.dataDirectory)"]
    }

    @discardableResult
    public static func install(appURL: URL, profile: Profile) throws -> String {
        guard let binary = locateBinary() else {
            throw BarracksError.installFailed("the Barracks launcher binary is missing; rebuild Barracks")
        }
        let plistURL = appURL.appending(path: "Contents/Info.plist")
        var doc = try PlistDocument.read(plistURL)
        let current = doc.values["CFBundleExecutable"] as? String ?? ""
        let real = (doc.values[InfoPlistKeys.realExecutable] as? String) ?? current
        guard !real.isEmpty, real != AppProvider.launchWrapperName else {
            throw BarracksError.verificationFailed("cannot find the app's own executable name")
        }
        let macOS = appURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        guard FileManager.default.isExecutableFile(atPath: macOS.appending(path: real).path) else {
            throw BarracksError.verificationFailed("Contents/MacOS/\(real) is missing")
        }
        let wrapper = macOS.appending(path: AppProvider.launchWrapperName)
        if FileManager.default.fileExists(atPath: wrapper.path) { try FileManager.default.removeItem(at: wrapper) }
        try FileManager.default.copyItem(at: binary, to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        doc.values["CFBundleExecutable"] = AppProvider.launchWrapperName
        doc.values[InfoPlistKeys.realExecutable] = real
        doc.values[argumentsKey] = launchArguments(for: profile)
        try doc.write()
        Log.info("build.launch_wrapper", ["profile": profile.id.uuidString, "real_executable": real, "launcher": binary.path])
        return real
    }
}
