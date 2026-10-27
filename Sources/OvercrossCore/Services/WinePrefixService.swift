import Foundation

enum WinePrefixError: LocalizedError, Sendable {
    case missingWineboot
    case invalidName
    case existingDirectory(URL)
    case couldNotStart(String)
    case initializationFailed(String)
    case verificationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .missingWineboot:
            "The selected runtime does not expose a wineboot executable, so Ludus cannot safely create a prefix with it."
        case .invalidName:
            "Prefix names may not be empty or contain path separators."
        case .existingDirectory(let url):
            "The prefix directory already exists and is not empty: \(url.path)"
        case .couldNotStart(let message):
            "Could not start wineboot: \(message)"
        case .initializationFailed(let message):
            "wineboot did not initialize the prefix: \(message)"
        case .verificationFailed(let url):
            "The prefix was not verified after initialization: \(url.path)"
        }
    }
}

struct WinePrefixService: Sendable {
    static func isVerifiedPrefix(at prefixURL: URL) -> Bool {
        guard isDirectory(prefixURL) else { return false }
        let registryURL = prefixURL.appendingPathComponent("system.reg")
        let driveCURL = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        return isRegularFile(registryURL) && isDirectory(driveCURL)
    }

    func createPrefix(
        name: String,
        rootURL: URL,
        runtime: DetectedRuntime,
        architecture: PrefixArchitecture
    ) async throws -> WinePrefix {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedName.contains("/"), !trimmedName.contains("\\") else {
            throw WinePrefixError.invalidName
        }
        guard let winebootURL = runtime.winebootURL else {
            throw WinePrefixError.missingWineboot
        }

        let prefixURL = rootURL.appendingPathComponent(trimmedName, isDirectory: true)
        if FileManager.default.fileExists(atPath: prefixURL.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: prefixURL.path)
            guard contents.isEmpty else { throw WinePrefixError.existingDirectory(prefixURL) }
        } else {
            try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)
        }

        let outcome = try await runWineboot(
            winebootURL: winebootURL,
            prefixURL: prefixURL,
            architecture: architecture
        )
        guard outcome.exitStatus == 0 else {
            throw WinePrefixError.initializationFailed(outcome.summary)
        }

        guard Self.isVerifiedPrefix(at: prefixURL) else {
            throw WinePrefixError.verificationFailed(prefixURL)
        }

        return WinePrefix(
            name: trimmedName,
            url: prefixURL,
            runtimeURL: runtime.executableURL,
            architecture: architecture
        )
    }

    /// Inspects the presence of key runtime components and redistributables inside the prefix.
    func inspectComponents(at prefixURL: URL) -> [PrefixComponentInfo] {
        let driveC = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        let definitions: [(id: String, name: String, category: String, path: String)] = [
            ("vcrun2015_vcruntime", "Visual C++ 2015-2022 (VCRUNTIME140)", "Visual C++", "windows/system32/vcruntime140.dll"),
            ("vcrun2015_msvcp", "Visual C++ 2015-2022 (MSVCP140)", "Visual C++", "windows/system32/msvcp140.dll"),
            ("vcrun2013", "Visual C++ 2013 (MSVCR120)", "Visual C++", "windows/system32/msvcr120.dll"),
            ("vcrun2012", "Visual C++ 2012 (MSVCR110)", "Visual C++", "windows/system32/msvcr110.dll"),
            ("vcrun2010", "Visual C++ 2010 (MSVCR100)", "Visual C++", "windows/system32/msvcr100.dll"),
            ("dx11_dxgi", "DirectX DXGI (dxgi.dll)", "DirectX", "windows/system32/dxgi.dll"),
            ("dx11_d3d11", "Direct3D 11 (d3d11.dll)", "DirectX", "windows/system32/d3d11.dll"),
            ("dx9_d3dx9_43", "Direct3D 9 (d3dx9_43.dll)", "DirectX", "windows/system32/d3dx9_43.dll"),
            ("dx11_d3dx11_43", "Direct3D 11 (d3dx11_43.dll)", "DirectX", "windows/system32/d3dx11_43.dll"),
            ("d3dcompiler47", "Direct3D Compiler 47", "DirectX", "windows/system32/d3dcompiler_47.dll"),
            ("d3dcompiler43", "Direct3D Compiler 43", "DirectX", "windows/system32/d3dcompiler_43.dll"),
            ("xinput1_3", "XInput 1.3 (xinput1_3.dll)", "Audio & Input", "windows/system32/xinput1_3.dll"),
            ("xaudio27", "XAudio 2.7 (xaudio2_7.dll)", "Audio & Input", "windows/system32/xaudio2_7.dll"),
            ("xactengine3_7", "XACT Audio Engine (xactengine3_7.dll)", "Audio & Input", "windows/system32/xactengine3_7.dll"),
            ("mscoree", "Wine Mono / .NET Host (mscoree.dll)", "Core Runtime", "windows/system32/mscoree.dll")
        ]

        return definitions.map { def in
            let fileURL = driveC.appendingPathComponent(def.path)
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            return PrefixComponentInfo(
                id: def.id,
                name: def.name,
                category: def.category,
                isInstalled: exists,
                relativePath: def.path
            )
        }
    }

    /// Runs wineboot update to verify essential prefix runtime components and registry integrity.
    func preflightRedistributables(
        prefixURL: URL,
        runtime: DetectedRuntime,
        architecture: PrefixArchitecture
    ) async throws -> GameLaunchOutcome {
        guard let winebootURL = runtime.winebootURL else {
            throw WinePrefixError.missingWineboot
        }
        guard Self.isVerifiedPrefix(at: prefixURL) else {
            throw WinePrefixError.verificationFailed(prefixURL)
        }

        return try await runWineboot(
            winebootURL: winebootURL,
            prefixURL: prefixURL,
            architecture: architecture,
            arguments: ["-u"]
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue
    }

    private func runWineboot(
        winebootURL: URL,
        prefixURL: URL,
        architecture: PrefixArchitecture,
        arguments: [String] = ["-i"]
    ) async throws -> GameLaunchOutcome {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LudusWineboot-\(UUID().uuidString)", isDirectory: true)
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
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = prefixURL.path
            environment["WINEARCH"] = architecture.rawValue
            environment["WINEDLLOVERRIDES"] = "mscoree,mshtml=d"
            process.environment = environment
            process.executableURL = winebootURL
            process.arguments = arguments
            process.standardOutput = outputFile
            process.standardError = errorFile

            do {
                try process.run()
            } catch {
                throw WinePrefixError.couldNotStart(error.localizedDescription)
            }
            process.waitUntilExit()
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
                standardOutput: readPrefixOutput(from: outputReader),
                standardError: readPrefixOutput(from: errorReader)
            )
        }.value
    }
}

private func readPrefixOutput(from handle: FileHandle) -> String {
    do {
        let data = try handle.read(upToCount: 64 * 1024) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}
