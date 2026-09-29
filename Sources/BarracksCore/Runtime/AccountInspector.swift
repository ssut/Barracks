import Foundation

public struct AccountInfo: Sendable, Equatable {
    public var accountUUID: String?
    public var email: String?
    public var fullName: String?
    public var displayName: String?
    public var plan: String?
    public var toolEmail: String?

    public var isEmpty: Bool {
        accountUUID == nil && email == nil && fullName == nil && displayName == nil && toolEmail == nil && plan == nil
    }

    public var headline: String? { email ?? displayName ?? fullName }

    public var personName: String? {
        let name = displayName ?? fullName
        return name == headline ? nil : name
    }
}

public enum AccountInspector {
    static let maxBlobBytes = 32 * 1024 * 1024
    static let searchWindow = 16 * 1024

    public static func inspect(provider: AppProvider, dataDirectory: URL, toolConfigDirectory: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AccountInfo {
        let info: AccountInfo
        switch provider {
        case .claude:
            info = inspectClaude(dataDirectory: dataDirectory, claudeCodeConfigDirectory: toolConfigDirectory, home: home)
        case .chatgpt:
            info = inspectCodex(codexHome: toolConfigDirectory ?? home.appending(path: provider.officialToolHomeRelativePath))
        }
        Log.debug("account.inspected", [
            "provider": provider.rawValue,
            "data": dataDirectory.lastPathComponent,
            "has_uuid": String(info.accountUUID != nil),
            "has_email": String(info.email != nil),
            "has_tool_email": String(info.toolEmail != nil),
        ])
        return info
    }

    static func inspectClaude(dataDirectory: URL, claudeCodeConfigDirectory: URL?, home: URL) -> AccountInfo {
        var info = AccountInfo()
        info.accountUUID = lastKnownAccountUUID(dataDirectory: dataDirectory)
        if let web = webAccount(dataDirectory: dataDirectory, accountUUID: info.accountUUID) {
            info.email = web.email
            info.fullName = web.fullName
            info.displayName = web.displayName
        }
        info.toolEmail = claudeCodeEmail(configDirectory: claudeCodeConfigDirectory, home: home)
        return info
    }

    static func inspectCodex(codexHome: URL) -> AccountInfo {
        var info = AccountInfo()
        guard let data = try? Data(contentsOf: codexHome.appending(path: "auth.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any]
        else { return info }
        if let accountID = tokens["account_id"] as? String, !accountID.isEmpty { info.accountUUID = accountID }
        guard let idToken = tokens["id_token"] as? String, let claims = jwtClaims(idToken) else { return info }
        if let email = claims["email"] as? String, isEmail(email) { info.email = email }
        if let name = claims["name"] as? String, !name.isEmpty { info.fullName = name }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            if let plan = auth["chatgpt_plan_type"] as? String, !plan.isEmpty { info.plan = plan.capitalized }
            if info.accountUUID == nil, let accountID = auth["chatgpt_account_id"] as? String { info.accountUUID = accountID }
        }
        return info
    }

    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func lastKnownAccountUUID(dataDirectory: URL) -> String? {
        guard let data = try? Data(contentsOf: dataDirectory.appending(path: "config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = object["lastKnownAccountUuid"] as? String,
              UUID(uuidString: uuid) != nil
        else { return nil }
        return uuid.lowercased()
    }

    static func claudeCodeEmail(configDirectory: URL?, home: URL) -> String? {
        let file = configDirectory?.appending(path: ".claude.json") ?? home.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String,
              isEmail(email)
        else { return nil }
        return email
    }

    struct WebAccount {
        var email: String?
        var fullName: String?
        var displayName: String?
    }

    static func webAccount(dataDirectory: URL, accountUUID: String?) -> WebAccount? {
        let root = dataDirectory.appending(path: "IndexedDB/https_claude.ai_0.indexeddb.blob", directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return nil }
        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= maxBlobBytes
            else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast))
        }
        var fallback: WebAccount?
        for file in files.sorted(by: { $0.modified > $1.modified }) {
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { continue }
            let bytes = [UInt8](data)
            if let accountUUID, let match = account(in: bytes, uuid: accountUUID) { return match }
            if fallback == nil, accountUUID == nil, let first = firstAccount(in: bytes) { fallback = first }
        }
        return fallback
    }

    static func account(in bytes: [UInt8], uuid: String) -> WebAccount? {
        for position in keyPositions("uuid", in: bytes) {
            guard let value = V8Strings.readValue(bytes, at: position), value.lowercased() == uuid else { continue }
            let window = position..<min(bytes.count, position + searchWindow)
            let email = firstValue("email_address", in: bytes, range: window).flatMap { isEmail($0) ? $0 : nil }
            guard email != nil else { continue }
            return WebAccount(
                email: email,
                fullName: firstValue("full_name", in: bytes, range: window),
                displayName: firstValue("display_name", in: bytes, range: window)
            )
        }
        return nil
    }

    static func firstAccount(in bytes: [UInt8]) -> WebAccount? {
        for position in keyPositions("email_address", in: bytes) {
            guard let email = V8Strings.readValue(bytes, at: position), isEmail(email) else { continue }
            let window = max(0, position - searchWindow)..<min(bytes.count, position + searchWindow)
            return WebAccount(
                email: email,
                fullName: firstValue("full_name", in: bytes, range: window),
                displayName: firstValue("display_name", in: bytes, range: window)
            )
        }
        return nil
    }

    static func firstValue(_ key: String, in bytes: [UInt8], range: Range<Int>) -> String? {
        for position in keyPositions(key, in: bytes, range: range) {
            if let value = V8Strings.readValue(bytes, at: position), !value.isEmpty, value.count <= 200 { return value }
        }
        return nil
    }

    static func keyPositions(_ key: String, in bytes: [UInt8], range: Range<Int>? = nil) -> [Int] {
        let keyBytes = Array(key.utf8)
        guard keyBytes.count < 128 else { return [] }
        let needle: [UInt8] = [0x22, UInt8(keyBytes.count)] + keyBytes
        let bounds = range ?? 0..<bytes.count
        var positions: [Int] = []
        var index = bounds.lowerBound
        let last = bounds.upperBound - needle.count
        while index <= last {
            if bytes[index] == 0x22, bytes[index + 1] == needle[1], bytes[index + 2] == needle[2] {
                var matched = true
                for offset in 3..<needle.count where bytes[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched {
                    positions.append(index + needle.count)
                    index += needle.count
                    continue
                }
            }
            index += 1
        }
        return positions
    }

    static func isEmail(_ value: String) -> Bool {
        value.count <= 254 && value.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
}

enum V8Strings {
    static func readValue(_ bytes: [UInt8], at start: Int) -> String? {
        var index = start
        while index < bytes.count, bytes[index] == 0x00 { index += 1 }
        guard index < bytes.count else { return nil }
        let tag = bytes[index]
        index += 1
        guard let (length, next) = readVarint(bytes, at: index), length <= 4096, next + length <= bytes.count else { return nil }
        let slice = Array(bytes[next..<(next + length)])
        switch tag {
        case 0x22:
            return String(bytes: slice, encoding: .isoLatin1)
        case 0x63:
            guard length % 2 == 0 else { return nil }
            return String(bytes: slice, encoding: .utf16LittleEndian)
        case 0x53:
            return String(bytes: slice, encoding: .utf8)
        default:
            return nil
        }
    }

    static func readVarint(_ bytes: [UInt8], at start: Int) -> (Int, Int)? {
        var result = 0
        var shift = 0
        var index = start
        while index < bytes.count, shift < 35 {
            let byte = bytes[index]
            result |= Int(byte & 0x7f) << shift
            index += 1
            if byte & 0x80 == 0 { return (result, index) }
            shift += 7
        }
        return nil
    }
}
