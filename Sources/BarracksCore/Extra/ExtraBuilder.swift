import Foundation

public struct ExtraBundle: Sendable {
    public struct Patch: Codable, Sendable, Equatable {
        public var name: String
        public var binary: String
        public var target: String
        public var sha256: String
    }

    struct Manifest: Codable, Sendable {
        var format: Int
        var upstream: String
        var commit: String
        var script: String
        var patches: [Patch]
        var mainTarget: String
        var mainAppend: String
        var mainAppendSHA256: String
        var staleMarkers: [String]
    }

    public static let supportedFormat = 1
    public static let folderName = "Extra"

    public let root: URL
    let manifest: Manifest
    public let manifestSHA256: String

    public var commit: String { manifest.commit }
    public var patches: [Patch] { manifest.patches }

    public static func candidates() -> [URL] {
        var urls: [URL] = []
        if let override = ProcessInfo.processInfo.environment["BARRACKS_EXTRA_BUNDLE"] { urls.append(URL(filePath: override, directoryHint: .isDirectory)) }
        if let resources = Bundle.main.resourceURL { urls.append(resources.appending(path: folderName, directoryHint: .isDirectory)) }
        let executable = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        urls.append(executable.appending(path: folderName, directoryHint: .isDirectory))
        var cursor = executable
        for _ in 0..<6 {
            urls.append(cursor.appending(path: "build/Barracks.app/Contents/Resources/\(folderName)", directoryHint: .isDirectory))
            cursor = cursor.deletingLastPathComponent()
        }
        return urls
    }

    public static func locate() -> ExtraBundle? {
        for url in candidates() where FileManager.default.fileExists(atPath: url.appending(path: "manifest.json").path) {
            do {
                return try load(root: url)
            } catch {
                Log.warning("extra.bundle_rejected", ["path": url.path, "error": error.localizedDescription])
            }
        }
        return nil
    }

    public static func load(root: URL) throws -> ExtraBundle {
        let manifestURL = root.appending(path: "manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.format == supportedFormat else {
            throw BarracksError.extraUnavailable("Extra bundle format \(manifest.format) is not supported.")
        }
        guard !manifest.patches.isEmpty else { throw BarracksError.extraUnavailable("The Extra bundle has no patches.") }
        for patch in manifest.patches {
            guard !patch.binary.contains(".."), !patch.target.contains(".."), !patch.target.contains("*") else {
                throw BarracksError.extraUnavailable("The Extra bundle has an unsafe path in \(patch.name).")
            }
            let binary = root.appending(path: patch.binary)
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                throw BarracksError.extraUnavailable("The Extra patch \(patch.name) is missing.")
            }
            guard try Hashing.sha256Hex(fileAt: binary) == patch.sha256 else {
                throw BarracksError.extraUnavailable("The Extra patch \(patch.name) was modified.")
            }
        }
        guard try Hashing.sha256Hex(fileAt: root.appending(path: manifest.mainAppend)) == manifest.mainAppendSHA256 else {
            throw BarracksError.extraUnavailable("The Extra startup module was modified.")
        }
        return ExtraBundle(root: root, manifest: manifest, manifestSHA256: Hashing.sha256Hex(data))
    }

    public func mainAppendText() throws -> String {
        try String(contentsOf: root.appending(path: manifest.mainAppend), encoding: .utf8)
    }
}

public enum ExtraBuilder {
    static let splitPrefix = Data("\n/*__CDB_SPLIT__".utf8)
    static let windowControlsMarker = "__cdbClaudeWorkMacWindowControls"
    static let fontsMarker = "var M=\"__cdbFonts\""
    static let chunkLoaderMarker = "require(\"./index.chunk-"

    public static func root(paths: BarracksPaths) -> URL {
        paths.supportRoot.appending(path: "Extra", directoryHint: .isDirectory)
    }

    static func bundle() throws -> ExtraBundle {
        guard let bundle = ExtraBundle.locate() else {
            throw BarracksError.extraUnavailable("This Barracks build doesn't include Extra.")
        }
        return bundle
    }

    public static func signature(sourceSHA256: String) throws -> String {
        signature(sourceSHA256: sourceSHA256, bundle: try bundle())
    }

    static func signature(sourceSHA256: String, bundle: ExtraBundle) -> String {
        "\(sourceSHA256.prefix(16))-\(bundle.commit.prefix(12))-\(bundle.manifestSHA256.prefix(12))"
    }

    public static func cachedBase(signature: String, paths: BarracksPaths) -> URL? {
        let url = root(paths: paths).appending(path: "bases/\(signature).asar")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func base(for source: AppInstallation, sourceSHA256: String, paths: BarracksPaths) throws -> URL {
        let bundle = try bundle()
        let signature = signature(sourceSHA256: sourceSHA256, bundle: bundle)
        if let cached = cachedBase(signature: signature, paths: paths) {
            Log.info("extra.base_cached", ["signature": signature])
            return cached
        }
        let extraRoot = root(paths: paths)
        let bases = extraRoot.appending(path: "bases", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bases, withIntermediateDirectories: true)
        let work = extraRoot.appending(path: "work-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let started = Date()
        Log.notice("extra.base_build_start", ["signature": signature, "source": source.appURL.path, "patches": String(bundle.patches.count)])

        let archive = try AsarArchive.open(source.asarURL)
        let replacements = try patchedFiles(archive: archive, bundle: bundle, work: work)
        let output = work.appending(path: "app.asar")
        _ = try archive.write(to: output, replacing: replacements)
        let written = try AsarArchive.open(output)
        for path in replacements.keys where try !written.verifyIntegrity(of: path) {
            throw BarracksError.asarMalformed("\(path) failed its integrity check after Extra was applied")
        }
        let destination = bases.appending(path: "\(signature).asar")
        try FileOps.swapOrMove(staged: output, target: destination)
        pruneBases(keeping: destination, in: bases)
        Log.notice("extra.base_built", [
            "signature": signature,
            "files": String(replacements.count),
            "seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
        ])
        return destination
    }

    public static func patchedFiles(archive: AsarArchive, bundle: ExtraBundle, work: URL) throws -> [String: Data] {
        var order: [String] = []
        var groups: [String: [ExtraBundle.Patch]] = [:]
        for patch in bundle.patches {
            if groups[patch.target] == nil { order.append(patch.target) }
            groups[patch.target, default: []].append(patch)
        }
        let markers = bundle.manifest.staleMarkers.map { Data($0.utf8) }
        var replacements: [String: Data] = [:]
        for (index, target) in order.enumerated() {
            let parts = try chunkParts(of: target, in: archive)
            let originals = try parts.map { try archive.readFile($0) }
            for (path, data) in zip(parts, originals) {
                if let marker = markers.first(where: { data.range(of: $0) != nil }) {
                    throw BarracksError.extraUnavailable("\(path) already contains \(String(decoding: marker, as: UTF8.self)); Extra needs the original Claude.")
                }
            }
            var staged = originals[0]
            for (path, data) in zip(parts.dropFirst(), originals.dropFirst()) {
                staged.append(marker(for: name(of: path)))
                staged.append(data)
            }
            let stagedURL = work.appending(path: "staged-\(index).js")
            try staged.write(to: stagedURL)
            for patch in groups[target] ?? [] {
                let result = try ProcessRunner.run(bundle.root.appending(path: patch.binary).path, [stagedURL.path], allowFailure: true, currentDirectory: work)
                guard result.status == 0 else {
                    let tail = String((result.stdoutString + result.stderrString).suffix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.error("extra.patch_failed", ["patch": patch.name, "status": String(result.status), "output": tail])
                    throw BarracksError.extraUnavailable("Extra patch \(patch.name) doesn't fit this Claude version (exit \(result.status)).")
                }
                Log.info("extra.patch_applied", ["patch": patch.name, "target": target])
            }
            let pieces = try split(try Data(contentsOf: stagedURL), parts: parts)
            try checkCrossPartIdentifiers(pieces, names: parts.map(name(of:)))
            for (position, path) in parts.enumerated() where pieces[position] != originals[position] {
                replacements[path] = pieces[position]
            }
        }
        let mainTarget = bundle.manifest.mainTarget
        let mainData = try replacements[mainTarget] ?? archive.readFile(mainTarget)
        let mainText = String(decoding: mainData, as: UTF8.self)
        guard mainText.contains(chunkLoaderMarker), !mainText.contains(windowControlsMarker), !mainText.contains(fontsMarker) else {
            throw BarracksError.extraUnavailable("Claude's main loader changed; Extra's startup module was not added.")
        }
        replacements[mainTarget] = Data((mainText + (try bundle.mainAppendText())).utf8)
        Log.info("extra.main_appended", ["target": mainTarget])
        return replacements
    }

    static func name(of path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    static func parent(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    static func chunkParts(of target: String, in archive: AsarArchive) throws -> [String] {
        let fileName = name(of: target)
        let dot = fileName.lastIndex(of: ".")
        let stem = dot.map { String(fileName[..<$0]) } ?? fileName
        let suffix = dot.map { String(fileName[$0...]) } ?? ""
        let directory = parent(of: target)
        _ = try archive.readFile(target)
        let chunks = try archive.childFiles(of: directory)
            .filter { candidate in
                guard candidate != fileName, candidate.hasPrefix(stem), candidate.hasSuffix(suffix), candidate.count >= stem.count + suffix.count else { return false }
                return candidate.dropFirst(stem.count).dropLast(suffix.count).contains(".chunk-")
            }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let prefix = directory.isEmpty ? "" : directory + "/"
        return [target] + chunks.map { prefix + $0 }
    }

    static func marker(for name: String) -> Data {
        Data("\n/*__CDB_SPLIT__\(name)__*/\n".utf8)
    }

    static func split(_ blob: Data, parts: [String]) throws -> [Data] {
        var count = 0
        var cursor = blob.startIndex
        while let range = blob.range(of: splitPrefix, in: cursor..<blob.endIndex) {
            count += 1
            cursor = range.upperBound
        }
        guard count == parts.count - 1 else {
            throw BarracksError.extraUnavailable("Extra chunk markers were corrupted (expected \(parts.count - 1), found \(count)).")
        }
        var pieces: [Data] = []
        var start = blob.startIndex
        for path in parts.dropFirst() {
            guard let range = blob.range(of: marker(for: name(of: path)), in: start..<blob.endIndex) else {
                throw BarracksError.extraUnavailable("Extra chunk marker for \(name(of: path)) is missing.")
            }
            pieces.append(blob.subdata(in: start..<range.lowerBound))
            start = range.upperBound
        }
        pieces.append(blob.subdata(in: start..<blob.endIndex))
        return pieces
    }

    static func checkCrossPartIdentifiers(_ contents: [Data], names: [String]) throws {
        guard contents.count > 1 else { return }
        let globalPattern = try NSRegularExpression(pattern: #"globalThis\.(__cdb[A-Za-z0-9_$]*)\s*="#)
        let barePattern = try NSRegularExpression(pattern: #"(?<![.A-Za-z0-9_$])(__cdb[A-Za-z0-9_$]*)"#)
        var globals = Set<String>()
        var owners: [String: Set<String>] = [:]
        for (name, content) in zip(names, contents) {
            let text = String(decoding: content, as: UTF8.self)
            let range = NSRange(text.startIndex..., in: text)
            for match in globalPattern.matches(in: text, range: range) {
                if let found = Range(match.range(at: 1), in: text) { globals.insert(String(text[found])) }
            }
            for match in barePattern.matches(in: text, range: range) {
                if let found = Range(match.range(at: 1), in: text) { owners[String(text[found]), default: []].insert(name) }
            }
        }
        let broken = owners.filter { $0.value.count > 1 && !globals.contains($0.key) }.keys.sorted()
        guard broken.isEmpty else {
            throw BarracksError.extraUnavailable("Extra would break across Claude's code chunks: \(broken.joined(separator: ", ")).")
        }
    }

    static func pruneBases(keeping: URL, in directory: URL, limit: Int = 3) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let sorted = items
            .filter { $0.pathExtension == "asar" && $0.standardizedPath != keeping.standardizedPath }
            .sorted { ((try? $0.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast) > ((try? $1.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast) }
        for stale in sorted.dropFirst(max(0, limit - 1)) {
            try? FileManager.default.removeItem(at: stale)
            Log.info("extra.base_pruned", ["file": stale.lastPathComponent])
        }
    }
}
