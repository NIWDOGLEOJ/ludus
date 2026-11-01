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

struct CrossOverDLSSIsolation: Sendable {
    let isolatedPaths: [(original: URL, isolated: URL)]

    init(isolatedPaths: [(original: URL, isolated: URL)] = []) {
        self.isolatedPaths = isolatedPaths
    }

    @discardableResult
    func restore() -> [URL] {
        var restored: [URL] = []
        for pair in isolatedPaths {
            guard FileManager.default.fileExists(atPath: pair.isolated.path) else { continue }
            do {
                if FileManager.default.fileExists(atPath: pair.original.path) {
                    let origSize = (try? FileManager.default.attributesOfItem(atPath: pair.original.path)[.size] as? UInt64) ?? 0
                    let isoSize = (try? FileManager.default.attributesOfItem(atPath: pair.isolated.path)[.size] as? UInt64) ?? 0
                    if origSize == 0 && isoSize > 0 {
                        try? FileManager.default.removeItem(at: pair.original)
                        try FileManager.default.moveItem(at: pair.isolated, to: pair.original)
                        restored.append(pair.original)
                    } else {
                        try? FileManager.default.removeItem(at: pair.isolated)
                    }
                } else {
                    try FileManager.default.moveItem(at: pair.isolated, to: pair.original)
                    restored.append(pair.original)
                }
            } catch {
                // Best-effort restoration
            }
        }
        return restored
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
        let targetFolderURL = game.installationURL ?? game.executableURL?.deletingLastPathComponent()
        if let targetFolderURL {
            let restored = restoreEssentialLibraries(at: targetFolderURL, isSony: isSony)
            if !restored.isEmpty {
                details.append("Restored \(restored.joined(separator: ", "))")
            }
            neutralized = neutralizeProblematicLibraries(at: targetFolderURL, isSony: isSony)
            if !neutralized.isEmpty {
                let hasDStorage = neutralized.contains(where: { $0.lowercased().contains("dstorage") })
                let hasInterposer = neutralized.contains(where: { $0.lowercased().contains("sl.interposer") })
                let reason = hasDStorage ? "bypassed DirectStorage I/O spinlock" : (hasInterposer ? "bypassed Streamline DLSS deadlock" : "prevented CPU spinlock")
                details.append("Neutralized \(neutralized.joined(separator: ", ")) (\(reason))")
            }
        }

        // 2. Spider-Man 2 T-Pose & Fog Barrier Fix (MacGameFix) & Driver Warning Bypass
        let isSM2 = Self.isSpiderMan2(
            title: game.title,
            executableURL: game.executableURL ?? (targetFolderURL?.appendingPathComponent("Spider-Man2.exe"))
        )
        if isSM2, let targetFolderURL {
            let sm2Result = Self.verifyOrInstallSpiderMan2Fix(at: targetFolderURL)
            if !sm2Result.details.isEmpty {
                details.append(contentsOf: sm2Result.details)
            }
            if Self.bypassSpiderMan2DriverWarning(at: targetFolderURL) {
                details.append("Bypassed driver popup dialog")
            }
        }

        // 3. Patch Wine's atiadlxx.dll to modern Radeon Software 25.10.1 to prevent Old Driver dialog
        if Self.patchAtiadlxxDriverVersion(in: prefixURL) {
            details.append("Patched atiadlxx.dll to Radeon Software 25.10.1")
        }

        // 4. Unreal Engine streaming & VRAM memory optimization
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

    // MARK: - CrossOver DLSS Stub Neutralization & Isolation

    static let crossoverDLSSRelativePaths = [
        "lib64/apple_gptk/wine/x86_64-windows/nvngx.dll",
        "lib/dxmt/x86_64-windows/nvngx.dll"
    ]

    static func crossoverCandidateDirectories(
        cxRootURL: URL? = nil,
        runtimeExecutableURL: URL? = nil
    ) -> [URL] {
        var baseDirectories: [URL] = []
        if let cxRootURL {
            baseDirectories.append(cxRootURL)
        }
        if let runtimeExecutableURL, runtimeExecutableURL.path.contains("SharedSupport/CrossOver") {
            let cxRoot = runtimeExecutableURL.deletingLastPathComponent().deletingLastPathComponent()
            if !baseDirectories.contains(cxRoot) {
                baseDirectories.append(cxRoot)
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let standardCandidates = [
            URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"),
            URL(fileURLWithPath: "\(home)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"),
            URL(fileURLWithPath: "/Users/godjoel/overcross/reference/crossover/Contents/SharedSupport/CrossOver")
        ]
        for candidate in standardCandidates where !baseDirectories.contains(candidate) {
            baseDirectories.append(candidate)
        }

        if let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for vol in volumes {
                let v = "/Volumes/\(vol)"
                let volCandidates = [
                    URL(fileURLWithPath: "\(v)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"),
                    URL(fileURLWithPath: "\(v)/downloads/CrossOver.app/Contents/SharedSupport/CrossOver"),
                    URL(fileURLWithPath: "\(v)/Downloads/CrossOver.app/Contents/SharedSupport/CrossOver")
                ]
                for vc in volCandidates where !baseDirectories.contains(vc) {
                    baseDirectories.append(vc)
                }
            }
        }
        return baseDirectories
    }

    /// Scans CrossOver runtime directories and isolates internal `nvngx.dll` DLSS stubs that cause DX12 render thread deadlocks in Nixxes titles.
    @discardableResult
    static func isolateCrossOverDLSS(
        cxRootURL: URL? = nil,
        runtimeExecutableURL: URL? = nil
    ) -> CrossOverDLSSIsolation {
        let bases: [URL]
        if let cxRootURL {
            var b = [cxRootURL]
            if let runtimeExecutableURL, runtimeExecutableURL.path.contains("SharedSupport/CrossOver") {
                let cxRoot = runtimeExecutableURL.deletingLastPathComponent().deletingLastPathComponent()
                if !b.contains(cxRoot) { b.append(cxRoot) }
            }
            bases = b
        } else {
            bases = crossoverCandidateDirectories(runtimeExecutableURL: runtimeExecutableURL)
        }

        var pairs: [(original: URL, isolated: URL)] = []

        for base in bases {
            for rel in crossoverDLSSRelativePaths {
                let original = base.appendingPathComponent(rel)
                let isolated = base.appendingPathComponent("\(rel).isolated")

                if FileManager.default.fileExists(atPath: original.path) {
                    do {
                        if FileManager.default.fileExists(atPath: isolated.path) {
                            try? FileManager.default.removeItem(at: isolated)
                        }
                        try FileManager.default.moveItem(at: original, to: isolated)
                        pairs.append((original: original, isolated: isolated))
                    } catch {
                        // Skip if unable to move
                    }
                } else if FileManager.default.fileExists(atPath: isolated.path) {
                    pairs.append((original: original, isolated: isolated))
                }
            }
        }
        return CrossOverDLSSIsolation(isolatedPaths: pairs)
    }

    /// Restores any previously isolated or disabled CrossOver DLSS stubs across known candidate runtime locations.
    @discardableResult
    static func restoreAllIsolatedDLSSStubs(
        cxRootURL: URL? = nil,
        runtimeExecutableURL: URL? = nil
    ) -> [URL] {
        let bases = crossoverCandidateDirectories(cxRootURL: cxRootURL, runtimeExecutableURL: runtimeExecutableURL)
        var restored: [URL] = []

        for base in bases {
            for rel in crossoverDLSSRelativePaths {
                let original = base.appendingPathComponent(rel)
                let isolatedCandidate = base.appendingPathComponent("\(rel).isolated")
                let disabledCandidate = base.appendingPathComponent("\(rel).disabled")
                let bakCandidate = base.appendingPathComponent("\(rel).bak")

                for candidate in [isolatedCandidate, disabledCandidate, bakCandidate] {
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        do {
                            if FileManager.default.fileExists(atPath: original.path) {
                                let origSize = (try? FileManager.default.attributesOfItem(atPath: original.path)[.size] as? UInt64) ?? 0
                                let candSize = (try? FileManager.default.attributesOfItem(atPath: candidate.path)[.size] as? UInt64) ?? 0
                                if origSize == 0 && candSize > 0 {
                                    try? FileManager.default.removeItem(at: original)
                                    try FileManager.default.moveItem(at: candidate, to: original)
                                    restored.append(original)
                                } else {
                                    try? FileManager.default.removeItem(at: candidate)
                                }
                            } else {
                                try FileManager.default.moveItem(at: candidate, to: original)
                                restored.append(original)
                            }
                        } catch {
                            // Skip if error
                        }
                    }
                }
            }
        }
        return restored
    }

    // MARK: - Spider-Man 2 T-Pose & Fog Barrier Fix (MacGameFix)

    public enum SpiderMan2FixStatus: Equatable, Sendable {
        case installed(build: String, fogBarrier: Bool)
        case missing
        case broken(reason: String)
        case notSpiderMan2
    }

    /// Checks if a title or executable belongs to Marvel's Spider-Man 2
    public static func isSpiderMan2(title: String, executableURL: URL?) -> Bool {
        let exeName = executableURL?.lastPathComponent.lowercased() ?? ""
        if exeName == "spider-man2.exe" || exeName == "spider-man 2.exe" {
            return true
        }
        let t = title.lowercased()
        if t.contains("spider-man 2") || t.contains("spiderman 2") || t.contains("spider-man2") || t.contains("spiderman2") {
            return true
        }
        return false
    }

    /// Normalizes game directory from URL (handles direct executable URL or directory URL).
    public static func normalizeGameDirectoryURL(from url: URL) -> URL {
        if url.pathExtension.lowercased() == "exe" {
            return url.deletingLastPathComponent()
        }
        return url
    }

    /// Neutralizes conflicting legacy d3d12.dll hooks in the Spider-Man 2 directory so the MacGameFix amd_ags_x64 proxy operates cleanly.
    @discardableResult
    public static func neutralizeLegacyD3D12InSpiderMan2(at installationURL: URL) -> Bool {
        let dir = normalizeGameDirectoryURL(from: installationURL)
        let d3d12URL = dir.appendingPathComponent("d3d12.dll")
        guard FileManager.default.fileExists(atPath: d3d12URL.path) else { return false }
        let backupURL = dir.appendingPathComponent("d3d12.dll.bak")
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.moveItem(at: d3d12URL, to: backupURL)
            return true
        } catch {
            return false
        }
    }

    /// Reads the PE TimeDateStamp and SizeOfImage from Spider-Man2.exe to verify the expected game build format (%08x-%08x).
    public static func readSpiderMan2GameBuild(from exeURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: exeURL) else { return nil }
        defer { try? handle.close() }
        guard let headerData = try? handle.read(upToCount: 4096), headerData.count >= 0x40 else { return nil }

        // Must check DOS header magic "MZ" (0x4D, 0x5A)
        guard headerData[0] == 0x4D && headerData[1] == 0x5A else { return nil }

        let peOffset = headerData.withUnsafeBytes { ptr -> UInt32 in
            ptr.loadUnaligned(fromByteOffset: 0x3c, as: UInt32.self).littleEndian
        }
        let peOffsetInt = Int(peOffset)
        guard peOffsetInt >= 0x40 && peOffsetInt + 84 <= headerData.count else { return nil }

        // Must check PE signature "PE\0\0" (0x50, 0x45, 0x00, 0x00)
        guard headerData[peOffsetInt] == 0x50 &&
              headerData[peOffsetInt + 1] == 0x45 &&
              headerData[peOffsetInt + 2] == 0x00 &&
              headerData[peOffsetInt + 3] == 0x00 else { return nil }

        let (timestamp, imageSize) = headerData.withUnsafeBytes { ptr -> (UInt32, UInt32) in
            let ts = ptr.loadUnaligned(fromByteOffset: peOffsetInt + 8, as: UInt32.self).littleEndian
            let sz = ptr.loadUnaligned(fromByteOffset: peOffsetInt + 80, as: UInt32.self).littleEndian
            return (ts, sz)
        }
        return String(format: "%08x-%08x", timestamp, imageSize)
    }

    /// Checks the installation status of MacGameFix for Spider-Man 2.
    public static func checkSpiderMan2FixStatus(at installationURL: URL) -> SpiderMan2FixStatus {
        let dir = normalizeGameDirectoryURL(from: installationURL)
        let exeURL = dir.appendingPathComponent("Spider-Man2.exe")
        guard FileManager.default.fileExists(atPath: exeURL.path) else {
            return .notSpiderMan2
        }

        guard let exeBuild = readSpiderMan2GameBuild(from: exeURL) else {
            return .broken(reason: "Spider-Man2.exe is not a valid Windows PE binary")
        }

        let liveProxyURL = dir.appendingPathComponent("amd_ags_x64.dll")
        let realDLLURL = dir.appendingPathComponent("amd_ags_x64_real.dll")
        let iniURL = dir.appendingPathComponent("sm2fix.ini")

        guard FileManager.default.fileExists(atPath: liveProxyURL.path) else {
            if FileManager.default.fileExists(atPath: realDLLURL.path) {
                return .broken(reason: "amd_ags_x64.dll is missing but amd_ags_x64_real.dll exists (half install)")
            }
            return .missing
        }

        // Verify proxy binary marker
        let marker = "sm2-tpose-fix.log"
        guard let proxyData = try? Data(contentsOf: liveProxyURL) else {
            return .broken(reason: "Cannot read amd_ags_x64.dll")
        }
        let isOurs = proxyData.range(of: Data(marker.utf8)) != nil
        if !isOurs {
            if !FileManager.default.fileExists(atPath: realDLLURL.path) {
                return .missing
            } else {
                return .broken(reason: "amd_ags_x64.dll is not the MacGameFix proxy")
            }
        }

        guard FileManager.default.fileExists(atPath: realDLLURL.path) else {
            return .broken(reason: "amd_ags_x64_real.dll original backup is missing")
        }

        guard FileManager.default.fileExists(atPath: iniURL.path),
              let iniContent = try? String(contentsOf: iniURL, encoding: .utf8) else {
            return .broken(reason: "sm2fix.ini is missing")
        }

        // Verify game build and settings
        var iniBuild: String?
        var fogBarrier = true
        var requiredShaders: [String] = []

        for line in iniContent.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if key == "game_build" {
                    iniBuild = val
                } else if key == "mgvf_fog_barrier" {
                    fogBarrier = (val != "0")
                } else if key == "shaders" {
                    requiredShaders = val.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                }
            }
        }

        guard let iniBuild, !iniBuild.isEmpty else {
            return .broken(reason: "sm2fix.ini is missing game_build entry")
        }

        if exeBuild != iniBuild {
            return .broken(reason: "Game build mismatch: exe is \(exeBuild), sm2fix.ini configured for \(iniBuild)")
        }

        guard !requiredShaders.isEmpty else {
            return .broken(reason: "sm2fix.ini specifies no shaders")
        }

        for shader in requiredShaders {
            let shaderURL = dir.appendingPathComponent("sm2fix-pool-\(shader).dxil")
            guard FileManager.default.fileExists(atPath: shaderURL.path) else {
                return .broken(reason: "Missing shader dxil: sm2fix-pool-\(shader).dxil")
            }
            guard let sData = try? Data(contentsOf: shaderURL), sData.count >= 32 else {
                return .broken(reason: "Damaged or incomplete shader dxil: sm2fix-pool-\(shader).dxil")
            }
            let magic = String(data: sData.prefix(4), encoding: .ascii)
            if magic != "DXBC" {
                return .broken(reason: "Damaged shader dxil: sm2fix-pool-\(shader).dxil")
            }
        }

        return .installed(build: exeBuild, fogBarrier: fogBarrier)
    }

    /// Restores original game files and removes MacGameFix artifacts for Spider-Man 2.
    @discardableResult
    public static func restoreSpiderMan2Fix(at installationURL: URL) -> (restored: Bool, details: [String]) {
        let dir = normalizeGameDirectoryURL(from: installationURL)
        var details: [String] = []

        let liveProxyURL = dir.appendingPathComponent("amd_ags_x64.dll")
        let realDLLURL = dir.appendingPathComponent("amd_ags_x64_real.dll")
        let iniURL = dir.appendingPathComponent("sm2fix.ini")
        let d3d12BakURL = dir.appendingPathComponent("d3d12.dll.bak")
        let d3d12URL = dir.appendingPathComponent("d3d12.dll")
        let logURL = dir.appendingPathComponent("sm2-tpose-fix.log")
        let sm2fixLogURL = dir.appendingPathComponent("sm2fix.log")

        // 1. Restore original amd_ags_x64.dll if real exists
        if FileManager.default.fileExists(atPath: realDLLURL.path) {
            do {
                if FileManager.default.fileExists(atPath: liveProxyURL.path) {
                    try FileManager.default.removeItem(at: liveProxyURL)
                }
                try FileManager.default.moveItem(at: realDLLURL, to: liveProxyURL)
                details.append("Restored original amd_ags_x64.dll")
            } catch {
                details.append("Failed to restore original amd_ags_x64.dll: \(error.localizedDescription)")
            }
        }

        // 2. Restore d3d12.dll if backup exists and target does not
        if FileManager.default.fileExists(atPath: d3d12BakURL.path) && !FileManager.default.fileExists(atPath: d3d12URL.path) {
            try? FileManager.default.moveItem(at: d3d12BakURL, to: d3d12URL)
            details.append("Restored d3d12.dll from backup")
        }

        // 3. Remove fix artifacts
        try? FileManager.default.removeItem(at: iniURL)
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: sm2fixLogURL)

        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files where f.hasPrefix("sm2fix-pool-") && f.hasSuffix(".dxil") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }

        details.append("Cleaned up MacGameFix shader pool and configuration")
        return (true, details)
    }

    /// Resolves the file URL of install-sm2-fix.sh from candidate locations.
    public static func resolveMacGameFixScript() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            cwd.appendingPathComponent("MacGameFix/fixes/install-sm2-fix.sh"),
            cwd.appendingPathComponent("reference/MacGameFix/fixes/install-sm2-fix.sh"),
            Bundle.main.bundleURL.appendingPathComponent("MacGameFix/fixes/install-sm2-fix.sh"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MacGameFix/fixes/install-sm2-fix.sh"),
            Bundle.main.resourceURL?.appendingPathComponent("MacGameFix/fixes/install-sm2-fix.sh"),
            home.appendingPathComponent("Library/Application Support/Overcross/MacGameFix/fixes/install-sm2-fix.sh"),
            home.appendingPathComponent("Library/Application Support/MacGameFix/fixes/install-sm2-fix.sh"),
            URL(fileURLWithPath: "/Users/godjoel/overcross/MacGameFix/fixes/install-sm2-fix.sh"),
            URL(fileURLWithPath: "/Users/godjoel/overcross/reference/MacGameFix/fixes/install-sm2-fix.sh")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Verifies that MacGameFix is installed and active for Spider-Man 2, neutralizing legacy d3d12.dll hooks and applying the fix if needed.
    public static func verifyOrInstallSpiderMan2Fix(at installationURL: URL) -> (installed: Bool, details: [String]) {
        let dir = normalizeGameDirectoryURL(from: installationURL)
        var details: [String] = []

        // 1. Neutralize legacy conflicting d3d12.dll if present
        if neutralizeLegacyD3D12InSpiderMan2(at: dir) {
            details.append("Neutralized legacy d3d12.dll in favor of MacGameFix proxy")
        }

        // 2. Optimize steam_emu.ini if present to eliminate overlay hooks and network hangs
        let steamEmuURL = dir.appendingPathComponent("steam_emu.ini")
        if FileManager.default.fileExists(atPath: steamEmuURL.path),
           let content = try? String(contentsOf: steamEmuURL, encoding: .utf8) {
            var updated = content
            updated = updated.replacingOccurrences(of: "Overlays=1", with: "Overlays=0")
            updated = updated.replacingOccurrences(of: "Offline=0", with: "Offline=1")
            if updated != content {
                try? updated.write(to: steamEmuURL, atomically: true, encoding: .utf8)
                details.append("Disabled Steam emulator overlay and enabled offline mode in steam_emu.ini")
            }
        }

        // 3. Check current status
        let status = checkSpiderMan2FixStatus(at: dir)
        switch status {
        case .installed(let build, let fogBarrier):
            let fogStr = fogBarrier ? "fog barrier active" : "fog barrier disabled"
            details.append("Verified MacGameFix active for Spider-Man 2 (build \(build), \(fogStr))")
            return (true, details)

        case .missing, .broken:
            let exeURL = dir.appendingPathComponent("Spider-Man2.exe")
            guard readSpiderMan2GameBuild(from: exeURL) != nil else {
                details.append("Spider-Man2.exe is not a valid Windows PE binary (\(status))")
                return (false, details)
            }

            // If broken because realDLL exists and live DLL is not our proxy, restore real first so install-sm2-fix.sh succeeds
            let liveProxyURL = dir.appendingPathComponent("amd_ags_x64.dll")
            let realDLLURL = dir.appendingPathComponent("amd_ags_x64_real.dll")
            if FileManager.default.fileExists(atPath: realDLLURL.path) && FileManager.default.fileExists(atPath: liveProxyURL.path) {
                let marker = "sm2-tpose-fix.log"
                let isOurs = (try? Data(contentsOf: liveProxyURL))?.range(of: Data(marker.utf8)) != nil
                if !isOurs {
                    try? FileManager.default.removeItem(at: liveProxyURL)
                    try? FileManager.default.moveItem(at: realDLLURL, to: liveProxyURL)
                    details.append("Restored original amd_ags_x64.dll prior to reinstallation")
                }
            }

            guard let scriptURL = resolveMacGameFixScript() else {
                details.append("MacGameFix script not found; status: \(status)")
                return (false, details)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path, dir.path]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let outputStr = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus == 0 {
                    details.append("Installed MacGameFix (Spider-Man 2 T-Pose & Fog Barrier Fix v1.3)")
                    return (true, details)
                } else {
                    let errSnippet = outputStr.isEmpty ? "no output" : (outputStr.components(separatedBy: "\n").last ?? outputStr)
                    details.append("MacGameFix installer exited with code \(process.terminationStatus) (\(errSnippet))")
                    return (false, details)
                }
            } catch {
                details.append("Failed to execute MacGameFix install script: \(error.localizedDescription)")
                return (false, details)
            }

        case .notSpiderMan2:
            return (false, details)
        }
    }

    /// Patches Wine's atiadlxx.dll in the bottle to report modern Radeon software version 25.10.1 instead of legacy versions to avoid Nixxes/Sony Old Driver preflight dialogs.
    @discardableResult
    public static func patchAtiadlxxDriverVersion(in prefixURL: URL) -> Bool {
        let targets = [
            prefixURL.appendingPathComponent("drive_c/windows/system32/atiadlxx.dll"),
            prefixURL.appendingPathComponent("drive_c/windows/syswow64/atiadlxx.dll")
        ]
        guard let modern = "25.10.1\0".data(using: .utf8) else { return false }
        let legacys = [
            "22.10.1\0".data(using: .utf8),
            "24.12.1\0".data(using: .utf8)
        ].compactMap { $0 }
        var patchedAny = false

        for target in targets {
            guard FileManager.default.fileExists(atPath: target.path),
                  var data = try? Data(contentsOf: target) else { continue }
            var modified = false
            for legacy in legacys {
                var searchRange = data.startIndex..<data.endIndex
                while let range = data.range(of: legacy, in: searchRange) {
                    data.replaceSubrange(range, with: modern)
                    searchRange = range.upperBound..<data.endIndex
                    modified = true
                }
            }
            if modified {
                try? data.write(to: target)
                patchedAny = true
            }
        }
        return patchedAny
    }

    /// Permanently bypasses the Nixxes graphics card warning dialog in Spider-Man2.exe by patching the call to MessageBoxW to return IDOK (1) immediately and forcing the success branch.
    @discardableResult
    public static func bypassSpiderMan2DriverWarning(at installationURL: URL) -> Bool {
        let dir = normalizeGameDirectoryURL(from: installationURL)
        let exeURL = dir.appendingPathComponent("Spider-Man2.exe")
        guard FileManager.default.fileExists(atPath: exeURL.path) else { return false }

        guard let handle = try? FileHandle(forUpdating: exeURL) else { return false }
        defer { try? handle.close() }

        // Patch 1: at offset 0x317c356 (callq *MessageBoxW -> mov eax, 1; nop)
        // Original bytes: FF 15 AC E4 11 02
        // Patched bytes:  B8 01 00 00 00 90
        let callOffset: UInt64 = 0x317c356
        guard (try? handle.seek(toOffset: callOffset)) != nil,
              let callBytes = try? handle.read(upToCount: 6) else { return false }

        let originalCall = Data([0xff, 0x15, 0xac, 0xe4, 0x11, 0x02])
        let patchedCall = Data([0xb8, 0x01, 0x00, 0x00, 0x00, 0x90])

        var didPatch = false
        if callBytes == originalCall {
            try? handle.seek(toOffset: callOffset)
            try? handle.write(contentsOf: patchedCall)
            didPatch = true
        } else if callBytes != patchedCall {
            // Not matching known build layout
            return false
        }

        // Patch 2: at offset 0x317c460 (jne 0x14 -> jmp short 0x14)
        // Original bytes: 75 14
        // Patched bytes:  EB 14
        let branchOffset: UInt64 = 0x317c460
        guard (try? handle.seek(toOffset: branchOffset)) != nil,
              let branchBytes = try? handle.read(upToCount: 2) else { return didPatch || callBytes == patchedCall }

        let originalBranch = Data([0x75, 0x14])
        let patchedBranch = Data([0xeb, 0x14])

        if branchBytes == originalBranch {
            try? handle.seek(toOffset: branchOffset)
            try? handle.write(contentsOf: patchedBranch)
            didPatch = true
        }

        return didPatch || callBytes == patchedCall
    }
}

// MARK: - Title Optimization Rules (Proton & steamac Integration)

struct TitleOptimizationRule: Sendable, Equatable {
    let appID: String?
    let executablePatterns: [String]
    let titleName: String
    let recommendedBackend: GraphicsBackend?
    let vkd3dFeatureLevel: String?
    let vkd3dShaderModel: String?
    let vkd3dDisableExtensions: String?
    let dxvkAsync: Bool?
    let enableMSync: Bool?
    let additionalEnvironment: [String: String]
    let recommendedArguments: [String]
    let notes: String

    init(
        appID: String? = nil,
        executablePatterns: [String] = [],
        titleName: String,
        recommendedBackend: GraphicsBackend? = nil,
        vkd3dFeatureLevel: String? = nil,
        vkd3dShaderModel: String? = nil,
        vkd3dDisableExtensions: String? = nil,
        dxvkAsync: Bool? = nil,
        enableMSync: Bool? = nil,
        additionalEnvironment: [String: String] = [:],
        recommendedArguments: [String] = [],
        notes: String = ""
    ) {
        self.appID = appID
        self.executablePatterns = executablePatterns
        self.titleName = titleName
        self.recommendedBackend = recommendedBackend
        self.vkd3dFeatureLevel = vkd3dFeatureLevel
        self.vkd3dShaderModel = vkd3dShaderModel
        self.vkd3dDisableExtensions = vkd3dDisableExtensions
        self.dxvkAsync = dxvkAsync
        self.enableMSync = enableMSync
        self.additionalEnvironment = additionalEnvironment
        self.recommendedArguments = recommendedArguments
        self.notes = notes
    }
}

struct TitleOptimizationRegistry: Sendable {
    static let knownRules: [TitleOptimizationRule] = [
        // Dragon's Dogma 2: Requires D3D 12_1 feature level and shader model 6.6
        TitleOptimizationRule(
            appID: "2054970",
            executablePatterns: ["DD2.exe", "DragonsDogma2.exe"],
            titleName: "Dragon's Dogma 2",
            recommendedBackend: .d3dmetal,
            vkd3dFeatureLevel: "12_1",
            vkd3dShaderModel: "6_6",
            vkd3dDisableExtensions: "",
            dxvkAsync: true,
            enableMSync: true,
            notes: "Exposes D3D 12_1 feature level and shader model 6.6 required by Dragon's Dogma 2"
        ),
        // Elden Ring: D3D12, bypass offline anti-cheat splash
        TitleOptimizationRule(
            appID: "1245620",
            executablePatterns: ["eldenring.exe", "start_protected_game.exe"],
            titleName: "Elden Ring",
            recommendedBackend: .d3dmetal,
            vkd3dFeatureLevel: "12_0",
            vkd3dShaderModel: "6_6",
            dxvkAsync: true,
            enableMSync: true,
            recommendedArguments: ["-eac_launcher_offline"],
            notes: "Configures D3D12 feature level 12_0 and offline launcher arguments for Elden Ring"
        ),
        // Cyberpunk 2077: D3D12, skip intro splash
        TitleOptimizationRule(
            appID: "1091500",
            executablePatterns: ["Cyberpunk2077.exe"],
            titleName: "Cyberpunk 2077",
            recommendedBackend: .d3dmetal,
            vkd3dFeatureLevel: "12_0",
            vkd3dShaderModel: "6_6",
            enableMSync: true,
            recommendedArguments: ["-skipStartScreen"],
            notes: "Optimizes D3DMetal translation pipeline and skips intro splash screens"
        ),
        // Marvel's Spider-Man 2 / Remastered / Miles Morales
        TitleOptimizationRule(
            appID: "1817070",
            executablePatterns: ["Spider-Man2.exe", "Spider-Man.exe", "MilesMorales.exe"],
            titleName: "Marvel's Spider-Man Series",
            recommendedBackend: .d3dmetal,
            vkd3dFeatureLevel: "12_0",
            vkd3dShaderModel: "6_6",
            enableMSync: true,
            recommendedArguments: ["-nolauncher", "-nostreamline"],
            notes: "Bypasses Nixxes launcher dialog and isolates Streamline/DLSS"
        ),
        // Death's Door: Unity Direct3D 11 title runs best on DXMT (direct Metal)
        TitleOptimizationRule(
            appID: "894020",
            executablePatterns: ["DeathsDoor.exe"],
            titleName: "Death's Door",
            recommendedBackend: .dxmt,
            dxvkAsync: true,
            enableMSync: true,
            notes: "Direct3D 11 Unity game runs with zero Vulkan translation overhead on DXMT"
        ),
        // Hollow Knight: Unity Direct3D 11
        TitleOptimizationRule(
            appID: "367520",
            executablePatterns: ["hollow_knight.exe"],
            titleName: "Hollow Knight",
            recommendedBackend: .dxmt,
            enableMSync: true,
            notes: "Runs natively smooth on DXMT with direct Metal command encoding"
        ),
        // Armored Core VI: Fires of Rubicon
        TitleOptimizationRule(
            appID: "1884840",
            executablePatterns: ["armoredcore6.exe"],
            titleName: "Armored Core VI",
            recommendedBackend: .d3dmetal,
            vkd3dFeatureLevel: "12_0",
            vkd3dShaderModel: "6_6",
            enableMSync: true,
            notes: "Enables D3DMetal immediate submission for low input latency"
        ),
        // American Truck Simulator & Euro Truck Simulator 2
        TitleOptimizationRule(
            appID: "270880",
            executablePatterns: ["amtrucks.exe"],
            titleName: "American Truck Simulator",
            recommendedBackend: .dxmt,
            dxvkAsync: true,
            notes: "Resolves missing vertex attributes and optimizes D3D11 rendering"
        ),
        TitleOptimizationRule(
            appID: "227300",
            executablePatterns: ["eurotrucks2.exe"],
            titleName: "Euro Truck Simulator 2",
            recommendedBackend: .dxmt,
            dxvkAsync: true,
            notes: "Optimizes D3D11 rendering on Apple Silicon GPU"
        ),
        // Monster Hunter: World
        TitleOptimizationRule(
            appID: "582010",
            executablePatterns: ["MonsterHunterWorld.exe"],
            titleName: "Monster Hunter: World",
            recommendedBackend: .d3dmetal,
            dxvkAsync: true,
            enableMSync: true,
            notes: "Accelerates pipeline state object compilation"
        ),
        // Ghost of Tsushima Director's Cut
        TitleOptimizationRule(
            appID: "2215430",
            executablePatterns: ["GhostOfTsushima.exe"],
            titleName: "Ghost of Tsushima Director's Cut",
            recommendedBackend: .d3dmetal,
            vkd3dFeatureLevel: "12_0",
            enableMSync: true,
            recommendedArguments: ["-nolauncher", "-nostreamline"],
            notes: "Bypasses PlayStation PC launcher and Streamline crash hooks"
        )
    ]

    /// Matches a title rule by Steam Application ID or Executable Path.
    static func rule(forAppID appID: String?, executablePath: String? = nil) -> TitleOptimizationRule? {
        if let appID = appID, !appID.isEmpty {
            if let match = knownRules.first(where: { $0.appID == appID }) {
                return match
            }
        }
        if let path = executablePath, !path.isEmpty {
            let lastComponent = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            return knownRules.first { rule in
                rule.executablePatterns.contains { pattern in
                    lastComponent == pattern.lowercased() || lastComponent.contains(pattern.lowercased())
                }
            }
        }
        return nil
    }
}

