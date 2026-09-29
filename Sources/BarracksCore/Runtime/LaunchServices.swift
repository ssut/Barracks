import CoreServices
import Foundation

public enum LaunchServices {
    public static func register(_ appURL: URL, enabled: Bool) {
        guard enabled else { return }
        let status = LSRegisterURL(appURL as CFURL, true)
        Log.info("launchservices.register", ["app": appURL.path, "status": String(status)])
    }

    public static func unregister(_ appURL: URL, enabled: Bool) {
        guard enabled else { return }
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let result = try? ProcessRunner.run(tool, ["-u", appURL.path], allowFailure: true)
        Log.info("launchservices.unregister", ["app": appURL.path, "status": String(result?.status ?? -1)])
    }
}
