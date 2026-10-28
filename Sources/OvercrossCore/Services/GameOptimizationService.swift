import Foundation

struct GameOptimizationReport: Sendable, Equatable {
    let neutralizedLibraries: [String]
    let configuredEngineINI: Bool
    let streamingPoolMB: Int?
    let details: [String]

    init(
        neutralizedLibraries: [String] = [],
        configuredEngineINI: Bool = false,
        streamingPoolMB: Int? = nil,
        details: [String] = []
    ) {
        self.neutralizedLibraries = neutralizedLibraries
        self.configuredEngineINI = configuredEngineINI
        self.streamingPoolMB = streamingPoolMB
        self.details = details
    }

    var summary: String? {
        guard !details.isEmpty else { return nil }
        return "[Automatic Optimizations: " + details.joined(separator: "; ") + "]"
    }
}

struct GameOptimizationService: Sendable {
    init() {}

    /// Known problematic libraries bundled in Windows games that cause thread spin-locks, CPU starvation, or crashes on Apple Silicon Wine.
    static let problematicLibraries: Set<String> = [
        "cchromaeditorlibrary64.dll",
        "cchromaeditorlibrary.dll"
    ]

    /// Recursively scans the game installation directory and neutralizes known problematic DLLs by safely renaming them to `.dll.bak`.
    @discardableResult
    func neutralizeProblematicLibraries(at installationURL: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: installationURL.path) else { return [] }

        var neutralized: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: installationURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            let filename = fileURL.lastPathComponent.lowercased()
            if Self.problematicLibraries.contains(filename) {
                let backupURL = fileURL.deletingPathExtension().appendingPathExtension("dll.bak")
                if !FileManager.default.fileExists(atPath: backupURL.path) {
                    do {
                        try FileManager.default.moveItem(at: fileURL, to: backupURL)
                        neutralized.append(fileURL.lastPathComponent)
                    } catch {
                        if (try? FileManager.default.removeItem(at: fileURL)) != nil {
                            neutralized.append(fileURL.lastPathComponent)
                        }
                    }
                } else {
                    if (try? FileManager.default.removeItem(at: fileURL)) != nil {
                        neutralized.append(fileURL.lastPathComponent)
                    }
                }
            }
        }

        return neutralized
    }

    /// Determines the optimal Unreal Engine texture streaming pool size based on physical unified memory.
    func optimalStreamingPoolMB(totalRAMBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let totalGB = Double(totalRAMBytes) / (1024.0 * 1024.0 * 1024.0)
        if totalGB <= 18.0 {
            // 8GB - 16GB Unified Memory Macs: cap at 2048MB (2 GB) to prevent memory exhaustion and macOS disk swap thrashing
            return 2048
        } else if totalGB <= 36.0 {
            // 24GB - 36GB Unified Memory Macs
            return 4096
        } else {
            // 48GB+ Unified Memory Macs
            return 6144
        }
    }

    /// Checks if a game appears to be an Unreal Engine title (or specifically known to need Engine.ini tuning).
    func isUnrealEngineTitle(installationURL: URL?, executableURL: URL?, gameTitle: String) -> Bool {
        let titleLower = gameTitle.lowercased()
        if titleLower.contains("hogwarts") || titleLower.contains("phoenix") {
            return true
        }

        if let exe = executableURL {
            let name = exe.deletingPathExtension().lastPathComponent.lowercased()
            if name.contains("shipping") || name.contains("win64") || name.contains("ue4") || name.contains("ue5") {
                return true
            }
        }

        if let install = installationURL {
            let checkPaths = [
                install.appendingPathComponent("Engine", isDirectory: true),
                install.appendingPathComponent("Phoenix", isDirectory: true),
                install.appendingPathComponent("Binaries/Win64", isDirectory: true)
            ]
            for p in checkPaths {
                if FileManager.default.fileExists(atPath: p.path) {
                    return true
                }
            }
        }

        return false
    }

    /// Locates or creates the game's Engine.ini in the bottle prefix AppData directory and applies streaming pool & garbage collection optimizations.
    @discardableResult
    func optimizeEngineINI(
        prefixURL: URL,
        gameTitle: String,
        executableURL: URL?,
        poolSizeMB: Int? = nil
    ) -> Bool {
        let poolMB = poolSizeMB ?? optimalStreamingPoolMB()
        let appDataLocal = prefixURL.appendingPathComponent("drive_c/users/crossover/AppData/Local", isDirectory: true)

        var targetEngineINI: URL?
        let cleanTitle = gameTitle.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let exeStem = executableURL?.deletingPathExtension().lastPathComponent ?? cleanTitle

        let candidateFolderNames = [
            gameTitle,
            cleanTitle,
            exeStem,
            "Hogwarts Legacy",
            "HogwartsLegacy",
            "Phoenix"
        ]

        if FileManager.default.fileExists(atPath: appDataLocal.path) {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: appDataLocal.path) {
                for entry in entries {
                    for candidate in candidateFolderNames {
                        if entry.lowercased() == candidate.lowercased() {
                            let ini = appDataLocal.appendingPathComponent("\(entry)/Saved/Config/WindowsNoEditor/Engine.ini")
                            targetEngineINI = ini
                            break
                        }
                    }
                    if targetEngineINI != nil { break }
                }
            }
        }

        let finalINIURL: URL
        if let existing = targetEngineINI {
            finalINIURL = existing
        } else {
            let folderName = cleanTitle.isEmpty ? (exeStem.isEmpty ? "UnrealGame" : exeStem) : cleanTitle
            finalINIURL = appDataLocal.appendingPathComponent("\(folderName)/Saved/Config/WindowsNoEditor/Engine.ini")
        }

        return applyEngineINISettings(to: finalINIURL, poolSizeMB: poolMB)
    }

    /// Safely updates or creates `Engine.ini` with optimal settings for Apple Silicon unified memory without wiping user customizations.
    func applyEngineINISettings(to iniURL: URL, poolSizeMB: Int) -> Bool {
        let parentDir = iniURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var content = (try? String(contentsOf: iniURL, encoding: .utf8)) ?? ""

        // Merge SystemSettings
        content = mergeSection(
            named: "SystemSettings",
            settings: [
                "r.TextureStreaming": "1",
                "r.Streaming.PoolSize": "\(poolSizeMB)",
                "r.Streaming.LimitPoolSizeToVRAM": "1",
                "r.bForceCPUAccessToGPUSkinVerts": "True",
                "r.GTSyncType": "1",
                "r.OneFrameThreadLag": "1",
                "r.FinishCurrentFrame": "0",
                "gc.TimeBetweenPurgingPendingKillObjects": "30"
            ],
            into: content
        )

        // Merge ConsoleVariables
        content = mergeSection(
            named: "ConsoleVariables",
            settings: [
                "AllowAsyncRenderThreadUpdates": "1",
                "AllowAsyncRenderThreadUpdatesDuringGamethreadUpdates": "1",
                "AllowAsyncRenderThreadUpdatesEditor": "1"
            ],
            into: content
        )

        do {
            try content.write(to: iniURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Full automatic preflight optimization for a game launch.
    func optimize(
        game: Game,
        prefixURL: URL
    ) -> GameOptimizationReport {
        var details: [String] = []

        // 1. Problematic DLL neutralization
        var neutralized: [String] = []
        if let installURL = game.installationURL {
            neutralized = neutralizeProblematicLibraries(at: installURL)
            if !neutralized.isEmpty {
                details.append("Neutralized \(neutralized.joined(separator: ", ")) (prevented CPU spinlock)")
            }
        }

        // 2. Unreal Engine streaming & VRAM memory optimization
        var configuredINI = false
        var poolSize: Int?
        if isUnrealEngineTitle(installationURL: game.installationURL, executableURL: game.executableURL, gameTitle: game.title) {
            let pool = optimalStreamingPoolMB()
            poolSize = pool
            if optimizeEngineINI(prefixURL: prefixURL, gameTitle: game.title, executableURL: game.executableURL, poolSizeMB: pool) {
                configuredINI = true
                details.append("Optimized Engine.ini streaming pool (\(pool)MB) for unified memory")
            }
        }

        return GameOptimizationReport(
            neutralizedLibraries: neutralized,
            configuredEngineINI: configuredINI,
            streamingPoolMB: poolSize,
            details: details
        )
    }

    private func mergeSection(
        named sectionName: String,
        settings: [String: String],
        into iniContent: String
    ) -> String {
        var lines = iniContent.components(separatedBy: "\n")
        let sectionHeader = "[\(sectionName)]".lowercased()

        var sectionStartIndex: Int?
        var sectionEndIndex: Int?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == sectionHeader {
                sectionStartIndex = index
            } else if sectionStartIndex != nil && trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                sectionEndIndex = index
                break
            }
        }

        if let start = sectionStartIndex {
            let end = sectionEndIndex ?? lines.count
            var existingKeys: [String: Int] = [:]

            for i in (start + 1)..<end {
                let line = lines[i]
                if let eqIndex = line.firstIndex(of: "=") {
                    let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                    existingKeys[key.lowercased()] = i
                }
            }

            var insertOffset = 0
            for (key, val) in settings {
                if let lineIdx = existingKeys[key.lowercased()] {
                    lines[lineIdx + insertOffset] = "\(key)=\(val)"
                } else {
                    lines.insert("\(key)=\(val)", at: end + insertOffset)
                    insertOffset += 1
                }
            }
        } else {
            if !lines.isEmpty && !lines.last!.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("[\(sectionName)]")
            for (key, val) in settings {
                lines.append("\(key)=\(val)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
