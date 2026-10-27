import Foundation

enum WinePrefixArchiveError: LocalizedError, Sendable {
    case missingPrefix(URL)
    case invalidDestination(URL)
    case archiveInsidePrefix(URL)
    case invalidArchive(URL)
    case unsupportedArchiveVersion(Int)
    case invalidArchiveName
    case destinationExists(URL)
    case unsafeRemoval(URL)

    var errorDescription: String? {
        switch self {
        case .missingPrefix(let url):
            "The prefix directory does not exist or is not a directory: \(url.path)"
        case .invalidDestination(let url):
            "The backup destination is not an existing directory: \(url.path)"
        case .archiveInsidePrefix(let url):
            "The backup destination cannot be inside the prefix being backed up: \(url.path)"
        case .invalidArchive(let url):
            "This folder is not a valid Ludus prefix backup: \(url.path)"
        case .unsupportedArchiveVersion(let version):
            "This prefix backup uses an unsupported format version: \(version)"
        case .invalidArchiveName:
            "The backup contains an invalid prefix name."
        case .destinationExists(let url):
            "The destination already exists: \(url.path)"
        case .unsafeRemoval(let url):
            "Ludus refused to remove a directory outside its managed prefix root: \(url.path)"
        }
    }
}

private struct WinePrefixArchiveMetadata: Codable, Sendable {
    let formatVersion: Int
    let name: String
    let runtimeURL: URL
    let architecture: PrefixArchitecture
    let createdAt: Date
    let status: String
}

struct WinePrefixArchiveService: Sendable {
    private static let formatVersion = 1
    private static let metadataFilename = "metadata.json"
    private static let payloadDirectoryName = "prefix"

    func backup(prefix: WinePrefix, to destinationDirectory: URL) throws -> URL {
        guard isDirectory(destinationDirectory) else {
            throw WinePrefixArchiveError.invalidDestination(destinationDirectory)
        }
        guard isDirectory(prefix.url) else {
            throw WinePrefixArchiveError.missingPrefix(prefix.url)
        }
        guard !isPath(destinationDirectory, inside: prefix.url) else {
            throw WinePrefixArchiveError.archiveInsidePrefix(destinationDirectory)
        }

        let archiveName = "Ludus-\(prefix.name)-\(prefix.id.uuidString.prefix(8))"
        let archiveURL = destinationDirectory.appendingPathComponent(archiveName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw WinePrefixArchiveError.destinationExists(archiveURL)
        }

        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: archiveURL)
            }
        }

        let metadata = WinePrefixArchiveMetadata(
            formatVersion: Self.formatVersion,
            name: prefix.name,
            runtimeURL: prefix.runtimeURL,
            architecture: prefix.architecture,
            createdAt: prefix.createdAt,
            status: prefix.status
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(
            to: archiveURL.appendingPathComponent(Self.metadataFilename),
            options: [.atomic]
        )
        try FileManager.default.copyItem(
            at: prefix.url,
            to: archiveURL.appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
        )
        completed = true
        return archiveURL
    }

    /// Creates a timestamped `.zip` archive containing the prefix and its metadata,
    /// defaulting to `~/Downloads`.
    func createZipBackup(
        prefix: WinePrefix,
        to destinationDirectory: URL? = nil
    ) async throws -> URL {
        guard isDirectory(prefix.url) else {
            throw WinePrefixArchiveError.missingPrefix(prefix.url)
        }
        let destination = destinationDirectory ?? (
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        )
        guard isDirectory(destination) else {
            throw WinePrefixArchiveError.invalidDestination(destination)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusZipBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let folderBackup = try backup(prefix: prefix, to: tempDir)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let zipFilename = "Ludus-\(prefix.name)-\(timestamp).zip"
        let targetZipURL = destination.appendingPathComponent(zipFilename)

        let runner = ProcessRunner()
        let result = try await Task.detached(priority: .utility) {
            try runner.run(
                "/usr/bin/ditto",
                arguments: ["-c", "-k", "--keepParent", folderBackup.path, targetZipURL.path]
            )
        }.value

        guard result.status == 0 else {
            throw WinePrefixArchiveError.invalidArchive(targetZipURL)
        }

        return targetZipURL
    }

    /// Creates a timestamped `.zip` archive of an arbitrary source directory (such as a game installation or save folder),
    /// defaulting to `~/Downloads`.
    func createDirectoryZipBackup(
        sourceDirectory: URL,
        name: String,
        to destinationDirectory: URL? = nil
    ) async throws -> URL {
        guard isDirectory(sourceDirectory) else {
            throw WinePrefixArchiveError.missingPrefix(sourceDirectory)
        }
        let destination = destinationDirectory ?? (
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        )
        guard isDirectory(destination) else {
            throw WinePrefixArchiveError.invalidDestination(destination)
        }

        let sanitizedName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let zipFilename = "Ludus-\(sanitizedName)-\(timestamp).zip"
        let targetZipURL = destination.appendingPathComponent(zipFilename)

        let runner = ProcessRunner()
        let result = try await Task.detached(priority: .utility) {
            try runner.run(
                "/usr/bin/ditto",
                arguments: ["-c", "-k", "--keepParent", sourceDirectory.path, targetZipURL.path]
            )
        }.value

        guard result.status == 0 else {
            throw WinePrefixArchiveError.invalidArchive(targetZipURL)
        }

        return targetZipURL
    }

    /// Creates a timestamped `.cxarchive` backup containing the prefix and its metadata,
    /// defaulting to `~/Downloads`.
    func createCxarchiveBackup(
        prefix: WinePrefix,
        to destinationDirectory: URL? = nil
    ) async throws -> URL {
        guard isDirectory(prefix.url) else {
            throw WinePrefixArchiveError.missingPrefix(prefix.url)
        }
        let destination = destinationDirectory ?? (
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        )
        guard isDirectory(destination) else {
            throw WinePrefixArchiveError.invalidDestination(destination)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusCxarchiveBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let folderBackup = try backup(prefix: prefix, to: tempDir)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let cxarchiveFilename = "Ludus-\(prefix.name)-\(timestamp).cxarchive"
        let targetURL = destination.appendingPathComponent(cxarchiveFilename)

        let runner = ProcessRunner()
        let result = try await Task.detached(priority: .utility) {
            try runner.run(
                "/usr/bin/ditto",
                arguments: ["-c", "-k", "--keepParent", folderBackup.path, targetURL.path]
            )
        }.value

        guard result.status == 0 else {
            throw WinePrefixArchiveError.invalidArchive(targetURL)
        }

        return targetURL
    }

    func restore(
        archiveURL: URL,
        into managedRoot: URL,
        fallbackRuntimeURL: URL? = nil
    ) throws -> WinePrefix {
        var sourceFolderURL = archiveURL
        var tempDirectoryToCleanup: URL? = nil
        defer {
            if let temp = tempDirectoryToCleanup {
                try? FileManager.default.removeItem(at: temp)
            }
        }

        let defaultRuntimeURL: URL
        if let fallbackRuntimeURL, FileManager.default.isExecutableFile(atPath: fallbackRuntimeURL.path) {
            defaultRuntimeURL = fallbackRuntimeURL
        } else if let cxWine = WineBottleService.findCrossOverResource(path: "bin/wine"),
                  FileManager.default.isExecutableFile(atPath: cxWine.path) {
            defaultRuntimeURL = cxWine
        } else {
            defaultRuntimeURL = URL(fileURLWithPath: "/usr/bin/wine")
        }

        // If archiveURL is a compressed archive (.zip or .cxarchive), extract it first
        let isFileArchive = !isDirectory(archiveURL) && (
            archiveURL.pathExtension.lowercased() == "zip" ||
            archiveURL.pathExtension.lowercased() == "cxarchive"
        )
        if isFileArchive {
            let tempExtract = FileManager.default.temporaryDirectory
                .appendingPathComponent("LudusRestoreExtract-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempExtract, withIntermediateDirectories: true)
            tempDirectoryToCleanup = tempExtract

            let runner = ProcessRunner()
            var extracted = false

            // Check magic bytes to select appropriate unpacker (tar.gz for real CrossOver archives, ditto/zip for Overcross)
            if let handle = try? FileHandle(forReadingFrom: archiveURL) {
                let header = (try? handle.read(upToCount: 4)) ?? Data()
                try? handle.close()

                if header.count >= 2 && header[0] == 0x1f && header[1] == 0x8b {
                    let tarResult = try runner.run(
                        "/usr/bin/tar",
                        arguments: ["-xzf", archiveURL.path, "-C", tempExtract.path]
                    )
                    extracted = (tarResult.status == 0)
                }
            }

            if !extracted {
                let extractResult = try runner.run(
                    "/usr/bin/ditto",
                    arguments: ["-x", "-k", archiveURL.path, tempExtract.path]
                )
                if extractResult.status == 0 {
                    extracted = true
                } else {
                    let tarResult = try runner.run(
                        "/usr/bin/tar",
                        arguments: ["-xf", archiveURL.path, "-C", tempExtract.path]
                    )
                    extracted = (tarResult.status == 0)
                }
            }

            guard extracted else {
                throw WinePrefixArchiveError.invalidArchive(archiveURL)
            }

            let contents = (try? FileManager.default.contentsOfDirectory(at: tempExtract, includingPropertiesForKeys: nil)) ?? []
            if let nestedBackup = contents.first(where: {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.metadataFilename).path)
            }) {
                sourceFolderURL = nestedBackup
            } else if let nestedPrefix = contents.first(where: {
                WinePrefixService.isVerifiedPrefix(at: $0)
            }) {
                sourceFolderURL = nestedPrefix
            } else {
                sourceFolderURL = tempExtract
            }
        }

        let metadataURL = sourceFolderURL.appendingPathComponent(Self.metadataFilename)
        let payloadURL = sourceFolderURL.appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)

        if isDirectory(sourceFolderURL), isDirectory(payloadURL),
           let metadataData = try? Data(contentsOf: metadataURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let metadata = try? decoder.decode(WinePrefixArchiveMetadata.self, from: metadataData) else {
                throw WinePrefixArchiveError.invalidArchive(archiveURL)
            }
            guard metadata.formatVersion == Self.formatVersion else {
                throw WinePrefixArchiveError.unsupportedArchiveVersion(metadata.formatVersion)
            }
            guard isSafePrefixName(metadata.name) else {
                throw WinePrefixArchiveError.invalidArchiveName
            }

            try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
            let restoredName = "\(metadata.name)-restored-\(UUID().uuidString.prefix(8))"
            let restoredURL = managedRoot.appendingPathComponent(restoredName, isDirectory: true)
            try FileManager.default.copyItem(at: payloadURL, to: restoredURL)
            let registryURL = restoredURL.appendingPathComponent("system.reg")
            let driveCURL = restoredURL.appendingPathComponent("drive_c", isDirectory: true)
            guard FileManager.default.fileExists(atPath: registryURL.path),
                  isDirectory(driveCURL) else {
                try? FileManager.default.removeItem(at: restoredURL)
                throw WinePrefixArchiveError.invalidArchive(archiveURL)
            }

            let runtimeToUse: URL
            if FileManager.default.isExecutableFile(atPath: metadata.runtimeURL.path) {
                runtimeToUse = metadata.runtimeURL
            } else {
                runtimeToUse = defaultRuntimeURL
            }

            return WinePrefix(
                name: restoredName,
                url: restoredURL,
                runtimeURL: runtimeToUse,
                architecture: metadata.architecture,
                createdAt: metadata.createdAt,
                status: "Restored; runtime verified"
            )
        }

        // Direct verified prefix directory (raw prefix or CrossOver .cxarchive bottle)
        let effectivePrefixURL = WinePrefixService.isVerifiedPrefix(at: sourceFolderURL) ? sourceFolderURL : payloadURL
        guard WinePrefixService.isVerifiedPrefix(at: effectivePrefixURL) else {
            throw WinePrefixArchiveError.invalidArchive(archiveURL)
        }

        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let baseName = archiveURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "Ludus-", with: "")
            .replacingOccurrences(of: "Overcross-", with: "")
        let safeName = isSafePrefixName(baseName) ? baseName : "RestoredBottle"
        let restoredName = "\(safeName)-restored-\(UUID().uuidString.prefix(8))"
        let restoredURL = managedRoot.appendingPathComponent(restoredName, isDirectory: true)
        try FileManager.default.copyItem(at: effectivePrefixURL, to: restoredURL)

        return WinePrefix(
            name: restoredName,
            url: restoredURL,
            runtimeURL: defaultRuntimeURL,
            architecture: .win64,
            createdAt: Date(),
            status: "Restored; runtime verified"
        )
    }

    func remove(prefix: WinePrefix, from managedRoot: URL) throws {
        guard isStrictlyInside(prefix.url, managedRoot) else {
            throw WinePrefixArchiveError.unsafeRemoval(prefix.url)
        }
        guard isDirectory(prefix.url) else {
            throw WinePrefixArchiveError.missingPrefix(prefix.url)
        }
        try FileManager.default.removeItem(at: prefix.url)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isPath(_ candidate: URL, inside parent: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == parentPath || candidatePath.hasPrefix(parentPath + "/")
    }

    private func isStrictlyInside(_ candidate: URL, _ parent: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(parentPath + "/")
    }

    private func isSafePrefixName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }
}
