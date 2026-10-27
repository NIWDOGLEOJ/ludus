import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let output: String
    let errorOutput: String
}

enum ProcessRunnerError: LocalizedError {
    case executableNotFound(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path): "Executable not found: \(path)"
        }
    }
}

struct ProcessRunner: Sendable {
    private static let defaultOutputLimit = 16 * 1024

    func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        outputLimit: Int = ProcessRunner.defaultOutputLimit
    ) throws -> ProcessResult {
        let process = Process()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("stdout.log")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputFile = try FileHandle(forWritingTo: outputURL)
        let errorFile = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputFile.close()
            try? errorFile.close()
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = outputFile
        process.standardError = errorFile

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.executableNotFound(executable)
        }

        process.waitUntilExit()

        try? outputFile.close()
        try? errorFile.close()
        let output = readBoundedOutput(from: outputURL, limit: outputLimit)
        let errorOutput = readBoundedOutput(from: errorURL, limit: outputLimit)

        return ProcessResult(status: process.terminationStatus, output: output, errorOutput: errorOutput)
    }
}

private func readBoundedOutput(from url: URL, limit: Int) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }

    var data = Data()
    let boundedLimit = max(1, limit)
    while data.count < boundedLimit {
        let chunk: Data
        do {
            guard let readData = try handle.read(upToCount: min(8 * 1024, boundedLimit - data.count)),
                  !readData.isEmpty else {
                break
            }
            chunk = readData
        } catch {
            break
        }
        data.append(chunk)
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
