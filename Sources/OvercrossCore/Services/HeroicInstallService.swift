import Foundation

enum HeroicInstallError: LocalizedError, Sendable {
    case invalidApplicationName
    case missingConfigurationDirectory
    case missingInstallDirectory
    case legendaryExecutableNotFound
    case cancelled
    case installationNotVerified
    case installationOutsideSelectedDirectory(URL)
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .invalidApplicationName:
            return "The Heroic application name is missing or contains unsafe path characters."
        case .missingConfigurationDirectory:
            return "Import Heroic or Legendary's installed.json first so Ludus can reuse the selected configuration directory."
        case .missingInstallDirectory:
            return "Choose a preferred install location before starting a Heroic installation."
        case .legendaryExecutableNotFound:
            return "Heroic's bundled Legendary executable was not found in the standard macOS application locations."
        case .cancelled:
            return "The Heroic installation was cancelled."
        case .installationNotVerified:
            return "Heroic completed the command, but installed.json did not verify a non-empty installation directory. The files were not marked installed."
        case let .installationOutsideSelectedDirectory(url):
            return "Heroic recorded the installation outside the selected base directory: \(url.path). The files were not marked installed."
        case let .commandFailed(status, output):
            if output.isEmpty {
                return "Heroic's Legendary installer exited with status \(status)."
            } else {
                return "Heroic's Legendary installer exited with status \(status): \(output)"
            }
        }
    }
}

struct HeroicInstallProgress: Equatable, Sendable {
    let fraction: Double?
    let detail: String
    let speed: String?
    let eta: String?
    let currentBytes: Int64?
    let totalBytes: Int64?

    init(
        fraction: Double?,
        detail: String,
        speed: String? = nil,
        eta: String? = nil,
        currentBytes: Int64? = nil,
        totalBytes: Int64? = nil
    ) {
        self.fraction = fraction
        self.detail = detail
        self.speed = speed
        self.eta = eta
        self.currentBytes = currentBytes
        self.totalBytes = totalBytes
    }
}

struct HeroicInstalledEvidence: Sendable {
    let installationURL: URL
    let executableURL: URL?
}

struct HeroicInstallResult: Sendable {
    let exitStatus: Int32
    let output: String
    let evidence: HeroicInstalledEvidence
}

struct HeroicInstallService: Sendable {
    private static let standardRelativeLegendaryPath =
        "Contents/Resources/app.asar.unpacked/build/bin/darwin/legendary"

    static func bundledLegendaryURL(
        fileManager: FileManager = .default
    ) -> URL? {
        if let found = EpicService.findLegendaryBinary() {
            return found
        }

        let candidates = [
            URL(fileURLWithPath: "/Applications/Heroic.app"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Heroic.app")
        ].flatMap { app -> [URL] in
            [
                app.appendingPathComponent("Contents/Resources/app.asar.unpacked/build/bin/arm64/darwin/legendary"),
                app.appendingPathComponent("Contents/Resources/app.asar.unpacked/build/bin/x64/darwin/legendary"),
                app.appendingPathComponent(standardRelativeLegendaryPath)
            ]
        }

        if let bundled = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return bundled
        }

        let systemPaths = [
            URL(fileURLWithPath: "/opt/homebrew/bin/legendary"),
            URL(fileURLWithPath: "/usr/local/bin/legendary")
        ]
        return systemPaths.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func installArguments(
        applicationName: String,
        baseDirectory: URL,
        updateOnly: Bool = false,
        installPrerequisites: Bool = false
    ) throws -> [String] {
        let trimmedName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              !trimmedName.contains("\\"),
              !trimmedName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !trimmedName.hasPrefix("-") else {
            throw HeroicInstallError.invalidApplicationName
        }

        var arguments = [
            "install",
            trimmedName,
            "--platform", "Windows",
            "--base-path", baseDirectory.path,
            "--skip-dlcs",
            "--skip-sdl",
            "-y"
        ]
        if !installPrerequisites {
            arguments.insert("--no-install", at: arguments.count - 1)
        }
        if updateOnly {
            arguments.insert("--update-only", at: arguments.count - 1)
        }
        return arguments
    }

    func install(
        applicationName: String,
        baseDirectory: URL,
        configurationDirectory: URL,
        updateOnly: Bool = false,
        installPrerequisites: Bool = false,
        progress: @escaping @Sendable (HeroicInstallProgress) -> Void
    ) async throws -> HeroicInstallResult {
        guard isDirectory(configurationDirectory) else {
            throw HeroicInstallError.missingConfigurationDirectory
        }
        guard isDirectory(baseDirectory) else {
            throw HeroicInstallError.missingInstallDirectory
        }
        guard let legendaryURL = Self.bundledLegendaryURL() else {
            throw HeroicInstallError.legendaryExecutableNotFound
        }
        let arguments = try Self.installArguments(
            applicationName: applicationName,
            baseDirectory: baseDirectory,
            updateOnly: updateOnly,
            installPrerequisites: installPrerequisites
        )
        let control = InstallProcessControl()
        let task = Task.detached(priority: .userInitiated) {
            try Self.run(
                executableURL: legendaryURL,
                arguments: arguments,
                configurationDirectory: configurationDirectory,
                baseDirectory: baseDirectory,
                control: control,
                progress: progress
            )
        }

        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            control.cancel()
        })
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    private static func run(
        executableURL: URL,
        arguments: [String],
        configurationDirectory: URL,
        baseDirectory: URL,
        control: InstallProcessControl,
        progress: @escaping @Sendable (HeroicInstallProgress) -> Void
    ) throws -> HeroicInstallResult {
        ensureLegendaryUpdateCheckDisabled(in: configurationDirectory)

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let output = InstallOutputCollector(progress: progress)

        process.executableURL = executableURL
        var commandArguments = arguments
        if !commandArguments.contains("-A") {
            commandArguments.insert(contentsOf: ["-A", "60"], at: 0)
        }
        process.arguments = commandArguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var environment = ProcessInfo.processInfo.environment
        environment["LEGENDARY_CONFIG_PATH"] = configurationDirectory.path
        process.environment = environment

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData, isError: false)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData, isError: true)
        }

        control.setProcess(process)
        if control.isCancelled {
            throw HeroicInstallError.cancelled
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        output.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile(), isError: false)
        output.append(stderrPipe.fileHandleForReading.readDataToEndOfFile(), isError: true)

        if control.isCancelled {
            throw HeroicInstallError.cancelled
        }
        guard process.terminationStatus == 0 else {
            throw HeroicInstallError.commandFailed(
                process.terminationStatus,
                output.lastUsefulLine
            )
        }
        let result = HeroicInstallResult(
            exitStatus: process.terminationStatus,
            output: output.combinedOutput,
            evidence: try Self.verifiedEvidence(
                applicationName: arguments[1],
                configurationDirectory: configurationDirectory,
                requiredBaseDirectory: baseDirectory
            )
        )
        return result
    }

    static func verifiedEvidence(
        applicationName: String,
        configurationDirectory: URL,
        requiredBaseDirectory: URL? = nil
    ) throws -> HeroicInstalledEvidence {
        let resumeFile = configurationDirectory.appendingPathComponent("tmp/\(applicationName).resume")
        if FileManager.default.fileExists(atPath: resumeFile.path) {
            throw HeroicInstallError.installationNotVerified
        }

        let installedJSON = configurationDirectory.appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: installedJSON),
              let entries = try? JSONDecoder().decode([String: InstalledRecord].self, from: data),
              let entry = entries[applicationName],
              let installPath = entry.installPath,
              !installPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HeroicInstallError.installationNotVerified
        }

        let installationURL = URL(fileURLWithPath: installPath).standardizedFileURL
        guard isDirectory(installationURL),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: installationURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ),
              !contents.isEmpty else {
            throw HeroicInstallError.installationNotVerified
        }

        if let requiredBaseDirectory,
           !isInsideOrEqual(installationURL, directory: requiredBaseDirectory) {
            throw HeroicInstallError.installationOutsideSelectedDirectory(installationURL)
        }

        return HeroicInstalledEvidence(
            installationURL: installationURL,
            executableURL: resolveExecutable(entry.executable, inside: installationURL)
        )
    }

    private static func resolveExecutable(_ value: String?, inside installationURL: URL) -> URL? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let candidate = URL(fileURLWithPath: value, relativeTo: installationURL).standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let resolvedInstallation = installationURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedInstallation.path + "/"),
              FileManager.default.fileExists(atPath: resolvedCandidate.path),
              FileManager.default.isExecutableFile(atPath: resolvedCandidate.path) else {
            return nil
        }
        return candidate
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    private static func isInsideOrEqual(_ candidate: URL, directory: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
    }

    private static func ensureLegendaryUpdateCheckDisabled(in configDir: URL) {
        let configFile = configDir.appendingPathComponent("config.ini")
        if FileManager.default.fileExists(atPath: configFile.path),
           let content = try? String(contentsOf: configFile, encoding: .utf8) {
            if !content.contains("disable_update_check = true") {
                let updated = content.replacingOccurrences(
                    of: "disable_update_check = false",
                    with: "disable_update_check = true"
                )
                try? updated.write(to: configFile, atomically: true, encoding: .utf8)
            }
        } else if !FileManager.default.fileExists(atPath: configFile.path) {
            let defaultIni = "[Legendary]\ndisable_update_check = true\ndisable_update_notice = true\n"
            try? defaultIni.write(to: configFile, atomically: true, encoding: .utf8)
        }
    }

    private struct InstalledRecord: Decodable {
        let installPath: String?
        let executable: String?

        private enum CodingKeys: String, CodingKey {
            case installPath = "install_path"
            case executable
        }
    }
}

private final class InstallProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func setProcess(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            if pid > 0 {
                let pkill = Process()
                pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                pkill.arguments = ["-TERM", "-P", "\(pid)"]
                try? pkill.run()
                pkill.waitUntilExit()
            }
        }
    }
}

final class InstallOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (HeroicInstallProgress) -> Void
    private var pendingLine = ""
    private var lines: [String] = []
    private var combined = ""
    private var lastFraction: Double?
    private var isResumed = false
    private var skippedBytes: Int64 = 0
    private var sessionInstallBytes: Int64 = 0
    private var sessionDownloadBytes: Int64 = 0
    private var sessionDownloadedBytes: Int64 = 0
    private var sessionWrittenBytes: Int64 = 0
    private var sessionFraction: Double?
    private var lastProgressDesc: String?
    private var lastSpeedDesc: String?
    private var lastEtaDesc: String?

    init(progress: @escaping @Sendable (HeroicInstallProgress) -> Void) {
        self.progress = progress
    }

    var combinedOutput: String {
        lock.lock()
        defer { lock.unlock() }
        return combined
    }

    var lastUsefulLine: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.last(where: { !$0.isEmpty }) ?? ""
    }

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        lock.lock()
        combined.append(text)
        if combined.count > 64_000 {
            combined = String(combined.suffix(64_000))
        }
        pendingLine.append(text)
        if pendingLine.count > 64_000 {
            pendingLine = String(pendingLine.suffix(64_000))
        }
        let completeLines = pendingLine.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0.prefix(4_000))
        }
        pendingLine = completeLines.last ?? ""
        let finished = completeLines.dropLast().map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        lines.append(contentsOf: finished)
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
        }
        lock.unlock()

        for line in finished where !line.isEmpty {
            if let update = processLine(line: line, isError: isError) {
                progress(update)
            }
        }
    }

    private static func parseSizeToBytes(valueStr: String, unitStr: String) -> Int64? {
        guard let val = Double(valueStr) else { return nil }
        let unit = unitStr.lowercased()
        let multiplier: Double
        if unit.hasPrefix("k") {
            multiplier = 1024
        } else if unit.hasPrefix("m") {
            multiplier = 1024 * 1024
        } else if unit.hasPrefix("g") {
            multiplier = 1024 * 1024 * 1024
        } else if unit.hasPrefix("t") {
            multiplier = 1024 * 1024 * 1024 * 1024
        } else {
            multiplier = 1
        }
        return Int64(val * multiplier)
    }

    private func processLine(line: String, isError: Bool) -> HeroicInstallProgress? {
        lock.lock()
        defer { lock.unlock() }

        // In UNIX tools (including Legendary), progress is written to stderr.
        // It should only be treated as an error if it is genuinely a failure/exception,
        // not an informational/progress message.
        let isRealError = isError &&
            (line.localizedCaseInsensitiveContains("error:") ||
             line.localizedCaseInsensitiveContains("exception:") ||
             line.localizedCaseInsensitiveContains("traceback (most recent") ||
             line.localizedCaseInsensitiveContains("critical:")) &&
            !line.contains("INFO:") &&
            !line.contains("WARNING:") &&
            !line.contains("[DLManager]")

        if isRealError {
            return HeroicInstallProgress(fraction: lastFraction, detail: "Error: \(line)")
        }

        if line.contains("Found previously interrupted download") || line.contains("based on resume data") {
            isResumed = true
        }

        // Reusable / skipped size
        // e.g. [cli] INFO: Reusable size: 0.00 MiB (chunks) / 33321.68 MiB (unchanged / skipped)
        if line.contains("unchanged / skipped"),
           let match = line.range(of: #"/\s*([0-9.]+)\s*([A-Za-z]+)\s*\(unchanged"#, options: .regularExpression) {
            let matchedStr = String(line[match])
            if let sub = matchedStr.range(of: #"([0-9.]+)\s*([A-Za-z]+)"#, options: .regularExpression) {
                let parts = String(matchedStr[sub]).split(separator: " ")
                if parts.count == 2, let bytes = Self.parseSizeToBytes(valueStr: String(parts[0]), unitStr: String(parts[1])) {
                    skippedBytes = bytes
                    if bytes > 0 {
                        isResumed = true
                    }
                }
            }
        }

        // Install size: e.g. [cli] INFO: Install size: 57208.92 MiB
        if line.contains("Install size:"),
           let match = line.range(of: #"Install size:\s*([0-9.]+)\s*([A-Za-z]+)"#, options: .regularExpression) {
            let matchedStr = String(line[match])
            if let sub = matchedStr.range(of: #"([0-9.]+)\s*([A-Za-z]+)"#, options: .regularExpression) {
                let parts = String(matchedStr[sub]).split(separator: " ")
                if parts.count == 2, let bytes = Self.parseSizeToBytes(valueStr: String(parts[0]), unitStr: String(parts[1])) {
                    sessionInstallBytes = bytes
                }
            }
        }

        // Download size: e.g. [cli] INFO: Download size: 56454.43 MiB
        if line.contains("Download size:"),
           let match = line.range(of: #"Download size:\s*([0-9.]+)\s*([A-Za-z]+)"#, options: .regularExpression) {
            let matchedStr = String(line[match])
            if let sub = matchedStr.range(of: #"([0-9.]+)\s*([A-Za-z]+)"#, options: .regularExpression) {
                let parts = String(matchedStr[sub]).split(separator: " ")
                if parts.count == 2, let bytes = Self.parseSizeToBytes(valueStr: String(parts[0]), unitStr: String(parts[1])) {
                    sessionDownloadBytes = bytes
                }
            }
        }

        // DLManager Progress & ETA
        // e.g. [DLManager] INFO: = Progress: 1.25% (735/58781), Running for 00:01:20, ETA: 01:45:00
        if line.contains("= Progress:") {
            if let pctMatch = line.range(of: #"=\s*Progress:\s*(\d+(?:\.\d+)?)%"#, options: .regularExpression) {
                let matchedStr = String(line[pctMatch])
                if let numMatch = matchedStr.range(of: #"(\d+(?:\.\d+)?)"#, options: .regularExpression),
                   let val = Double(matchedStr[numMatch]) {
                    sessionFraction = min(max(val / 100.0, 0), 1.0)
                }
            }
            if let etaMatch = line.range(of: #"ETA:\s*([0-9:]+)"#, options: .regularExpression) {
                lastEtaDesc = String(line[etaMatch]).replacingOccurrences(of: "ETA:", with: "").trimmingCharacters(in: .whitespaces)
            }
            if let chunkMatch = line.range(of: #"\(([0-9/.]+)\)"#, options: .regularExpression) {
                lastProgressDesc = String(line[chunkMatch])
            }
        } else if sessionFraction == nil,
                  !line.contains("savings:"),
                  !line.contains("Compression"),
                  let range = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) {
            let pctStr = String(line[range]).replacingOccurrences(of: "%", with: "")
            if let val = Double(pctStr) {
                sessionFraction = min(max(val / 100.0, 0), 1.0)
            }
        }

        // Downloaded & Written MiB
        // e.g. [DLManager] INFO:  - Downloaded: 710.25 MiB, Written: 705.10 MiB
        if line.contains("Downloaded:") && line.contains("Written:") {
            if let dlMatch = line.range(of: #"Downloaded:\s*([0-9.]+)\s*([A-Za-z]+)"#, options: .regularExpression) {
                let matchedStr = String(line[dlMatch])
                if let sub = matchedStr.range(of: #"([0-9.]+)\s*([A-Za-z]+)"#, options: .regularExpression) {
                    let parts = String(matchedStr[sub]).split(separator: " ")
                    if parts.count == 2, let bytes = Self.parseSizeToBytes(valueStr: String(parts[0]), unitStr: String(parts[1])) {
                        sessionDownloadedBytes = bytes
                    }
                }
            }
            if let wMatch = line.range(of: #"Written:\s*([0-9.]+)\s*([A-Za-z]+)"#, options: .regularExpression) {
                let matchedStr = String(line[wMatch])
                if let sub = matchedStr.range(of: #"([0-9.]+)\s*([A-Za-z]+)"#, options: .regularExpression) {
                    let parts = String(matchedStr[sub]).split(separator: " ")
                    if parts.count == 2, let bytes = Self.parseSizeToBytes(valueStr: String(parts[0]), unitStr: String(parts[1])) {
                        sessionWrittenBytes = bytes
                    }
                }
            }
        }

        // Speed e.g. [DLManager] INFO:  + Download	- 12.50 MiB/s (raw)
        if (line.contains("Download") || line.contains("+ Download")) && line.contains("/s") {
            if let speedMatch = line.range(of: #"([0-9.]+\s*[A-Za-z]+\/s)"#, options: .regularExpression) {
                lastSpeedDesc = String(line[speedMatch])
            }
        }

        // Calculate overall progress across past sessions and current session
        let sessionTargetBytes = sessionInstallBytes > 0 ? sessionInstallBytes : sessionDownloadBytes
        let totalTargetBytes = skippedBytes + sessionTargetBytes

        let currentDoneBytes: Int64
        let overallFraction: Double

        if totalTargetBytes > 0 {
            if let sessionFrac = sessionFraction {
                let currentSessionBytes = Int64(Double(sessionTargetBytes) * sessionFrac)
                currentDoneBytes = min(totalTargetBytes, skippedBytes + max(currentSessionBytes, sessionDownloadedBytes))
            } else if sessionDownloadedBytes > 0 {
                currentDoneBytes = min(totalTargetBytes, skippedBytes + sessionDownloadedBytes)
            } else {
                currentDoneBytes = skippedBytes
            }
            overallFraction = min(max(Double(currentDoneBytes) / Double(totalTargetBytes), 0.0), 1.0)
            lastFraction = overallFraction
        } else if let sessionFrac = sessionFraction {
            currentDoneBytes = 0
            overallFraction = sessionFrac
            lastFraction = overallFraction
        } else {
            currentDoneBytes = 0
            overallFraction = lastFraction ?? 0.0
        }

        var parts: [String] = []
        let pctInt = Int(overallFraction * 100)

        if totalTargetBytes > 0 {
            let doneStr = ByteCountFormatter.string(fromByteCount: currentDoneBytes, countStyle: .file)
            let totalStr = ByteCountFormatter.string(fromByteCount: totalTargetBytes, countStyle: .file)
            if isResumed {
                parts.append("Resuming: \(doneStr) of \(totalStr) (\(pctInt)%)")
            } else {
                parts.append("Downloading: \(doneStr) of \(totalStr) (\(pctInt)%)")
            }
        } else if overallFraction > 0 {
            if isResumed {
                parts.append("Resuming: \(pctInt)%")
            } else {
                parts.append("Downloading: \(pctInt)%")
            }
        }

        if let speed = lastSpeedDesc {
            parts.append(speed)
        }
        if let eta = lastEtaDesc {
            parts.append("ETA: \(eta)")
        }

        let detail: String
        if !parts.isEmpty {
            detail = parts.joined(separator: " • ")
        } else {
            var clean = line
            for prefix in ["[DLManager] INFO: ", "[cli] INFO: ", "[Core] INFO: ", "[cli] WARNING: ", "[Core] WARNING: "] {
                if clean.hasPrefix(prefix) {
                    clean = String(clean.dropFirst(prefix.count))
                }
            }
            detail = clean
        }

        return HeroicInstallProgress(
            fraction: lastFraction,
            detail: detail,
            speed: lastSpeedDesc,
            eta: lastEtaDesc,
            currentBytes: currentDoneBytes > 0 ? currentDoneBytes : nil,
            totalBytes: totalTargetBytes > 0 ? totalTargetBytes : nil
        )
    }
}
