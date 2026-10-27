import Foundation
import CryptoKit

struct InstalledRuntimeBundle: Sendable {
    let rootURL: URL
    let executableURL: URL
}

enum RuntimeBundleInstallError: LocalizedError, Sendable {
    case invalidSource
    case invalidExecutablePath
    case invalidChecksum
    case checksumMismatch(expected: String, actual: String)
    case executableUnavailable
    case winebootUnavailable
    case healthCheckFailed(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            "Choose a runtime bundle directory containing the runtime files."
        case .invalidExecutablePath:
            "The executable-relative path must be non-empty, relative, and must not contain '..'."
        case .invalidChecksum:
            "Enter the published SHA-256 checksum for the runtime executable."
        case let .checksumMismatch(expected, actual):
            "The runtime checksum does not match. Expected \(expected), received \(actual)."
        case .executableUnavailable:
            "The selected runtime executable is missing or is not executable."
        case .winebootUnavailable:
            "The runtime bundle must contain an executable named wineboot beside the selected runtime executable."
        case let .healthCheckFailed(detail):
            "The copied runtime failed its health check: \(detail)"
        case let .copyFailed(message):
            "The runtime bundle could not be copied into Ludus storage: \(message)"
        }
    }
}

struct RuntimeBundleInstaller: Sendable {
    func install(
        sourceRootURL: URL,
        executableRelativePath: String,
        expectedSHA256: String,
        managedRootURL: URL
    ) throws -> InstalledRuntimeBundle {
        var isDirectory: ObjCBool = false
        guard sourceRootURL.isFileURL,
              FileManager.default.fileExists(atPath: sourceRootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RuntimeBundleInstallError.invalidSource
        }

        guard Self.isSafeRelativePath(executableRelativePath) else {
            throw RuntimeBundleInstallError.invalidExecutablePath
        }

        let normalizedChecksum = expectedSHA256
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedChecksum.count == 64,
              normalizedChecksum.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RuntimeBundleInstallError.invalidChecksum
        }

        let sourceExecutableURL = sourceRootURL
            .appendingPathComponent(executableRelativePath)
            .standardizedFileURL
        let sourceRoot = sourceRootURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedExecutable = sourceExecutableURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isInside(resolvedExecutable, directory: sourceRoot),
              Self.isRegularFile(sourceExecutableURL),
              FileManager.default.isExecutableFile(atPath: sourceExecutableURL.path) else {
            throw RuntimeBundleInstallError.executableUnavailable
        }

        let actualChecksum = try Self.sha256(of: sourceExecutableURL)
        guard actualChecksum == normalizedChecksum else {
            throw RuntimeBundleInstallError.checksumMismatch(
                expected: normalizedChecksum,
                actual: actualChecksum
            )
        }

        let sourceWinebootURL = sourceExecutableURL
            .deletingLastPathComponent()
            .appendingPathComponent("wineboot")
        guard Self.isRegularFile(sourceWinebootURL),
              FileManager.default.isExecutableFile(atPath: sourceWinebootURL.path) else {
            throw RuntimeBundleInstallError.winebootUnavailable
        }

        let safeName = Self.safeDirectoryName(sourceRootURL.lastPathComponent)
        let destinationURL = managedRootURL
            .appendingPathComponent("\(safeName)-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: managedRootURL, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceRootURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw RuntimeBundleInstallError.copyFailed(error.localizedDescription)
        }

        let installedExecutableURL = destinationURL.appendingPathComponent(executableRelativePath)
        guard Self.isRegularFile(installedExecutableURL),
              FileManager.default.isExecutableFile(atPath: installedExecutableURL.path) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw RuntimeBundleInstallError.executableUnavailable
        }
        guard try Self.sha256(of: installedExecutableURL) == normalizedChecksum else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw RuntimeBundleInstallError.copyFailed("The copied executable failed checksum verification.")
        }
        let installedWinebootURL = installedExecutableURL
            .deletingLastPathComponent()
            .appendingPathComponent("wineboot")
        guard Self.isRegularFile(installedWinebootURL),
              FileManager.default.isExecutableFile(atPath: installedWinebootURL.path) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw RuntimeBundleInstallError.winebootUnavailable
        }

        return InstalledRuntimeBundle(rootURL: destinationURL, executableURL: installedExecutableURL)
    }

    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    private static func isInside(_ candidate: URL, directory: URL) -> Bool {
        candidate.path == directory.path || candidate.path.hasPrefix(directory.path + "/")
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func safeDirectoryName(_ value: String) -> String {
        let allowed = value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        let name = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? "runtime" : name
    }
}
