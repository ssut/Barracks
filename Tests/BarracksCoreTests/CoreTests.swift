import CoreGraphics
import Foundation
import Testing
@testable import BarracksCore

func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "barracks-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct AsarTests {
    @Test func roundTripReplacesOneFileAndKeepsOthers() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "app.asar")
        let files: [String: Data] = [
            "package.json": Data(#"{"name":"x","main":".vite/build/index.pre.js"}"#.utf8),
            ".vite/build/index.pre.js": Data(#""use strict";console.log(1);"#.utf8),
            ".vite/build/other.js": Data(repeating: 0x61, count: 5 * 1024 * 1024),
            "assets/한글 파일.txt": Data("unicode".utf8),
        ]
        try AsarBuilder.build(files: files, to: source)

        let archive = try AsarArchive.open(source)
        for (path, contents) in files {
            #expect(try archive.readFile(path) == contents)
            #expect(try archive.verifyIntegrity(of: path))
        }

        let replacement = Data(#""use strict";;(function(){})();\nconsole.log(2);"#.utf8)
        let output = dir.appending(path: "out.asar")
        let result = try archive.write(to: output, replacing: [".vite/build/index.pre.js": replacement])
        let reopened = try AsarArchive.open(output)
        #expect(reopened.headerSHA256 == result.headerSHA256)
        #expect(try reopened.readFile(".vite/build/index.pre.js") == replacement)
        #expect(try reopened.verifyIntegrity(of: ".vite/build/index.pre.js"))
        #expect(try reopened.readFile(".vite/build/other.js") == files[".vite/build/other.js"])
        #expect(try reopened.readFile("assets/한글 파일.txt") == files["assets/한글 파일.txt"])
        let blocks = ((try reopened.entry(".vite/build/other.js"))["integrity"] as? [String: Any])?["blocks"] as? [String]
        #expect(blocks?.count == 2)
    }

    @Test func rejectsGarbage() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "bad.asar")
        try Data(repeating: 7, count: 64).write(to: url)
        #expect(throws: BarracksError.self) { try AsarArchive.open(url) }
    }
}

@Suite struct BootstrapTests {
    let config = ProfileBootstrapConfig(profileID: "ABC", environment: ["CLAUDE_USER_DATA_DIR": "/Users/me/Library/Application Support/Barracks/Profiles/a\"b", "CLAUDE_CONFIG_DIR": "/tmp/code"])

    @Test func insertsAfterStrictDirectiveWithSeparator() throws {
        let source = Data(#""use strict";(function(){var a=1})();"#.utf8)
        let hooked = try ProfileBootstrap.inject(into: source, config: config)
        let text = String(decoding: hooked, as: UTF8.self)
        #expect(text.hasPrefix(#""use strict";;(function(){"#))
        #expect(text.contains("})();\n(function(){var a=1})();"))
        #expect(ProfileBootstrap.containsHook(hooked, profileID: "ABC"))
        try ProfileBootstrap.checkSyntax(hooked, label: "hooked")
    }

    @Test func handlesMissingDirective() throws {
        let hooked = try ProfileBootstrap.inject(into: Data("module.exports=1;".utf8), config: config)
        #expect(String(decoding: hooked, as: UTF8.self).hasSuffix(";\nmodule.exports=1;"))
        try ProfileBootstrap.checkSyntax(hooked, label: "hooked")
    }

    @Test func refusesAlreadyHookedSources() throws {
        let once = try ProfileBootstrap.inject(into: Data(#""use strict";x();"#.utf8), config: config)
        #expect(throws: BarracksError.self) { try ProfileBootstrap.inject(into: once, config: config) }
        let legacy = Data(#""use strict";;(function(){process.env.CLAUDE_PROFILE="Work"})();"#.utf8)
        #expect(throws: BarracksError.self) { try ProfileBootstrap.inject(into: legacy, config: config) }
    }

    @Test func syntaxCheckCatchesBrokenCode() {
        #expect(throws: BarracksError.self) { try ProfileBootstrap.checkSyntax(Data("function(".utf8), label: "broken") }
    }

    @Test func syntaxCheckAllowsCommonJSReturn() throws {
        try ProfileBootstrap.checkSyntax(Data("if (x) return; module.exports = 1;".utf8), label: "cjs")
    }

    @Test func escapesStrings() {
        #expect(ProfileBootstrap.jsString("a\"b\\c\n\u{2028}") == "\"a\\\"b\\\\c\\n\\u2028\"")
    }
}

@Suite struct NameTests {
    @Test func normalizesWhitespace() throws {
        #expect(try ProfileNameRules.normalize("  Side   Project ") == "Side Project")
    }

    @Test func rejectsBadNames() {
        for bad in ["", "   ", "a/b", "a:b", ".hidden", String(repeating: "x", count: 41), "tab\u{0007}"] {
            #expect(throws: BarracksError.self) { try ProfileNameRules.normalize(bad) }
        }
    }

    @Test func comparesCaseInsensitively() {
        #expect(ProfileNameRules.isSameName("Work", "work"))
        #expect(!ProfileNameRules.isSameName("Work", "Works"))
    }

    @Test func tokensAreStableAndBundleSafe() {
        let id = UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!
        #expect(Profile.makeToken(from: id) == "123456789a")
        #expect(Profile.bundleIdentifier(forToken: "123456789a", provider: .claude) == "com.anthropic.claudefordesktop.barracks.p123456789a")
        #expect(Profile.bundleIdentifier(forToken: "123456789a", provider: .chatgpt) == "com.openai.codex.barracks.p123456789a")
    }
}

@Suite struct RegistryTests {
    @Test func savesAndLoads() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = BarracksPaths.sandboxed(root: dir)
        let registry = ProfileRegistry(paths: paths)
        #expect(try registry.load().isEmpty)
        let id = UUID()
        let profile = Profile(id: id, provider: .claude, token: Profile.makeToken(from: id), name: "Work", color: .teal, customColor: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000), lastLaunchedAt: nil, dataDirectory: "/tmp/w", dataDirectoryAdopted: false, isolateToolConfig: true, bundleIdentifier: "x", appBundlePath: nil, build: nil)
        try registry.mutate { $0.append(profile) }
        #expect(try registry.load() == [profile])
        #expect(profile.toolConfigDirectory == "/tmp/w/claude-code-config")
        #expect(profile.launchEnvironment["CLAUDE_USER_DATA_DIR"] == "/tmp/w")
        var gpt = profile
        gpt.provider = .chatgpt
        gpt.isolateToolConfig = false
        #expect(gpt.toolConfigDirectory == "/tmp/w/codex-home")
        #expect(gpt.launchEnvironment["CODEX_ELECTRON_USER_DATA_PATH"] == "/tmp/w")
        #expect(gpt.launchEnvironment["CODEX_HOME"] == "/tmp/w/codex-home")
        #expect(gpt.launchEnvironment["CODEX_SPARKLE_ENABLED"] == "false")
        #expect(gpt.launchEnvironment["CLAUDE_USER_DATA_DIR"] == nil)
    }

    @Test func rejectsNewerSchema() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = BarracksPaths.sandboxed(root: dir)
        try paths.ensureBaseDirectories()
        try Data(#"{"schemaVersion":99,"profiles":[]}"#.utf8).write(to: paths.registryURL)
        #expect(throws: BarracksError.self) { try ProfileRegistry(paths: paths).load() }
    }
}

@Suite struct PlistTests {
    @Test func rewritesNestedBundleIdentifiersOnly() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appending(path: "Test.app")
        let helper = app.appending(path: "Contents/Frameworks/Helper.app/Contents")
        let other = app.appending(path: "Contents/Frameworks/Other.framework/Resources")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        func write(_ id: String, to url: URL) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            try data.write(to: url.appending(path: "Info.plist"))
        }
        try write("com.anthropic.claudefordesktop", to: app.appending(path: "Contents"))
        try write("com.anthropic.claudefordesktop.helper", to: helper)
        try write("com.github.Electron.framework", to: other)
        let changed = try InfoPlistEditor.rewriteNestedBundleIdentifiers(appURL: app, from: "com.anthropic.claudefordesktop", to: "com.example.p1")
        #expect(changed == 1)
        #expect(try PlistDocument.read(helper.appending(path: "Info.plist")).values["CFBundleIdentifier"] as? String == "com.example.p1.helper")
        #expect(try PlistDocument.read(other.appending(path: "Info.plist")).values["CFBundleIdentifier"] as? String == "com.github.Electron.framework")
        #expect(try PlistDocument.read(app.appending(path: "Contents/Info.plist")).values["CFBundleIdentifier"] as? String == "com.anthropic.claudefordesktop")
    }
}

@Suite struct PathTests {
    @Test func descendantChecksDoNotMatchSiblingPrefixes() {
        let claude = URL(filePath: "/tmp/AS/Claude")
        #expect(!URL(filePath: "/tmp/AS/Barracks/Profiles/x").isSameOrDescendant(of: claude))
        #expect(!URL(filePath: "/tmp/AS/Claude-Work").isSameOrDescendant(of: claude))
        #expect(URL(filePath: "/tmp/AS/Claude/Local State").isSameOrDescendant(of: claude))
    }
}

@Suite struct IconTests {
    @Test func rendersIcons() throws {
        #expect(IconComposer.renderProfileIcon(color: .violet, name: "한글", size: 64) != nil)
        #expect(IconComposer.renderAppIcon(size: 64) != nil)
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "p.icns")
        try IconComposer.writeProfileIcns(tint: .preset(.rose), name: "Personal", to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct AccountTests {
    func v8(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return [0x22, UInt8(bytes.count)] + bytes
    }

    func v8TwoByte(_ text: String) -> [UInt8] {
        let units = Array(text.utf16)
        var out: [UInt8] = [0x63, UInt8(units.count * 2)]
        for unit in units { out += [UInt8(unit & 0xff), UInt8(unit >> 8)] }
        return out
    }

    @Test func readsMatchingAccountFromIndexedDBBlob() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let uuid = "8019eb2b-dcc5-4a26-b9d2-ba2090f4b14d"
        try Data(#"{"lastKnownAccountUuid":"\#(uuid.uppercased())"}"#.utf8).write(to: dir.appending(path: "config.json"))
        let blobDir = dir.appending(path: "IndexedDB/https_claude.ai_0.indexeddb.blob/1/00")
        try FileManager.default.createDirectory(at: blobDir, withIntermediateDirectories: true)
        var blob: [UInt8] = [0xff, 0x0f, 0x6f]
        blob += v8("uuid") + v8("11111111-2222-3333-4444-555555555555") + v8("email_address") + v8("other@example.com")
        blob += Array(repeating: 0x41, count: 64)
        blob += v8("uuid") + v8(uuid) + v8("email_address") + [0x00] + v8("me@example.com") + v8("full_name") + v8TwoByte("한수훈") + v8("display_name") + [0x30]
        try Data(blob).write(to: blobDir.appending(path: "26"))
        let codeDir = dir.appending(path: "code")
        try FileManager.default.createDirectory(at: codeDir, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"code@example.com"}}"#.utf8).write(to: codeDir.appending(path: ".claude.json"))

        let info = AccountInspector.inspect(provider: .claude, dataDirectory: dir, toolConfigDirectory: codeDir, home: dir)
        #expect(info.accountUUID == uuid)
        #expect(info.email == "me@example.com")
        #expect(info.fullName == "한수훈")
        #expect(info.displayName == nil)
        #expect(info.toolEmail == "code@example.com")
        #expect(info.headline == "me@example.com")
    }

    @Test func emptyFolderMeansNoAccount() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = AccountInspector.inspect(provider: .claude, dataDirectory: dir, toolConfigDirectory: dir, home: dir)
        #expect(info.isEmpty)
        #expect(info.headline == nil)
    }
}

@Suite struct CodexAccountTests {
    @Test func readsEmailNameAndPlanFromIdToken() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claims: [String: Any] = [
            "email": "gpt@example.com",
            "name": "Test User",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_account_id": "acct-1"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let auth: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["id_token": "eyJhbGciOiJub25lIn0.\(payload).sig"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: dir.appending(path: "auth.json"))
        let info = AccountInspector.inspect(provider: .chatgpt, dataDirectory: dir, toolConfigDirectory: dir, home: dir)
        #expect(info.email == "gpt@example.com")
        #expect(info.fullName == "Test User")
        #expect(info.plan == "Plus")
        #expect(info.accountUUID == "acct-1")
    }

    @Test func missingLoginMeansNoAccount() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AccountInspector.inspect(provider: .chatgpt, dataDirectory: dir, toolConfigDirectory: dir, home: dir).isEmpty)
    }
}

@Suite struct TintTests {
    @Test func parsesPresetsAndHex() {
        #expect(ProfileTint.parse("teal") == .preset(.teal))
        #expect(ProfileTint.parse("#ff8800")?.cacheKey == "#FF8800")
        #expect(ProfileTint.parse("f80")?.cacheKey == "#FF8800")
        #expect(ProfileTint.parse("#12345") == nil)
        #expect(ProfileTint.parse("purple-ish") == nil)
    }

    @Test func customColorOverridesPresetAndClears() {
        let id = UUID()
        var profile = Profile(id: id, provider: .claude, token: "t", name: "W", color: .teal, customColor: nil, createdAt: Date(), lastLaunchedAt: nil, dataDirectory: "/tmp/w", dataDirectoryAdopted: false, isolateToolConfig: true, bundleIdentifier: "x", appBundlePath: nil, build: nil)
        profile.apply(.custom(RGBColor(hex: "#102030")!))
        #expect(profile.customColor == "#102030")
        #expect(profile.tint == .custom(RGBColor(hex: "#102030")!))
        profile.apply(.preset(.rose))
        #expect(profile.customColor == nil)
        #expect(profile.tint == .preset(.rose))
    }

    @Test func oldRegistryWithoutCustomColorStillDecodes() throws {
        let json = #"{"id":"3388F368-CE72-4CC1-871B-613C45EFADFF","provider":"claude","token":"t","name":"W","color":"teal","createdAt":"2026-09-29T00:00:00Z","dataDirectory":"/tmp/w","dataDirectoryAdopted":false,"isolateToolConfig":true,"bundleIdentifier":"x"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(Profile.self, from: Data(json.utf8))
        #expect(profile.tint == .preset(.teal))
    }

    @Test func rendersCustomIcon() {
        #expect(IconComposer.renderProfileIcon(tint: .custom(RGBColor(hex: "#00AAFF")!), name: "Z", provider: .chatgpt, size: 64) != nil)
    }
}

@Suite struct LaunchWrapperTests {
    @Test func pinsDataFolderArgument() {
        let id = UUID()
        let profile = Profile(id: id, provider: .chatgpt, token: "t", name: "W", color: .teal, customColor: nil, createdAt: Date(), lastLaunchedAt: nil, dataDirectory: "/Users/me/Library/Application Support/Barracks/Profiles/x", dataDirectoryAdopted: false, isolateToolConfig: true, bundleIdentifier: "x", appBundlePath: nil, build: nil)
        #expect(LaunchWrapper.launchArguments(for: profile) == ["--user-data-dir=/Users/me/Library/Application Support/Barracks/Profiles/x"])
    }
}

@Suite struct ComputerUseModeTests {
    @Test func placesAppInHiddenFolderAndKeepsOfficialIdentity() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = ProfileManager(paths: BarracksPaths.sandboxed(root: dir))
        let id = UUID()
        var profile = Profile(id: id, provider: .chatgpt, token: "abc123", name: "Work", color: .teal, customColor: nil, createdAt: Date(), lastLaunchedAt: nil, dataDirectory: "/tmp/w", dataDirectoryAdopted: false, isolateToolConfig: true, bundleIdentifier: "x", appBundlePath: nil, build: nil)
        #expect(!profile.usesComputerUseMode)
        #expect(manager.targetAppURL(for: profile).path.hasSuffix("/Applications/ChatGPT Work.app"))
        profile.computerUseMode = true
        #expect(profile.usesComputerUseMode)
        #expect(manager.targetAppURL(for: profile).path.hasSuffix("/Support/Apps.noindex/abc123/ChatGPT Work.app"))
        var claude = profile
        claude.provider = .claude
        #expect(!claude.usesComputerUseMode)
    }

    @Test func sidecarMarksOwnership() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appending(path: "tok/ChatGPT Work.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let bundle = dir.appending(path: "tok/ChatGPT Work.app")
        let id = UUID()
        #expect(ProfileOwnership.owner(of: bundle) == nil)
        try ProfileOwnership.writeSidecar(for: bundle, profileID: id)
        #expect(ProfileOwnership.isOwned(bundle, by: id))
        #expect(!ProfileOwnership.isOwned(bundle, by: UUID()))
    }
}

@Suite struct IconRecolorTests {
    static func syntheticIcon(background: (Double, Double, Double), glyph: (Double, Double, Double), size: Int = 128) -> CGImage {
        let context = IconComposer.makeContext(size: size)!
        context.setFillColor(CGColor(srgbRed: background.0, green: background.1, blue: background.2, alpha: 1))
        context.fill(CGRect(x: size / 10, y: size / 10, width: size * 8 / 10, height: size * 8 / 10))
        context.setFillColor(CGColor(srgbRed: glyph.0, green: glyph.1, blue: glyph.2, alpha: 1))
        context.fill(CGRect(x: size * 3 / 10, y: size * 3 / 10, width: size * 4 / 10, height: size * 4 / 10))
        return context.makeImage()!
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> SIMD3<Double> {
        let pixels = Pixels(image)!
        return pixels.color(at: (y * pixels.width + x) * 4)
    }

    static func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tolerance: Double = 0.03) -> Bool {
        IconRecolor.distance(a, b) <= tolerance
    }

    @Test func detectsBackgroundFromTileBorderAndGlyph() throws {
        let image = Self.syntheticIcon(background: (0.9, 0.4, 0.25), glyph: (1, 1, 1))
        let palette = try #require(IconRecolor.analyze(image))
        #expect(Self.close(palette.background, SIMD3(0.9, 0.4, 0.25)))
        #expect(Self.close(try #require(palette.glyph), SIMD3(1, 1, 1)))
    }

    @Test func swapsBackgroundAndKeepsGlyph() throws {
        let image = Self.syntheticIcon(background: (0.9, 0.4, 0.25), glyph: (1, 1, 1))
        let palette = try #require(IconRecolor.analyze(image))
        let result = try #require(IconRecolor.recolor(image, palette: palette, tint: RGBColor(red: 0.2, green: 0.6, blue: 0.6)))
        #expect(Self.close(Self.pixel(result, x: 20, y: 20), SIMD3(0.2, 0.6, 0.6)))
        #expect(Self.close(Self.pixel(result, x: 64, y: 64), SIMD3(1, 1, 1)))
        #expect(Pixels(result)!.data[3] == 0)
    }

    @Test func flipsGlyphWhenTintHidesIt() throws {
        let image = Self.syntheticIcon(background: (0.97, 0.97, 0.97), glyph: (0.15, 0.15, 0.2))
        let palette = try #require(IconRecolor.analyze(image))
        let result = try #require(IconRecolor.recolor(image, palette: palette, tint: RGBColor(red: 0.13, green: 0.13, blue: 0.13)))
        #expect(Self.close(Self.pixel(result, x: 20, y: 20), SIMD3(0.13, 0.13, 0.13)))
        #expect(IconRecolor.luminance(Self.pixel(result, x: 64, y: 64)) > 0.8)
        let kept = try #require(IconRecolor.recolor(image, palette: palette, tint: RGBColor(red: 0.9, green: 0.6, blue: 0.2)))
        #expect(Self.close(Self.pixel(kept, x: 64, y: 64), SIMD3(0.15, 0.15, 0.2)))
    }
}

@Suite struct LegacyMigrationTests {
    func fakeHome() throws -> (URL, BarracksPaths) {
        let home = try scratchDirectory()
        let paths = BarracksPaths(
            home: home,
            supportRoot: home.appending(path: "Library/Application Support/Barracks", directoryHint: .isDirectory),
            appsRoot: home.appending(path: "Applications/Barracks", directoryHint: .isDirectory),
            logsRoot: home.appending(path: "Library/Logs/Barracks", directoryHint: .isDirectory),
            registersWithLaunchServices: false
        )
        return (home, paths)
    }

    @Test func detectsClaudeWorkAppAndData() throws {
        let (home, paths) = try fakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(LegacyClaudeWork.state(main: nil, paths: paths).isEmpty)
        let contents = home.appending(path: "Applications/Claude Work.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": LegacyClaudeWork.workBundleIdentifier], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        let data = paths.applicationSupportDirectory.appending(path: "Claude-Work")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: data.appending(path: "config.json"))
        let state = LegacyClaudeWork.state(main: nil, paths: paths)
        #expect(state.workApp?.lastPathComponent == "Claude Work.app")
        #expect(state.workData?.lastPathComponent == "Claude-Work")
        #expect(state.canImportWork)
        #expect(!state.canRestoreDefault)
    }

    @Test func ignoresForeignAppNamedClaudeWork() throws {
        let (home, paths) = try fakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let contents = home.appending(path: "Applications/Claude Work.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.other"], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        #expect(LegacyClaudeWork.state(main: nil, paths: paths).workApp == nil)
    }

    @Test func parsesMainRecord() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = String(repeating: "a", count: 64)
        let b = String(repeating: "b", count: 64)
        try Data("2.9939.4\n\(a)\n\(b)\n10\n".utf8).write(to: root.appending(path: "main-source"))
        #expect(LegacyClaudeWork.mainRecord(root: root) == LegacyClaudeWork.MainRecord(version: "2.9939.4", sourceSHA256: a, patchedSHA256: b))
        try Data("2.9939.4\nnot-a-hash\n\(b)\n".utf8).write(to: root.appending(path: "main-source"))
        #expect(LegacyClaudeWork.mainRecord(root: root) == nil)
    }
}

@Suite struct ExtraRunnerTests {
    struct Fixture {
        var root: URL
        var archive: AsarArchive
        var bundle: ExtraBundle
        var work: URL
    }

    static func script(_ body: String) -> Data {
        Data("#!/bin/sh\nset -e\n\(body)\n".utf8)
    }

    func fixture(index: String = "\"use strict\";require(\"./index.chunk-a1.js\");", patches: [(String, String, Data)]) throws -> Fixture {
        let root = try scratchDirectory()
        let asar = root.appending(path: "app.asar")
        try AsarBuilder.build(files: [
            ".vite/build/index.js": Data(index.utf8),
            ".vite/build/index.chunk-a1.js": Data("var one=1;".utf8),
            ".vite/build/index.chunk-b2.js": Data("var two=2;".utf8),
            ".vite/build/mainView.js": Data("view();".utf8),
        ], to: asar)
        let bundleRoot = root.appending(path: "Extra", directoryHint: .isDirectory)
        var entries: [[String: Any]] = []
        for (name, target, body) in patches {
            let binary = bundleRoot.appending(path: "patches/core/\(name)")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            entries.append(["name": name, "binary": "patches/core/\(name)", "target": target, "sha256": Hashing.sha256Hex(body)])
        }
        let append = Data(";/*appended*/\n".utf8)
        try append.write(to: bundleRoot.appending(path: "main-append.js"))
        let manifest: [String: Any] = [
            "format": 1, "upstream": "test", "commit": String(repeating: "d", count: 40), "script": "x",
            "patches": entries, "mainTarget": ".vite/build/index.js", "mainAppend": "main-append.js",
            "mainAppendSHA256": Hashing.sha256Hex(append), "staleMarkers": ["__cdb", "__nav_spoof_applied"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: bundleRoot.appending(path: "manifest.json"))
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return Fixture(root: root, archive: try AsarArchive.open(asar), bundle: try ExtraBundle.load(root: bundleRoot), work: work)
    }

    @Test func patchesChunkedBundleAndAppendsStartupModule() throws {
        let f = try fixture(patches: [
            ("p1", ".vite/build/index.js", Self.script("printf 'globalThis.__cdbT=1;' >> \"$1\"")),
            ("p2", ".vite/build/mainView.js", Self.script("printf 'patched();' >> \"$1\"")),
        ])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let replacements = try ExtraBuilder.patchedFiles(archive: f.archive, bundle: f.bundle, work: f.work)
        #expect(Set(replacements.keys) == [".vite/build/index.js", ".vite/build/index.chunk-b2.js", ".vite/build/mainView.js"])
        #expect(String(decoding: replacements[".vite/build/index.chunk-b2.js"]!, as: UTF8.self) == "var two=2;globalThis.__cdbT=1;")
        #expect(String(decoding: replacements[".vite/build/index.js"]!, as: UTF8.self).hasSuffix(";/*appended*/\n"))
        #expect(String(decoding: replacements[".vite/build/mainView.js"]!, as: UTF8.self) == "view();patched();")
        let output = f.root.appending(path: "out.asar")
        _ = try f.archive.write(to: output, replacing: replacements)
        let written = try AsarArchive.open(output)
        #expect(try written.verifyIntegrity(of: ".vite/build/index.chunk-b2.js"))
        #expect(String(decoding: try written.readFile(".vite/build/index.chunk-a1.js"), as: UTF8.self) == "var one=1;")
    }

    @Test func rejectsAlreadyPatchedInput() throws {
        let f = try fixture(index: "\"use strict\";var __cdbOld=1;require(\"./index.chunk-a1.js\");", patches: [
            ("p1", ".vite/build/index.js", Self.script("true")),
        ])
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(throws: BarracksError.self) { try ExtraBuilder.patchedFiles(archive: f.archive, bundle: f.bundle, work: f.work) }
    }

    @Test func failsWhenPatchDoesNotFit() throws {
        let f = try fixture(patches: [("p1", ".vite/build/index.js", Self.script("exit 3"))])
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(throws: BarracksError.self) { try ExtraBuilder.patchedFiles(archive: f.archive, bundle: f.bundle, work: f.work) }
    }

    @Test func failsWhenPatchBreaksChunkMarkers() throws {
        let f = try fixture(patches: [("p1", ".vite/build/index.js", Self.script("printf 'x' > \"$1\""))])
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(throws: BarracksError.self) { try ExtraBuilder.patchedFiles(archive: f.archive, bundle: f.bundle, work: f.work) }
    }

    @Test func failsOnCrossChunkLocalIdentifier() throws {
        let f = try fixture(patches: [("p1", ".vite/build/index.js", Self.script("printf 'var __cdbLocal=1;' | cat - \"$1\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\" && printf '__cdbLocal();' >> \"$1\""))])
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(throws: BarracksError.self) { try ExtraBuilder.patchedFiles(archive: f.archive, bundle: f.bundle, work: f.work) }
    }

    @Test func rejectsTamperedPatchBinary() throws {
        let f = try fixture(patches: [("p1", ".vite/build/index.js", Self.script("true"))])
        defer { try? FileManager.default.removeItem(at: f.root) }
        try Self.script("echo evil").write(to: f.bundle.root.appending(path: "patches/core/p1"))
        #expect(throws: BarracksError.self) { try ExtraBundle.load(root: f.bundle.root) }
    }
}
