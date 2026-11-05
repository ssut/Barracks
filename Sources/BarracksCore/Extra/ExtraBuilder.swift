import Foundation

public struct ExtraBundle: Sendable {
    public struct Patch: Codable, Sendable, Equatable {
        public var name: String
        public var binary: String
        public var target: String
        public var sha256: String
    }

    public struct Generation: Codable, Sendable, Equatable {
        public var id: String
        public var minimumClaudeVersion: String
        public var commit: String
        public var patches: [Patch]
        public var mainAppend: String
        public var mainAppendSHA256: String
    }

    struct Manifest: Decodable, Sendable {
        var format: Int
        var upstream: String
        var script: String
        var mainTarget: String
        var staleMarkers: [String]
        var generations: [Generation]

        enum CodingKeys: String, CodingKey {
            case format, upstream, script, mainTarget, staleMarkers, generations, commit, patches, mainAppend, mainAppendSHA256
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decode(Int.self, forKey: .format)
            guard ExtraBundle.supportedFormats.contains(format) else {
                throw BarracksError.extraUnavailable("Extra bundle format \(format) is not supported.")
            }
            upstream = try container.decode(String.self, forKey: .upstream)
            script = try container.decode(String.self, forKey: .script)
            mainTarget = try container.decode(String.self, forKey: .mainTarget)
            staleMarkers = try container.decode([String].self, forKey: .staleMarkers)
            if format == 1 {
                let commit = try container.decode(String.self, forKey: .commit)
                generations = [Generation(
                    id: String(commit.prefix(12)),
                    minimumClaudeVersion: "0",
                    commit: commit,
                    patches: try container.decode([Patch].self, forKey: .patches),
                    mainAppend: try container.decode(String.self, forKey: .mainAppend),
                    mainAppendSHA256: try container.decode(String.self, forKey: .mainAppendSHA256)
                )]
            } else {
                generations = try container.decode([Generation].self, forKey: .generations)
            }
        }
    }

    public static let supportedFormats: Set<Int> = [1, 2]
    public static let folderName = "Extra"

    public let root: URL
    let manifest: Manifest
    public let manifestSHA256: String

    public var generations: [Generation] { manifest.generations }

    public func generations(forClaudeVersion version: String) -> [Generation] {
        let ordered = manifest.generations.sorted { (ClaudeVersion($0.minimumClaudeVersion) ?? .zero) > (ClaudeVersion($1.minimumClaudeVersion) ?? .zero) }
        guard let installed = ClaudeVersion(version) else { return ordered }
        guard let preferred = ordered.firstIndex(where: { (ClaudeVersion($0.minimumClaudeVersion) ?? .zero) <= installed }) else { return ordered.reversed() }
        return [ordered[preferred]] + ordered.indices.filter { $0 != preferred }.map { ordered[$0] }
    }

    public func preferredGeneration(forClaudeVersion version: String) -> Generation {
        generations(forClaudeVersion: version)[0]
    }

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
        guard !manifest.generations.isEmpty else { throw BarracksError.extraUnavailable("The Extra bundle has no patch sets.") }
        guard Set(manifest.generations.map(\.id)).count == manifest.generations.count else {
            throw BarracksError.extraUnavailable("The Extra bundle lists a patch set twice.")
        }
        for generation in manifest.generations {
            guard ClaudeVersion(generation.minimumClaudeVersion) != nil else {
                throw BarracksError.extraUnavailable("The Extra patch set \(generation.id) has an invalid Claude version \(generation.minimumClaudeVersion).")
            }
            guard !generation.patches.isEmpty else { throw BarracksError.extraUnavailable("The Extra patch set \(generation.id) has no patches.") }
            for patch in generation.patches {
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
            guard !generation.mainAppend.contains("..") else {
                throw BarracksError.extraUnavailable("The Extra bundle has an unsafe startup module path in \(generation.id).")
            }
            guard try Hashing.sha256Hex(fileAt: root.appending(path: generation.mainAppend)) == generation.mainAppendSHA256 else {
                throw BarracksError.extraUnavailable("The Extra startup module was modified.")
            }
        }
        return ExtraBundle(root: root, manifest: manifest, manifestSHA256: Hashing.sha256Hex(data))
    }

    public func mainAppendText(for generation: Generation) throws -> String {
        try String(contentsOf: root.appending(path: generation.mainAppend), encoding: .utf8)
    }
}

struct ClaudeVersion: Comparable, Sendable {
    static let zero = ClaudeVersion(components: [0])

    let components: [Int]

    private init(components: [Int]) {
        self.components = components
    }

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            values.append(value)
        }
        components = values
    }

    static func < (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
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

    public static func signature(sourceSHA256: String, claudeVersion: String) throws -> String {
        signature(sourceSHA256: sourceSHA256, claudeVersion: claudeVersion, bundle: try bundle())
    }

    static func signature(sourceSHA256: String, claudeVersion: String, bundle: ExtraBundle) -> String {
        let generation = bundle.preferredGeneration(forClaudeVersion: claudeVersion)
        return "\(sourceSHA256.prefix(16))-\(generation.commit.prefix(12))-\(bundle.manifestSHA256.prefix(12))"
    }

    public static func cachedBase(signature: String, paths: BarracksPaths) -> URL? {
        let url = root(paths: paths).appending(path: "bases/\(signature).asar")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func base(for source: AppInstallation, sourceSHA256: String, paths: BarracksPaths) throws -> URL {
        let bundle = try bundle()
        let signature = signature(sourceSHA256: sourceSHA256, claudeVersion: source.version, bundle: bundle)
        if let cached = cachedBase(signature: signature, paths: paths) {
            Log.info("extra.base_cached", ["signature": signature, "claude_version": source.version])
            return cached
        }
        let extraRoot = root(paths: paths)
        let bases = extraRoot.appending(path: "bases", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bases, withIntermediateDirectories: true)
        let work = extraRoot.appending(path: "work-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let started = Date()
        let candidates = bundle.generations(forClaudeVersion: source.version)
        Log.notice("extra.base_build_start", [
            "signature": signature,
            "source": source.appURL.path,
            "claude_version": source.version,
            "candidates": candidates.map(\.id).joined(separator: ","),
        ])

        let archive = try AsarArchive.open(source.asarURL)
        let (generation, replacements) = try patchedFiles(archive: archive, bundle: bundle, candidates: candidates, work: work)
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
            "generation": generation.id,
            "claude_version": source.version,
            "files": String(replacements.count),
            "seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
        ])
        return destination
    }

    public static func patchedFiles(archive: AsarArchive, bundle: ExtraBundle, candidates: [ExtraBundle.Generation], work: URL) throws -> (ExtraBundle.Generation, [String: Data]) {
        var firstError: Error?
        for (attempt, generation) in candidates.enumerated() {
            let attemptWork = work.appending(path: "attempt-\(attempt)-\(generation.id)", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: attemptWork, withIntermediateDirectories: true)
                let replacements = try patchedFiles(archive: archive, bundle: bundle, generation: generation, work: attemptWork)
                Log.notice("extra.generation_selected", [
                    "generation": generation.id,
                    "commit": String(generation.commit.prefix(12)),
                    "attempt": String(attempt + 1),
                    "preferred": candidates[0].id,
                ])
                return (generation, replacements)
            } catch {
                Log.warning("extra.generation_rejected", [
                    "generation": generation.id,
                    "attempt": String(attempt + 1),
                    "remaining": String(candidates.count - attempt - 1),
                    "error": error.localizedDescription,
                ])
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? BarracksError.extraUnavailable("The Extra bundle has no patch set for this Claude version.")
    }

    public static func patchedFiles(archive: AsarArchive, bundle: ExtraBundle, generation: ExtraBundle.Generation, work: URL) throws -> [String: Data] {
        var order: [String] = []
        var groups: [String: [ExtraBundle.Patch]] = [:]
        for patch in generation.patches {
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
                    Log.error("extra.patch_failed", ["generation": generation.id, "patch": patch.name, "status": String(result.status), "output": tail])
                    throw BarracksError.extraUnavailable("Extra patch \(patch.name) doesn't fit this Claude version (exit \(result.status)).")
                }
                Log.info("extra.patch_applied", ["generation": generation.id, "patch": patch.name, "target": target])
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
        replacements[mainTarget] = Data((mainText + (try bundle.mainAppendText(for: generation))).utf8)
        Log.info("extra.main_appended", ["generation": generation.id, "target": mainTarget])
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
