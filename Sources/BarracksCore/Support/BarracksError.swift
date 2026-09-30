import Foundation

public enum BarracksError: Error, LocalizedError, Sendable, Equatable {
    case appNotFound(provider: String, searched: [String])
    case appInvalid(path: String, reason: String)
    case sourceIsProfileClone(path: String, marker: String)
    case sourceChangedDuringCopy
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case invalidProfileName(String)
    case duplicateProfileName(String)
    case profileNotFound(String)
    case profileRunning(String)
    case profileDataInUse(path: String, pid: Int32, executable: String)
    case dataDirectoryInvalid(path: String, reason: String)
    case dataDirectoryClaimed(path: String, profile: String)
    case appBundleMissing(String)
    case foreignBundleAtTarget(String)
    case asarMalformed(String)
    case asarEntryMissing(String)
    case mainEntryUnsupported(String)
    case javascriptSyntax(String)
    case processFailed(command: String, status: Int32, stderr: String)
    case signatureInvalid(String)
    case verificationFailed(String)
    case installFailed(String)
    case launchFailed(String)
    case stopTimedOut(String)
    case registryCorrupt(String)
    case lockUnavailable(String)
    case extraUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let provider, let searched):
            "\(provider) was not found. Looked in: \(searched.joined(separator: ", "))."
        case .appInvalid(let path, let reason):
            "The app at \(path) cannot be used: \(reason)"
        case .sourceIsProfileClone(let path, let marker):
            "\(path) is itself a profile copy (found \(marker)). Choose the official app instead."
        case .sourceChangedDuringCopy:
            "The app changed while it was being copied (probably an update). Try again after the update finishes."
        case .insufficientDiskSpace(let required, let available):
            "Not enough free disk space: need about \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)), have \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))."
        case .invalidProfileName(let reason):
            "Invalid profile name: \(reason)"
        case .duplicateProfileName(let name):
            "A profile named “\(name)” already exists."
        case .profileNotFound(let key):
            "No profile matches “\(key)”."
        case .profileRunning(let name):
            "“\(name)” is running. Quit it first."
        case .profileDataInUse(let path, let pid, let executable):
            "The data folder \(path) is already in use by process \(pid) (\(executable)). Quit that app first."
        case .dataDirectoryInvalid(let path, let reason):
            "Cannot use \(path) as a profile folder: \(reason)"
        case .dataDirectoryClaimed(let path, let profile):
            "\(path) already belongs to profile “\(profile)”."
        case .appBundleMissing(let path):
            "The profile app is missing at \(path). Rebuild the profile."
        case .foreignBundleAtTarget(let path):
            "\(path) exists but was not created by Barracks. Move it away first."
        case .asarMalformed(let reason):
            "The app archive could not be read: \(reason)"
        case .asarEntryMissing(let path):
            "The app archive has no \(path)."
        case .mainEntryUnsupported(let reason):
            "The app's startup script changed shape: \(reason)"
        case .javascriptSyntax(let reason):
            "The profile startup hook failed a JavaScript syntax check: \(reason)"
        case .processFailed(let command, let status, let stderr):
            "\(command) failed with status \(status): \(stderr)"
        case .signatureInvalid(let reason):
            "Code signature check failed: \(reason)"
        case .verificationFailed(let reason):
            "Profile app verification failed: \(reason)"
        case .installFailed(let reason):
            "Could not install the profile app: \(reason)"
        case .launchFailed(let reason):
            "Could not launch: \(reason)"
        case .stopTimedOut(let name):
            "“\(name)” did not quit in time."
        case .registryCorrupt(let reason):
            "The profile list could not be read: \(reason)"
        case .extraUnavailable(let reason):
            reason
        case .lockUnavailable(let reason):
            "Another Barracks operation is in progress: \(reason)"
        }
    }
}
