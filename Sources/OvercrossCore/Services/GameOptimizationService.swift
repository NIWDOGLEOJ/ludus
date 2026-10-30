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
        "cchromaeditorlibrary.dll",
        "dstorage.dll",
        "dstoragecore.dll"
    ]

    /// Essential game libraries that must never remain renamed to `.bak` as games require them to bootstrap.
    static let essentialLibrariesToRestore: Set<String> = [
        "sl.interposer.dll",
        "sl.reflex.dll",
        "sl.common.dll",
        "sl.deepdvc.dll",
        "sl.dlss_g.dll",
        "sl.pcl.dll",
        "gfesdk.dll"
    ]

    /// Libraries in Nixxes / Sony PC ports that trigger CrossOver nvngx/Streamline translation deadlocks
    static let problematicSonyLibraries: Set<String> = [
        "sl.interposer.dll"
    ]

    /// Scans the game installation directory and automatically restores any essential libraries previously renamed to `.dll.bak`.
    @discardableResult
    func restoreEssentialLibraries(at installationURL: URL, isSony: Bool = false) -> [String] {
        guard FileManager.default.fileExists(atPath: installationURL.path) else { return [] }

        var restored: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: installationURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            let filename = fileURL.lastPathComponent.lowercased()
            if filename.hasSuffix(".bak") {
                let originalStem = fileURL.deletingPathExtension().lastPathComponent.lowercased()
                if isSony && Self.problematicSonyLibraries.contains(originalStem) {
                    continue
                }
                if Self.essentialLibrariesToRestore.contains(originalStem) {
                    let targetURL = fileURL.deletingPathExtension()
                    do {
                        if FileManager.default.fileExists(atPath: targetURL.path) {
                            try FileManager.default.removeItem(at: fileURL)
                            restored.append(targetURL.lastPathComponent)
                        } else {
                            try FileManager.default.moveItem(at: fileURL, to: targetURL)
                            restored.append(targetURL.lastPathComponent)
                        }
                    } catch {
                        // Ignore move errors
                    }
                }
            }
        }
        return restored
    }

    /// Recursively scans the game installation directory and neutralizes known problematic DLLs by safely renaming them to `.dll.bak`.
    @discardableResult
    func neutralizeProblematicLibraries(at installationURL: URL, isSony: Bool = false) -> [String] {
        guard FileManager.default.fileExists(atPath: installationURL.path) else { return [] }

        let targets = isSony ? Self.problematicLibraries.union(Self.problematicSonyLibraries) : Self.problematicLibraries
        var neutralized: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: installationURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            let filename = fileURL.lastPathComponent.lowercased()
            if targets.contains(filename) {
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
        if titleLower.contains("hogwarts") || titleLower.contains("phoenix") || titleLower.contains("unreal") {
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

            // Dynamically check subdirectories for Unreal signatures (e.g. Binaries/Win64 or Content/Paks)
            if let subdirs = try? FileManager.default.contentsOfDirectory(at: install, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for subdir in subdirs {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: subdir.path, isDirectory: &isDir), isDir.boolValue {
                        let win64 = subdir.appendingPathComponent("Binaries/Win64", isDirectory: true)
                        let paks = subdir.appendingPathComponent("Content/Paks", isDirectory: true)
                        if FileManager.default.fileExists(atPath: win64.path) || FileManager.default.fileExists(atPath: paks.path) {
                            return true
                        }
                    }
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

        let cleanTitle = gameTitle.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let exeStem = executableURL?.deletingPathExtension().lastPathComponent ?? cleanTitle
        let strippedStem = exeStem
            .replacingOccurrences(of: "-Win64-Shipping", with: "")
            .replacingOccurrences(of: "Shipping", with: "")

        var candidateFolderNames = [
            gameTitle,
            cleanTitle,
            exeStem,
            strippedStem,
            "Hogwarts Legacy",
            "HogwartsLegacy",
            "Phoenix"
        ]
        if !strippedStem.isEmpty {
            candidateFolderNames.append(strippedStem.components(separatedBy: CharacterSet.alphanumerics.inverted).joined())
        }

        var existingCandidateURLs: [URL] = []
        if FileManager.default.fileExists(atPath: appDataLocal.path) {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: appDataLocal.path) {
                for entry in entries {
                    for candidate in candidateFolderNames where !candidate.isEmpty {
                        if entry.lowercased() == candidate.lowercased() {
                            let possibleInis = [
                                appDataLocal.appendingPathComponent("\(entry)/Saved/Config/WindowsNoEditor/Engine.ini"),
                                appDataLocal.appendingPathComponent("\(entry)/Saved/Config/Windows/Engine.ini")
                            ]
                            for ini in possibleInis {
                                if FileManager.default.fileExists(atPath: ini.path) && !existingCandidateURLs.contains(ini) {
                                    existingCandidateURLs.append(ini)
                                }
                            }
                        }
                    }
                }
            }
        }

        var success = false
        if !existingCandidateURLs.isEmpty {
            for iniURL in existingCandidateURLs {
                if applyEngineINISettings(to: iniURL, poolSizeMB: poolMB) {
                    success = true
                }
            }
        } else {
            let folderName = cleanTitle.isEmpty ? (exeStem.isEmpty ? "UnrealGame" : exeStem) : cleanTitle
            let fallbackURL = appDataLocal.appendingPathComponent("\(folderName)/Saved/Config/WindowsNoEditor/Engine.ini")
            success = applyEngineINISettings(to: fallbackURL, poolSizeMB: poolMB)
        }

        return success
    }

    /// Safely updates or creates `Engine.ini` with optimal settings for Apple Silicon unified memory without wiping user customizations.
    func applyEngineINISettings(to iniURL: URL, poolSizeMB: Int) -> Bool {
        let parentDir = iniURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var content = (try? String(contentsOf: iniURL, encoding: .utf8)) ?? ""

        // Scrub hazardous directives, deduplicate keys, and apply unified memory streaming settings
        content = updateSection(
            named: "SystemSettings",
            scrubKeys: [
                "r.CreateShadersOnLoad",
                "r.ShaderPipelineCache.BatchSize",
                "r.ShaderPipelineCache.BackgroundBatchSize",
                "r.ShaderPipelineCache.PreCompileBatchTime",
                "r.ShaderPipelineCache.ReportPSO",
                "r.ShaderPipelineCache.Enabled",
                "r.D3D12.TexturePoolSize",
                "r.Shaders.Optimize",
                "r.XGEShaderCompile"
            ],
            settings: [
                "r.TextureStreaming": "1",
                "r.Streaming.PoolSize": "\(poolSizeMB)",
                "r.Streaming.LimitPoolSizeToVRAM": "1",
                "r.Streaming.UseFixedPoolSize": "1",
                "r.Streaming.HLODStrategy": "2",
                "r.Streaming.DefragDynamicBounds": "1",
                "r.bForceCPUAccessToGPUSkinVerts": "True",
                "r.GTSyncType": "1",
                "r.OneFrameThreadLag": "1",
                "r.FinishCurrentFrame": "0",
                "r.VSync": "0",
                "t.MaxFPS": "120",
                "gc.TimeBetweenPurgingPendingKillObjects": "30"
            ],
            in: content
        )

        // Deduplicate and apply async render thread console variables
        content = updateSection(
            named: "ConsoleVariables",
            scrubKeys: [],
            settings: [
                "AllowAsyncRenderThreadUpdates": "1",
                "AllowAsyncRenderThreadUpdatesDuringGamethreadUpdates": "1",
                "AllowAsyncRenderThreadUpdatesEditor": "1"
            ],
            in: content
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

        // 1. Problematic DLL neutralization & essential library restoration
        var neutralized: [String] = []
        let isSony = GameLaunchService.isNixxesOrSonyTitle(
            title: game.title,
            executableURL: game.executableURL ?? (game.installationURL ?? URL(fileURLWithPath: "/"))
        )
        if let installURL = game.installationURL {
            let restored = restoreEssentialLibraries(at: installURL, isSony: isSony)
            if !restored.isEmpty {
                details.append("Restored \(restored.joined(separator: ", "))")
            }
            neutralized = neutralizeProblematicLibraries(at: installURL, isSony: isSony)
            if !neutralized.isEmpty {
                let hasDStorage = neutralized.contains(where: { $0.lowercased().contains("dstorage") })
                let hasInterposer = neutralized.contains(where: { $0.lowercased().contains("sl.interposer") })
                let reason = hasDStorage ? "bypassed DirectStorage I/O spinlock" : (hasInterposer ? "bypassed Streamline DLSS deadlock" : "prevented CPU spinlock")
                details.append("Neutralized \(neutralized.joined(separator: ", ")) (\(reason))")
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

    /// Updates or creates a section in an INI file, scrubbing specified keys, deduplicating keys, and merging new settings.
    func updateSection(
        named sectionName: String,
        scrubKeys: [String] = [],
        settings: [String: String] = [:],
        in iniContent: String
    ) -> String {
        let lines = iniContent.components(separatedBy: "\n")
        let targetHeader = "[\(sectionName)]".lowercased()
        let scrubSet = Set(scrubKeys.map { $0.lowercased() })

        // 1. Partition lines into sections
        var sections: [(header: String?, lines: [String])] = []
        var currentHeader: String?
        var currentLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if currentHeader != nil || !currentLines.isEmpty {
                    sections.append((currentHeader, currentLines))
                }
                currentHeader = trimmed
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        sections.append((currentHeader, currentLines))

        // 2. Locate or create target section
        var targetIndex = sections.firstIndex { sec in
            sec.header?.trimmingCharacters(in: .whitespaces).lowercased() == targetHeader
        }

        if targetIndex == nil {
            sections.append(("[\(sectionName)]", []))
            targetIndex = sections.count - 1
        }

        guard let index = targetIndex else { return iniContent }
        let targetLines = sections[index].lines

        // 3. Process section lines: scrub, deduplicate, and update existing settings
        var seenKeys: Set<String> = []
        var filteredLines: [String] = []
        var updatedKeys: Set<String> = []

        var lowerSettings: [String: (String, String)] = [:]
        for (k, v) in settings {
            lowerSettings[k.lowercased()] = (k, v)
        }

        for line in targetLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
                filteredLines.append(line)
                continue
            }
            if let eqIndex = line.firstIndex(of: "=") {
                let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let lowerKey = key.lowercased()

                if scrubSet.contains(lowerKey) {
                    continue
                }

                if seenKeys.contains(lowerKey) {
                    continue
                }
                seenKeys.insert(lowerKey)

                if let (canonicalKey, newValue) = lowerSettings[lowerKey] {
                    filteredLines.append("\(canonicalKey)=\(newValue)")
                    updatedKeys.insert(lowerKey)
                } else {
                    filteredLines.append(line)
                }
            } else {
                filteredLines.append(line)
            }
        }

        // 4. Append new settings that were not present in existing lines
        for (key, val) in settings {
            let lowerKey = key.lowercased()
            if !updatedKeys.contains(lowerKey) && !seenKeys.contains(lowerKey) {
                filteredLines.append("\(key)=\(val)")
                updatedKeys.insert(lowerKey)
            }
        }

        // 5. Trim trailing blank lines in section
        while let last = filteredLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            filteredLines.removeLast()
        }

        sections[index].lines = filteredLines

        // 6. Reconstruct document
        var outputLines: [String] = []
        for (header, secLines) in sections {
            if let header {
                if !outputLines.isEmpty && !outputLines.last!.trimmingCharacters(in: .whitespaces).isEmpty {
                    outputLines.append("")
                }
                outputLines.append(header)
            }
            outputLines.append(contentsOf: secLines)
        }

        return outputLines.joined(separator: "\n")
    }

    func removeSettings(
        keys: [String],
        from sectionName: String,
        in iniContent: String
    ) -> String {
        updateSection(named: sectionName, scrubKeys: keys, settings: [:], in: iniContent)
    }

    func mergeSection(
        named sectionName: String,
        settings: [String: String],
        into iniContent: String
    ) -> String {
        updateSection(named: sectionName, scrubKeys: [], settings: settings, in: iniContent)
    }
}
