import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

struct RuntimeDiagnosticsService: Sendable {
    private let processRunner = ProcessRunner()

    func collectReport() -> RuntimeDiagnosticReport {
        let architecture = commandOutput("/usr/bin/uname", arguments: ["-m"]) ?? "Unknown"
        let macOSVersion = commandOutput("/usr/bin/sw_vers", arguments: ["-productVersion"]) ?? "Unknown"
        let developerDirectory = commandOutput("/usr/bin/xcode-select", arguments: ["-p"])
        var findings: [DiagnosticFinding] = []
        let runtimes = detectRuntimes()

        if architecture == "arm64" {
            findings.append(DiagnosticFinding(
                title: "Apple Silicon detected",
                detail: "The host reports arm64, which matches the target architecture.",
                severity: .success
            ))
        } else {
            findings.append(DiagnosticFinding(
                title: "Unexpected host architecture",
                detail: "The host reports \(architecture). Apple Silicon compatibility testing requires arm64.",
                severity: .warning
            ))
        }

        let detectedXcode = findApplicationPath(named: "Xcode.app")

        if let detectedXcode {
            findings.append(DiagnosticFinding(
                title: "Full Xcode detected",
                detail: "Xcode found at \(detectedXcode). Full app-bundle and toolchain verification active.",
                severity: .success
            ))
        } else if developerDirectory?.contains("CommandLineTools") == true {
            findings.append(DiagnosticFinding(
                title: "Command Line Tools active",
                detail: "Active developer directory: \(developerDirectory ?? ""). Command Line Tools available.",
                severity: .info
            ))
        } else if let developerDirectory {
            findings.append(DiagnosticFinding(
                title: "Developer tools detected",
                detail: developerDirectory,
                severity: .success
            ))
        } else {
            findings.append(DiagnosticFinding(
                title: "Developer tools unavailable",
                detail: "xcode-select did not return an active developer directory.",
                severity: .info
            ))
        }

        let detectedWine = detectWine()

        if let detectedWine {
            findings.append(DiagnosticFinding(
                title: "Wine executable detected",
                detail: detectedWine,
                severity: .success
            ))
        } else {
            findings.append(DiagnosticFinding(
                title: "No supported Wine executable detected",
                detail: "A Wine runtime is required to run Windows games. Ludus can automatically install and configure one for you.",
                severity: .warning,
                fixActionTitle: "Auto-Install Wine",
                fixActionKind: .installWine
            ))
        }

        let detectedHeroic = findApplicationPath(named: "Heroic.app")
        let heroicInstalled = detectedHeroic != nil
        findings.append(DiagnosticFinding(
            title: heroicInstalled ? "Heroic detected" : "Heroic not detected",
            detail: heroicInstalled
                ? "Heroic application bundle found at \(detectedHeroic!). Ludus can reuse its selected authenticated configuration without reading Epic credentials."
                : "Heroic is required if you want to play games from your Epic Games library. Ludus can automatically install it for you.",
            severity: heroicInstalled ? .success : .info,
            fixActionTitle: heroicInstalled ? nil : "Auto-Install Heroic",
            fixActionKind: heroicInstalled ? nil : .installHeroic
        ))

        let detectedSteam = findApplicationPath(named: "Steam.app")
        let steamInstalled = detectedSteam != nil
        findings.append(DiagnosticFinding(
            title: steamInstalled ? "Steam detected" : "Steam not detected",
            detail: steamInstalled
                ? "Steam application bundle found at \(detectedSteam!). Delegated launch and local library import available."
                : "Steam is not detected in Applications. Ludus can manage Steam games when Steam is installed.",
            severity: steamInstalled ? .success : .info,
            fixActionTitle: steamInstalled ? nil : "Auto-Install Steam",
            fixActionKind: steamInstalled ? nil : .installSteam
        ))

        return RuntimeDiagnosticReport(
            generatedAt: Date(),
            hostArchitecture: architecture,
            macOSVersion: macOSVersion,
            developerDirectory: developerDirectory,
            findings: findings,
            runtimes: runtimes
        )
    }

    private func findApplicationPath(named appName: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/Applications/\(appName)",
            "\(home)/Applications/\(appName)"
        ]
        if let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for vol in volumes {
                candidates.append("/Volumes/\(vol)/Applications/\(appName)")
            }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func inspectRuntime(at executableURL: URL, name: String = "User-selected Wine") -> DetectedRuntime? {
        guard executableURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        let standardizedURL = executableURL.standardizedFileURL
        let winebootURL = standardizedURL
            .deletingLastPathComponent()
            .appendingPathComponent("wineboot")
        let detectedWineboot = FileManager.default.isExecutableFile(atPath: winebootURL.path)
            ? winebootURL
            : nil
        return DetectedRuntime(
            id: Self.stableIdentifier(for: standardizedURL),
            name: name,
            executableURL: standardizedURL,
            winebootURL: detectedWineboot,
            version: commandOutput(standardizedURL.path, arguments: ["--version"]) ?? "Version unavailable",
            architecture: executableArchitecture(at: standardizedURL.path),
            status: detectedWineboot == nil
                ? "Selected; wineboot unavailable"
                : "Selected; prefix creation available"
        )
    }

    func healthCheck(for runtime: DetectedRuntime) -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        let executablePath = runtime.executableURL.path
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            findings.append(DiagnosticFinding(
                title: "Runtime executable unavailable",
                detail: executablePath,
                severity: .error
            ))
            return findings
        }

        guard let versionResult = try? processRunner.run(executablePath, arguments: ["--version"]),
              versionResult.status == 0,
              !versionResult.output.isEmpty else {
            findings.append(DiagnosticFinding(
                title: "Runtime version check failed",
                detail: "The selected executable could not complete --version successfully.",
                severity: .error
            ))
            return findings
        }
        findings.append(DiagnosticFinding(
            title: "Runtime executable responds",
            detail: versionResult.output,
            severity: .success
        ))

        let architecture = executableArchitecture(at: executablePath)
        if architecture == "Unknown" {
            findings.append(DiagnosticFinding(
                title: "Runtime architecture unavailable",
                detail: "The macOS file inspection did not identify arm64 or x86_64.",
                severity: .warning
            ))
        } else {
            findings.append(DiagnosticFinding(
                title: "Runtime architecture inspected",
                detail: architecture,
                severity: .success
            ))
        }

        guard let winebootURL = runtime.winebootURL,
              FileManager.default.isExecutableFile(atPath: winebootURL.path) else {
            findings.append(DiagnosticFinding(
                title: "wineboot unavailable",
                detail: "Prefix creation remains unavailable until a sibling executable named wineboot is present.",
                severity: .warning
            ))
            return findings
        }
        findings.append(DiagnosticFinding(
            title: "wineboot available",
            detail: winebootURL.path,
            severity: .success
        ))
        return findings
    }

    func detectWine() -> String? {
        candidateWineLocations().map(\.1).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func candidateWineLocations() -> [(String, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [(String, String)] = []

        // Managed Ludus Runtime (Application Support)
        let managedWine64 = LudusStorage.applicationSupportURL.appendingPathComponent("Runtime/bin/wine64").path
        let managedWine = LudusStorage.applicationSupportURL.appendingPathComponent("Runtime/bin/wine").path
        candidates.append(("Ludus Managed Wine (64-bit)", managedWine64))
        candidates.append(("Ludus Managed Wine", managedWine))

        // Dynamically discovered system CrossOver via LaunchServices
        #if canImport(AppKit)
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeweavers.CrossOver") {
            let wine64 = appURL.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine64").path
            let wine = appURL.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine").path
            candidates.append(("CrossOver Wine (System 64-bit)", wine64))
            candidates.append(("CrossOver Wine (System)", wine))
        }
        #endif

        candidates.append(contentsOf: [
            ("Wine on Homebrew", "/opt/homebrew/bin/wine"),
            ("Wine on Homebrew (opt path)", "/opt/homebrew/opt/wine/bin/wine"),
            ("Wine 64-bit on Homebrew", "/opt/homebrew/bin/wine64"),
            ("Wine on Intel Homebrew", "/usr/local/bin/wine"),
            ("Wine on Intel Homebrew (opt path)", "/usr/local/opt/wine/bin/wine"),
            // CrossOver (64-bit and 32-bit)
            ("CrossOver Wine (64-bit)", "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64"),
            ("CrossOver Wine", "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"),
            ("CrossOver Wine (User 64-bit)", "\(home)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64"),
            ("CrossOver Wine (User)", "\(home)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"),
            // Game Porting Toolkit
            ("Game Porting Toolkit Wine (64-bit)", "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"),
            ("Game Porting Toolkit Wine", "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine"),
            ("Game Porting Toolkit Wine (User 64-bit)", "\(home)/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"),
            ("Game Porting Toolkit Wine (User)", "\(home)/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine"),
            // Whisky
            ("Whisky Wine (64-bit)", "\(home)/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64"),
            ("Whisky Wine", "\(home)/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine"),
            ("Whisky Bundle Wine (64-bit)", "/Applications/Whisky.app/Contents/Resources/Wine/bin/wine64"),
            ("Whisky Bundle Wine", "/Applications/Whisky.app/Contents/Resources/Wine/bin/wine"),
            ("Whisky Bundle Wine (User 64-bit)", "\(home)/Applications/Whisky.app/Contents/Resources/Wine/bin/wine64"),
            ("Whisky Bundle Wine (User)", "\(home)/Applications/Whisky.app/Contents/Resources/Wine/bin/wine"),
            // GPTK Homebrew
            ("Game Porting Toolkit (Homebrew 64-bit)", "/usr/local/opt/game-porting-toolkit/bin/wine64"),
            ("Game Porting Toolkit (Homebrew)", "/usr/local/opt/game-porting-toolkit/bin/wine"),
            ("Game Porting Toolkit (Homebrew opt 64-bit)", "/opt/homebrew/opt/game-porting-toolkit/bin/wine64"),
            ("Game Porting Toolkit (Homebrew opt)", "/opt/homebrew/opt/game-porting-toolkit/bin/wine"),
            // Wine Staging / Crossover / Devel / Stable
            ("Wine Crossover", "/Applications/Wine Crossover.app/Contents/Resources/wine/bin/wine"),
            ("Wine Crossover (User)", "\(home)/Applications/Wine Crossover.app/Contents/Resources/wine/bin/wine"),
            ("Wine Staging", "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine"),
            ("Wine Staging (User)", "\(home)/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine"),
            ("Wine Devel", "/Applications/Wine Devel.app/Contents/Resources/wine/bin/wine"),
            ("Wine Stable", "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine")
        ])

        if let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for vol in volumes {
                let v = "/Volumes/\(vol)"
                candidates.append(("CrossOver Wine (\(vol) 64-bit)", "\(v)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64"))
                candidates.append(("CrossOver Wine (\(vol))", "\(v)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"))
                candidates.append(("CrossOver Wine (\(vol) downloads 64-bit)", "\(v)/downloads/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64"))
                candidates.append(("CrossOver Wine (\(vol) downloads)", "\(v)/downloads/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"))
                candidates.append(("CrossOver Wine (\(vol) Downloads 64-bit)", "\(v)/Downloads/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64"))
                candidates.append(("CrossOver Wine (\(vol) Downloads)", "\(v)/Downloads/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"))
                candidates.append(("Game Porting Toolkit Wine (\(vol) 64-bit)", "\(v)/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"))
                candidates.append(("Game Porting Toolkit Wine (\(vol))", "\(v)/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine"))
                candidates.append(("Whisky Wine (\(vol) 64-bit)", "\(v)/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64"))
                candidates.append(("Whisky Wine (\(vol))", "\(v)/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine"))
                candidates.append(("Whisky Bundle Wine (\(vol) 64-bit)", "\(v)/Applications/Whisky.app/Contents/Resources/Wine/bin/wine64"))
                candidates.append(("Whisky Bundle Wine (\(vol))", "\(v)/Applications/Whisky.app/Contents/Resources/Wine/bin/wine"))
                candidates.append(("Wine Crossover (\(vol))", "\(v)/Applications/Wine Crossover.app/Contents/Resources/wine/bin/wine"))
                candidates.append(("Wine Staging (\(vol))", "\(v)/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine"))
            }
        }
        return candidates
    }

    func detectRuntimes() -> [DetectedRuntime] {
        var candidates: [(String, String)] = candidateWineLocations()

        let managedRuntimesDir = LudusStorage.applicationSupportURL.appendingPathComponent("Runtimes", isDirectory: true)

        if let contents = try? FileManager.default.contentsOfDirectory(at: managedRuntimesDir, includingPropertiesForKeys: nil) {
            for dir in contents {
                let candidateWine = dir.appendingPathComponent("bin/wine").path
                let directWine = dir.appendingPathComponent("wine").path
                if FileManager.default.isExecutableFile(atPath: candidateWine) {
                    candidates.append(("Ludus: \(dir.lastPathComponent)", candidateWine))
                } else if FileManager.default.isExecutableFile(atPath: directWine) {
                    candidates.append(("Ludus: \(dir.lastPathComponent)", directWine))
                }
            }
        }

        var seenPaths = Set<String>()
        return candidates.compactMap { candidate in
            let (name, path) = candidate
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else { return nil }
            let version = commandOutput(path, arguments: ["--version"]) ?? "Version unavailable"
            let winebootURL = URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .appendingPathComponent("wineboot")
            let detectedWineboot = FileManager.default.isExecutableFile(atPath: winebootURL.path) ? winebootURL : nil
            let architecture = executableArchitecture(at: path)
            return DetectedRuntime(
                id: Self.stableIdentifier(for: URL(fileURLWithPath: path)),
                name: name,
                executableURL: URL(fileURLWithPath: path),
                winebootURL: detectedWineboot,
                version: version,
                architecture: architecture,
                status: detectedWineboot == nil
                    ? "Detected; wineboot unavailable"
                    : "Detected; prefix creation available"
            )
        }
    }

    static func stableIdentifier(for executableURL: URL) -> UUID {
        let canonicalURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
        let digest = SHA256.hash(data: Data(canonicalURL.path.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hexadecimal = bytes.map { String(format: "%02x", $0) }.joined()
        let uuidString = [
            hexadecimal.prefix(8),
            hexadecimal.dropFirst(8).prefix(4),
            hexadecimal.dropFirst(12).prefix(4),
            hexadecimal.dropFirst(16).prefix(4),
            hexadecimal.dropFirst(20)
        ]
        .map(String.init)
        .joined(separator: "-")
        return UUID(uuidString: uuidString)!
    }

    private func executableArchitecture(at path: String) -> String {
        guard let output = commandOutput("/usr/bin/file", arguments: [path]) else {
            return "Unknown"
        }
        let hasArm64 = output.localizedCaseInsensitiveContains("arm64")
        let hasX8664 = output.localizedCaseInsensitiveContains("x86_64")
        switch (hasArm64, hasX8664) {
        case (true, true): return "arm64 + x86_64"
        case (true, false): return "arm64"
        case (false, true): return "x86_64"
        default: return "Unknown"
        }
    }

    private func commandOutput(_ executable: String, arguments: [String]) -> String? {
        guard let result = try? processRunner.run(executable, arguments: arguments), result.status == 0 else {
            return nil
        }
        return result.output.isEmpty ? nil : result.output
    }
}
