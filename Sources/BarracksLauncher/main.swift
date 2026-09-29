import Darwin
import Foundation

let info = Bundle.main.infoDictionary ?? [:]
guard let real = info["BarracksRealExecutable"] as? String, !real.isEmpty, !real.contains("/") else {
    FileHandle.standardError.write(Data("{\"event\":\"launcher.missing_target\",\"level\":\"error\"}\n".utf8))
    exit(78)
}
let target = Bundle.main.bundleURL.appending(path: "Contents/MacOS").appending(path: real).path
if let environment = info["LSEnvironment"] as? [String: String] {
    for (key, value) in environment { setenv(key, value, 1) }
}
let fixed = (info["BarracksLaunchArguments"] as? [String]) ?? []
let passthrough = Array(CommandLine.arguments.dropFirst()).filter { !fixed.contains($0) }
var argv: [UnsafeMutablePointer<CChar>?] = ([target] + fixed + passthrough).map { strdup($0) }
argv.append(nil)
execv(target, &argv)
FileHandle.standardError.write(Data("{\"event\":\"launcher.exec_failed\",\"level\":\"error\",\"errno\":\(errno)}\n".utf8))
exit(71)
