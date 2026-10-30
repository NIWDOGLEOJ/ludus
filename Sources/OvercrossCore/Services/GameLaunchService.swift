import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct GameLaunchOutcome: Sendable {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
    var diagnosticNote: String? = nil

    var summary: String {
        let exitSummary: String
        if exitStatus == 0 {
            exitSummary = "Process exited successfully."
        } else {
            exitSummary = "Process exited with status \(exitStatus)."
        }
        guard let diagnosticNote, !diagnosticNote.isEmpty else { return exitSummary }
        return "\(exitSummary) \(diagnosticNote)"
    }
}

enum GameLaunchError: LocalizedError, Sendable {
    case missingExecutable
    case executableIsNotFile(URL)
    case executableIsNotRunnable(URL)
    case cancelled
    case missingRuntime
    case missingPrefix
    case prefixIsNotVerified
    case runtimePrefixMismatch
    case profileDoesNotMatchGame
    case profileExecutableDoesNotMatchGame
    case profileRequiresLauncher(String)
    case profilePrefixDoesNotMatch
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "This game has no executable selected."
        case .executableIsNotFile(let url):
            "The selected executable is not a file: \(url.path)"
        case .executableIsNotRunnable(let url):
            "The selected executable is not runnable: \(url.path)"
        case .cancelled:
            "The game launch was cancelled."
        case .missingRuntime:
            "A Windows game requires a detected compatibility runtime."
        case .missingPrefix:
            "A Windows game requires a verified compatibility prefix."
        case .prefixIsNotVerified:
            "The selected compatibility prefix is missing system.reg or drive_c and is not verified."
        case .runtimePrefixMismatch:
            "The selected prefix was created with a different runtime."
        case .profileDoesNotMatchGame:
            "The selected compatibility profile does not match this game."
        case .profileExecutableDoesNotMatchGame:
            "The selected compatibility profile points to a different executable."
        case .profileRequiresLauncher(let launcher):
            "The selected compatibility profile requires \(launcher); launch it through that supported launcher instead of direct Wine."
        case .profilePrefixDoesNotMatch:
            "The selected compatibility profile requires a different compatibility prefix."
        case .couldNotStart(let error):
            "Could not start the game: \(error)"
        }
    }
}

struct GameLaunchService: Sendable {
    fileprivate static let outputLimit = 64 * 1024
    private let audioRepairService = AudioRepairService()

    func launch(_ game: Game) async throws -> GameLaunchOutcome {
        guard let executableURL = game.executableURL else {
            throw GameLaunchError.missingExecutable
        }
        guard executableURL.isFileURL else {
            throw GameLaunchError.executableIsNotFile(executableURL)
        }
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw GameLaunchError.executableIsNotFile(executableURL)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GameLaunchError.executableIsNotRunnable(executableURL)
        }

        var environment = ProcessInfo.processInfo.environment
        if !game.customEnvironment.isEmpty {
            environment.merge(game.customEnvironment) { _, customValue in customValue }
        }

        return try await launchProcess(
            executableURL: executableURL,
            arguments: game.customLaunchArguments,
            workingDirectory: game.installationURL ?? executableURL.deletingLastPathComponent(),
            environment: game.customEnvironment.isEmpty ? nil : environment
        )
    }

    func launchWindows(
        game: Game,
        runtime: DetectedRuntime,
        prefix: WinePrefix,
        profile: CompatibilityProfile? = nil,
        appSettings: AppSettings? = nil,
        additionalArguments: [String] = []
    ) async throws -> GameLaunchOutcome {
        guard let executableURL = game.executableURL else {
            throw GameLaunchError.missingExecutable
        }
        guard executableURL.isFileURL, FileManager.default.fileExists(atPath: executableURL.path) else {
            throw GameLaunchError.executableIsNotFile(executableURL)
        }
        guard FileManager.default.fileExists(atPath: runtime.executableURL.path),
              FileManager.default.isExecutableFile(atPath: runtime.executableURL.path)
        else {
            throw GameLaunchError.missingRuntime
        }
        guard FileManager.default.fileExists(atPath: prefix.url.path) else {
            throw GameLaunchError.missingPrefix
        }
        guard WinePrefixService.isVerifiedPrefix(at: prefix.url) else {
            throw GameLaunchError.prefixIsNotVerified
        }
        guard prefix.runtimeURL.resolvingSymlinksInPath().standardizedFileURL
            == runtime.executableURL.resolvingSymlinksInPath().standardizedFileURL
            || (FileManager.default.isExecutableFile(atPath: prefix.runtimeURL.path)
                && FileManager.default.isExecutableFile(atPath: runtime.executableURL.path)) else {
            throw GameLaunchError.runtimePrefixMismatch
        }
        if let profile {
            guard profile.store == game.store,
                  profile.storeApplicationID == game.storeApplicationID,
                  profile.isVerified,
                  profile.prefixArchitecture == nil || profile.prefixArchitecture == prefix.architecture,
                  profile.runtimeIdentifier == nil || profile.runtimeIdentifier == runtime.id.uuidString,
                  profile.prefixID == nil || profile.prefixID == prefix.id
            else {
                if profile.prefixID != nil && profile.prefixID != prefix.id {
                    throw GameLaunchError.profilePrefixDoesNotMatch
                }
                throw GameLaunchError.profileDoesNotMatchGame
            }
            if let requiredLauncher = profile.requiredLauncher?.trimmingCharacters(in: .whitespacesAndNewlines),
               !requiredLauncher.isEmpty {
                throw GameLaunchError.profileRequiresLauncher(requiredLauncher)
            }
            if let executableRelativePath = profile.executableRelativePath {
                guard let installationURL = game.installationURL,
                      !executableRelativePath.isEmpty,
                      !executableRelativePath.hasPrefix("/"),
                      !executableRelativePath.split(separator: "/").contains("..")
                else {
                    throw GameLaunchError.profileExecutableDoesNotMatchGame
                }
                let profiledExecutableURL = installationURL
                    .appendingPathComponent(executableRelativePath)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                guard profiledExecutableURL == executableURL.resolvingSymlinksInPath().standardizedFileURL else {
                    throw GameLaunchError.profileExecutableDoesNotMatchGame
                }
            }
        }

        var environment = ProcessInfo.processInfo.environment
        if let profile {
            environment.merge(profile.environment) { _, profileValue in profileValue }
        }
        if !game.customEnvironment.isEmpty {
            environment.merge(game.customEnvironment) { _, customValue in customValue }
        }
        environment["WINEPREFIX"] = prefix.url.path
        environment["WINEARCH"] = prefix.architecture.rawValue

        // Metal Performance HUD overlay (Apple Silicon real-time FPS/GPU stats)
        let hudEnabled: Bool
        if let explicit = game.metalHUDEnabled {
            hudEnabled = explicit
        } else if let custom = game.customEnvironment["MTL_HUD_ENABLED"] {
            hudEnabled = (custom == "1" || custom.lowercased() == "true")
        } else {
            hudEnabled = appSettings?.metalHUDEnabled ?? false
        }
        if hudEnabled {
            environment["MTL_HUD_ENABLED"] = "1"
        } else {
            environment.removeValue(forKey: "MTL_HUD_ENABLED")
        }

        // Synchronization engine toggles: MSync (optimal on Apple Silicon) / ESync
        let msync: Bool
        if let explicit = game.msyncEnabled {
            msync = explicit
        } else if let custom = game.customEnvironment["WINEMSYNC"] {
            msync = (custom == "1" || custom.lowercased() == "true")
        } else {
            msync = appSettings?.msyncEnabled ?? true
        }
        if msync {
            environment["WINEMSYNC"] = "1"
            environment.removeValue(forKey: "WINEESYNC")
        } else {
            environment.removeValue(forKey: "WINEMSYNC")
        }

        let esync: Bool
        if let explicit = game.esyncEnabled {
            esync = explicit
        } else if let custom = game.customEnvironment["WINEESYNC"] {
            esync = (custom == "1" || custom.lowercased() == "true")
        } else {
            esync = appSettings?.esyncEnabled ?? false
        }
        if esync {
            environment["WINEESYNC"] = "1"
        } else {
            environment.removeValue(forKey: "WINEESYNC")
        }

        environment["CX_BOTTLE"] = prefix.name
        environment["CX_BOTTLE_PATH"] = prefix.url.deletingLastPathComponent().path

        // CrossOver runtime engine environment
        var cxRootURL: URL?
        if runtime.executableURL.path.contains("SharedSupport/CrossOver") {
            cxRootURL = runtime.executableURL.deletingLastPathComponent().deletingLastPathComponent()
        } else if let found = WineBottleService.findCrossOverResource(path: "") {
            cxRootURL = found
        }
        if let cxRoot = cxRootURL {
            environment["CX_ROOT"] = cxRoot.path
            environment["WINELOADER"] = cxRoot.appendingPathComponent("bin/wineloader").path
            environment["WINESERVER"] = cxRoot.appendingPathComponent("bin/wineserver").path
            let libPath = cxRoot.appendingPathComponent("lib").path
            environment["WINEDLLPATH"] = "\(libPath)/wine/x86_64-windows:\(libPath)/wine/i386-windows:\(libPath)/wine"

            let gptkShared = cxRoot.appendingPathComponent("lib64/apple_gptk/external/libd3dshared.dylib")
            if FileManager.default.fileExists(atPath: gptkShared.path) {
                environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = gptkShared.path
            }
        }

        // DirectX graphics backend (d3dmetal vs dxvk vs dxmt)
        // Per-game user configuration takes top precedence over default profile recommendations
        let backend: GraphicsBackend
        if let gameBackendStr = game.graphicsBackend,
           let parsed = GraphicsBackend(rawValue: gameBackendStr),
           parsed != .automatic && parsed != .unknown {
            backend = parsed
        } else if let customBackend = game.customEnvironment["OVERCROSS_GRAPHICS_BACKEND"],
                  let parsed = GraphicsBackend(rawValue: customBackend),
                  parsed != .automatic && parsed != .unknown {
            backend = parsed
        } else if let customBackend = game.customEnvironment["CX_GRAPHICS_BACKEND"],
                  let parsed = GraphicsBackend(rawValue: customBackend),
                  parsed != .automatic && parsed != .unknown {
            backend = parsed
        } else if let profileBackend = profile?.graphicsBackend,
                  profileBackend != .automatic && profileBackend != .unknown {
            backend = profileBackend
        } else if let appDefault = appSettings?.defaultGraphicsBackend,
                  appDefault != .automatic && appDefault != .unknown {
            backend = appDefault
        } else {
            backend = .automatic
        }

        let requiredOverrides: String
        switch backend {
        case .d3dmetal:
            environment["OVERCROSS_GRAPHICS_BACKEND"] = "d3dmetal"
            environment["CX_GRAPHICS_BACKEND"] = "d3dmetal"
            environment["WINED3DMETAL"] = "1"
            environment.removeValue(forKey: "WINEDXVK")
            environment.removeValue(forKey: "WINEDXMT")
            requiredOverrides = "d3d12,d3d11,dxgi=native"
        case .dxvk:
            environment["OVERCROSS_GRAPHICS_BACKEND"] = "dxvk"
            environment["CX_GRAPHICS_BACKEND"] = "dxvk"
            environment["WINEDXVK"] = "1"
            if hudEnabled {
                environment["DXVK_HUD"] = "devinfo,fps"
            }
            environment.removeValue(forKey: "WINED3DMETAL")
            environment.removeValue(forKey: "WINEDXMT")
            requiredOverrides = "d3d11,dxgi=native"
        case .dxmt:
            environment["OVERCROSS_GRAPHICS_BACKEND"] = "dxmt"
            environment["CX_GRAPHICS_BACKEND"] = "dxmt"
            environment["WINEDXMT"] = "1"
            environment.removeValue(forKey: "WINED3DMETAL")
            environment.removeValue(forKey: "WINEDXVK")
            requiredOverrides = "d3d11,dxgi=native"
        default:
            environment.removeValue(forKey: "OVERCROSS_GRAPHICS_BACKEND")
            environment.removeValue(forKey: "CX_GRAPHICS_BACKEND")
            environment.removeValue(forKey: "WINED3DMETAL")
            environment.removeValue(forKey: "WINEDXVK")
            environment.removeValue(forKey: "WINEDXMT")
            environment.removeValue(forKey: "DXVK_HUD")
            requiredOverrides = ""
        }

        if !requiredOverrides.isEmpty {
            if let existing = environment["WINEDLLOVERRIDES"], !existing.isEmpty {
                if !existing.contains(requiredOverrides) {
                    environment["WINEDLLOVERRIDES"] = "\(existing);\(requiredOverrides)"
                }
            } else {
                environment["WINEDLLOVERRIDES"] = requiredOverrides
            }
        }

        // Maximize Apple Silicon GPU Utilization & Pipeline Throughput
        // Disable Metal shader validation and capture layers that cause GPU pipeline stalls
        environment["MTL_SHADER_VALIDATION"] = "0"
        environment["MTL_DEBUG_LAYER"] = "0"
        environment["MTL_CAPTURE_ENABLED"] = "0"
        environment["MTL_SHADER_CACHE_MODE"] = "1"

        // High-performance GPU scheduling & queue saturation
        environment["WINE_HIGH_PERFORMANCE"] = "1"
        environment["WINE_D3D_GPU_PRIORITY"] = "high"
        if backend == .d3dmetal || backend == .automatic {
            environment["DX12_MAX_FRAME_LATENCY"] = "2"
            environment["D3DMETAL_SUBMISSION_MODE"] = "immediate"
        } else if backend == .dxvk {
            environment["DXVK_ASYNC"] = "1"
            environment["DXVK_STATE_CACHE"] = "1"
        }

        // Low-latency Audio Stability & Stutter Protection
        environment["STAGING_AUDIO_DURATION"] = "100000"
        environment["WINEAUDIO_BUFFER_SIZE"] = "4096"
        environment["PULSE_LATENCY_MSEC"] = "60"

        // Retina / HiDPI Scaling
        let retinaEnabled: Bool
        if let explicit = game.retinaScalingEnabled {
            retinaEnabled = explicit
        } else if let custom = game.customEnvironment["WINE_ENABLE_RETINA"] {
            retinaEnabled = (custom == "1" || custom.lowercased() == "true")
        } else {
            retinaEnabled = appSettings?.retinaScalingEnabled ?? false
        }
        if retinaEnabled {
            environment["WINE_ENABLE_RETINA"] = "1"
            environment["WINE_ALLOW_HIGHDPI"] = "1"
        } else {
            environment.removeValue(forKey: "WINE_ENABLE_RETINA")
            environment.removeValue(forKey: "WINE_ALLOW_HIGHDPI")
        }

        // Synchronize bottle registry (macOS Spaces Native Fullscreen, mouse confinement, DirectSound buffers, Retina)
        _ = try? WineBottleService.syncBottleRegistry(prefixURL: prefix.url, retina: retinaEnabled)

        // Synchronize bottle configuration file (cxbottle.conf)
        WineBottleService.syncBottleConfiguration(
            prefixURL: prefix.url,
            backend: backend,
            msync: msync,
            retina: retinaEnabled
        )

        let launchExecutableURL = Self.resolveWindowsExecutable(
            selectedURL: executableURL,
            installationURL: game.installationURL
        )
        var runtimeExecutableURL = runtime.executableURL
        var diagnosticNotes: [String] = []
        if launchExecutableURL != executableURL {
            diagnosticNotes.append("Using nested Windows executable (\(launchExecutableURL.lastPathComponent)).")
        }

        // Preflight cleanup of any stale/lingering Wine daemon or orphan helper processes (winedevice.exe, etc.)
        WineBottleService.terminateBottleProcesses(prefixURL: prefix.url, runtime: runtime)

        // Automatic Game Optimization (problematic DLL neutralization & memory/streaming tuning)
        let optimizationReport = GameOptimizationService().optimize(game: game, prefixURL: prefix.url)
        if let summary = optimizationReport.summary {
            diagnosticNotes.append(summary)
        }
        // A 32-bit game can run inside a win64 WoW64 prefix. Select the
        // CoreAudio repair from the executable's PE machine type, not only
        // from the prefix label. NFS Most Wanted is PE32 in the user's
        // existing win64 prefix.
        if prefix.architecture == .win32 || Self.is32BitWindowsExecutable(at: launchExecutableURL) {
            do {
                let preparation = try audioRepairService.prepare(runtimeExecutableURL: runtime.executableURL)
                runtimeExecutableURL = preparation.executableURL
                diagnosticNotes.append(preparation.status)
                environment["OVERCROSS_AUDIO_REPAIR_STATUS"] = preparation.status
                environment["OVERCROSS_AUDIO_BACKEND"] = "winecoreaudio (WoW64 Mach VM 32-bit bridge)"
            } catch {
                // Unknown or changed Wine builds must remain runnable without
                // an unvalidated binary mutation. The launch log carries the
                // explicit status through the environment for diagnostics.
                let status = "Audio repair not applied: \(error.localizedDescription)"
                diagnosticNotes.append(status)
                environment["OVERCROSS_AUDIO_REPAIR_STATUS"] = status
                environment["OVERCROSS_AUDIO_BACKEND"] = "winecoreaudio (unrepaired fallback)"
            }
        } else {
            environment["OVERCROSS_AUDIO_REPAIR_STATUS"] = "Bypassed (64-bit native executable)"
            environment["OVERCROSS_AUDIO_BACKEND"] = "winecoreaudio (native 64-bit)"
        }
        environment["OVERCROSS_RUNTIME_SELECTED"] = runtimeExecutableURL.path

        let workingDir: URL
        if launchExecutableURL != executableURL {
            workingDir = launchExecutableURL.deletingLastPathComponent()
        } else {
            workingDir = game.installationURL ?? launchExecutableURL.deletingLastPathComponent()
        }

        var winePreArguments: [String] = []
        let isNixxes = Self.isNixxesOrSonyTitle(title: game.title, executableURL: launchExecutableURL)

        var dllOverrides = game.customEnvironment["WINEDLLOVERRIDES"] ?? ""
        if isNixxes && !dllOverrides.contains("nvngx") {
            let nixxesDllOverrides = "nvngx=d;nvngx_dlss=d;nvngx_dlssd=d;nvngx_dlssg=d;sl.dlss=d;sl.dlss_d=d;sl.dlss_g=d;sl.interposer=d"
            dllOverrides = dllOverrides.isEmpty ? nixxesDllOverrides : "\(dllOverrides);\(nixxesDllOverrides)"
        }

        if runtime.executableURL.path.contains("SharedSupport/CrossOver") {
            winePreArguments.append(contentsOf: ["--bottle", prefix.name])
            winePreArguments.append(contentsOf: ["--workdir", workingDir.path])
            if !dllOverrides.isEmpty {
                winePreArguments.append(contentsOf: ["--dll", dllOverrides])
            }
        }
        if !dllOverrides.isEmpty {
            environment["WINEDLLOVERRIDES"] = dllOverrides
        }

        var gameLaunchArgs = (profile?.launchArguments ?? []) + game.customLaunchArguments + additionalArguments
        if isNixxes {
            if !gameLaunchArgs.contains("-nolauncher") {
                gameLaunchArgs.append("-nolauncher")
            }
        }

        if environment["ROSETTA_ADVERTISE_AVX"] == nil {
            environment["ROSETTA_ADVERTISE_AVX"] = "1"
        }

        let arguments = winePreArguments + [launchExecutableURL.path] + gameLaunchArgs
        // Lock/snap hardware cursor to screen center to avoid triggering macOS Hot Corners on startup
        #if canImport(CoreGraphics)
        let mainDisplay = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(mainDisplay)
        let centerPoint = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        CGWarpMouseCursorPosition(centerPoint)

        let modalWatcher = startPreflightModalWatcher(
            processName: launchExecutableURL.deletingPathExtension().lastPathComponent,
            enabled: isNixxes
        )
        defer { modalWatcher.cancel() }
        #endif

        defer {
            // Guaranteed cleanup of wineserver, winedevice.exe, services.exe, etc. when the game process finishes
            WineBottleService.terminateBottleProcesses(prefixURL: prefix.url, runtime: runtime)
        }

        var outcome = try await launchProcess(
            executableURL: runtimeExecutableURL,
            arguments: arguments,
            workingDirectory: workingDir,
            environment: environment
        )
        if let audioAnalysis = Self.analyzeAudioDiagnostics(
            standardOutput: outcome.standardOutput,
            standardError: outcome.standardError
        ) {
            diagnosticNotes.append(audioAnalysis)
        }
        outcome.diagnosticNote = diagnosticNotes.isEmpty ? nil : diagnosticNotes.joined(separator: " ")
        return outcome
    }

    static func isNixxesOrSonyTitle(title: String, executableURL: URL) -> Bool {
        let t = title.lowercased()
        let exe = executableURL.deletingPathExtension().lastPathComponent.lowercased()
        let keywords = [
            "spider-man",
            "spiderman",
            "milesmorales",
            "ratchet",
            "riftapart",
            "horizon",
            "forbiddenwest",
            "zerodawn",
            "tsushima",
            "ghost of tsushima",
            "nixxes",
            "returnal",
            "the last of us",
            "god of war",
            "uncharted"
        ]
        return keywords.contains { t.contains($0) || exe.contains($0) }
    }

    #if canImport(CoreGraphics)
    private func startPreflightModalWatcher(
        processName: String,
        enabled: Bool = true,
        timeoutSeconds: Double = 30.0
    ) -> PreflightModalWatcher {
        guard enabled else {
            return PreflightModalWatcher(task: nil)
        }

        let task = Task.detached { [processName] in
            let startTime = Date()
            let lowerTarget = processName.lowercased()
            var consecutiveCleanChecks = 0

            while !Task.isCancelled {
                if Date().timeIntervalSince(startTime) > timeoutSeconds {
                    break
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }

                guard let windowInfoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
                    continue
                }

                var hasDialog = false
                var foundGameWindow = false
                var dialogBounds: (x: Double, y: Double, w: Double, h: Double)?

                for window in windowInfoList {
                    let ownerName = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
                    let windowName = (window[kCGWindowName as String] as? String ?? "").lowercased()

                    let matchesOwner = ownerName.contains(lowerTarget) || ownerName.contains("wine") || ownerName.contains("crossover") || ownerName.contains("spider")
                    let matchesTitle = windowName.contains(lowerTarget) || windowName.contains("spider") || windowName.contains("marvel") || windowName.contains("wine")

                    guard matchesOwner || matchesTitle else { continue }

                    if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                       let height = boundsDict["Height"] as? Double,
                       let width = boundsDict["Width"] as? Double,
                       let x = boundsDict["X"] as? Double,
                       let y = boundsDict["Y"] as? Double {
                        if height >= 80 && height <= 450 && width >= 150 && width <= 800 {
                            hasDialog = true
                            dialogBounds = (x, y, width, height)
                        } else if height >= 450 && width >= 600 {
                            foundGameWindow = true
                        }
                    }
                }

                if hasDialog {
                    consecutiveCleanChecks = 0
                    // 1. Synthesize direct Quartz mouse click on dialog's OK button
                    if let db = dialogBounds {
                        let clickPt1 = CGPoint(x: db.x + (db.w / 2.0) - 50.0, y: db.y + db.h - 35.0)
                        let clickPt2 = CGPoint(x: db.x + (db.w / 2.0), y: db.y + db.h - 35.0)
                        for pt in [clickPt1, clickPt2] {
                            if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
                               let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left) {
                                down.post(tap: .cghidEventTap)
                                usleep(30_000)
                                up.post(tap: .cghidEventTap)
                            }
                        }
                    }

                    // 2. Auxiliary AppleScript key dispatch
                    let appleScript = """
                    tell application "System Events"
                        set procs to (every process whose name contains "\(processName)" or name contains "wine" or name contains "Spider")
                        repeat with p in procs
                            try
                                set frontmost of p to true
                                delay 0.05
                                key code 36
                            end try
                        end repeat
                    end tell
                    """
                    let scriptProcess = Process()
                    scriptProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    scriptProcess.arguments = ["-e", appleScript]
                    try? scriptProcess.run()
                    scriptProcess.waitUntilExit()

                    try? await Task.sleep(nanoseconds: 800_000_000)
                } else if foundGameWindow {
                    consecutiveCleanChecks += 1
                    if consecutiveCleanChecks >= 6 {
                        break
                    }
                }
            }
        }

        return PreflightModalWatcher(task: task)
    }
    #else
    private func startPreflightModalWatcher(
        processName: String,
        enabled: Bool = true,
        timeoutSeconds: Double = 30.0
    ) -> PreflightModalWatcher {
        return PreflightModalWatcher(task: nil)
    }
    #endif

    static func analyzeAudioDiagnostics(
        standardOutput: String,
        standardError: String
    ) -> String? {
        let combined = standardError + "\n" + standardOutput

        if combined.contains("Unhandled page fault on write access to 00000200") ||
           (combined.contains("Unhandled page fault on write access to 00000000") && combined.contains("dsound")) {
            return "[Audio Status: FAILED - DirectSound 32-bit pointer truncation page fault detected]"
        }
        if combined.contains("8007000e") || combined.contains("E_OUTOFMEMORY") {
            if combined.contains("coreaudio") || combined.contains("AudioClient") || combined.contains("dsound") {
                return "[Audio Status: FAILED - CoreAudio buffer allocation returned E_OUTOFMEMORY (0x8007000e)]"
            }
        }
        if combined.contains("err:coreaudio:") {
            return "[Audio Status: WARNING - CoreAudio reported driver errors]"
        }
        if combined.contains("Successfully migrated stream") ||
           combined.contains("allocate_32bit_buffer SUCCESS") {
            return "[Audio Status: OPERATIONAL - WoW64 CoreAudio Mach VM bridge active and streamed 32-bit render buffers]"
        }
        if combined.contains("DSOUND_MixToPrimary") {
            return "[Audio Status: OPERATIONAL - DirectSound primary buffer mixing confirmed]"
        }
        return nil
    }

    static func resolveWindowsExecutable(
        selectedURL: URL,
        installationURL: URL?
    ) -> URL {
        guard selectedURL.pathExtension.lowercased() == "exe",
              let installationURL,
              selectedURL.deletingLastPathComponent().standardizedFileURL
                == installationURL.standardizedFileURL else {
            return selectedURL
        }

        let fileManager = FileManager.default
        let stem = selectedURL.deletingPathExtension().lastPathComponent
        let candidateNames = [
            stem,
            "\(stem)-Win64-Shipping",
            "\(stem)-Shipping"
        ]
        var candidateDirectories = [
            installationURL.appendingPathComponent("Binaries/Win64", isDirectory: true),
            installationURL.appendingPathComponent("Phoenix/Binaries/Win64", isDirectory: true)
        ]

        // Dynamically discover any subdirectories containing Binaries/Win64 (e.g. Unreal Engine project folders)
        if let subdirs = try? fileManager.contentsOfDirectory(at: installationURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for subdir in subdirs {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: subdir.path, isDirectory: &isDir), isDir.boolValue {
                    let win64Dir = subdir.appendingPathComponent("Binaries/Win64", isDirectory: true)
                    if fileManager.fileExists(atPath: win64Dir.path) && !candidateDirectories.contains(win64Dir) {
                        candidateDirectories.append(win64Dir)
                    }
                }
            }
        }

        let selectedSize = (try? selectedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var bestCandidate: URL?
        var bestSize = selectedSize

        for directory in candidateDirectories {
            for name in candidateNames {
                let candidate = directory.appendingPathComponent(name).appendingPathExtension("exe")
                guard fileManager.fileExists(atPath: candidate.path),
                      candidate.standardizedFileURL.path.hasPrefix(installationURL.standardizedFileURL.path + "/") else {
                    continue
                }
                let candidateSize = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if candidateSize > bestSize {
                    bestSize = candidateSize
                    bestCandidate = candidate
                }
            }

            // Also search for any shipping executable inside the Win64 directory
            if let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                for file in entries where file.pathExtension.lowercased() == "exe" {
                    let fileName = file.deletingPathExtension().lastPathComponent.lowercased()
                    if fileName.contains("shipping") || fileName.contains("win64") {
                        guard file.standardizedFileURL.path.hasPrefix(installationURL.standardizedFileURL.path + "/") else { continue }
                        let candidateSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        if candidateSize > bestSize {
                            bestSize = candidateSize
                            bestCandidate = file
                        }
                    }
                }
            }
        }
        return bestCandidate ?? selectedURL
    }

    static func is32BitWindowsExecutable(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count >= 0x40,
              data[0] == 0x4d, data[1] == 0x5a else {
            return false
        }

        let peOffset = Int(data[0x3c]) |
            (Int(data[0x3d]) << 8) |
            (Int(data[0x3e]) << 16) |
            (Int(data[0x3f]) << 24)
        guard peOffset >= 0,
              peOffset + 6 <= data.count,
              data[peOffset] == 0x50,
              data[peOffset + 1] == 0x45,
              data[peOffset + 2] == 0,
              data[peOffset + 3] == 0 else {
            return false
        }

        let machine = UInt16(data[peOffset + 4]) |
            (UInt16(data[peOffset + 5]) << 8)
        return machine == 0x014c
    }

    private func launchProcess(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]?
    ) async throws -> GameLaunchOutcome {
        let control = LaunchProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                reason: "Ludus Game Execution"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LudusLaunch-\(UUID().uuidString)", isDirectory: true)
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

            process.executableURL = executableURL
            process.currentDirectoryURL = workingDirectory
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = outputFile
            process.standardError = errorFile

            do {
                try process.run()
            } catch {
                throw GameLaunchError.couldNotStart(error.localizedDescription)
            }

            control.install(process)
            process.waitUntilExit()
            if control.wasCancelled {
                throw GameLaunchError.cancelled
            }
            try? outputFile.close()
            try? errorFile.close()
            let outputReader = try FileHandle(forReadingFrom: outputURL)
            let errorReader = try FileHandle(forReadingFrom: errorURL)
            defer {
                try? outputReader.close()
                try? errorReader.close()
            }
            return GameLaunchOutcome(
                exitStatus: process.terminationStatus,
                standardOutput: readBoundedOutput(from: outputReader),
                standardError: readBoundedOutput(from: errorReader)
            )
            }.value
        }, onCancel: {
            control.cancel()
        })
    }
}

private final class LaunchProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ process: Process) {
        lock.lock()
        let shouldTerminate = cancelled
        if !shouldTerminate {
            self.process = process
        }
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
            process.terminate()
        }
    }
}

final class PreflightModalWatcher: @unchecked Sendable {
    private let task: Task<Void, Never>?

    init(task: Task<Void, Never>? = nil) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
    }
}

private func readBoundedOutput(from handle: FileHandle) -> String {
    var data = Data()
    while data.count < GameLaunchService.outputLimit {
        let toRead = min(8 * 1024, GameLaunchService.outputLimit - data.count)
        let chunk: Data?
        do {
            chunk = try handle.read(upToCount: toRead)
        } catch {
            break
        }
        guard let chunk, !chunk.isEmpty else { break }
        data.append(chunk)
    }
    return String(data: data, encoding: .utf8) ?? ""
}
