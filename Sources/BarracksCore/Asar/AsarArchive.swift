import Foundation

public struct AsarWriteResult: Sendable {
    public var headerSHA256: String
    public var fileSHA256: String
    public var replacedPaths: [String]
}

public struct AsarArchive {
    public static let defaultBlockSize = 4 * 1024 * 1024

    public let url: URL
    public let headerData: Data
    public let header: [String: Any]
    public let dataOffset: UInt64
    public let fileSize: UInt64

    public var headerSHA256: String { Hashing.sha256Hex(headerData) }

    public static func open(_ url: URL) throws -> AsarArchive {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard fileSize >= 16, let prefix = try handle.read(upToCount: 16), prefix.count == 16 else {
            throw BarracksError.asarMalformed("file is too small")
        }
        let sizePickleLength = prefix.readUInt32LE(at: 0)
        let headerPickleSize = UInt64(prefix.readUInt32LE(at: 4))
        let headerPayloadSize = UInt64(prefix.readUInt32LE(at: 8))
        let headerStringLength = UInt64(prefix.readUInt32LE(at: 12))
        guard sizePickleLength == 4,
              headerPayloadSize + 4 == headerPickleSize,
              headerStringLength + 4 <= headerPayloadSize,
              8 + headerPickleSize <= fileSize
        else {
            throw BarracksError.asarMalformed("unexpected pickle header layout")
        }
        guard let headerData = try handle.read(upToCount: Int(headerStringLength)), UInt64(headerData.count) == headerStringLength else {
            throw BarracksError.asarMalformed("truncated header")
        }
        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["files"] is [String: Any] else {
            throw BarracksError.asarMalformed("header is not a directory listing")
        }
        return AsarArchive(url: url, headerData: headerData, header: header, dataOffset: 8 + headerPickleSize, fileSize: fileSize)
    }

    public func entry(_ path: String) throws -> [String: Any] {
        var node: [String: Any] = header
        for component in Self.components(of: path) {
            guard let files = node["files"] as? [String: Any], let next = files[component] as? [String: Any] else {
                throw BarracksError.asarEntryMissing(path)
            }
            node = next
        }
        return node
    }

    public func childFiles(of directory: String) throws -> [String] {
        let node = directory.isEmpty ? header : try entry(directory)
        guard let files = node["files"] as? [String: Any] else { throw BarracksError.asarMalformed("\(directory) is not a directory") }
        return files.compactMap { name, value in
            guard let child = value as? [String: Any], child["files"] == nil, child["link"] == nil else { return nil }
            return name
        }
    }

    public func readFile(_ path: String) throws -> Data {
        let node = try entry(path)
        if node["files"] != nil { throw BarracksError.asarMalformed("\(path) is a directory") }
        if node["link"] != nil { throw BarracksError.asarMalformed("\(path) is a symlink") }
        if (node["unpacked"] as? Bool) == true {
            let unpacked = URL(filePath: url.path + ".unpacked").appending(path: path)
            return try Data(contentsOf: unpacked)
        }
        guard let offsetString = node["offset"] as? String, let offset = UInt64(offsetString), let size = (node["size"] as? NSNumber)?.uint64Value else {
            throw BarracksError.asarMalformed("\(path) has no offset or size")
        }
        guard dataOffset + offset + size <= fileSize else { throw BarracksError.asarMalformed("\(path) points past the end of the archive") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: dataOffset + offset)
        let data = try handle.read(upToCount: Int(size)) ?? Data()
        guard UInt64(data.count) == size else { throw BarracksError.asarMalformed("\(path) is truncated") }
        return data
    }

    public func verifyIntegrity(of path: String) throws -> Bool {
        let node = try entry(path)
        guard let integrity = node["integrity"] as? [String: Any], let expected = integrity["hash"] as? String else { return true }
        return Hashing.sha256Hex(try readFile(path)) == expected
    }

    public func write(to destination: URL, replacing replacements: [String: Data]) throws -> AsarWriteResult {
        var newHeader = header
        let dataRegionLength = fileSize - dataOffset
        var appendOffset = dataRegionLength
        let orderedPaths = replacements.keys.sorted()
        for path in orderedPaths {
            guard let contents = replacements[path] else { continue }
            let existing = try entry(path)
            if existing["files"] != nil || existing["link"] != nil {
                throw BarracksError.asarMalformed("\(path) is not a regular file")
            }
            let blockSize = ((existing["integrity"] as? [String: Any])?["blockSize"] as? NSNumber)?.intValue ?? Self.defaultBlockSize
            var updated = existing
            updated.removeValue(forKey: "unpacked")
            updated["offset"] = String(appendOffset)
            updated["size"] = NSNumber(value: contents.count)
            updated["integrity"] = Self.integrity(for: contents, blockSize: blockSize)
            try Self.setEntry(in: &newHeader, components: Self.components(of: path)[...], value: updated)
            appendOffset += UInt64(contents.count)
        }

        let newHeaderData = try JSONSerialization.data(withJSONObject: newHeader, options: [.withoutEscapingSlashes])
        let paddedLength = (newHeaderData.count + 3) & ~3
        let payloadSize = UInt32(4 + paddedLength)
        let headerPickleSize = UInt32(4 + Int(payloadSize))

        var prefix = Data()
        prefix.appendUInt32LE(4)
        prefix.appendUInt32LE(headerPickleSize)
        prefix.appendUInt32LE(payloadSize)
        prefix.appendUInt32LE(UInt32(newHeaderData.count))
        prefix.append(newHeaderData)
        prefix.append(Data(count: paddedLength - newHeaderData.count))

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o644])
        let output = try FileHandle(forWritingTo: destination)
        let input = try FileHandle(forReadingFrom: url)
        defer {
            try? output.close()
            try? input.close()
        }
        try output.write(contentsOf: prefix)
        try input.seek(toOffset: dataOffset)
        var remaining = dataRegionLength
        while remaining > 0 {
            let chunk = try input.read(upToCount: Int(min(remaining, 8 * 1024 * 1024))) ?? Data()
            if chunk.isEmpty { throw BarracksError.asarMalformed("archive ended early while copying") }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        for path in orderedPaths {
            if let contents = replacements[path] { try output.write(contentsOf: contents) }
        }
        try output.synchronize()

        let result = AsarWriteResult(
            headerSHA256: Hashing.sha256Hex(newHeaderData),
            fileSHA256: try Hashing.sha256Hex(fileAt: destination),
            replacedPaths: orderedPaths
        )
        Log.info("asar.written", ["destination": destination.lastPathComponent, "replaced": orderedPaths.joined(separator: ","), "header_sha256": result.headerSHA256])
        return result
    }

    static func integrity(for data: Data, blockSize: Int) -> [String: Any] {
        var blocks: [String] = []
        var start = 0
        repeat {
            let end = min(start + blockSize, data.count)
            blocks.append(Hashing.sha256Hex(data.subdata(in: start..<end)))
            start = end
        } while start < data.count
        return ["algorithm": "SHA256", "hash": Hashing.sha256Hex(data), "blockSize": NSNumber(value: blockSize), "blocks": blocks]
    }

    static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
    }

    static func setEntry(in node: inout [String: Any], components: ArraySlice<String>, value: [String: Any]) throws {
        guard let first = components.first else { return }
        guard var files = node["files"] as? [String: Any] else { throw BarracksError.asarEntryMissing(first) }
        if components.count == 1 {
            files[first] = value
        } else {
            guard var child = files[first] as? [String: Any] else { throw BarracksError.asarEntryMissing(first) }
            try setEntry(in: &child, components: components.dropFirst(), value: value)
            files[first] = child
        }
        node["files"] = files
    }
}

public enum AsarBuilder {
    public static func build(files: [String: Data], to destination: URL) throws {
        var root: [String: Any] = ["files": [String: Any]()]
        var body = Data()
        for path in files.keys.sorted() {
            guard let contents = files[path] else { continue }
            let entry: [String: Any] = [
                "size": NSNumber(value: contents.count),
                "offset": String(body.count),
                "integrity": AsarArchive.integrity(for: contents, blockSize: AsarArchive.defaultBlockSize),
            ]
            try insert(entry, at: AsarArchive.components(of: path)[...], into: &root)
            body.append(contents)
        }
        let headerData = try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
        let padded = (headerData.count + 3) & ~3
        var out = Data()
        out.appendUInt32LE(4)
        out.appendUInt32LE(UInt32(8 + padded))
        out.appendUInt32LE(UInt32(4 + padded))
        out.appendUInt32LE(UInt32(headerData.count))
        out.append(headerData)
        out.append(Data(count: padded - headerData.count))
        out.append(body)
        try out.write(to: destination)
    }

    private static func insert(_ entry: [String: Any], at components: ArraySlice<String>, into node: inout [String: Any]) throws {
        guard let first = components.first else { return }
        var files = node["files"] as? [String: Any] ?? [:]
        if components.count == 1 {
            files[first] = entry
        } else {
            var child = files[first] as? [String: Any] ?? ["files": [String: Any]()]
            try insert(entry, at: components.dropFirst(), into: &child)
            files[first] = child
        }
        node["files"] = files
    }
}

extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(self[self.startIndex + offset + i]) << (8 * UInt32(i))
        }
        return value
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        for i in 0..<4 {
            append(UInt8((value >> (8 * UInt32(i))) & 0xff))
        }
    }
}
