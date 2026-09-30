import Foundation

public enum ProfileOwnership {
    public static let sidecarName = ".barracks-profile"

    public static func owner(of appURL: URL) -> String? {
        if let marker = (try? PlistDocument.read(appURL.appending(path: "Contents/Info.plist")))?.values[InfoPlistKeys.profileID] as? String {
            return marker
        }
        let sidecar = appURL.deletingLastPathComponent().appending(path: sidecarName)
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public static func isOwned(_ appURL: URL, by profileID: UUID) -> Bool {
        owner(of: appURL) == profileID.uuidString
    }

    public static func writeSidecar(for appURL: URL, profileID: UUID) throws {
        let folder = appURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileOps.writeAtomically(Data((profileID.uuidString + "\n").utf8), to: folder.appending(path: sidecarName))
    }
}
