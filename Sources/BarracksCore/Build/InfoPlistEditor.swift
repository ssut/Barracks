import Foundation

public enum InfoPlistKeys {
    public static let profileID = "BarracksProfileID"
    public static let builderVersion = "BarracksBuilderVersion"
    public static let dataDirectory = "BarracksDataDirectory"
    public static let profileIconFile = "barracks-profile.icns"
    public static let realExecutable = "BarracksRealExecutable"
}

public struct PlistDocument {
    public let url: URL
    public var values: [String: Any]
    let format: PropertyListSerialization.PropertyListFormat

    public static func read(_ url: URL) throws -> PlistDocument {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw BarracksError.verificationFailed("\(url.path) is not a dictionary plist")
        }
        return PlistDocument(url: url, values: values, format: format)
    }

    public func write() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: format == .binary ? .binary : .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}

public struct MainPlistEdit {
    public var bundleIdentifier: String
    public var displayName: String
    public var environment: [String: String]
    public var asarHeaderSHA256: String?
    public var iconFile: String?
    public var profileID: String
    public var dataDirectory: String
    public var builderVersion: Int
    public var keysToRemove: [String]
    public var booleansToSet: [String: Bool]
    public var renameBundle: Bool = true
}

public enum InfoPlistEditor {
    public static func applyMain(_ edit: MainPlistEdit, appURL: URL) throws {
        var doc = try PlistDocument.read(appURL.appending(path: "Contents/Info.plist"))
        doc.values["CFBundleIdentifier"] = edit.bundleIdentifier
        doc.values["CFBundleDisplayName"] = edit.displayName
        if edit.renameBundle { doc.values["CFBundleName"] = edit.displayName }
        var env = doc.values["LSEnvironment"] as? [String: Any] ?? [:]
        for (key, value) in edit.environment { env[key] = value }
        doc.values["LSEnvironment"] = env
        if let hash = edit.asarHeaderSHA256 {
            var integrity = doc.values["ElectronAsarIntegrity"] as? [String: Any] ?? [:]
            integrity["Resources/app.asar"] = ["algorithm": "SHA256", "hash": hash]
            doc.values["ElectronAsarIntegrity"] = integrity
        }
        if let icon = edit.iconFile {
            doc.values.removeValue(forKey: "CFBundleIconName")
            doc.values["CFBundleIconFile"] = icon
        }
        for key in edit.keysToRemove { doc.values.removeValue(forKey: key) }
        for (key, value) in edit.booleansToSet { doc.values[key] = value }
        doc.values[InfoPlistKeys.profileID] = edit.profileID
        doc.values[InfoPlistKeys.dataDirectory] = edit.dataDirectory
        doc.values[InfoPlistKeys.builderVersion] = edit.builderVersion
        try doc.write()
        Log.info("plist.main_updated", ["bundle_id": edit.bundleIdentifier, "display_name": edit.displayName])
    }

    public static let signedNestedRoots = ["Contents/Frameworks", "Contents/Helpers", "Contents/PlugIns", "Contents/XPCServices", "Contents/Library"]

    public static func isInSignedNestedRoot(_ url: URL, appURL: URL) -> Bool {
        signedNestedRoots.contains { url.isSameOrDescendant(of: appURL.appending(path: $0)) }
    }

    @discardableResult
    public static func rewriteNestedBundleIdentifiers(appURL: URL, from sourceID: String, to targetID: String) throws -> Int {
        let mainPlist = appURL.appending(path: "Contents/Info.plist").standardizedPath
        guard let enumerator = FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return 0 }
        var changed = 0
        for case let url as URL in enumerator where url.lastPathComponent == "Info.plist" {
            if url.standardizedPath == mainPlist { continue }
            guard isInSignedNestedRoot(url, appURL: appURL) else { continue }
            guard var doc = try? PlistDocument.read(url), let id = doc.values["CFBundleIdentifier"] as? String else { continue }
            let newID: String
            if id == sourceID {
                newID = targetID
            } else if id.hasPrefix(sourceID + ".") {
                newID = targetID + id.dropFirst(sourceID.count)
            } else {
                continue
            }
            doc.values["CFBundleIdentifier"] = newID
            try doc.write()
            changed += 1
            Log.debug("plist.nested_updated", ["path": url.path, "bundle_id": newID])
        }
        Log.info("plist.nested_summary", ["changed": String(changed)])
        return changed
    }
}
