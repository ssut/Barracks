import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunner {
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let started = Date()
        let command = ([URL(filePath: executable).lastPathComponent] + arguments.prefix(3)).joined(separator: " ")
        Log.debug("process.start", ["command": command])
        try process.run()

        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()

        let result = ProcessResult(status: process.terminationStatus, stdout: outData, stderr: errData)
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        Log.debug("process.finish", ["command": command, "status": String(result.status), "seconds": elapsed])
        if result.status != 0 && !allowFailure {
            let tail = String(result.stderrString.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.error("process.failed", ["command": command, "status": String(result.status), "stderr": tail])
            throw BarracksError.processFailed(command: command, status: result.status, stderr: tail)
        }
        return result
    }
}
