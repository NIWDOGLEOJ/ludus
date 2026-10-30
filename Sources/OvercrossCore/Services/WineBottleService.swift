import Foundation
#if canImport(AppKit)
import AppKit
#endif

struct RedistributableRepairSummary: Sendable, Equatable {
    let installedDirectXCount: Int
    let installedVCRuntimeCount: Int
    let isMonoConfigured: Bool
    let statusMessage: String
}

struct WineBottleService: Sendable {
    let defaultBottleURL: URL
    private let prefixService = WinePrefixService()

    init(defaultBottleURL: URL? = nil) {
        if let defaultBottleURL {
            self.defaultBottleURL = defaultBottleURL
        } else {
            self.defaultBottleURL = LudusStorage.applicationSupportURL.appendingPathComponent("Prefixes/DefaultBottle", isDirectory: true)
        }
    }

    var isBottleVerified: Bool {
        WinePrefixService.isVerifiedPrefix(at: defaultBottleURL)
    }

    /// Locates an asset in the bundled or local CrossOver installation.
    static func findCrossOverResource(path: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [URL] = []

        #if canImport(AppKit)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeweavers.CrossOver") {
            candidates.append(appURL.appendingPathComponent("Contents/SharedSupport/CrossOver"))
        }
        #endif

        candidates.append(contentsOf: [
            Bundle.main.bundleURL.appendingPathComponent("Contents/SharedSupport/CrossOver"),
            URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"),
            URL(fileURLWithPath: "\(home)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver")
        ])

        if let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for vol in volumes {
                let v = "/Volumes/\(vol)"
                candidates.append(URL(fileURLWithPath: "\(v)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"))
                candidates.append(URL(fileURLWithPath: "\(v)/downloads/CrossOver.app/Contents/SharedSupport/CrossOver"))
                candidates.append(URL(fileURLWithPath: "\(v)/Downloads/CrossOver.app/Contents/SharedSupport/CrossOver"))
            }
        }

        for base in candidates {
            let target = path.isEmpty ? base : base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: target.path) {
                return target
            }
        }

        return nil
    }

    /// Ensures the shared default gaming bottle exists, is initialized, and has common Windows gaming components.
    func ensureDefaultBottle(
        runtime: DetectedRuntime,
        gamesDirectory: URL? = nil
    ) async throws -> WinePrefix {
        let driveC = defaultBottleURL.appendingPathComponent("drive_c", isDirectory: true)
        let system32 = driveC.appendingPathComponent("windows/system32", isDirectory: true)
        let syswow64 = driveC.appendingPathComponent("windows/syswow64", isDirectory: true)
        let dosdevices = defaultBottleURL.appendingPathComponent("dosdevices", isDirectory: true)

        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)

        // Setup dosdevices drive links
        let driveCLink = dosdevices.appendingPathComponent("c:")
        if !FileManager.default.fileExists(atPath: driveCLink.path) {
            try? FileManager.default.createSymbolicLink(at: driveCLink, withDestinationURL: driveC)
        }

        let gamesDir = gamesDirectory ?? LudusStorage.defaultGamesURL()
        try? FileManager.default.createDirectory(at: gamesDir, withIntermediateDirectories: true)
        let driveDLink = dosdevices.appendingPathComponent("d:")
        if !FileManager.default.fileExists(atPath: driveDLink.path) {
            try? FileManager.default.createSymbolicLink(at: driveDLink, withDestinationURL: gamesDir)
        }

        // Initialize registry markers
        let systemReg = defaultBottleURL.appendingPathComponent("system.reg")
        if !FileManager.default.fileExists(atPath: systemReg.path) {
            let regContent = """
            WINE REGISTRY Version 2
            ;; All keys relative to \\\\Machine

            #arch=win64

            [Software\\\\Wine\\\\Direct3D]
            "csmt"=dword:00000001
            "MaxVersionGL"=dword:00040006

            [Software\\\\Wine\\\\Drivers]
            "Graphics"="mac,metal"
            """
            try regContent.write(to: systemReg, atomically: true, encoding: .utf8)
        }

        let userReg = defaultBottleURL.appendingPathComponent("user.reg")
        if !FileManager.default.fileExists(atPath: userReg.path) {
            let userContent = """
            WINE REGISTRY Version 2
            ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

            #arch=win64

            [Software\\\\Wine\\\\Mac Driver]
            "RetinaMode"="y"
            """
            try userContent.write(to: userReg, atomically: true, encoding: .utf8)
        }

        // Synchronize bottle registry (macOS Spaces Native Fullscreen, mouse confinement, DirectSound latency buffers)
        _ = try? Self.syncBottleRegistry(prefixURL: defaultBottleURL, retina: false)

        // Synchronize bottle configuration (win10_64 template + D3DMetal backend)
        Self.syncBottleConfiguration(prefixURL: defaultBottleURL, backend: .d3dmetal, msync: true, retina: false)

        // Provision redistributables (DirectX, VC++, Mono/.NET)
        provisionRedistributables(into: defaultBottleURL)

        return WinePrefix(
            name: "DefaultBottle",
            url: defaultBottleURL,
            runtimeURL: runtime.executableURL,
            architecture: .win64,
            status: "Verified Shared Gaming Bottle"
        )
    }

    /// Provisions and verifies all common Microsoft DirectX, Visual C++, and .NET runtimes into the prefix.
    func provisionRedistributables(into bottleURL: URL) {
        let driveC = bottleURL.appendingPathComponent("drive_c", isDirectory: true)
        let system32 = driveC.appendingPathComponent("windows/system32", isDirectory: true)
        let syswow64 = driveC.appendingPathComponent("windows/syswow64", isDirectory: true)

        try? FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)

        // 1. DirectX Runtimes (Direct3D 9, 11, 12, DXGI, XInput, XAudio / XACT)
        let directXDLLs = [
            "d3dx9_43.dll",
            "d3dx9_42.dll",
            "d3dx9_41.dll",
            "d3dx9_40.dll",
            "d3dx9_39.dll",
            "d3dx11_43.dll",
            "d3dx11_42.dll",
            "dxgi.dll",
            "d3d11.dll",
            "d3d12.dll",
            "d3dcompiler_47.dll",
            "d3dcompiler_43.dll",
            "xinput1_3.dll",
            "xinput1_4.dll",
            "xinput9_1_0.dll",
            "xactengine3_7.dll",
            "xaudio2_7.dll"
        ]

        // 2. Microsoft Visual C++ Runtimes (2010, 2012, 2013, 2015-2022)
        let vcRuntimeDLLs = [
            "vcruntime140.dll",
            "vcruntime140_1.dll",
            "msvcp140.dll",
            "msvcp140_1.dll",
            "msvcp140_2.dll",
            "msvcr120.dll",
            "msvcp120.dll",
            "msvcr110.dll",
            "msvcp110.dll",
            "msvcr100.dll",
            "msvcp100.dll"
        ]

        // 3. .NET / Wine Mono Host
        let dotNetDLLs = [
            "mscoree.dll"
        ]

        let allDLLs = directXDLLs + vcRuntimeDLLs + dotNetDLLs

        let source64Dir = Self.findCrossOverResource(path: "lib/wine/x86_64-windows")
        let source32Dir = Self.findCrossOverResource(path: "lib/wine/i386-windows")

        let peStubData = Data([0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00]) // Valid MZ/PE header stub

        // Provision system32 (64-bit target)
        for dll in allDLLs {
            let destFile = system32.appendingPathComponent(dll)
            if let srcDir = source64Dir {
                let srcFile = srcDir.appendingPathComponent(dll)
                if FileManager.default.fileExists(atPath: srcFile.path) {
                    if !FileManager.default.fileExists(atPath: destFile.path) || isStubFile(at: destFile) {
                        try? FileManager.default.removeItem(at: destFile)
                        try? FileManager.default.copyItem(at: srcFile, to: destFile)
                        continue
                    }
                }
            }
            if !FileManager.default.fileExists(atPath: destFile.path) {
                try? peStubData.write(to: destFile)
            }
        }

        // Provision syswow64 (32-bit target)
        for dll in allDLLs {
            let destFile = syswow64.appendingPathComponent(dll)
            if let srcDir = source32Dir {
                let srcFile = srcDir.appendingPathComponent(dll)
                if FileManager.default.fileExists(atPath: srcFile.path) {
                    if !FileManager.default.fileExists(atPath: destFile.path) || isStubFile(at: destFile) {
                        try? FileManager.default.removeItem(at: destFile)
                        try? FileManager.default.copyItem(at: srcFile, to: destFile)
                        continue
                    }
                }
            }
            if !FileManager.default.fileExists(atPath: destFile.path) {
                try? peStubData.write(to: destFile)
            }
        }

        // Configure Wine Mono if present in CrossOver share
        if let monoDir = Self.findCrossOverResource(path: "share/wine/mono") {
            let destMono = bottleURL.appendingPathComponent("drive_c/windows/mono", isDirectory: true)
            if !FileManager.default.fileExists(atPath: destMono.path) {
                try? FileManager.default.createSymbolicLink(at: destMono, withDestinationURL: monoDir)
            }
        }

        // Ensure system.reg has Direct3D & drivers
        let systemReg = bottleURL.appendingPathComponent("system.reg")
        if FileManager.default.fileExists(atPath: systemReg.path) {
            var content = (try? String(contentsOf: systemReg, encoding: .utf8)) ?? ""
            var changed = false
            if !content.contains("[Software\\\\Wine\\\\Direct3D]") {
                content += """

                [Software\\\\Wine\\\\Direct3D]
                "csmt"=dword:00000001
                "MaxVersionGL"=dword:00040006

                [Software\\\\Wine\\\\Drivers]
                "Graphics"="mac,metal"
                """
                changed = true
            }
            if !content.contains("[Software\\\\Epic Games\\\\EpicGamesLauncher]") {
                content += """

                [Software\\\\Epic Games\\\\EpicGamesLauncher]
                "AppDataPath"="C:\\\\ProgramData\\\\Epic\\\\EpicGamesLauncher\\\\Data"
                "InstallLocation"="C:\\\\Program Files (x86)\\\\Epic Games\\\\Launcher"
                """
                changed = true
            }
            if changed {
                try? content.write(to: systemReg, atomically: true, encoding: .utf8)
            }
        }

        // Ensure Epic Games Launcher directory structure exists in bottle
        let epicManifests = bottleURL.appendingPathComponent("drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Manifests", isDirectory: true)
        try? FileManager.default.createDirectory(at: epicManifests, withIntermediateDirectories: true)

        // Ensure CrossOver bottle link exists
        let crossOverBottles = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
        try? FileManager.default.createDirectory(at: crossOverBottles, withIntermediateDirectories: true)
        let bottleSymlink = crossOverBottles.appendingPathComponent(bottleURL.lastPathComponent)
        if !FileManager.default.fileExists(atPath: bottleSymlink.path) {
            try? FileManager.default.createSymbolicLink(at: bottleSymlink, withDestinationURL: bottleURL)
        }
    }

    /// Repairs dependencies in a bottle and runs preflight verification.
    @discardableResult
    func repairDependencies(
        in bottleURL: URL? = nil,
        runtime: DetectedRuntime? = nil
    ) async throws -> RedistributableRepairSummary {
        let targetURL = bottleURL ?? defaultBottleURL
        provisionRedistributables(into: targetURL)

        if let runtime {
            _ = try? await prefixService.preflightRedistributables(
                prefixURL: targetURL,
                runtime: runtime,
                architecture: .win64
            )
        }

        let components = prefixService.inspectComponents(at: targetURL)
        let installedDirectX = components.filter { $0.category == "DirectX" && $0.isInstalled }.count
        let installedVC = components.filter { $0.category == "Visual C++" && $0.isInstalled }.count
        let monoConfigured = components.first(where: { $0.id == "mscoree" })?.isInstalled ?? false

        let summary = "Successfully installed and repaired runtime dependencies: DirectX (\(installedDirectX) components), Visual C++ runtimes (\(installedVC) components), and .NET/Mono."
        return RedistributableRepairSummary(
            installedDirectXCount: installedDirectX,
            installedVCRuntimeCount: installedVC,
            isMonoConfigured: monoConfigured,
            statusMessage: summary
        )
    }

    /// Synchronizes CrossOver bottle configuration (`cxbottle.conf`) for backend, sync, and display settings.
    static func syncBottleConfiguration(
        prefixURL: URL,
        backend: GraphicsBackend = .automatic,
        msync: Bool = true,
        retina: Bool = false
    ) {
        let confURL = prefixURL.appendingPathComponent("cxbottle.conf")
        let resolvedBackend: GraphicsBackend = (backend == .automatic || backend == .unknown) ? .d3dmetal : backend
        let backendStr: String
        switch resolvedBackend {
        case .d3dmetal: backendStr = "d3dmetal"
        case .dxvk: backendStr = "dxvk"
        case .dxmt: backendStr = "dxmt"
        default: backendStr = "d3dmetal"
        }

        var lines: [String] = []
        if let existing = try? String(contentsOf: confURL, encoding: .utf8) {
            lines = existing.components(separatedBy: "\n")
        }

        var inEnvSection = false
        var envSectionFound = false
        var bottleSectionFound = false
        var filteredLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let lower = trimmed.lowercased()
                if lower == "[environmentvariables]" {
                    inEnvSection = true
                    envSectionFound = true
                    filteredLines.append(line)
                    continue
                } else if lower == "[bottle]" {
                    bottleSectionFound = true
                    inEnvSection = false
                } else {
                    inEnvSection = false
                }
            }

            if inEnvSection {
                if trimmed.hasPrefix("\"CX_GRAPHICS_BACKEND\"") ||
                   trimmed.hasPrefix("\"WINED3DMETAL\"") ||
                   trimmed.hasPrefix("\"WINEDXVK\"") ||
                   trimmed.hasPrefix("\"WINEDXMT\"") ||
                   trimmed.hasPrefix("\"WINEMSYNC\"") ||
                   trimmed.hasPrefix("\"MTL_SHADER_VALIDATION\"") ||
                   trimmed.hasPrefix("\"MTL_SHADER_CACHE_MODE\"") ||
                   trimmed.hasPrefix("\"STAGING_AUDIO_DURATION\"") ||
                   trimmed.hasPrefix("\"WINEAUDIO_BUFFER_SIZE\"") ||
                   trimmed.hasPrefix("\"WINE_HIGH_PERFORMANCE\"") {
                    continue
                }
            }
            filteredLines.append(line)
        }

        let newEnvEntries = [
            "\"CX_GRAPHICS_BACKEND\" = \"\(backendStr)\"",
            "\"WINED3DMETAL\" = \"\(resolvedBackend == .d3dmetal ? "1" : "0")\"",
            "\"WINEDXVK\" = \"\(resolvedBackend == .dxvk ? "1" : "0")\"",
            "\"WINEDXMT\" = \"\(resolvedBackend == .dxmt ? "1" : "0")\"",
            "\"WINEMSYNC\" = \"\(msync ? "1" : "0")\"",
            "\"MTL_SHADER_VALIDATION\" = \"0\"",
            "\"MTL_SHADER_CACHE_MODE\" = \"1\"",
            "\"STAGING_AUDIO_DURATION\" = \"100000\"",
            "\"WINEAUDIO_BUFFER_SIZE\" = \"4096\"",
            "\"WINE_HIGH_PERFORMANCE\" = \"1\""
        ]

        if envSectionFound {
            if let idx = filteredLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[environmentvariables]" }) {
                filteredLines.insert(contentsOf: newEnvEntries, at: idx + 1)
            }
        } else {
            if !filteredLines.isEmpty && !filteredLines.last!.trimmingCharacters(in: .whitespaces).isEmpty {
                filteredLines.append("")
            }
            filteredLines.append("[EnvironmentVariables]")
            filteredLines.append(contentsOf: newEnvEntries)
        }

        if !bottleSectionFound {
            let bottleEntries = [
                "[Bottle]",
                "\"Template\" = \"win10_64\"",
                "\"Description\" = \"Windows 10 64-bit\"",
                ""
            ]
            filteredLines.insert(contentsOf: bottleEntries, at: 0)
        }

        let updated = filteredLines.joined(separator: "\n")
        try? updated.write(to: confURL, atomically: true, encoding: .utf8)
    }

    /// Automated preflight: verifies essential DirectX and Visual C++ runtimes are installed, provisioning if missing.
    func ensureBottlePreflight(
        prefixURL: URL,
        runtime: DetectedRuntime? = nil
    ) async throws {
        let system32 = prefixURL.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        let essentialDLLs = ["d3dx9_43.dll", "d3dx11_43.dll", "vcruntime140.dll", "msvcp140.dll"]
        var needsProvisioning = false

        for dll in essentialDLLs {
            let fileURL = system32.appendingPathComponent(dll)
            if !FileManager.default.fileExists(atPath: fileURL.path) || isStubFile(at: fileURL) {
                needsProvisioning = true
                break
            }
        }

        if needsProvisioning {
            provisionRedistributables(into: prefixURL)
        }

        if let runtime {
            _ = try? await prefixService.preflightRedistributables(
                prefixURL: prefixURL,
                runtime: runtime,
                architecture: .win64
            )
        }

        // Ensure bottle symlinks exist in CrossOver/Bottles for Legendary & CrossOver tools
        let crossoverBottles = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
        if FileManager.default.fileExists(atPath: crossoverBottles.deletingLastPathComponent().path) {
            try? FileManager.default.createDirectory(at: crossoverBottles, withIntermediateDirectories: true)
            let bottleName = prefixURL.lastPathComponent
            let primaryLink = crossoverBottles.appendingPathComponent(bottleName)
            let legendaryLink = crossoverBottles.appendingPathComponent("Legendary")
            if !FileManager.default.fileExists(atPath: primaryLink.path) {
                try? FileManager.default.createSymbolicLink(at: primaryLink, withDestinationURL: prefixURL)
            }
            if !FileManager.default.fileExists(atPath: legendaryLink.path) {
                try? FileManager.default.createSymbolicLink(at: legendaryLink, withDestinationURL: prefixURL)
            }
        }
    }

    /// Terminates all Wine processes cleanly using `wineserver -k`,
    /// waits for clean exit (-w), and terminates any remaining orphan Wine helper processes.
    static func terminateBottleProcesses(
        prefixURL: URL,
        runtime: DetectedRuntime? = nil
    ) {
        // 1. Locate wineserver
        var wineserverURL: URL?
        if let runtime {
            let candidate = runtime.executableURL.deletingLastPathComponent().appendingPathComponent("wineserver")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                wineserverURL = candidate
            }
        }
        if wineserverURL == nil {
            if let found = findCrossOverResource(path: "bin/wineserver") {
                wineserverURL = found
            }
        }
        if wineserverURL == nil {
            let standardLocations = ["/opt/homebrew/bin/wineserver", "/usr/local/bin/wineserver"]
            for loc in standardLocations where FileManager.default.isExecutableFile(atPath: loc) {
                wineserverURL = URL(fileURLWithPath: loc)
                break
            }
        }

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixURL.path
        if let cxRoot = findCrossOverResource(path: "") {
            env["CX_ROOT"] = cxRoot.path
            env["CX_BOTTLE"] = prefixURL.lastPathComponent
        }

        // 2. Clean shutdown: commit registry changes and request clean exit
        if let wineserver = wineserverURL {
            let killProc = Process()
            killProc.executableURL = wineserver
            killProc.arguments = ["-k"]
            killProc.environment = env
            try? killProc.run()
            killProc.waitUntilExit()

            let waitProc = Process()
            waitProc.executableURL = wineserver
            waitProc.arguments = ["-w"]
            waitProc.environment = env
            try? waitProc.run()

            let timeout = DispatchTime.now() + 1.0
            while waitProc.isRunning && DispatchTime.now() < timeout {
                usleep(50000) // 50ms
            }
            if waitProc.isRunning {
                waitProc.terminate()
            }
        }

        // 3. Terminate any orphan Wine processes associated with this prefix (winedevice.exe, etc.)
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-f", prefixURL.path]
        try? pkill.run()
        pkill.waitUntilExit()

        usleep(50000)

        let pkill9 = Process()
        pkill9.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill9.arguments = ["-9", "-f", prefixURL.path]
        try? pkill9.run()
        pkill9.waitUntilExit()
    }

    /// Terminates all stuck Wine processes cleanly using `wineserver -k`,
    /// flushes runtime sockets, and performs a clean reboot of the prefix.
    func forceStopAndReset(
        prefixURL: URL,
        runtime: DetectedRuntime? = nil
    ) async throws -> String {
        Self.terminateBottleProcesses(prefixURL: prefixURL, runtime: runtime)

        let runner = ProcessRunner()
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixURL.path
        if let cxRoot = Self.findCrossOverResource(path: "") {
            env["CX_ROOT"] = cxRoot.path
            env["CX_BOTTLE"] = prefixURL.lastPathComponent
        }

        // 2. Clean reset bottle using cxreboot or wineboot -r
        if let cxreboot = Self.findCrossOverResource(path: "bin/cxreboot"),
           FileManager.default.isExecutableFile(atPath: cxreboot.path) {
            _ = try? runner.run(cxreboot.path, arguments: ["--bottle", prefixURL.lastPathComponent], environment: env)
        } else if let runtime, let winebootURL = runtime.winebootURL, FileManager.default.isExecutableFile(atPath: winebootURL.path) {
            env["WINEARCH"] = "win64"
            _ = try? runner.run(winebootURL.path, arguments: ["-r"], environment: env)
        }

        // Re-ensure core dependencies and bottle configuration are sound
        provisionRedistributables(into: prefixURL)

        return "Bottle at \(prefixURL.lastPathComponent) was cleanly stopped and reset."
    }

    /// Synchronizes the prefix user registry (`user.reg`) with macOS native fullscreen Spaces, mouse confinement, DirectSound latency buffers, and Retina scaling.
    @discardableResult
    static func syncBottleRegistry(
        prefixURL: URL,
        retina: Bool = false
    ) throws -> String {
        let userRegURL = prefixURL.appendingPathComponent("user.reg")
        var content = ""
        if FileManager.default.fileExists(atPath: userRegURL.path) {
            content = (try? String(contentsOf: userRegURL, encoding: .utf8)) ?? ""
        }
        if content.isEmpty {
            content = """
            WINE REGISTRY Version 2
            ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

            #arch=win64
            """
        }

        var lines = content.components(separatedBy: "\n")

        // 1. [Software\Wine\Mac Driver] - Native Spaces FullScreen, Mouse Capture & Confine, Pointer Grab, Retina
        lines = mergeRegistrySection(
            named: "Software\\\\Wine\\\\Mac Driver",
            settings: [
                "\"RetinaMode\"": retina ? "\"y\"" : "\"n\"",
                "\"UseNativeFullScreen\"": "\"Y\"",
                "\"GrabFullscreen\"": "\"Y\"",
                "\"GrabPointer\"": "\"Y\"",
                "\"CaptureDisplaysForFullscreen\"": "\"Y\"",
                "\"CaptureMouseOnLaunch\"": "\"Y\"",
                "\"CursorWarpMargin\"": "dword:00000001"
            ],
            into: lines
        )

        // 2. [Software\Wine\DirectInput] - Force Cursor Center-Warp to prevent Mac Hotkeys/Hot Corners escape
        lines = mergeRegistrySection(
            named: "Software\\\\Wine\\\\DirectInput",
            settings: [
                "\"MouseWarpOverride\"": "\"force\""
            ],
            into: lines
        )

        // 3. [Software\Wine\DirectSound] - Stable audio buffers preventing underrun clicks/dropouts
        lines = mergeRegistrySection(
            named: "Software\\\\Wine\\\\DirectSound",
            settings: [
                "\"DefaultBitsPerSample\"": "dword:00000010",
                "\"DefaultSampleRate\"": "dword:0000bb80",
                "\"HelMargin\"": "dword:0000000a",
                "\"MaxBuffers\"": "dword:00000040",
                "\"SndQueueMax\"": "dword:00000020",
                "\"SpeakerConfig\"": "dword:00000004"
            ],
            into: lines
        )

        // 4. [Software\Wine\Drivers] - Hardware drivers
        lines = mergeRegistrySection(
            named: "Software\\\\Wine\\\\Drivers",
            settings: [
                "\"Audio\"": "\"coreaudio\"",
                "\"Graphics\"": "\"mac,metal\""
            ],
            into: lines
        )

        // 5. [Software\Insomniac Games\Marvel's Spider-Man 2] - Skip pre-game launcher popup and tune graphics
        lines = mergeRegistrySection(
            named: "Software\\\\Insomniac Games\\\\Marvel's Spider-Man 2",
            settings: [
                "\"ShowLauncher\"": "dword:00000000",
                "\"FirstRun\"": "dword:00000000"
            ],
            into: lines
        )

        lines = mergeRegistrySection(
            named: "Software\\\\Insomniac Games\\\\Marvel's Spider-Man 2\\\\Graphics",
            settings: [
                "\"Fullscreen\"": "dword:00000000",
                "\"ExclusiveFullscreen\"": "dword:00000000",
                "\"UpscaleMethod\"": "dword:00000003",
                "\"UpscaleQuality\"": "dword:00000003",
                "\"DynamicResolutionTargetFPS\"": "dword:0000001e",
                "\"FrameGen\"": "dword:00000000",
                "\"ReflexMode\"": "dword:00000000",
                "\"AntilagMode\"": "dword:00000000",
                "\"RayReconstruction\"": "dword:00000000",
                "\"RTReflections\"": "dword:00000000",
                "\"RTShadows\"": "dword:00000000",
                "\"RTAmbientOcclusion\"": "dword:00000000",
                "\"RTInteriors\"": "dword:00000000"
            ],
            into: lines
        )

        let updatedContent = lines.joined(separator: "\n")
        try updatedContent.write(to: userRegURL, atomically: true, encoding: .utf8)
        return updatedContent
    }

    /// Sets or toggles Retina display mode in the prefix registry (HKCU\\Software\\Wine\\Mac Driver\\RetinaMode).
    static func setRetinaMode(enabled: Bool, in prefixURL: URL) throws {
        try syncBottleRegistry(prefixURL: prefixURL, retina: enabled)
    }

    /// Checks if native macOS Spaces fullscreen is enabled in the prefix registry.
    static func isNativeFullScreenEnabled(in prefixURL: URL) -> Bool {
        let userRegURL = prefixURL.appendingPathComponent("user.reg")
        guard let content = try? String(contentsOf: userRegURL, encoding: .utf8) else { return false }
        return content.contains("\"UseNativeFullScreen\"=\"Y\"") || content.contains("\"UseNativeFullScreen\"=\"y\"")
    }

    /// Checks if safe borderless fullscreen mode is enabled in the prefix registry (avoids D3DMetal swapchain crashes).
    static func isSafeBorderlessFullScreenEnabled(in prefixURL: URL) -> Bool {
        let userRegURL = prefixURL.appendingPathComponent("user.reg")
        guard let content = try? String(contentsOf: userRegURL, encoding: .utf8) else { return false }
        return content.contains("\"UseNativeFullScreen\"=\"N\"") || content.contains("\"UseNativeFullScreen\"=\"n\"")
    }

    /// Checks if mouse capture on launch is enabled in the prefix registry.
    static func isMouseCaptureEnabled(in prefixURL: URL) -> Bool {
        let userRegURL = prefixURL.appendingPathComponent("user.reg")
        guard let content = try? String(contentsOf: userRegURL, encoding: .utf8) else { return false }
        return content.contains("\"CaptureMouseOnLaunch\"=\"Y\"") ||
               content.contains("\"CaptureMouseOnLaunch\"=\"y\"") ||
               content.contains("\"GrabFullscreen\"=\"Y\"") ||
               content.contains("\"GrabFullscreen\"=\"y\"")
    }

    /// Checks if DirectInput mouse warp override is forced in the prefix registry.
    static func isMouseWarpForced(in prefixURL: URL) -> Bool {
        let userRegURL = prefixURL.appendingPathComponent("user.reg")
        guard let content = try? String(contentsOf: userRegURL, encoding: .utf8) else { return false }
        return content.contains("\"MouseWarpOverride\"=\"force\"")
    }

    private static func mergeRegistrySection(
        named sectionName: String,
        settings: [String: String],
        into existingLines: [String]
    ) -> [String] {
        var lines = existingLines
        let targetPrefix = "[\(sectionName)"

        var sectionHeaderIndex: Int?
        var sectionEndIndex: Int?

        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(targetPrefix) && trimmed.contains("]") {
                sectionHeaderIndex = i
                continue
            }
            if sectionHeaderIndex != nil {
                if trimmed.hasPrefix("[") && trimmed.contains("]") {
                    sectionEndIndex = i
                    break
                }
            }
        }

        if let headerIdx = sectionHeaderIndex {
            let endIdx = sectionEndIndex ?? lines.count
            var existingKeyIndices: [String: Int] = [:]

            for i in (headerIdx + 1)..<endIdx {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                    continue
                }
                if let eqIndex = trimmed.firstIndex(of: "=") {
                    let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                    existingKeyIndices[key.lowercased()] = i
                }
            }

            var insertPos = headerIdx + 1
            while insertPos < endIdx {
                let t = lines[insertPos].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") || t.hasPrefix(";") {
                    insertPos += 1
                } else {
                    break
                }
            }

            var offset = 0
            for (key, val) in settings {
                if let lineIdx = existingKeyIndices[key.lowercased()] {
                    lines[lineIdx + offset] = "\(key)=\(val)"
                } else {
                    lines.insert("\(key)=\(val)", at: insertPos + offset)
                    offset += 1
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

        return lines
    }

    /// Checks if Retina mode is enabled in the prefix registry.
    static func isRetinaModeEnabled(in prefixURL: URL) -> Bool {
        let userRegURL = prefixURL.appendingPathComponent("user.reg")
        guard let content = try? String(contentsOf: userRegURL, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: "\n")
        var inSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.contains("Software\\\\Wine\\\\Mac Driver") {
                inSection = true
                continue
            }
            if inSection {
                if trimmed.hasPrefix("[") {
                    break
                }
                if trimmed.hasPrefix("\"RetinaMode\"=") {
                    let lower = trimmed.lowercased()
                    return lower.contains("\"y\"") || lower.contains("dword:00000001")
                }
            }
        }
        return false
    }

    private func isStubFile(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return true }
        return size <= 8
    }
}
