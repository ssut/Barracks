import Foundation
import JavaScriptCore

public struct ProfileBootstrapConfig: Sendable, Equatable {
    public var profileID: String
    public var environment: [String: String]
    public var disableElectronAutoUpdater: Bool
    public var userDataDirectory: String?

    public init(profileID: String, environment: [String: String], disableElectronAutoUpdater: Bool = true, userDataDirectory: String? = nil) {
        self.profileID = profileID
        self.environment = environment
        self.disableElectronAutoUpdater = disableElectronAutoUpdater
        self.userDataDirectory = userDataDirectory
    }

    public init(profile: Profile) {
        self.init(profileID: profile.id.uuidString, environment: profile.launchEnvironment, userDataDirectory: profile.dataDirectory)
    }
}

public enum ProfileBootstrap {
    public static let version = 1
    public static let marker = "__barracks"
    public static let foreignMarkers: [String] = [marker, "CLAUDE_PROFILE=\"Work\"", "process.env.CLAUDE_PROFILE="]

    public static func script(for config: ProfileBootstrapConfig) -> String {
        var body = "var p=process,e=p.env;"
        for key in config.environment.keys.sorted() {
            guard let value = config.environment[key] else { continue }
            body += "e[\(jsString(key))]=\(jsString(value));"
        }
        body += "globalThis.\(marker)={version:\(version),profile:\(jsString(config.profileID))};"
        if let directory = config.userDataDirectory {
            body += "var a=require(\"electron\").app,d=\(jsString(directory));"
            body += "try{a.setPath(\"userData\",d);a.setPath(\"crashDumps\",d+\"/Crashpad\");a.setAppLogsPath(d+\"/Logs\")}catch(x){}"
            body += "if(a.getPath(\"userData\")!==d){try{require(\"fs\").writeSync(2,\"barracks: data folder pin failed\\n\")}catch(y){}p.exit(78)}"
        }
        if config.disableElectronAutoUpdater {
            body += "try{var u=require(\"electron\").autoUpdater;"
            body += "u.setFeedURL=function(){};"
            body += "u.checkForUpdates=function(){setImmediate(function(){u.emit(\"update-not-available\")})};"
            body += "u.quitAndInstall=function(){}}catch(x){}"
        }
        return ";(function(){\(body)})()"
    }

    public static func inject(into source: Data, config: ProfileBootstrapConfig) throws -> Data {
        guard let text = String(data: source, encoding: .utf8) else {
            throw BarracksError.mainEntryUnsupported("the startup script is not UTF-8")
        }
        if let found = foreignMarkers.first(where: { text.contains($0) }) {
            throw BarracksError.sourceIsProfileClone(path: "startup script", marker: found)
        }
        let hook = script(for: config) + ";\n"
        var prefix = ""
        var rest = Substring(text)
        if rest.hasPrefix("\u{FEFF}") {
            prefix = "\u{FEFF}"
            rest = rest.dropFirst()
        }
        for directive in ["\"use strict\";", "'use strict';"] where rest.hasPrefix(directive) {
            let output = prefix + directive + hook + rest.dropFirst(directive.count)
            return Data(output.utf8)
        }
        if rest.hasPrefix("\"use strict\"") || rest.hasPrefix("'use strict'") {
            throw BarracksError.mainEntryUnsupported("strict-mode directive without a semicolon")
        }
        return Data((prefix + hook + rest).utf8)
    }

    public static func containsHook(_ source: Data, profileID: String) -> Bool {
        guard let text = String(data: source, encoding: .utf8) else { return false }
        return text.contains(marker) && text.contains(jsString(profileID))
    }

    public static func checkSyntax(_ source: Data, label: String) throws {
        guard let text = String(data: source, encoding: .utf8) else {
            throw BarracksError.javascriptSyntax("\(label) is not UTF-8")
        }
        let wrapped = "(function (exports, require, module, __filename, __dirname) {\n" + text + "\n})"
        guard let context = JSContext() else { throw BarracksError.javascriptSyntax("JavaScriptCore is unavailable") }
        let script = JSStringCreateWithCFString(wrapped as CFString)
        let url = JSStringCreateWithCFString(label as CFString)
        defer {
            JSStringRelease(script)
            JSStringRelease(url)
        }
        var exception: JSValueRef?
        let ok = JSCheckScriptSyntax(context.jsGlobalContextRef, script, url, 1, &exception)
        if !ok {
            let message = exception.flatMap { JSValue(jsValueRef: $0, in: context)?.toString() } ?? "unknown error"
            throw BarracksError.javascriptSyntax("\(label): \(message)")
        }
    }

    static func jsString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
