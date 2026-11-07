import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Metal)
import Metal
#endif
@testable import OvercrossCore

final class GameLibraryStoreTests: XCTestCase, @unchecked Sendable {
    func testWindowsLaunchResolvesNestedUnrealExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossExecutableResolution-\(UUID().uuidString)", isDirectory: true)
        let selected = root.appendingPathComponent("HogwartsLegacy.exe")
        let nested = root.appendingPathComponent("Phoenix/Binaries/Win64/HogwartsLegacy.exe")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128).write(to: selected)
        try Data(repeating: 2, count: 4096).write(to: nested)

        let resolved = GameLaunchService.resolveWindowsExecutable(
            selectedURL: selected,
            installationURL: root
        )
        XCTAssertEqual(resolved.standardizedFileURL, nested.standardizedFileURL)
    }

    func testWindowsLaunchRecognizesPE32ExecutableInsideWin64Prefix() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossPE32-\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: executable) }

        var data = Data(repeating: 0, count: 0x80)
        data[0] = 0x4d
        data[1] = 0x5a
        data[0x3c] = 0x40
        data[0x40] = 0x50
        data[0x41] = 0x45
        data[0x44] = 0x4c
        data[0x45] = 0x01
        try data.write(to: executable)

        XCTAssertTrue(GameLaunchService.is32BitWindowsExecutable(at: executable))
    }

    func testAudioRepairRejectsUnknownBinaryWithoutMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossAudioRepair-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("bin/wine64")
        let library = root.appendingPathComponent("lib/wine/x86_32on64-unix/winecoreaudio.so")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: library)

        XCTAssertThrowsError(try AudioRepairService().prepare(runtimeExecutableURL: executable)) { error in
            XCTAssertTrue(error is AudioRepairService.Error)
        }
        XCTAssertEqual(try Data(contentsOf: library), Data([0, 1, 2, 3]))
    }

    func testPE32AndPE32PlusDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossPEDetection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Valid PE32 (machine 0x014c: Intel 386)
        let pe32URL = tempDir.appendingPathComponent("test32.exe")
        var pe32Data = Data(repeating: 0, count: 0x80)
        pe32Data[0] = 0x4d // M
        pe32Data[1] = 0x5a // Z
        pe32Data[0x3c] = 0x40 // PE offset
        pe32Data[0x40] = 0x50 // P
        pe32Data[0x41] = 0x45 // E
        pe32Data[0x44] = 0x4c // 0x014c (little-endian)
        pe32Data[0x45] = 0x01
        try pe32Data.write(to: pe32URL)
        XCTAssertTrue(GameLaunchService.is32BitWindowsExecutable(at: pe32URL))

        // Valid PE32+ (machine 0x8664: AMD64 / x86_64)
        let pe64URL = tempDir.appendingPathComponent("test64.exe")
        var pe64Data = Data(repeating: 0, count: 0x80)
        pe64Data[0] = 0x4d // M
        pe64Data[1] = 0x5a // Z
        pe64Data[0x3c] = 0x40 // PE offset
        pe64Data[0x40] = 0x50 // P
        pe64Data[0x41] = 0x45 // E
        pe64Data[0x44] = 0x64 // 0x8664 (little-endian)
        pe64Data[0x45] = 0x86
        try pe64Data.write(to: pe64URL)
        XCTAssertFalse(GameLaunchService.is32BitWindowsExecutable(at: pe64URL))

        // Non-PE executable (e.g. script)
        let scriptURL = tempDir.appendingPathComponent("script.exe")
        try "#!/bin/sh\necho hello\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(GameLaunchService.is32BitWindowsExecutable(at: scriptURL))
    }

    func testAudioDiagnosticsDetection() throws {
        // DirectSound pointer truncation fault
        let truncationLog = "0024:err:seh:raise_exception wine: Unhandled page fault on write access to 00000200 at address 70BD45E8"
        let truncationDiag = GameLaunchService.analyzeAudioDiagnostics(standardOutput: "", standardError: truncationLog)
        XCTAssertNotNil(truncationDiag)
        XCTAssertTrue(truncationDiag?.contains("DirectSound 32-bit pointer truncation page fault detected") == true)

        // E_OUTOFMEMORY during AudioClient initialization
        let oomLog = "0024:err:coreaudio:AudioClient_Initialize AudioClient_Initialize failed: 8007000e"
        let oomDiag = GameLaunchService.analyzeAudioDiagnostics(standardOutput: "", standardError: oomLog)
        XCTAssertNotNil(oomDiag)
        XCTAssertTrue(oomDiag?.contains("E_OUTOFMEMORY (0x8007000e)") == true)

        // Operational bridge output
        let operationalLog = "[overcross-audio] Successfully migrated stream 0x6215668 local_buffer to 0x79000000 (32-bit addressable)"
        let opDiag = GameLaunchService.analyzeAudioDiagnostics(standardOutput: "", standardError: operationalLog)
        XCTAssertNotNil(opDiag)
        XCTAssertTrue(opDiag?.contains("WoW64 CoreAudio Mach VM bridge active") == true)

        // Clean normal output
        let normalDiag = GameLaunchService.analyzeAudioDiagnostics(standardOutput: "Game initialized normally", standardError: "")
        XCTAssertNil(normalDiag)
    }

    func testAudioRepairStagingAndRollbackPreservesSourceRuntime() throws {
        let realRuntime = URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64")
        guard FileManager.default.fileExists(atPath: realRuntime.path) else { return }

        let sourceLib = URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib/wine/x86_32on64-unix/winecoreaudio.so")
        guard let sourceDataBefore = try? Data(contentsOf: sourceLib) else { return }

        let service = AudioRepairService()
        guard service.isSupported(sourceDataBefore) else { return }

        // Staging should succeed
        let prep = try service.prepare(runtimeExecutableURL: realRuntime)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: prep.executableURL.path))

        // Source binary must be 100% byte-identical
        let sourceDataAfter = try Data(contentsOf: sourceLib)
        XCTAssertEqual(sourceDataBefore, sourceDataAfter)

        // Staged runtime must be verified
        XCTAssertTrue(service.isStaged(for: realRuntime))

        // Subsequent call must reuse cache
        let prep2 = try service.prepare(runtimeExecutableURL: realRuntime)
        XCTAssertTrue(prep2.status.contains("reused"))

        // Rollback removes staged runtime
        try service.rollback(for: realRuntime)
        XCTAssertFalse(service.isStaged(for: realRuntime))

        // Source binary still untouched after rollback
        let sourceDataAfterRollback = try Data(contentsOf: sourceLib)
        XCTAssertEqual(sourceDataBefore, sourceDataAfterRollback)

        // Re-prepare so system remains in ready state
        _ = try service.prepare(runtimeExecutableURL: realRuntime)
        XCTAssertTrue(service.isStaged(for: realRuntime))
    }

    func testWindowsLaunchBypassesAudioRepairFor64BitExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Overcross64BypassTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        let executableURL = root.appendingPathComponent("game64.exe")
        try "#!/bin/sh\nprintf '%s|%s\\n' \"$OVERCROSS_AUDIO_REPAIR_STATUS\" \"$OVERCROSS_AUDIO_BACKEND\"\n"
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            id: UUID(),
            name: "Process harness",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(
            name: "Harness win64 prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(
            title: "64-bit Game",
            store: .local,
            storeApplicationID: "game64",
            installationURL: root,
            executableURL: executableURL
        )

        let outcome = try await GameLaunchService().launchWindows(
            game: game,
            runtime: runtime,
            prefix: prefix
        )
        XCTAssertEqual(outcome.exitStatus, 0)
        XCTAssertEqual(
            outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "Bypassed (64-bit native executable)|winecoreaudio (native 64-bit)"
        )
    }

    func testSettingsDecodePreservesOlderSavedShape() throws {
        let data = Data(#"{"preferredInstallDirectory":"/Games","performanceMonitoringEnabled":true,"launchAtLogin":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.preferredInstallDirectory?.path, "/Games")
        XCTAssertNil(settings.heroicLegendaryConfigDirectory)
        XCTAssertFalse(settings.heroicInstallPrerequisites)
        XCTAssertTrue(settings.performanceMonitoringEnabled)
    }

    func testSettingsRoundTripPreservesExplicitEpicPrerequisiteChoice() throws {
        let settings = AppSettings(
            preferredInstallDirectory: nil,
            heroicInstallPrerequisites: true
        )
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertTrue(decoded.heroicInstallPrerequisites)
    }

    func testLibraryRoundTripsARealGameRecord() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossTests-\(UUID().uuidString)")
            .appendingPathComponent("games.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let game = Game(
            title: "Local Test Game",
            store: .local,
            artworkURL: URL(fileURLWithPath: "/tmp/Test Game/cover.png"),
            installationURL: URL(fileURLWithPath: "/tmp/Test Game"),
            executableURL: URL(fileURLWithPath: "/tmp/Test Game/game"),
            installationMethod: "Manual local import",
            compatibilityStatus: .notTested,
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = GameLibraryStore(fileURL: fileURL)

        try store.save([game])
        let loaded = store.load()

        XCTAssertEqual(loaded, [game])
    }

    func testOlderGameRecordsDefaultToUnconfirmedOwnershipEvidence() throws {
        let id = UUID()
        let data = Data("""
        {
          "id": "\(id.uuidString)",
          "title": "Legacy Game",
          "store": "steam",
          "compatibilityStatus": "notTested"
        }
        """.utf8)

        let game = try JSONDecoder().decode(Game.self, from: data)

        XCTAssertEqual(game.ownershipEvidence, .unknown)
        XCTAssertEqual(game.platform, .unknown)
    }

    func testGamePlatformInferenceIsConservative() {
        XCTAssertEqual(GamePlatform.inferred(from: URL(fileURLWithPath: "/Games/example.exe")), .windows)
        XCTAssertEqual(GamePlatform.inferred(from: URL(fileURLWithPath: "/Applications/example.app")), .nativeMacOS)
        XCTAssertEqual(GamePlatform.inferred(from: URL(fileURLWithPath: "/Applications/example.app/Contents/MacOS/example")), .nativeMacOS)
        XCTAssertEqual(GamePlatform.inferred(from: URL(fileURLWithPath: "/Games/example")), .unknown)
    }

    func testDownloadOperationStoreRoundTripsAndBoundsHistory() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossDownloadTests-\(UUID().uuidString)")
            .appendingPathComponent("download-operations.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        var operation = DownloadOperation(
            gameID: UUID(),
            gameTitle: "Example Game",
            kind: .install,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            detail: String(repeating: "x", count: 10_000)
        )
        XCTAssertEqual(operation.detail.count, DownloadOperation.maximumDetailLength)
        operation.update(
            state: .failed,
            fraction: 1.5,
            detail: "The operation failed.",
            error: "Network unavailable.",
            finishedAt: Date(timeIntervalSince1970: 1_700_000_100),
            at: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let store = DownloadOperationStore(fileURL: fileURL)
        try store.save([operation])
        let loaded = store.load()

        XCTAssertEqual(loaded, [operation])
        XCTAssertEqual(loaded.first?.fraction, 1)
        XCTAssertEqual(loaded.first?.detail, "The operation failed.")
    }

    func testDownloadOperationRunningStateCanBeMarkedForRecovery() {
        var operation = DownloadOperation(
            gameID: UUID(),
            gameTitle: "Interrupted Game",
            kind: .update,
            detail: "Downloading…"
        )

        operation.update(
            state: .recoveryRequired,
            detail: "The app closed before verification.",
            error: "Interrupted.",
            at: Date(timeIntervalSince1970: 1_700_000_200)
        )

        XCTAssertEqual(operation.state, .recoveryRequired)
        XCTAssertEqual(operation.error, "Interrupted.")
        XCTAssertNil(operation.finishedAt)
    }

    func testAccountBackedOwnershipEvidenceSurvivesLibraryRoundTrip() throws {
        let game = Game(
            title: "Visible Steam Game",
            store: .steam,
            storeApplicationID: "12345",
            ownershipEvidence: .steamWebAPI
        )
        let data = try JSONEncoder().encode(game)

        let decoded = try JSONDecoder().decode(Game.self, from: data)

        XCTAssertEqual(decoded.ownershipEvidence, .steamWebAPI)
    }

    func testLibraryMergePromotesAContainedLocalExecutableWithoutCreatingADuplicate() {
        let installationURL = URL(fileURLWithPath: "/Games/Example Game")
        let executableURL = installationURL.appendingPathComponent("Example.exe")
        let localGame = Game(
            title: "Example",
            store: .local,
            ownershipEvidence: .userSelectedLocal,
            installationURL: installationURL,
            executableURL: executableURL,
            isFavorite: true,
            categories: ["RPG"]
        )
        let steamGame = Game(
            title: "Example Game",
            store: .steam,
            storeApplicationID: "12345",
            ownershipEvidence: .steamLocalManifest,
            installationURL: installationURL,
            installationMethod: "Steam local library manifest"
        )

        let merged = GameLibraryMergeService.merge(existing: [localGame], imported: [steamGame])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.store, .steam)
        XCTAssertEqual(merged.first?.storeApplicationID, "12345")
        XCTAssertEqual(merged.first?.executableURL, executableURL)
        XCTAssertEqual(merged.first?.ownershipEvidence, .steamLocalManifest)
        XCTAssertTrue(merged.first?.isFavorite == true)
        XCTAssertEqual(merged.first?.categories, ["RPG"])
    }

    func testLibraryMergeDoesNotUseSimilarTitlesToCombineDifferentInstallations() {
        let first = Game(
            title: "Example",
            store: .local,
            installationURL: URL(fileURLWithPath: "/Games/Example-A"),
            executableURL: URL(fileURLWithPath: "/Games/Example-A/game.exe")
        )
        let second = Game(
            title: "Example",
            store: .steam,
            storeApplicationID: "67890",
            ownershipEvidence: .steamLocalManifest,
            installationURL: URL(fileURLWithPath: "/Games/Example-B")
        )

        let merged = GameLibraryMergeService.merge(existing: [first], imported: [second])

        XCTAssertEqual(merged.count, 2)
    }

    func testLaunchRejectsMissingExecutableInsteadOfInventingSuccess() async {
        let game = Game(title: "Missing", store: .local)

        do {
            _ = try await GameLaunchService().launch(game)
            XCTFail("A game without an executable must not launch successfully.")
        } catch let error as GameLaunchError {
            XCTAssertEqual(error.errorDescription, "This game has no executable selected.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testImportsOnlyTheSelectedSteamLibraryManifests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossSteamTests-\(UUID().uuidString)")
        let steamApps = root.appendingPathComponent("steamapps", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)

        let manifest = #"""
        "AppState"
        {
            "appid" "12345"
            "name" "Example Game"
            "installdir" "Example Game"
        }
        """#
        let manifestURL = steamApps.appendingPathComponent("appmanifest_12345.acf")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let games = try SteamLibraryImporter().importGames(from: root)

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.store, .steam)
        XCTAssertEqual(games.first?.storeApplicationID, "12345")
        XCTAssertEqual(games.first?.ownershipEvidence, .steamLocalManifest)
        XCTAssertEqual(games.first?.title, "Example Game")
        XCTAssertEqual(games.first?.platform, .unknown)
        XCTAssertEqual(games.first?.compatibilityStatus, .notTested)
        XCTAssertNil(games.first?.installationURL)
    }

    func testSteamManifestRecordsAnInstallationOnlyWhenTheDirectoryExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossSteamInstallStateTests-\(UUID().uuidString)")
        let steamApps = root.appendingPathComponent("steamapps", isDirectory: true)
        let installDirectory = steamApps
            .appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent("Example Game", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        let manifest = #"""
        "AppState"
        {
            "appid" "12345"
            "name" "Example Game"
            "installdir" "Example Game"
        }
        """#
        try manifest.write(
            to: steamApps.appendingPathComponent("appmanifest_12345.acf"),
            atomically: true,
            encoding: .utf8
        )

        let games = try SteamLibraryImporter().importGames(from: root)

        XCTAssertEqual(games.first?.installationURL, installDirectory.standardizedFileURL)
    }

    func testImportsExistingHeroicInstallationEvidenceWithoutCredentials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossHeroicTests-\(UUID().uuidString)")
        let installationURL = root.appendingPathComponent("Example Game", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: installationURL, withIntermediateDirectories: true)

        let executableURL = installationURL.appendingPathComponent("Example.exe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("MZ".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let installedJSON = root.appendingPathComponent("installed.json")
        let payload = """
        {
          "ExampleGame": {
            "install_path": "\(installationURL.path)",
            "executable": "Example.exe",
            "version": "1.0",
            "platform": "Windows"
          }
        }
        """
        try payload.write(to: installedJSON, atomically: true, encoding: .utf8)

        let games = try HeroicLibraryImporter().importGames(from: installedJSON)

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.store, .epic)
        XCTAssertEqual(games.first?.storeApplicationID, "ExampleGame")
        XCTAssertEqual(games.first?.ownershipEvidence, .heroicInstalledCache)
        XCTAssertEqual(games.first?.platform, .windows)
        XCTAssertEqual(games.first?.installationURL, installationURL.standardizedFileURL)
        XCTAssertEqual(games.first?.executableURL, executableURL.standardizedFileURL)
        XCTAssertEqual(games.first?.compatibilityStatus, .notTested)
    }

    func testHeroicLaunchURLUsesTheSupportedQueryProtocol() throws {
        let url = try HeroicLaunchService.launchURL(appName: "Example Game / EU")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try XCTUnwrap(components.queryItems)

        XCTAssertEqual(components.scheme, "heroic")
        XCTAssertEqual(components.host, "launch")
        XCTAssertEqual(queryItems.first(where: { $0.name == "appName" })?.value, "Example Game / EU")
        XCTAssertEqual(queryItems.first(where: { $0.name == "runner" })?.value, "legendary")
    }

    func testHeroicImportRecordsTheSelectedLegendaryConfigurationDirectory() {
        let fileURL = URL(fileURLWithPath: "/tmp/legendary-config/installed.json")

        XCTAssertEqual(
            HeroicLibraryImporter().configurationDirectory(for: fileURL),
            URL(fileURLWithPath: "/tmp/legendary-config").standardizedFileURL
        )
    }

    func testHeroicInstallArgumentsUseTheMaintainedLegendaryInstallShape() throws {
        let arguments = try HeroicInstallService.installArguments(
            applicationName: "Example Game",
            baseDirectory: URL(fileURLWithPath: "/Games")
        )

        XCTAssertEqual(
            arguments,
            [
                "install", "Example Game",
                "--platform", "Windows",
                "--base-path", "/Games",
                "--skip-dlcs", "--skip-sdl", "--no-install", "-y"
            ]
        )
    }

    func testHeroicInstallCanExplicitlyAllowPrerequisiteInstallers() throws {
        let arguments = try HeroicInstallService.installArguments(
            applicationName: "Example Game",
            baseDirectory: URL(fileURLWithPath: "/Games"),
            installPrerequisites: true
        )

        XCTAssertFalse(arguments.contains("--no-install"))
    }

    func testHeroicInstallRejectsPathLikeApplicationNames() {
        XCTAssertThrowsError(
            try HeroicInstallService.installArguments(
                applicationName: "../unsafe",
                baseDirectory: URL(fileURLWithPath: "/Games")
            )
        ) { error in
            XCTAssertEqual(
                (error as? HeroicInstallError)?.errorDescription,
                "The Heroic application name is missing or contains unsafe path characters."
            )
        }
    }

    func testHeroicLibraryDecodesAccountEntriesAndOmitsDLC() throws {
        let payload = #"""
        [
          {"app_name":"example-app","app_title":"Example Game","is_dlc":false},
          {"app_name":"example-dlc","app_title":"Example DLC","is_dlc":true},
          {"app_name":"untitled","is_dlc":false}
        ]
        """#

        let entries = try HeroicLibraryService.decodeLibrary(Data(payload.utf8))

        XCTAssertEqual(entries.map(\.appName), ["example-app", "untitled"])
        XCTAssertEqual(entries.map(\.title), ["Example Game", "untitled"])
    }

    func testHeroicLibraryUsesTheMaintainedListArguments() {
        XCTAssertEqual(
            HeroicLibraryService.libraryArguments,
            ["list", "--third-party", "--platform", "Windows", "--json"]
        )
    }

    func testHeroicGameInfoUsesTheWindowsJSONMetadataArguments() throws {
        XCTAssertEqual(
            try HeroicGameInfoService.infoArguments(applicationName: "ExampleGame"),
            ["info", "ExampleGame", "--json", "--platform", "Windows"]
        )
    }

    func testHeroicGameInfoDecodesDownloadAndDiskSizes() throws {
        let payload = #"""
        {
          "game": {"app_name": "ExampleGame", "title": "Example"},
          "manifest": {"download_size": 1234, "disk_size": 5678}
        }
        """#

        let estimate = try HeroicGameInfoService.decode(Data(payload.utf8))

        XCTAssertEqual(estimate.downloadBytes, 1234)
        XCTAssertEqual(estimate.diskBytes, 5678)
        XCTAssertEqual(estimate.minimumFreeBytes, 5678)
    }

    func testHeroicGameInfoRejectsMissingSizeMetadata() {
        let payload = #"{"manifest":{"download_size":null,"disk_size":null}}"#

        XCTAssertThrowsError(try HeroicGameInfoService.decode(Data(payload.utf8))) { error in
            XCTAssertEqual(
                (error as? HeroicGameInfoError)?.errorDescription,
                "Heroic returned game metadata without a reliable download or disk-size value."
            )
        }
    }

    func testHeroicInstallVerificationRequiresRecordedNonEmptyFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossHeroicVerificationTests-\(UUID().uuidString)")
        let configurationDirectory = root.appendingPathComponent("legendary", isDirectory: true)
        let installationDirectory = root.appendingPathComponent("Example Game", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installationDirectory, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: installationDirectory.appendingPathComponent("content.bin"))
        let installedJSON = """
        {
          "ExampleGame": {
            "install_path": "\(installationDirectory.path)",
            "executable": "missing.exe"
          }
        }
        """
        try installedJSON.write(
            to: configurationDirectory.appendingPathComponent("installed.json"),
            atomically: true,
            encoding: .utf8
        )

        let evidence = try HeroicInstallService.verifiedEvidence(
            applicationName: "ExampleGame",
            configurationDirectory: configurationDirectory
        )

        XCTAssertEqual(evidence.installationURL, installationDirectory.standardizedFileURL)
        XCTAssertNil(evidence.executableURL)
    }

    func testHeroicInstallVerificationRejectsAnInstallationOutsideTheSelectedBase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossHeroicBoundaryTests-\(UUID().uuidString)")
        let configurationDirectory = root.appendingPathComponent("legendary", isDirectory: true)
        let selectedBaseDirectory = root.appendingPathComponent("selected", isDirectory: true)
        let outsideInstallationDirectory = root.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectedBaseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideInstallationDirectory, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: outsideInstallationDirectory.appendingPathComponent("content.bin"))
        let installedJSON = """
        {
          "ExampleGame": {
            "install_path": "\(outsideInstallationDirectory.path)"
          }
        }
        """
        try installedJSON.write(
            to: configurationDirectory.appendingPathComponent("installed.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(
            try HeroicInstallService.verifiedEvidence(
                applicationName: "ExampleGame",
                configurationDirectory: configurationDirectory,
                requiredBaseDirectory: selectedBaseDirectory
            )
        ) { error in
            XCTAssertEqual(
                (error as? HeroicInstallError)?.errorDescription,
                "Heroic recorded the installation outside the selected base directory: \(outsideInstallationDirectory.path). The files were not marked installed."
            )
        }
    }

    func testHeroicUpdateArgumentsOnlyUpdateExistingInstallations() throws {
        let arguments = try HeroicInstallService.installArguments(
            applicationName: "ExampleGame",
            baseDirectory: URL(fileURLWithPath: "/tmp/Games"),
            updateOnly: true
        )

        XCTAssertEqual(
            arguments,
            [
                "install", "ExampleGame", "--platform", "Windows",
                "--base-path", "/tmp/Games", "--skip-dlcs", "--skip-sdl",
                "--no-install", "--update-only", "-y"
            ]
        )
    }

    func testHeroicMoveArgumentsValidateTheDestination() throws {
        XCTAssertEqual(
            try HeroicMoveService.makeArguments(
                applicationName: "ExampleGame",
                destinationDirectory: URL(fileURLWithPath: "/Volumes/Games")
            ),
            ["move", "ExampleGame", "/Volumes/Games"]
        )

        XCTAssertThrowsError(
            try HeroicMoveService.makeArguments(
                applicationName: "../unsafe",
                destinationDirectory: URL(fileURLWithPath: "/Volumes/Games")
            )
        )
    }

    func testHeroicUninstallReadsOnlyInstalledEntryNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossHeroicUninstallTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = #"{"ExampleGame":{"install_path":"/tmp/Example"}}"#
        try payload.write(
            to: root.appendingPathComponent("installed.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            HeroicUninstallService.installedEntries(in: root),
            ["ExampleGame"]
        )
    }

    func testHeroicUninstallArgumentsRequireConfirmationMode() throws {
        XCTAssertEqual(
            try HeroicUninstallService.makeArguments(
                applicationName: "ExampleGame",
                preserveFiles: true
            ),
            ["uninstall", "ExampleGame", "--keep-files", "-y"]
        )
    }

    func testRuntimeInspectionUsesTheSelectedExecutableAndSiblingWineboot() throws {
        let service = RuntimeDiagnosticsService()
        let report = service.collectReport()
        XCTAssertFalse(report.findings.isEmpty)
        let xcodeFinding = report.findings.first(where: { $0.title.contains("Xcode") })
        XCTAssertNotNil(xcodeFinding)
        if FileManager.default.fileExists(atPath: "/Volumes/sata ssd 1/Applications/Xcode.app") {
            XCTAssertEqual(xcodeFinding?.severity, .success)
        }
        let wineFinding = report.findings.first(where: { $0.title.contains("Wine") })
        XCTAssertNotNil(wineFinding)
        if wineFinding?.severity != .success {
            XCTAssertEqual(wineFinding?.fixActionKind, .installWine)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossRuntimeInspectionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wineURL = root.appendingPathComponent("wine")
        let winebootURL = root.appendingPathComponent("wineboot")
        try "#!/bin/sh\necho wine-test\n".write(to: wineURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho wineboot-test\n".write(to: winebootURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: winebootURL.path)

        let runtime = try XCTUnwrap(RuntimeDiagnosticsService().inspectRuntime(at: wineURL))

        XCTAssertEqual(runtime.executableURL, wineURL.standardizedFileURL)
        XCTAssertEqual(runtime.winebootURL, winebootURL.standardizedFileURL)
        XCTAssertEqual(runtime.version, "wine-test")

        let findings = RuntimeDiagnosticsService().healthCheck(for: runtime)
        XCTAssertTrue(findings.contains(where: { $0.title == "Runtime executable responds" }))
        XCTAssertTrue(findings.contains(where: { $0.title == "wineboot available" }))
    }

    func testRuntimeIdentifierIsStableForTheSameExecutablePath() {
        let executableURL = URL(fileURLWithPath: "/usr/local/bin/wine")
        let equivalentURL = URL(fileURLWithPath: "/usr/local/bin/./wine")
        let differentURL = URL(fileURLWithPath: "/usr/local/bin/wine64")

        XCTAssertEqual(
            RuntimeDiagnosticsService.stableIdentifier(for: executableURL),
            RuntimeDiagnosticsService.stableIdentifier(for: equivalentURL)
        )
        XCTAssertNotEqual(
            RuntimeDiagnosticsService.stableIdentifier(for: executableURL),
            RuntimeDiagnosticsService.stableIdentifier(for: differentURL)
        )
    }

    func testSteamOpenIDFormEncodingEscapesSpecialCharactersCorrectly() {
        let items = [
            URLQueryItem(name: "openid.mode", value: "check_authentication"),
            URLQueryItem(name: "openid.sig", value: "a+b/c=="),
            URLQueryItem(name: "openid.signed", value: "mode,sig")
        ]
        let encoded = SteamOpenIDService.encodeFormParameters(items)
        XCTAssertTrue(encoded.contains("openid.mode=check_authentication"))
        XCTAssertTrue(encoded.contains("openid.sig=a%2Bb%2Fc%3D%3D"))
        XCTAssertTrue(encoded.contains("openid.signed=mode%2Csig"))
    }

    func testSteamLibraryImporterDiscoversAvailableDefaultLibraries() {
        let libraries = SteamLibraryImporter.defaultSteamLibraryURLs()
        for url in libraries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testSteamLaunchURLUsesTheOfficialRunProtocol() throws {
        let url = try SteamLaunchService.launchURL(applicationID: "730")

        XCTAssertEqual(url.scheme, "steam")
        XCTAssertEqual(url.host, "run")
        XCTAssertEqual(url.path, "/730")
    }

    func testSteamOpenIDAuthorizationURLUsesTheDelegatedCallbackContract() throws {
        let url = try SteamOpenIDService.authorizationURL()
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try XCTUnwrap(components.queryItems)

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "steamcommunity.com")
        XCTAssertEqual(queryItems.first(where: { $0.name == "openid.mode" })?.value, "checkid_setup")
        XCTAssertEqual(queryItems.first(where: { $0.name == "openid.return_to" })?.value, "overcross://steam-auth")
        XCTAssertEqual(queryItems.first(where: { $0.name == "openid.realm" })?.value, "overcross://")
        XCTAssertNil(queryItems.first(where: { $0.name == "password" }))
    }

    func testSteamOpenIDCallbackRequiresTheInitiatedSteamEndpointAndRealm() throws {
        let validURL = try XCTUnwrap(URL(string: "overcross://steam-auth?openid.ns=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0&openid.mode=id_res&openid.op_endpoint=https%3A%2F%2Fsteamcommunity.com%2Fopenid%2Flogin&openid.realm=overcross%3A%2F%2F&openid.return_to=overcross%3A%2F%2Fsteam-auth&openid.claimed_id=https%3A%2F%2Fsteamcommunity.com%2Fopenid%2Fid%2F76561198000000000"))
        let invalidURL = try XCTUnwrap(URL(string: "overcross://steam-auth?openid.ns=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0&openid.mode=id_res&openid.op_endpoint=https%3A%2F%2Fsteamcommunity.com%2Fopenid%2Fother&openid.realm=overcross%3A%2F%2F&openid.return_to=overcross%3A%2F%2Fsteam-auth&openid.claimed_id=https%3A%2F%2Fsteamcommunity.com%2Fopenid%2Fid%2F76561198000000000"))

        let validated = try SteamOpenIDService.validatedCallback(validURL)
        XCTAssertEqual(validated.steamID, "76561198000000000")

        XCTAssertThrowsError(try SteamOpenIDService.validatedCallback(invalidURL)) { error in
            guard case SteamOpenIDError.authenticationRejected = error else {
                return XCTFail("Expected authentication rejection, received \(error)")
            }
        }
    }

    func testSteamOpenIDExtractsOnlyNumericSteamIDsFromClaimedIDs() throws {
        XCTAssertEqual(
            try SteamOpenIDService.steamID(fromClaimedID: "http://steamcommunity.com/openid/id/76561198000000000"),
            "76561198000000000"
        )
        XCTAssertThrowsError(
            try SteamOpenIDService.steamID(fromClaimedID: "https://example.com/openid/id/76561198000000000")
        )
    }

    func testSteamLoopbackListenerBindsToValidPortAndReceivesCallback() async throws {
        let listener = try SteamLoopbackListener()
        XCTAssertTrue(listener.port > 0)
        let port = listener.port

        async let callbackTask = listener.waitForCallback()

        let url = URL(string: "http://127.0.0.1:\(port)/callback?test=success")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        let html = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(html.contains("Authentication Received"))

        let receivedURL = try await callbackTask
        XCTAssertEqual(receivedURL.absoluteString, "http://127.0.0.1:\(port)/callback?test=success")
    }

    func testSteamWebAPIDecodesVisibleOwnedGamesWithoutAppData() throws {
        let payload = #"{"response":{"game_count":1,"games":[{"appid":730,"name":"Counter-Strike 2","playtime_forever":120}]}}"#

        let games = try SteamWebAPIClient.decodeOwnedGames(Data(payload.utf8))

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.appID, 730)
        XCTAssertEqual(games.first?.name, "Counter-Strike 2")
        XCTAssertEqual(games.first?.playtimeForeverMinutes, 120)
    }

    func testSteamWebAPIRequestUsesValidGETShape() throws {
        let apiKey = "test-secret-key"
        let request = try SteamWebAPIClient.makeRequest(
            steamID: "76561198000000000",
            apiKey: apiKey
        )

        XCTAssertEqual(request.httpMethod, "GET")
        guard let urlString = request.url?.absoluteString else {
            XCTFail("Missing request URL")
            return
        }
        XCTAssertTrue(urlString.contains("key=test-secret-key"))
        XCTAssertTrue(urlString.contains("steamid=76561198000000000"))
        XCTAssertTrue(urlString.contains("include_appinfo=1"))
    }

    func testPrefixCreationRejectsPathTraversalNames() async {
        let runtime = DetectedRuntime(
            name: "Test runtime",
            executableURL: URL(fileURLWithPath: "/tmp/wine"),
            winebootURL: nil,
            version: "test",
            architecture: "unknown",
            status: "test"
        )

        do {
            _ = try await WinePrefixService().createPrefix(
                name: "../unsafe",
                rootURL: FileManager.default.temporaryDirectory,
                runtime: runtime,
                architecture: .win64
            )
            XCTFail("Prefix traversal names must be rejected.")
        } catch let error as WinePrefixError {
            XCTAssertEqual(error.errorDescription, "Prefix names may not be empty or contain path separators.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPrefixArchiveRestoresAndRemovesOnlyManagedPrefix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossPrefixArchiveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sourcePrefixURL = root.appendingPathComponent("source-prefix", isDirectory: true)
        let backupDestination = root.appendingPathComponent("backups", isDirectory: true)
        let managedRoot = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePrefixURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sourcePrefixURL.appendingPathComponent("drive_c", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("registry".utf8).write(to: sourcePrefixURL.appendingPathComponent("system.reg"))
        try FileManager.default.createDirectory(at: backupDestination, withIntermediateDirectories: true)

        let prefix = WinePrefix(
            name: "Example Prefix",
            url: sourcePrefixURL,
            runtimeURL: URL(fileURLWithPath: "/tmp/wine"),
            architecture: .win64
        )
        let service = WinePrefixArchiveService()

        let archiveURL = try service.backup(prefix: prefix, to: backupDestination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.appendingPathComponent("metadata.json").path))

        let restored = try service.restore(archiveURL: archiveURL, into: managedRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.url.appendingPathComponent("system.reg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.url.appendingPathComponent("drive_c").path))

        try service.remove(prefix: restored, from: managedRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePrefixURL.appendingPathComponent("system.reg").path))
    }

    func testProfileSelectionRequiresExactVerifiedStoreMatch() {
        let game = Game(title: "Example", store: .steam, storeApplicationID: "123")
        let untested = CompatibilityProfile(store: .steam, storeApplicationID: "123")
        let verifiedDifferentGame = CompatibilityProfile(
            store: .steam,
            storeApplicationID: "456",
            testResult: .working
        )
        let verified = CompatibilityProfile(
            store: .steam,
            storeApplicationID: "123",
            testEnvironment: "fixture runtime",
            testResult: .working
        )
        let selector = CompatibilityProfileSelectionService()

        XCTAssertNil(selector.verifiedProfile(for: game, profiles: [untested, verifiedDifferentGame]))
        XCTAssertEqual(selector.verifiedProfile(for: game, profiles: [untested, verifiedDifferentGame, verified]), verified)
    }

    func testCompatibilityProfileRequiresRecordedTestEnvironmentEvidence() {
        let game = Game(title: "Example", store: .steam, storeApplicationID: "123")
        let claimedWorking = CompatibilityProfile(
            store: .steam,
            storeApplicationID: "123",
            testResult: .working
        )
        let selector = CompatibilityProfileSelectionService()

        XCTAssertFalse(claimedWorking.isVerified)
        XCTAssertNil(selector.verifiedProfile(for: game, profiles: [claimedWorking]))
    }

    func testCompatibilityProfileStoreImportsISO8601ProfileLists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossProfileImportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profileURL = root.appendingPathComponent("profiles.json")
        let profile = CompatibilityProfile(
            store: .epic,
            storeApplicationID: "example-game",
            lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            testEnvironment: "Apple Silicon fixture",
            testResult: .partiallyWorking
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: profileURL)

        let imported = try CompatibilityProfileStore().importProfiles(from: profileURL)

        XCTAssertEqual(imported, [profile])
        XCTAssertTrue(imported[0].isVerified)
    }

    func testWindowsLaunchRequiresARealRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossLaunchTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appendingPathComponent("game.exe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("MZ".utf8))

        let game = Game(title: "Windows game", store: .local, executableURL: executableURL)
        let runtime = DetectedRuntime(
            name: "Missing runtime",
            executableURL: root.appendingPathComponent("wine"),
            version: "unknown",
            architecture: "unknown",
            status: "missing"
        )
        let prefix = WinePrefix(
            name: "test",
            url: root,
            runtimeURL: runtime.executableURL,
            architecture: .win64
        )

        do {
            _ = try await GameLaunchService().launchWindows(game: game, runtime: runtime, prefix: prefix)
            XCTFail("Windows launch must reject a missing runtime.")
        } catch let error as GameLaunchError {
            XCTAssertEqual(error.errorDescription, "A Windows game requires a detected compatibility runtime.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRuntimeStoreRoundTripsUserSelectedRuntimeRecords() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossRuntimeStoreTests-\(UUID().uuidString)")
            .appendingPathComponent("runtimes.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let runtime = DetectedRuntime(
            name: "Selected runtime",
            executableURL: URL(fileURLWithPath: "/opt/example/wine"),
            winebootURL: URL(fileURLWithPath: "/opt/example/wineboot"),
            version: "wine-10.0",
            architecture: "arm64",
            status: "Selected; prefix creation available"
        )
        let store = RuntimeStore(fileURL: fileURL)

        try store.save([runtime])

        XCTAssertEqual(store.load(), [runtime])
    }

    func testRuntimeBundleInstallerVerifiesChecksumAndCopiesBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossRuntimeBundleTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let binDirectory = sourceRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let wineURL = binDirectory.appendingPathComponent("wine")
        let winebootURL = binDirectory.appendingPathComponent("wineboot")
        try "#!/bin/sh\nexit 0\n".write(to: wineURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: winebootURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: winebootURL.path)

        let checksum = try RuntimeBundleInstaller.sha256(of: wineURL)
        let installed = try RuntimeBundleInstaller().install(
            sourceRootURL: sourceRoot,
            executableRelativePath: "bin/wine",
            expectedSHA256: checksum,
            managedRootURL: root.appendingPathComponent("managed", isDirectory: true)
        )

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.executableURL.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.rootURL.appendingPathComponent("bin/wineboot").path))
        XCTAssertEqual(try RuntimeBundleInstaller.sha256(of: installed.executableURL), checksum)
    }

    func testRuntimeBundleInstallerRejectsChecksumMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossRuntimeChecksumTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let binDirectory = root.appendingPathComponent("runtime/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let wineURL = binDirectory.appendingPathComponent("wine")
        let winebootURL = binDirectory.appendingPathComponent("wineboot")
        try Data("wine".utf8).write(to: wineURL)
        try Data("wineboot".utf8).write(to: winebootURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: winebootURL.path)

        XCTAssertThrowsError(try RuntimeBundleInstaller().install(
            sourceRootURL: root.appendingPathComponent("runtime"),
            executableRelativePath: "bin/wine",
            expectedSHA256: String(repeating: "0", count: 64),
            managedRootURL: root.appendingPathComponent("managed")
        )) { error in
            guard case RuntimeBundleInstallError.checksumMismatch = error else {
                return XCTFail("Expected a checksum mismatch, received \(error)")
            }
        }
    }

    func testWindowsLaunchRejectsAnUnverifiedPrefix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossUnverifiedPrefixTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appendingPathComponent("game.exe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("MZ".utf8))

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            name: "Harness runtime",
            executableURL: runtimeURL,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(
            name: "Unverified prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(title: "Unverified prefix game", store: .local, executableURL: executableURL)

        do {
            _ = try await GameLaunchService().launchWindows(game: game, runtime: runtime, prefix: prefix)
            XCTFail("An unverified prefix must not be launched.")
        } catch let error as GameLaunchError {
            XCTAssertEqual(error.errorDescription, "The selected compatibility prefix is missing system.reg or drive_c and is not verified.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWindowsLaunchProcessHarnessCapturesConfigurationAndOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossLaunchHarnessTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        let executableURL = root.appendingPathComponent("game.exe")
        try "#!/bin/sh\nprintf '%s|%s|%s|%s\\n' \"$WINEPREFIX\" \"$WINEARCH\" \"$OVERCROSS_TEST\" \"$1\"\n"
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            id: UUID(),
            name: "Process harness",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(
            name: "Harness prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(
            title: "Harness game",
            store: .local,
            storeApplicationID: "harness-game",
            installationURL: root,
            executableURL: executableURL
        )
        let profile = CompatibilityProfile(
            store: .local,
            storeApplicationID: "harness-game",
            runtimeIdentifier: runtime.id.uuidString,
            prefixArchitecture: .win64,
            launchArguments: ["hello"],
            environment: ["OVERCROSS_TEST": "yes"],
            testEnvironment: "Process harness",
            testResult: .working
        )

        let outcome = try await GameLaunchService().launchWindows(
            game: game,
            runtime: runtime,
            prefix: prefix,
            profile: profile
        )

        XCTAssertEqual(outcome.exitStatus, 0)
        XCTAssertTrue(outcome.standardOutput.contains("\(root.path)|win64|yes|hello"))
    }

    func testWindowsLaunchRejectsAProfileForADifferentExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossProfileExecutableTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        let executableURL = root.appendingPathComponent("actual.exe")
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            name: "Process harness",
            executableURL: runtimeURL,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(name: "Harness prefix", url: root, runtimeURL: runtimeURL, architecture: .win64)
        let game = Game(
            title: "Profile executable game",
            store: .local,
            storeApplicationID: "profile-executable-game",
            installationURL: root,
            executableURL: executableURL
        )
        let profile = CompatibilityProfile(
            store: .local,
            storeApplicationID: "profile-executable-game",
            executableRelativePath: "different.exe",
            testEnvironment: "Harness",
            testResult: .working
        )

        do {
            _ = try await GameLaunchService().launchWindows(game: game, runtime: runtime, prefix: prefix, profile: profile)
            XCTFail("A profile for another executable must not be used to launch this game.")
        } catch let error as GameLaunchError {
            XCTAssertEqual(error.errorDescription, "The selected compatibility profile points to a different executable.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWindowsLaunchRejectsAProfileThatRequiresAnExternalLauncher() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossRequiredLauncherTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appendingPathComponent("game.exe")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("system.reg"))

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            name: "Process harness",
            executableURL: runtimeURL,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(name: "Harness prefix", url: root, runtimeURL: runtimeURL, architecture: .win64)
        let game = Game(
            title: "Launcher-required game",
            store: .steam,
            storeApplicationID: "launcher-required-game",
            installationURL: root,
            executableURL: executableURL
        )
        let profile = CompatibilityProfile(
            store: .steam,
            storeApplicationID: "launcher-required-game",
            requiredLauncher: "Steam",
            testEnvironment: "Harness",
            testResult: .working
        )

        do {
            _ = try await GameLaunchService().launchWindows(game: game, runtime: runtime, prefix: prefix, profile: profile)
            XCTFail("A profile requiring Steam must not be launched directly through Wine.")
        } catch let error as GameLaunchError {
            guard case .profileRequiresLauncher("Steam") = error else {
                return XCTFail("Expected a required-launcher error, received \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWindowsLaunchRejectsAProfileForADifferentPrefix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossProfilePrefixTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appendingPathComponent("game.exe")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("system.reg"))

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            name: "Process harness",
            executableURL: runtimeURL,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(name: "Selected prefix", url: root, runtimeURL: runtimeURL, architecture: .win64)
        let game = Game(
            title: "Prefix-specific game",
            store: .local,
            storeApplicationID: "prefix-specific-game",
            installationURL: root,
            executableURL: executableURL
        )
        let profile = CompatibilityProfile(
            store: .local,
            storeApplicationID: "prefix-specific-game",
            prefixID: UUID(),
            testEnvironment: "Harness",
            testResult: .working
        )

        do {
            _ = try await GameLaunchService().launchWindows(game: game, runtime: runtime, prefix: prefix, profile: profile)
            XCTFail("A profile bound to a different prefix must not be launched.")
        } catch let error as GameLaunchError {
            guard case .profilePrefixDoesNotMatch = error else {
                return XCTFail("Expected a prefix-mismatch error, received \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLaunchLogStoreBoundsStreamsAndRoundTrips() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossLogTests-\(UUID().uuidString)")
            .appendingPathComponent("launch-logs.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let longOutput = String(repeating: "x", count: LaunchLogRecord.maximumStreamLength + 100)
        let record = LaunchLogRecord(
            gameID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_001),
            kind: .native,
            exitStatus: 0,
            summary: "Process exited successfully.",
            standardOutput: longOutput
        )
        let store = LaunchLogStore(fileURL: fileURL)

        try store.save([record])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.standardOutput.count, LaunchLogRecord.maximumStreamLength)
        XCTAssertEqual(loaded.first?.summary, record.summary)
    }

    func testStorageUsageMeasuresInstalledGameFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossStorageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("game.bin")
        try Data(repeating: 1, count: 32).write(to: fileURL)

        let game = Game(
            title: "Storage test",
            store: .local,
            installationURL: root
        )
        XCTAssertGreaterThanOrEqual(StorageUsageService().usage(for: game) ?? 0, 32)
    }

    func testApplicationCacheCleanupRemovesOnlyOwnedCacheContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        let nested = cache.appendingPathComponent("metadata", isDirectory: true)
        let outside = root.appendingPathComponent("game.bin")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: nested.appendingPathComponent("cover.data"))
        try Data(repeating: 2, count: 32).write(to: outside)

        let service = ApplicationCacheService(rootURL: cache)
        XCTAssertGreaterThanOrEqual(service.usage(), 64)

        try service.clear()

        XCTAssertEqual(service.usage(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    func testApplicationCacheCleanupRejectsAFileAsItsRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossCacheRootTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)

        XCTAssertThrowsError(try ApplicationCacheService(rootURL: root).clear()) { error in
            guard case ApplicationCacheError.invalidRoot = error else {
                return XCTFail("Expected an invalid cache root error, received \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testApplicationCacheCleanupRejectsASymbolicLinkRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossCacheSymlinkTests-\(UUID().uuidString)")
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("Cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("protected".utf8).write(to: target.appendingPathComponent("file.data"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try ApplicationCacheService(rootURL: link).clear()) { error in
            guard case ApplicationCacheError.invalidRoot = error else {
                return XCTFail("Expected a symbolic-link root error, received \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("file.data").path))
    }

    func testSteamArtworkPortraitAndHeaderURLs() {
        let portrait = SteamArtwork.libraryPortraitURL(forAppID: "1091500")
        XCTAssertEqual(portrait?.absoluteString, "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/1091500/library_600x900.jpg")

        let header = SteamArtwork.headerURL(forAppID: "1091500")
        XCTAssertEqual(header?.absoluteString, "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/1091500/header.jpg")

        XCTAssertNil(SteamArtwork.libraryPortraitURL(forAppID: ""))
        XCTAssertNil(SteamArtwork.libraryPortraitURL(forAppID: "   "))
        XCTAssertNil(SteamArtwork.libraryPortraitURL(forAppID: "invalid"))
        XCTAssertNil(SteamArtwork.headerURL(forAppID: "0"))
        XCTAssertNil(SteamArtwork.headerURL(forAppID: "-50"))
    }

    func testHeroicArtworkExtractionFromLegendaryMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossHeroicArtTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let metaDir = root.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)

        let json = """
        {
          "app_name": "TestEpicGame",
          "keyImages": [
            {
              "type": "DieselGameBoxTall",
              "url": "https://cdn.example.com/cover_tall.jpg"
            },
            {
              "type": "Thumbnail",
              "url": "https://cdn.example.com/thumb.jpg"
            }
          ]
        }
        """
        let metaFile = metaDir.appendingPathComponent("TestEpicGame.json")
        try json.data(using: .utf8)?.write(to: metaFile)

        let artwork = HeroicArtworkService.resolveArtworkURL(appName: "TestEpicGame", configurationDirectory: root)
        XCTAssertEqual(artwork?.absoluteString, "https://cdn.example.com/cover_tall.jpg")

        XCTAssertNil(HeroicArtworkService.resolveArtworkURL(appName: "", configurationDirectory: root))
    }

    func testAppSettingsAppleSiliconPerformanceDefaultsAndRoundTrip() throws {
        let settings = AppSettings(preferredInstallDirectory: nil)
        XCTAssertFalse(settings.metalHUDEnabled)
        XCTAssertTrue(settings.msyncEnabled)
        XCTAssertFalse(settings.esyncEnabled)
        XCTAssertFalse(settings.retinaScalingEnabled)
        XCTAssertEqual(settings.defaultGraphicsBackend, .automatic)

        var custom = settings
        custom.metalHUDEnabled = true
        custom.msyncEnabled = false
        custom.esyncEnabled = true
        custom.retinaScalingEnabled = true
        custom.defaultGraphicsBackend = .dxvk

        let encoded = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        XCTAssertTrue(decoded.metalHUDEnabled)
        XCTAssertFalse(decoded.msyncEnabled)
        XCTAssertTrue(decoded.esyncEnabled)
        XCTAssertTrue(decoded.retinaScalingEnabled)
        XCTAssertEqual(decoded.defaultGraphicsBackend, .dxvk)
    }

    func testGameCustomLaunchArgumentsAndEnvironmentOverridesRoundTrip() throws {
        let game = Game(
            title: "Overridden Game",
            store: .local,
            customLaunchArguments: ["-novid", "-fullscreen"],
            customEnvironment: ["ENABLE_FEATURE": "1", "LANG": "C"],
            metalHUDEnabled: true,
            msyncEnabled: false,
            esyncEnabled: true,
            retinaScalingEnabled: true
        )

        let encoded = try JSONEncoder().encode(game)
        let decoded = try JSONDecoder().decode(Game.self, from: encoded)

        XCTAssertEqual(decoded.customLaunchArguments, ["-novid", "-fullscreen"])
        XCTAssertEqual(decoded.customEnvironment, ["ENABLE_FEATURE": "1", "LANG": "C"])
        XCTAssertEqual(decoded.metalHUDEnabled, true)
        XCTAssertEqual(decoded.msyncEnabled, false)
        XCTAssertEqual(decoded.esyncEnabled, true)
        XCTAssertEqual(decoded.retinaScalingEnabled, true)
    }

    func testWinePrefixServiceInspectsComponents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossPrefixInspectTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sys32 = root.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        try FileManager.default.createDirectory(at: sys32, withIntermediateDirectories: true)
        try Data().write(to: sys32.appendingPathComponent("vcruntime140.dll"))
        try Data().write(to: sys32.appendingPathComponent("dxgi.dll"))

        let service = WinePrefixService()
        let components = service.inspectComponents(at: root)
        XCTAssertGreaterThan(components.count, 5)

        let vcruntime = components.first(where: { $0.id == "vcrun2015_vcruntime" })
        XCTAssertNotNil(vcruntime)
        XCTAssertTrue(vcruntime?.isInstalled ?? false)

        let dxgi = components.first(where: { $0.id == "dx11_dxgi" })
        XCTAssertNotNil(dxgi)
        XCTAssertTrue(dxgi?.isInstalled ?? false)

        let mscoree = components.first(where: { $0.id == "mscoree" })
        XCTAssertNotNil(mscoree)
        XCTAssertFalse(mscoree?.isInstalled ?? true)
    }

    func testWinePrefixArchiveCreatesZipBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossZipTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let prefixURL = root.appendingPathComponent("TestPrefix", isDirectory: true)
        let driveC = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
        try Data("dummy reg".utf8).write(to: prefixURL.appendingPathComponent("system.reg"))

        let destDir = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let prefix = WinePrefix(
            name: "TestPrefix",
            url: prefixURL,
            runtimeURL: URL(fileURLWithPath: "/usr/bin/true"),
            architecture: .win64
        )

        let archiveService = WinePrefixArchiveService()
        let zipURL = try await archiveService.createZipBackup(prefix: prefix, to: destDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertTrue(zipURL.pathExtension.lowercased() == "zip")
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let size = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    func testWinePrefixPreflightRedistributables() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossPreflightTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let driveC = root.appendingPathComponent("drive_c", isDirectory: true)
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
        try Data("dummy reg".utf8).write(to: root.appendingPathComponent("system.reg"))

        let winebootScript = root.appendingPathComponent("wineboot")
        try "#!/bin/sh\nprintf 'wineboot %s\\n' \"$1\"\n"
            .write(to: winebootScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: winebootScript.path)

        let runtime = DetectedRuntime(
            id: UUID(),
            name: "Preflight runtime",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            winebootURL: winebootScript,
            version: "1.0",
            architecture: "arm64",
            status: "ready"
        )

        let service = WinePrefixService()
        let outcome = try await service.preflightRedistributables(
            prefixURL: root,
            runtime: runtime,
            architecture: .win64
        )
        XCTAssertEqual(outcome.exitStatus, 0)
        XCTAssertTrue(outcome.standardOutput.contains("wineboot -u"))
    }

    func testWindowsLaunchProcessHarnessCapturesPerformanceEnvironmentAndCustomArgs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossLaunchPerfHarnessTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        let executableURL = root.appendingPathComponent("game.exe")
        try "#!/bin/sh\nprintf '%s|%s|%s|%s|%s|%s|%s\\n' \"$MTL_HUD_ENABLED\" \"$WINEMSYNC\" \"$WINE_ENABLE_RETINA\" \"$OVERCROSS_GRAPHICS_BACKEND\" \"$CUSTOM_KEY\" \"$1\" \"$2\"\n"
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            id: UUID(),
            name: "Process harness",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(
            name: "Harness prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(
            title: "Harness Perf Game",
            store: .local,
            storeApplicationID: "harness-perf-game",
            installationURL: root,
            executableURL: executableURL,
            customLaunchArguments: ["custom_arg1", "custom_arg2"],
            customEnvironment: ["CUSTOM_KEY": "custom_val"],
            metalHUDEnabled: true,
            msyncEnabled: true,
            retinaScalingEnabled: true
        )
        let settings = AppSettings(
            preferredInstallDirectory: nil,
            defaultGraphicsBackend: .dxvk
        )

        let outcome = try await GameLaunchService().launchWindows(
            game: game,
            runtime: runtime,
            prefix: prefix,
            profile: nil,
            appSettings: settings
        )

        XCTAssertEqual(outcome.standardOutput, "1|1|1|dxvk|custom_val|custom_arg1|custom_arg2\n")
        XCTAssertEqual(outcome.exitStatus, 0)
    }

    func testNativeGameLaunchPassesCustomArgumentsAndEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossNativeLaunchTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executableURL = root.appendingPathComponent("native_game.sh")
        try "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$NATIVE_KEY\" \"$1\" \"$2\"\n"
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let game = Game(
            title: "Native Game",
            store: .local,
            platform: .nativeMacOS,
            installationURL: root,
            executableURL: executableURL,
            customLaunchArguments: ["--novid", "--windowed"],
            customEnvironment: ["NATIVE_KEY": "native_val"]
        )

        let outcome = try await GameLaunchService().launch(game)
        XCTAssertEqual(outcome.standardOutput, "native_val|--novid|--windowed\n")
        XCTAssertEqual(outcome.exitStatus, 0)
    }

    func testWindowsLaunchExplicitlyDisablesPerformanceOverridesWhenSetToFalse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossLaunchDisabledPerfTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        let executableURL = root.appendingPathComponent("game.exe")
        try "#!/bin/sh\nprintf '%s|%s|%s|%s\\n' \"$MTL_HUD_ENABLED\" \"$WINEMSYNC\" \"$WINEESYNC\" \"$WINE_ENABLE_RETINA\"\n"
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            id: UUID(),
            name: "Process harness",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(
            name: "Disabled Perf Prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(
            title: "Disabled Perf Game",
            store: .local,
            storeApplicationID: "disabled-perf-game",
            installationURL: root,
            executableURL: executableURL,
            metalHUDEnabled: false,
            msyncEnabled: false,
            esyncEnabled: false,
            retinaScalingEnabled: false
        )
        let settings = AppSettings(
            preferredInstallDirectory: nil,
            metalHUDEnabled: true,
            msyncEnabled: true,
            esyncEnabled: true,
            retinaScalingEnabled: true
        )

        let outcome = try await GameLaunchService().launchWindows(
            game: game,
            runtime: runtime,
            prefix: prefix,
            profile: nil,
            appSettings: settings
        )

        XCTAssertEqual(outcome.standardOutput, "|||\n")
        XCTAssertEqual(outcome.exitStatus, 0)
    }

    func testRuntimeDiagnosticsDetectWineAndCandidatePaths() {
        let service = RuntimeDiagnosticsService()
        let locations = service.candidateWineLocations()
        XCTAssertGreaterThan(locations.count, 10)

        let hasCrossOver = locations.contains { $0.1.contains("CrossOver.app") }
        let hasGPTK = locations.contains { $0.1.contains("Game Porting Toolkit.app") }
        let hasWhisky = locations.contains { $0.1.contains("Whisky") }

        XCTAssertTrue(hasCrossOver)
        XCTAssertTrue(hasGPTK)
        XCTAssertTrue(hasWhisky)

        // detectWine() can be called safely
        _ = service.detectWine()
    }

    func testWinePrefixArchiveCreateDirectoryZipBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossDirZipTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDir = root.appendingPathComponent("GameFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try Data("game data".utf8).write(to: sourceDir.appendingPathComponent("game.dat"))

        let destDir = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let archiveService = WinePrefixArchiveService()
        let zipURL = try await archiveService.createDirectoryZipBackup(
            sourceDirectory: sourceDir,
            name: "My Game: Test",
            to: destDir
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertTrue(zipURL.lastPathComponent.hasPrefix("Ludus-My Game- Test-"))
        XCTAssertTrue(zipURL.pathExtension.lowercased() == "zip")
    }

    func testConnectedGamepadProperties() {
        let gamepad = ConnectedGamepad(
            id: "controller-0",
            vendorName: "DualSense Wireless Controller",
            isAttachedToDevice: false
        )
        XCTAssertEqual(gamepad.id, "controller-0")
        XCTAssertEqual(gamepad.vendorName, "DualSense Wireless Controller")
        XCTAssertFalse(gamepad.isAttachedToDevice)
    }

    func testAntiCheatRegistryDetectsKernelAntiCheatTitles() {
        let fortnite = AntiCheatRegistry.inspect(title: "Fortnite")
        XCTAssertTrue(fortnite.requiresKernelAntiCheat)
        XCTAssertNotNil(fortnite.warningMessage)

        let valorant = AntiCheatRegistry.inspect(title: "VALORANT")
        XCTAssertTrue(valorant.requiresKernelAntiCheat)

        let destiny = AntiCheatRegistry.inspect(title: "Destiny 2", storeApplicationID: "392100")
        XCTAssertTrue(destiny.requiresKernelAntiCheat)

        let celeste = AntiCheatRegistry.inspect(title: "Celeste", storeApplicationID: "504230")
        XCTAssertFalse(celeste.requiresKernelAntiCheat)
        XCTAssertNil(celeste.warningMessage)
    }

    func testRuntimeBootstrapServiceProvisionsEnvironment() async throws {
        let tempRuntimeDir = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedRuntime-\(UUID().uuidString)", isDirectory: true)
        let bootstrap = RuntimeBootstrapService(managedRuntimeDirectory: tempRuntimeDir)
        XCTAssertFalse(bootstrap.isRuntimeInstalled)

        let runtime = try await bootstrap.ensureRuntime()
        XCTAssertTrue(bootstrap.isRuntimeInstalled)
        XCTAssertTrue(["arm64", "x86_64"].contains(runtime.architecture))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bootstrap.managedExecutableURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bootstrap.managedWinebootURL.path))
    }

    func testWineBottleServiceInitializesDefaultBottleWithRedistributables() async throws {
        let tempPrefixDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestBottle-\(UUID().uuidString)", isDirectory: true)
        let tempGamesDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestGames-\(UUID().uuidString)", isDirectory: true)
        let bottleService = WineBottleService(defaultBottleURL: tempPrefixDir)
        XCTAssertFalse(bottleService.isBottleVerified)

        let dummyExe = FileManager.default.temporaryDirectory.appendingPathComponent("wine-\(UUID().uuidString)")
        try "dummy".write(to: dummyExe, atomically: true, encoding: .utf8)
        let runtime = DetectedRuntime(
            name: "Test Runtime",
            executableURL: dummyExe,
            winebootURL: dummyExe,
            version: "Wine-CX Test",
            architecture: "arm64",
            status: "Ready"
        )

        let prefix = try await bottleService.ensureDefaultBottle(runtime: runtime, gamesDirectory: tempGamesDir)
        XCTAssertTrue(bottleService.isBottleVerified)
        XCTAssertEqual(prefix.name, "DefaultBottle")

        let driveC = tempPrefixDir.appendingPathComponent("drive_c")
        let vcruntime = driveC.appendingPathComponent("windows/system32/vcruntime140.dll")
        let dxgi = driveC.appendingPathComponent("windows/system32/dxgi.dll")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vcruntime.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dxgi.path))
    }

    func testEpicServiceDecodesWindowsGamesAndFiltersDLCs() throws {
        let epicJSON = """
        [
            {
                "app_name": "Hades",
                "app_title": "Hades",
                "is_dlc": false,
                "metadata": {
                    "keyImages": [
                        {"type": "DieselGameBox", "url": "https://cdn.epicgames.com/hades.jpg"}
                    ]
                }
            },
            {
                "app_name": "Hades_Soundtrack",
                "app_title": "Hades Original Soundtrack",
                "is_dlc": true
            }
        ]
        """.data(using: .utf8)!

        let tempConfigDir = FileManager.default.temporaryDirectory.appendingPathComponent("EpicConfig-\(UUID().uuidString)", isDirectory: true)
        let service = EpicService(configurationDirectory: tempConfigDir)
        let entries = try service.decodeLibraryEntries(from: epicJSON)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.appName, "Hades")
        XCTAssertEqual(entries.first?.title, "Hades")
        XCTAssertEqual(entries.first?.artworkURL?.absoluteString, "https://cdn.epicgames.com/hades.jpg")
    }

    func testEpicServiceExtractsJSONDataWithPrefixLogLines() throws {
        let rawOutput = """
        [Core] WARNING: Getting locale failed: ValueError('not enough values to unpack'), falling back to en-US.
        [cli] INFO: Logging in...
        [Core] INFO: Trying to re-use existing login session...
        [cli] INFO: Getting game list...
        [{"app_name": "Game1", "app_title": "Game One", "is_dlc": false}]
        """

        let data = EpicService.extractJSONData(from: rawOutput)
        XCTAssertNotNil(data)
        if let data {
            let tempConfigDir = FileManager.default.temporaryDirectory.appendingPathComponent("EpicConfig-\(UUID().uuidString)", isDirectory: true)
            let service = EpicService(configurationDirectory: tempConfigDir)
            let entries = try service.decodeLibraryEntries(from: data)
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.title, "Game One")
        }
    }

    func testEpicServiceRejectsMockDummyUserJSON() throws {
        let tempConfigDir = FileManager.default.temporaryDirectory.appendingPathComponent("EpicConfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempConfigDir, withIntermediateDirectories: true)
        let mock = """
        {"displayName": "Epic Player", "account_id": "ep_12345"}
        """
        try mock.write(to: tempConfigDir.appendingPathComponent("user.json"), atomically: true, encoding: .utf8)

        let service = EpicService(configurationDirectory: tempConfigDir, allowAutoImportFromHeroic: false)
        let status = service.checkAuthStatus()
        XCTAssertEqual(status, .notConnected)
    }

    func testSteamServicePreparesOfflineAppIDLaunch() throws {
        let service = SteamService()
        let gameDir = FileManager.default.temporaryDirectory.appendingPathComponent("Terraria-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

        try service.prepareGameDirectory(at: gameDir, appID: 105600)
        let appIDFile = gameDir.appendingPathComponent("steam_appid.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appIDFile.path))
        let content = try String(contentsOf: appIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(content, "105600")
    }

    func testHeroicInstallProgressParsesResumeAndOverallProgress() throws {
        final class ProgressBox: @unchecked Sendable {
            var updates: [HeroicInstallProgress] = []
        }
        let box = ProgressBox()
        let collector = InstallOutputCollector { progress in
            box.updates.append(progress)
        }

        let lines = [
            "[DLM] INFO: Found previously interrupted download. Download will be resumed if possible.",
            "[DLM] INFO: Skipping 240 files based on resume data.",
            "[cli] INFO: Install size: 57208.92 MiB",
            "[cli] INFO: Download size: 56454.43 MiB (Compression savings: 1.3%)",
            "[cli] INFO: Reusable size: 0.00 MiB (chunks) / 33321.68 MiB (unchanged / skipped)",
            "[DLManager] INFO:  + Download\t- 15.20 MiB/s (raw) / 22.10 MiB/s (decompressed)",
            "[DLManager] INFO: = Progress: 50.00% (29390/58781), Running for 00:10:00, ETA: 00:10:00\n"
        ]

        for line in lines {
            collector.append(Data("\(line)\n".utf8), isError: false)
        }

        let last = try XCTUnwrap(box.updates.last)
        let fraction = try XCTUnwrap(last.fraction)
        // Overall: (33321.68 + 0.5 * 57208.92) / (33321.68 + 57208.92) = 61926.14 / 90530.60 ≈ 0.684
        XCTAssertTrue(fraction > 0.65)
        XCTAssertTrue(fraction < 0.72)
        XCTAssertTrue(last.detail.contains("Resuming:"))
        XCTAssertTrue(last.detail.contains("15.20 MiB/s"))
        XCTAssertTrue(last.detail.contains("ETA: 00:10:00"))
        XCTAssertEqual(last.speed, "15.20 MiB/s")
        XCTAssertEqual(last.eta, "00:10:00")
    }

    func testDownloadOperationStateSupportsPaused() throws {
        let op = DownloadOperation(
            gameID: UUID(),
            gameTitle: "Test Game",
            kind: .install,
            state: .paused,
            fraction: 0.45,
            detail: "Download paused"
        )
        XCTAssertEqual(op.state, .paused)
        XCTAssertEqual(op.state.displayName, "Paused")

        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(DownloadOperation.self, from: data)
        XCTAssertEqual(decoded.state, .paused)
        XCTAssertEqual(decoded.fraction, 0.45)
    }

    func testHeroicDeleteDownloadDataRemovesResumeAndJsonFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossDeleteDownloadDataTest-\(UUID().uuidString)")
        let configDir = root.appendingPathComponent("EpicConfig", isDirectory: true)
        let tmpDir = configDir.appendingPathComponent("tmp", isDirectory: true)
        let targetDir = root.appendingPathComponent("TargetDir", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let resumeFile = tmpDir.appendingPathComponent("TestApp.resume")
        let jsonFile = tmpDir.appendingPathComponent("TestApp.json")
        try Data("resume data".utf8).write(to: resumeFile)
        try Data("json data".utf8).write(to: jsonFile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: resumeFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonFile.path))

        let epicService = EpicService(configurationDirectory: configDir)
        XCTAssertTrue(epicService.isGameResumable(appName: "TestApp"))

        epicService.deleteDownloadData(appName: "TestApp", targetDirectory: targetDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonFile.path))
        XCTAssertFalse(epicService.isGameResumable(appName: "TestApp"))
    }

    func testHeroicInstallVerificationFailsWhenResumeFileStillExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossHeroicResumeTest-\(UUID().uuidString)")
        let configurationDirectory = root.appendingPathComponent("legendary", isDirectory: true)
        let installationDirectory = root.appendingPathComponent("installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: configurationDirectory.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installationDirectory, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: installationDirectory.appendingPathComponent("content.bin"))

        // Create resume file indicating download was incomplete
        try Data("resume data".utf8).write(to: configurationDirectory.appendingPathComponent("tmp/ExampleGame.resume"))

        let installedJSON = """
        {
          "ExampleGame": {
            "install_path": "\(installationDirectory.path)"
          }
        }
        """
        try installedJSON.write(
            to: configurationDirectory.appendingPathComponent("installed.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(
            try HeroicInstallService.verifiedEvidence(
                applicationName: "ExampleGame",
                configurationDirectory: configurationDirectory
            )
        )
    }

    // MARK: - CrossOver Boost & Bottle Service Tests

    func testGraphicsBackendDXMTAndCrossOverEnvironmentVariables() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossDXMTHarnessTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        let executableURL = root.appendingPathComponent("game.exe")
        try "#!/bin/sh\nprintf '%s|%s|%s|%s|%s|%s\\n' \"$OVERCROSS_GRAPHICS_BACKEND\" \"$CX_GRAPHICS_BACKEND\" \"$WINEDXMT\" \"$WINED3DMETAL\" \"$WINEDXVK\" \"$CX_BOTTLE\"\n"
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            id: UUID(),
            name: "Process harness",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(
            name: "TestBottle",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )

        // 1. Test DXMT
        let dxmtProfile = CompatibilityProfile(
            store: .local,
            storeApplicationID: "dxmt-game",
            graphicsBackend: .dxmt,
            testEnvironment: "test harness",
            testResult: .working
        )
        let gameDXMT = Game(
            title: "DXMT Game",
            store: .local,
            storeApplicationID: "dxmt-game",
            installationURL: root,
            executableURL: executableURL
        )
        let outcomeDXMT = try await GameLaunchService().launchWindows(
            game: gameDXMT,
            runtime: runtime,
            prefix: prefix,
            profile: dxmtProfile
        )
        XCTAssertEqual(outcomeDXMT.exitStatus, 0)
        XCTAssertEqual(
            outcomeDXMT.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "dxmt|dxmt|1|||TestBottle"
        )

        // 2. Test D3DMetal
        let d3dmetalProfile = CompatibilityProfile(
            store: .local,
            storeApplicationID: "dxmt-game",
            graphicsBackend: .d3dmetal,
            testEnvironment: "test harness",
            testResult: .working
        )
        let outcomeD3DMetal = try await GameLaunchService().launchWindows(
            game: gameDXMT,
            runtime: runtime,
            prefix: prefix,
            profile: d3dmetalProfile
        )
        XCTAssertEqual(outcomeD3DMetal.exitStatus, 0)
        XCTAssertEqual(
            outcomeD3DMetal.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "d3dmetal|d3dmetal||1||TestBottle"
        )

        // 3. Test DXVK
        let dxvkProfile = CompatibilityProfile(
            store: .local,
            storeApplicationID: "dxmt-game",
            graphicsBackend: .dxvk,
            testEnvironment: "test harness",
            testResult: .working
        )
        let outcomeDXVK = try await GameLaunchService().launchWindows(
            game: gameDXMT,
            runtime: runtime,
            prefix: prefix,
            profile: dxvkProfile
        )
        XCTAssertEqual(outcomeDXVK.exitStatus, 0)
        XCTAssertEqual(
            outcomeDXVK.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "dxvk|dxvk|||1|TestBottle"
        )

        // 4. Test Game-level explicit backend overrules Profile backend recommendation
        let gameWithExplicitBackend = Game(
            title: "Overridden Game",
            store: .local,
            storeApplicationID: "dxmt-game",
            installationURL: root,
            executableURL: executableURL,
            graphicsBackend: "dxmt"
        )
        let outcomePrecedence = try await GameLaunchService().launchWindows(
            game: gameWithExplicitBackend,
            runtime: runtime,
            prefix: prefix,
            profile: d3dmetalProfile // Profile asks for d3dmetal, but user chose dxmt
        )
        XCTAssertEqual(outcomePrecedence.exitStatus, 0)
        XCTAssertEqual(
            outcomePrecedence.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "dxmt|dxmt|1|||TestBottle"
        )

        // 5. Test resolvedGraphicsBackend cascades from appSettings
        let unconfiguredGame = Game(title: "Unconfigured", store: .local)
        XCTAssertEqual(unconfiguredGame.resolvedGraphicsBackend(appSettings: nil), .automatic)
        let appSettingsWithDXVK = AppSettings(defaultGraphicsBackend: .dxvk)
        XCTAssertEqual(unconfiguredGame.resolvedGraphicsBackend(appSettings: appSettingsWithDXVK), .dxvk)

        // 6. Test cxbottle.conf synchronization
        let confURL = root.appendingPathComponent("cxbottle.conf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: confURL.path))
        let confContent = (try? String(contentsOf: confURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(confContent.contains("[EnvironmentVariables]"))
        XCTAssertTrue(confContent.contains("\"CX_GRAPHICS_BACKEND\" = \"dxmt\""))
    }

    func testAutomatedRedistributableAndDependencyRepair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossRedistRepairTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let bottleService = WineBottleService(defaultBottleURL: root)
        let summary = try await bottleService.repairDependencies(in: root)

        XCTAssertTrue(summary.installedDirectXCount >= 4)
        XCTAssertTrue(summary.installedVCRuntimeCount >= 2)
        XCTAssertTrue(summary.isMonoConfigured)
        XCTAssertTrue(summary.statusMessage.contains("Successfully installed and repaired runtime dependencies"))

        let system32 = root.appendingPathComponent("drive_c/windows/system32")
        let syswow64 = root.appendingPathComponent("drive_c/windows/syswow64")

        // Verify DirectX DLLs exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: system32.appendingPathComponent("d3dx9_43.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: system32.appendingPathComponent("d3dx11_43.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: system32.appendingPathComponent("xinput1_3.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: system32.appendingPathComponent("xactengine3_7.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: syswow64.appendingPathComponent("d3dx9_43.dll").path))

        // Verify VC++ DLLs exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: system32.appendingPathComponent("vcruntime140.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: system32.appendingPathComponent("msvcp140.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: syswow64.appendingPathComponent("vcruntime140.dll").path))

        // Verify Mono/DotNet exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: system32.appendingPathComponent("mscoree.dll").path))

        // Verify inspectComponents detects the installed components
        let components = WinePrefixService().inspectComponents(at: root)
        let d3dx9 = components.first(where: { $0.id == "dx9_d3dx9_43" })
        let d3dx11 = components.first(where: { $0.id == "dx11_d3dx11_43" })
        let xinput = components.first(where: { $0.id == "xinput1_3" })
        let xact = components.first(where: { $0.id == "xactengine3_7" })

        XCTAssertNotNil(d3dx9)
        XCTAssertTrue(d3dx9?.isInstalled == true)
        XCTAssertNotNil(d3dx11)
        XCTAssertTrue(d3dx11?.isInstalled == true)
        XCTAssertNotNil(xinput)
        XCTAssertTrue(xinput?.isInstalled == true)
        XCTAssertNotNil(xact)
        XCTAssertTrue(xact?.isInstalled == true)

        // Test ensureBottlePreflight on existing prefix
        try await bottleService.ensureBottlePreflight(prefixURL: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: system32.appendingPathComponent("vcruntime140.dll").path))
    }

    func testForceStopAndCleanResetBottle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossResetBottleTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: root.appendingPathComponent("system.reg"))
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: root.appendingPathComponent("user.reg"))

        let bottleService = WineBottleService(defaultBottleURL: root)
        let message = try await bottleService.forceStopAndReset(prefixURL: root)

        XCTAssertTrue(message.contains("was cleanly stopped and reset"))
        // Check that bottle redistributables were re-provisioned and intact
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("drive_c/windows/system32/vcruntime140.dll").path))
    }

    func testRetinaDisplayModeToggleAndRegistrySync() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossRetinaTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let userRegURL = root.appendingPathComponent("user.reg")

        // Test with real Wine timestamp header format: [Software\\Wine\\Mac Driver] 1729000000
        let initialWineReg = """
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        [Software\\\\Wine\\\\Mac Driver] 1729000000
        #time=1db000000000000
        "RetinaMode"="n"

        [Software\\\\Wine\\\\WineD3D] 1729000000
        "csmt"=dword:00000001
        """
        try initialWineReg.write(to: userRegURL, atomically: true, encoding: .utf8)

        // Initially disabled
        XCTAssertFalse(WineBottleService.isRetinaModeEnabled(in: root))

        // Enable Retina mode
        try WineBottleService.setRetinaMode(enabled: true, in: root)
        XCTAssertTrue(WineBottleService.isRetinaModeEnabled(in: root))
        let enabledContent = try String(contentsOf: userRegURL, encoding: .utf8)
        XCTAssertTrue(enabledContent.contains("[Software\\\\Wine\\\\Mac Driver] 1729000000"))
        XCTAssertTrue(enabledContent.contains("\"RetinaMode\"=\"y\""))
        XCTAssertFalse(enabledContent.contains("\"RetinaMode\"=\"n\""))

        // Disable Retina mode
        try WineBottleService.setRetinaMode(enabled: false, in: root)
        XCTAssertFalse(WineBottleService.isRetinaModeEnabled(in: root))
        let disabledContent = try String(contentsOf: userRegURL, encoding: .utf8)
        XCTAssertTrue(disabledContent.contains("[Software\\\\Wine\\\\Mac Driver] 1729000000"))
        XCTAssertTrue(disabledContent.contains("\"RetinaMode\"=\"n\""))
        XCTAssertFalse(disabledContent.contains("\"RetinaMode\"=\"y\""))
    }

    func testWinePrefixArchiveCxarchiveBackupAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercrossCxarchiveTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sourcePrefixDir = root.appendingPathComponent("SourcePrefix", isDirectory: true)
        let system32 = sourcePrefixDir.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)

        let testFile = system32.appendingPathComponent("game_payload.dll")
        try "Payload Content".write(to: testFile, atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n".write(to: sourcePrefixDir.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n".write(to: sourcePrefixDir.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

        let archiveService = WinePrefixArchiveService()
        let backupDir = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let activeRuntimeURL = URL(fileURLWithPath: "/bin/sh")
        let sourcePrefix = WinePrefix(
            name: "SourcePrefix",
            url: sourcePrefixDir,
            runtimeURL: activeRuntimeURL,
            architecture: .win64
        )

        let createdURL = try await archiveService.createCxarchiveBackup(prefix: sourcePrefix, to: backupDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))
        XCTAssertEqual(createdURL.pathExtension, "cxarchive")

        let restoreDir = root.appendingPathComponent("RestoredPrefix", isDirectory: true)
        let restoredPrefix = try archiveService.restore(
            archiveURL: createdURL,
            into: restoreDir,
            fallbackRuntimeURL: activeRuntimeURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredPrefix.url.path))
        XCTAssertEqual(restoredPrefix.runtimeURL.standardizedFileURL, activeRuntimeURL.standardizedFileURL)
        let restoredPayload = restoredPrefix.url.appendingPathComponent("drive_c/windows/system32/game_payload.dll")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredPayload.path))
        let payloadString = try String(contentsOf: restoredPayload, encoding: .utf8)
        XCTAssertEqual(payloadString, "Payload Content")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredPrefix.url.appendingPathComponent("system.reg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredPrefix.url.appendingPathComponent("user.reg").path))

        // Test restoring a raw archive (like a real CrossOver bottle) without metadata.json using fallbackRuntimeURL
        let rawBottleDir = root.appendingPathComponent("RawCrossOverBottle", isDirectory: true)
        try FileManager.default.createDirectory(at: rawBottleDir.appendingPathComponent("drive_c/windows/system32", isDirectory: true), withIntermediateDirectories: true)
        try "WINE REGISTRY Version 2\n".write(to: rawBottleDir.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)

        let restoredRaw = try archiveService.restore(
            archiveURL: rawBottleDir,
            into: restoreDir,
            fallbackRuntimeURL: activeRuntimeURL
        )
        XCTAssertEqual(restoredRaw.runtimeURL.standardizedFileURL, activeRuntimeURL.standardizedFileURL)
        XCTAssertTrue(WinePrefixService.isVerifiedPrefix(at: restoredRaw.url))
    }

    func testWineToolEnumMetadataAndCases() {
        XCTAssertEqual(WineTool.allCases.count, 3)
        XCTAssertEqual(WineTool.winecfg.id, "winecfg")
        XCTAssertEqual(WineTool.regedit.id, "regedit")
        XCTAssertEqual(WineTool.taskmgr.id, "taskmgr")

        XCTAssertEqual(WineTool.winecfg.displayName, "Wine Configuration (winecfg)")
        XCTAssertEqual(WineTool.regedit.displayName, "Registry Editor (regedit)")
        XCTAssertEqual(WineTool.taskmgr.displayName, "Task Manager (taskmgr)")

        XCTAssertEqual(WineTool.winecfg.iconName, "gearshape.2.fill")
        XCTAssertEqual(WineTool.regedit.iconName, "list.bullet.rectangle")
        XCTAssertEqual(WineTool.taskmgr.iconName, "chart.bar.xaxis")
    }

    func testEpicServiceGetLaunchArguments() async throws {
        let epicService = EpicService()
        let args = await epicService.getLaunchArguments(for: "fa4240e57a3c46b39f169041b7811293")
        XCTAssertTrue(args.isEmpty || args.contains("-EpicPortal") || args.contains(where: { $0.hasPrefix("-UserDir") }))
    }

    func testEpicServiceFindApplicationID() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpicTestConfig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let installedJSON = tempDir.appendingPathComponent("installed.json")
        let sampleData = """
        {
          "mock_epic_game_123": {
            "app_name": "mock_epic_game_123",
            "title": "Hogwarts Legacy",
            "install_path": "/MockVolumes/Games/HogwartsLegacy",
            "executable": "HogwartsLegacy.exe"
          }
        }
        """.data(using: .utf8)!
        try sampleData.write(to: installedJSON)

        let epicService = EpicService(configurationDirectory: tempDir)

        // Matching by installationURL
        let match1 = epicService.findApplicationID(
            installationURL: URL(fileURLWithPath: "/MockVolumes/Games/HogwartsLegacy"),
            executableURL: nil
        )
        XCTAssertEqual(match1, "mock_epic_game_123")

        // Matching by executableURL
        let match2 = epicService.findApplicationID(
            installationURL: nil,
            executableURL: URL(fileURLWithPath: "/MockVolumes/Games/HogwartsLegacy/Phoenix/Binaries/Win64/HogwartsLegacy.exe")
        )
        XCTAssertEqual(match2, "mock_epic_game_123")

        // Non-matching
        let noMatch = epicService.findApplicationID(
            installationURL: URL(fileURLWithPath: "/MockVolumes/Games/OtherGame"),
            executableURL: nil
        )
        XCTAssertNil(noMatch)
    }

    func testGitHubUpdateServiceVersionComparison() {
        XCTAssertTrue(GitHubUpdateService.isVersion("0.2.0", newerThan: "0.1.0"))
        XCTAssertTrue(GitHubUpdateService.isVersion("v1.0.0", newerThan: "v0.9.9"))
        XCTAssertTrue(GitHubUpdateService.isVersion("0.1.1", newerThan: "0.1.0"))
        XCTAssertFalse(GitHubUpdateService.isVersion("0.1.0", newerThan: "0.1.0"))
        XCTAssertFalse(GitHubUpdateService.isVersion("0.0.9", newerThan: "0.1.0"))
        XCTAssertFalse(GitHubUpdateService.isVersion("v0.1.0", newerThan: "v0.1.1"))
    }

    func testLogSanitizerScrubsPII() {
        let rawLog = "Error at /Users/john_appleseed/Library/Application Support/Ludus/game.exe for player test.user@example.com with -AUTH_PASSWORD=secret123 --code auth_code_999 -epicovt=/Users/john/token.ovt"
        let sanitized = AnonymousDiagnosticsService.sanitize(log: rawLog)

        XCTAssertFalse(sanitized.contains("/Users/john_appleseed"))
        XCTAssertFalse(sanitized.contains("john_appleseed"))
        XCTAssertFalse(sanitized.contains("test.user@example.com"))
        XCTAssertFalse(sanitized.contains("secret123"))
        XCTAssertFalse(sanitized.contains("auth_code_999"))
        XCTAssertTrue(sanitized.contains("~/Library/Application Support/Ludus/game.exe"))
        XCTAssertTrue(sanitized.contains("[REDACTED_EMAIL]"))
        XCTAssertTrue(sanitized.contains("-AUTH_PASSWORD=[REDACTED]"))
        XCTAssertTrue(sanitized.contains("--code [REDACTED]"))
    }

    func testAnonymousDiagnosticPayloadGeneration() {
        let service = AnonymousDiagnosticsService()
        let error = NSError(domain: "GameLaunchService", code: 42, userInfo: [NSLocalizedDescriptionKey: "Failed launching at /Users/developer/game.exe"])
        let payload = service.buildPayload(
            component: "GameLaunchService",
            error: error,
            rawLogs: ["Starting process at /Users/developer/wine", "Bearer secret_token_123"],
            anonymousInstallationID: "anon-test-uuid-1234"
        )

        XCTAssertEqual(payload.component, "GameLaunchService")
        XCTAssertEqual(payload.anonymousInstallationID, "anon-test-uuid-1234")
        XCTAssertFalse(payload.errorDescription.contains("/Users/developer"))
        XCTAssertTrue(payload.errorDescription.contains("~/game.exe"))
        XCTAssertEqual(payload.sanitizedLogs.count, 2)
        XCTAssertTrue(payload.sanitizedLogs[1].contains("Bearer [REDACTED]"))
        XCTAssertFalse(payload.chipModel.isEmpty)
        XCTAssertFalse(payload.chipArchitecture.isEmpty)
    }

    func testDiagnosticsConsentAndSettingsPersistence() {
        var settings = AppSettings()
        XCTAssertEqual(settings.diagnosticsConsentStatus, .undetermined)
        XCTAssertFalse(settings.anonymousDiagnosticsEnabled)
        XCTAssertFalse(settings.anonymousInstallationID.isEmpty)

        settings.diagnosticsConsentStatus = .optedIn
        settings.anonymousDiagnosticsEnabled = true
        settings.save()

        let reloaded = AppSettings.load()
        XCTAssertEqual(reloaded.diagnosticsConsentStatus, .optedIn)
        XCTAssertTrue(reloaded.anonymousDiagnosticsEnabled)
        XCTAssertEqual(reloaded.anonymousInstallationID, settings.anonymousInstallationID)
    }

    func testAnonymousDiagnosticsLocalReportStorage() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LudusDiagTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = AnonymousDiagnosticsService(baseDirectory: tempDir)
        let error = NSError(domain: "TestDomain", code: 99, userInfo: [NSLocalizedDescriptionKey: "Test error description"])
        let payload = service.buildPayload(
            component: "BottleManager",
            error: error,
            rawLogs: ["Line 1", "Line 2"],
            anonymousInstallationID: "test-storage-id"
        )

        service.saveReportLocally(payload)

        let loaded = service.loadLastReport()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.component, "BottleManager")
        XCTAssertEqual(loaded?.anonymousInstallationID, "test-storage-id")
        XCTAssertEqual(loaded?.sanitizedLogs, ["Line 1", "Line 2"])

        let history = service.loadReportHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.component, "BottleManager")
    }

    func testAnonymousDiagnosticsTelegramSecretDecodingAndConfiguration() {
        let token = AnonymousDiagnosticsService.decodeSecret(AnonymousDiagnosticsService.defaultTelegramBotTokenEncoded)
        let chatID = AnonymousDiagnosticsService.decodeSecret(AnonymousDiagnosticsService.defaultTelegramChatIDEncoded)
        XCTAssertFalse(token.isEmpty)
        XCTAssertTrue(token.contains(":"))
        XCTAssertFalse(chatID.isEmpty)
        XCTAssertEqual(chatID, "9071372703")
    }

    func testGameLifecycleReportingFormatters() {
        let durationStr = AnonymousDiagnosticsService.formatDuration(3672)
        XCTAssertEqual(durationStr, "1h 1m 12s")

        let shortDuration = AnonymousDiagnosticsService.formatDuration(45)
        XCTAssertEqual(shortDuration, "45s")

        let escaped = AnonymousDiagnosticsService.escapeHTML("<Game & Title>")
        XCTAssertEqual(escaped, "&lt;Game &amp; Title&gt;")
    }

    func testAppSettingsTelegramReportsDefaultsToTrue() {
        let settings = AppSettings()
        XCTAssertTrue(settings.telegramGameReportsEnabled)
        XCTAssertFalse(settings.anonymousDiagnosticsEnabled)
        XCTAssertEqual(settings.diagnosticsConsentStatus, .undetermined)
    }

    func testGameOptimizationNeutralizesProblematicLibraries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusOptimizationTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pluginDir = root.appendingPathComponent("Phoenix/Plugins/ChromaSDKPlugin/Binaries/Win64", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let problematicDLL = pluginDir.appendingPathComponent("CChromaEditorLibrary64.dll")
        let harmlessDLL = pluginDir.appendingPathComponent("OtherPlugin.dll")

        try Data([1, 2, 3]).write(to: problematicDLL)
        try Data([4, 5, 6]).write(to: harmlessDLL)

        let service = GameOptimizationService()
        let neutralized = service.neutralizeProblematicLibraries(at: root)

        XCTAssertEqual(neutralized, ["CChromaEditorLibrary64.dll"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: problematicDLL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("CChromaEditorLibrary64.dll.bak").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harmlessDLL.path))
    }

    func testGameOptimizationEngineINISettings16GB() throws {
        let prefixDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusPrefixTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefixDir) }

        let service = GameOptimizationService()
        let ram16GB: UInt64 = 16 * 1024 * 1024 * 1024
        let pool = service.optimalStreamingPoolMB(totalRAMBytes: ram16GB)
        XCTAssertEqual(pool, 2048)

        let applied = service.optimizeEngineINI(
            prefixURL: prefixDir,
            gameTitle: "Hogwarts Legacy",
            executableURL: URL(fileURLWithPath: "C:/Games/Hogwarts Legacy/HogwartsLegacy.exe"),
            poolSizeMB: pool
        )
        XCTAssertTrue(applied)

        let iniURL = prefixDir.appendingPathComponent("drive_c/users/crossover/AppData/Local/HogwartsLegacy/Saved/Config/WindowsNoEditor/Engine.ini")
        XCTAssertTrue(FileManager.default.fileExists(atPath: iniURL.path))
        let content = try String(contentsOf: iniURL, encoding: .utf8)
        XCTAssertTrue(content.contains("[SystemSettings]"))
        XCTAssertTrue(content.contains("r.Streaming.PoolSize=2048"))
        XCTAssertTrue(content.contains("r.TextureStreaming=1"))
        XCTAssertTrue(content.contains("r.Streaming.LimitPoolSizeToVRAM=1"))
        XCTAssertTrue(content.contains("gc.TimeBetweenPurgingPendingKillObjects=30"))
        XCTAssertTrue(content.contains("[ConsoleVariables]"))
        XCTAssertTrue(content.contains("AllowAsyncRenderThreadUpdates=1"))
    }

    func testGameOptimizationEngineINIPreservesExistingKeys() throws {
        let prefixDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusPrefixTestPreserve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefixDir) }

        let iniURL = prefixDir.appendingPathComponent("drive_c/users/crossover/AppData/Local/CustomGame/Saved/Config/WindowsNoEditor/Engine.ini")
        try FileManager.default.createDirectory(at: iniURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let initialContent = """
        [SystemSettings]
        r.CustomUserOption=999
        r.Streaming.PoolSize=1000

        [MyCustomSection]
        SomeKey=SomeValue
        """
        try initialContent.write(to: iniURL, atomically: true, encoding: .utf8)

        let service = GameOptimizationService()
        _ = service.applyEngineINISettings(to: iniURL, poolSizeMB: 4096)

        let updated = try String(contentsOf: iniURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("r.CustomUserOption=999"))
        XCTAssertTrue(updated.contains("r.Streaming.PoolSize=4096"))
        XCTAssertTrue(updated.contains("r.VSync=0"))
        XCTAssertTrue(updated.contains("t.MaxFPS=120"))
        XCTAssertTrue(updated.contains("SomeKey=SomeValue"))
    }

    func testOptimalStreamingPoolMBForDifferentRAMSizes() {
        let service = GameOptimizationService()
        XCTAssertEqual(service.optimalStreamingPoolMB(totalRAMBytes: 8 * 1024 * 1024 * 1024), 2048)
        XCTAssertEqual(service.optimalStreamingPoolMB(totalRAMBytes: 16 * 1024 * 1024 * 1024), 2048)
        XCTAssertEqual(service.optimalStreamingPoolMB(totalRAMBytes: 24 * 1024 * 1024 * 1024), 4096)
        XCTAssertEqual(service.optimalStreamingPoolMB(totalRAMBytes: 32 * 1024 * 1024 * 1024), 4096)
        XCTAssertEqual(service.optimalStreamingPoolMB(totalRAMBytes: 64 * 1024 * 1024 * 1024), 6144)
    }

    func testWindowsLaunchInjectsGPUPerformanceAndOptimizationEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusLaunchGPUPerfTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        let executableURL = root.appendingPathComponent("game.exe")
        try "#!/bin/sh\nprintf '%s|%s|%s|%s|%s\\n' \"$MTL_SHADER_VALIDATION\" \"$DX12_MAX_FRAME_LATENCY\" \"$WINE_HIGH_PERFORMANCE\" \"$WINE_D3D_GPU_PRIORITY\" \"$WINEMSYNC\"\n"
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            id: UUID(),
            name: "Process harness",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(
            name: "GPU Harness prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(
            title: "GPU Harness Game",
            store: .local,
            storeApplicationID: "gpu-harness-game",
            installationURL: root,
            executableURL: executableURL
        )

        let outcome = try await GameLaunchService().launchWindows(
            game: game,
            runtime: runtime,
            prefix: prefix
        )

        XCTAssertEqual(outcome.standardOutput, "0|2|1|high|1\n")
        XCTAssertEqual(outcome.exitStatus, 0)
    }

    func testWineBottleRegistrySyncMacDriverAndDirectInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusRegistrySyncTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let initialWineReg = """
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        [Software\\\\Wine\\\\Mac Driver] 1729000000
        #time=1db000000000000
        "RetinaMode"="n"
        """
        let userRegURL = root.appendingPathComponent("user.reg")
        try initialWineReg.write(to: userRegURL, atomically: true, encoding: .utf8)

        // Run bottle registry synchronization
        try WineBottleService.syncBottleRegistry(prefixURL: root, retina: false)

        XCTAssertTrue(WineBottleService.isNativeFullScreenEnabled(in: root))
        XCTAssertTrue(WineBottleService.isMouseCaptureEnabled(in: root))
        XCTAssertTrue(WineBottleService.isMouseWarpForced(in: root))

        let content = try String(contentsOf: userRegURL, encoding: .utf8)
        XCTAssertTrue(content.contains("[Software\\\\Wine\\\\Mac Driver] 1729000000"))
        XCTAssertTrue(content.contains("\"UseNativeFullScreen\"=\"Y\""))
        XCTAssertTrue(content.contains("\"GrabFullscreen\"=\"Y\""))
        XCTAssertTrue(content.contains("\"GrabPointer\"=\"Y\""))
        XCTAssertTrue(content.contains("\"CaptureDisplaysForFullscreen\"=\"Y\""))
        XCTAssertTrue(content.contains("\"CaptureMouseOnLaunch\"=\"Y\""))
        XCTAssertTrue(content.contains("\"CursorWarpMargin\"=dword:00000001"))
        XCTAssertTrue(content.contains("[Software\\\\Wine\\\\DirectInput]"))
        XCTAssertTrue(content.contains("\"MouseWarpOverride\"=\"force\""))
        XCTAssertTrue(content.contains("[Software\\\\Wine\\\\DirectSound]"))
        XCTAssertTrue(content.contains("\"MaxBuffers\"=dword:00000040"))
        XCTAssertTrue(content.contains("\"DefaultSampleRate\"=dword:0000bb80"))
    }

    func testGameOptimizationNeutralizesProblematicLibrariesAndRestoresEssential() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusRestoreTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let streamlineDir = root.appendingPathComponent("Engine/Plugins/Runtime/Nvidia/Streamline/Binaries/ThirdParty/Win64", isDirectory: true)
        try FileManager.default.createDirectory(at: streamlineDir, withIntermediateDirectories: true)
        let interposerBak = streamlineDir.appendingPathComponent("sl.interposer.dll.bak")
        let reflexBak = streamlineDir.appendingPathComponent("sl.reflex.dll.bak")
        let chromaDLL = streamlineDir.appendingPathComponent("CChromaEditorLibrary64.dll")

        try Data([1, 2, 3]).write(to: interposerBak)
        try Data([4, 5, 6]).write(to: reflexBak)
        try Data([7, 8, 9]).write(to: chromaDLL)

        let service = GameOptimizationService()

        // 1. Restore essential libraries needed by game bootstrap
        let restored = service.restoreEssentialLibraries(at: root)
        XCTAssertTrue(restored.contains("sl.interposer.dll"))
        XCTAssertTrue(restored.contains("sl.reflex.dll"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: streamlineDir.appendingPathComponent("sl.interposer.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: streamlineDir.appendingPathComponent("sl.reflex.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: interposerBak.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reflexBak.path))

        // 2. Neutralize only CPU spinlock libraries (Chroma), leaving Streamline intact
        let neutralized = service.neutralizeProblematicLibraries(at: root)
        XCTAssertEqual(neutralized, ["CChromaEditorLibrary64.dll"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: streamlineDir.appendingPathComponent("sl.interposer.dll").path))
    }

    func testGameOptimizationEngineINISettingsSafeForUnifiedMemory() throws {
        let prefixDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusShaderCacheTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefixDir) }

        let iniURL = prefixDir.appendingPathComponent("drive_c/users/crossover/AppData/Local/HogwartsLegacy/Saved/Config/WindowsNoEditor/Engine.ini")
        try FileManager.default.createDirectory(at: iniURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Seed with hazardous startup compilation directive from previous build
        let initialContent = """
        [SystemSettings]
        r.CreateShadersOnLoad=1
        r.ShaderPipelineCache.BatchSize=50
        """
        try initialContent.write(to: iniURL, atomically: true, encoding: .utf8)

        let service = GameOptimizationService()
        let applied = service.optimizeEngineINI(
            prefixURL: prefixDir,
            gameTitle: "Hogwarts Legacy",
            executableURL: URL(fileURLWithPath: "C:/Games/Hogwarts Legacy/HogwartsLegacy.exe"),
            poolSizeMB: 2048
        )
        XCTAssertTrue(applied)

        let content = try String(contentsOf: iniURL, encoding: .utf8)
        // Ensure hazardous directive was scrubbed
        XCTAssertFalse(content.contains("r.CreateShadersOnLoad=1"))
        XCTAssertFalse(content.contains("r.ShaderPipelineCache.BatchSize=50"))
        // Ensure safe unified memory streaming settings applied
        XCTAssertTrue(content.contains("r.Streaming.PoolSize=2048"))
        XCTAssertTrue(content.contains("r.Streaming.UseFixedPoolSize=1"))
        XCTAssertTrue(content.contains("r.Streaming.HLODStrategy=2"))
        XCTAssertTrue(content.contains("r.Streaming.DefragDynamicBounds=1"))
        XCTAssertTrue(content.contains("gc.TimeBetweenPurgingPendingKillObjects=30"))
    }

    func testWindowsLaunchInjectsNvidiaOverridesAndAudioProtectionEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusPerfHarness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        let executableURL = root.appendingPathComponent("game.exe")
        try "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$MTL_SHADER_CACHE_MODE\" \"$STAGING_AUDIO_DURATION\" \"$WINEAUDIO_BUFFER_SIZE\"\n"
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let runtimeURL = URL(fileURLWithPath: "/bin/sh")
        let runtime = DetectedRuntime(
            id: UUID(),
            name: "Process harness",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "harness",
            architecture: "arm64",
            status: "test harness"
        )
        let prefix = WinePrefix(
            name: "Harness prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(
            title: "Harness Game",
            store: .local,
            storeApplicationID: "harness-game",
            installationURL: root,
            executableURL: executableURL
        )

        let outcome = try await GameLaunchService().launchWindows(
            game: game,
            runtime: runtime,
            prefix: prefix
        )

        let output = outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "1")
        XCTAssertEqual(parts[1], "100000")
        XCTAssertEqual(parts[2], "4096")
        XCTAssertEqual(outcome.exitStatus, 0)
    }

    func testGameOptimizationNeutralizesDirectStorageLibraries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusDStorageTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dstorageDLL = root.appendingPathComponent("dstorage.dll")
        let dstorageCoreDLL = root.appendingPathComponent("dstoragecore.dll")
        let gameEXE = root.appendingPathComponent("Spider-Man2.exe")

        try Data([1, 2, 3]).write(to: dstorageDLL)
        try Data([4, 5, 6]).write(to: dstorageCoreDLL)
        try Data([7, 8, 9]).write(to: gameEXE)

        let service = GameOptimizationService()
        let neutralized = service.neutralizeProblematicLibraries(at: root)

        XCTAssertTrue(neutralized.contains("dstorage.dll"))
        XCTAssertTrue(neutralized.contains("dstoragecore.dll"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstorageDLL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstorageCoreDLL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("dstorage.dll.bak").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("dstoragecore.dll.bak").path))

        // Re-write to test full optimize reporting
        try Data([1, 2, 3]).write(to: dstorageDLL)
        let game = Game(
            title: "Marvel's Spider-Man 2",
            store: .local,
            storeApplicationID: "spiderman-2",
            installationURL: root,
            executableURL: gameEXE
        )
        let report = service.optimize(game: game, prefixURL: root)
        XCTAssertEqual(report.neutralizedLibraries, ["dstorage.dll"])
        XCTAssertTrue(report.details.contains(where: { $0.contains("bypassed DirectStorage I/O spinlock") }))
    }

    func testNixxesOrSonyTitleDetection() {
        XCTAssertTrue(GameLaunchService.isNixxesOrSonyTitle(
            title: "Marvel's Spider-Man 2",
            executableURL: URL(fileURLWithPath: "/Games/Spider-Man2.exe")
        ))
        XCTAssertTrue(GameLaunchService.isNixxesOrSonyTitle(
            title: "Marvel's Spider-Man: Miles Morales",
            executableURL: URL(fileURLWithPath: "/Games/MilesMorales.exe")
        ))
        XCTAssertTrue(GameLaunchService.isNixxesOrSonyTitle(
            title: "Ratchet & Clank: Rift Apart",
            executableURL: URL(fileURLWithPath: "/Games/RiftApart.exe")
        ))
        XCTAssertTrue(GameLaunchService.isNixxesOrSonyTitle(
            title: "Ghost of Tsushima DIRECTOR'S CUT",
            executableURL: URL(fileURLWithPath: "/Games/GhostOfTsushima.exe")
        ))
        XCTAssertTrue(GameLaunchService.isNixxesOrSonyTitle(
            title: "Custom Title",
            executableURL: URL(fileURLWithPath: "/Games/nixxes_sample.exe")
        ))

        // Non-Nixxes titles
        XCTAssertFalse(GameLaunchService.isNixxesOrSonyTitle(
            title: "Need for Speed: Most Wanted",
            executableURL: URL(fileURLWithPath: "/Games/speed.exe")
        ))
        XCTAssertFalse(GameLaunchService.isNixxesOrSonyTitle(
            title: "Hogwarts Legacy",
            executableURL: URL(fileURLWithPath: "/Games/HogwartsLegacy.exe")
        ))
        XCTAssertFalse(GameLaunchService.isNixxesOrSonyTitle(
            title: "Cyberpunk 2077",
            executableURL: URL(fileURLWithPath: "/Games/Cyberpunk2077.exe")
        ))
    }

    func testWindowsLaunchNixxesInjectsNoLauncherAndCrossOverArguments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusNixxesHarness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        // Mock CrossOver runtime script that dumps arguments and ROSETTA_ADVERTISE_AVX
        let runtimeURL = root.appendingPathComponent("SharedSupport/CrossOver/bin/wine")
        try FileManager.default.createDirectory(at: runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$ROSETTA_ADVERTISE_AVX\" \"$*\" \"$PWD\"\n"
            .write(to: runtimeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtimeURL.path)

        let executableURL = root.appendingPathComponent("Spider-Man2.exe")
        try Data("fake exe".utf8).write(to: executableURL)

        let runtime = DetectedRuntime(
            id: UUID(),
            name: "CrossOver Wine",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "26.3",
            architecture: "arm64",
            status: "ready"
        )
        let prefix = WinePrefix(
            name: "Harness prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(
            title: "Marvel's Spider-Man 2",
            store: .local,
            storeApplicationID: "spiderman-2",
            installationURL: root,
            executableURL: executableURL
        )

        let outcome = try await GameLaunchService().launchWindows(
            game: game,
            runtime: runtime,
            prefix: prefix
        )

        let output = outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 3)
        // 1. ROSETTA_ADVERTISE_AVX is set to 1
        XCTAssertEqual(parts[0], "1")
        // 2. Arguments contain --bottle, --workdir, game path, and -nolauncher
        let rawArgs = parts[1]
        XCTAssertTrue(rawArgs.contains("--bottle Harness prefix"))
        XCTAssertTrue(rawArgs.contains("--workdir \(root.path)"))
        XCTAssertTrue(rawArgs.contains(executableURL.path))
        XCTAssertTrue(rawArgs.contains("-nolauncher"))
        XCTAssertTrue(rawArgs.contains("--dll nvngx=d"))
        XCTAssertEqual(outcome.exitStatus, 0)

        // Test non-Nixxes game does NOT inject -nolauncher or DLSS overrides
        let speedExecutableURL = root.appendingPathComponent("speed.exe")
        try Data("fake speed exe".utf8).write(to: speedExecutableURL)
        let standardGame = Game(
            title: "Standard Racing Game",
            store: .local,
            storeApplicationID: "racing-game",
            installationURL: root,
            executableURL: speedExecutableURL
        )
        let outcomeStandard = try await GameLaunchService().launchWindows(
            game: standardGame,
            runtime: runtime,
            prefix: prefix
        )
        let outputStandard = outcomeStandard.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let partsStandard = outputStandard.components(separatedBy: "|")
        XCTAssertFalse(partsStandard[1].contains("-nolauncher"))
        XCTAssertFalse(partsStandard[1].contains("nvngx=d"))
    }

    func testWineBottleRegistryMergeSectionRobustness() throws {
        let originalLines = [
            "WINE REGISTRY Version 2",
            "[Software\\\\Insomniac Games\\\\Marvel's Spider-Man 2\\\\Graphics] 1793357060",
            "#time=1dd685b9ed8695e",
            "\"AA\"=dword:00000002",
            "\"DynamicResolutionTargetFPS\"=dword:0000001e",
            "\"Fullscreen\"=dword:00000001",
            "\"WindowWidth\"=dword:000005a0",
            "",
            "[Software\\\\Wine\\\\DirectSound] 1793052511",
            "#time=1dd6596895b3e02",
            "\"MaxBuffers\"=dword:00000040"
        ]

        let settings = [
            "\"DynamicResolutionTargetFPS\"": "dword:00000000",
            "\"Fullscreen\"": "dword:00000000",
            "\"AsyncCompute\"": "dword:00000000",
            "\"UpscaleMethod\"": "dword:00000003"
        ]

        let merged = WineBottleService.mergeRegistrySection(
            named: "Software\\\\Insomniac Games\\\\Marvel's Spider-Man 2\\\\Graphics",
            settings: settings,
            into: originalLines
        )

        let mergedText = merged.joined(separator: "\n")
        XCTAssertTrue(mergedText.contains("\"DynamicResolutionTargetFPS\"=dword:00000000"))
        XCTAssertFalse(mergedText.contains("\"DynamicResolutionTargetFPS\"=dword:0000001e"))
        XCTAssertTrue(mergedText.contains("\"Fullscreen\"=dword:00000000"))
        XCTAssertFalse(mergedText.contains("\"Fullscreen\"=dword:00000001"))
        XCTAssertTrue(mergedText.contains("\"AsyncCompute\"=dword:00000000"))
        XCTAssertTrue(mergedText.contains("\"UpscaleMethod\"=dword:00000003"))
        XCTAssertTrue(mergedText.contains("\"AA\"=dword:00000002"))
        XCTAssertTrue(mergedText.contains("\"WindowWidth\"=dword:000005a0"))
        XCTAssertTrue(mergedText.contains("[Software\\\\Wine\\\\DirectSound] 1793052511"))
        XCTAssertTrue(mergedText.contains("\"MaxBuffers\"=dword:00000040"))

        let newSectionMerged = WineBottleService.mergeRegistrySection(
            named: "Software\\\\Wine\\\\AppDefaults\\\\Spider-Man2.exe\\\\DllOverrides",
            settings: ["\"d3d12\"": "\"native,builtin\""],
            into: merged
        )
        let newSectionText = newSectionMerged.joined(separator: "\n")
        XCTAssertTrue(newSectionText.contains("[Software\\\\Wine\\\\AppDefaults\\\\Spider-Man2.exe\\\\DllOverrides]"))
        XCTAssertTrue(newSectionText.contains("\"d3d12\"=\"native,builtin\""))

        // Multiline continuation replacement test
        let multilineOriginal = [
            "[System\\\\CurrentControlSet\\\\Enum\\\\PCI\\\\VEN_106B&DEV_03F1\\\\00000000\\\\Properties\\\\{A8B865DD-2E3D-4094-AD97-E593A70C75D6}\\\\0008] 1793062733",
            "#time=1dd65ae5624f786",
            "@=hex(ffff0012):50,00,43,00,49,00,5c,00,\\",
            "  00,42,00,26,00,\\",
            "  00,00,00,00",
            "",
            "[System\\\\CurrentControlSet\\\\NextKey] 1793062733",
            "\"Key\"=\"Val\""
        ]
        let multilineMerged = WineBottleService.mergeRegistrySection(
            named: "System\\\\CurrentControlSet\\\\Enum\\\\PCI\\\\VEN_106B&DEV_03F1\\\\00000000\\\\Properties\\\\{A8B865DD-2E3D-4094-AD97-E593A70C75D6}\\\\0008",
            settings: ["@": "hex(ffff0012):new_value"],
            into: multilineOriginal
        )
        let multiText = multilineMerged.joined(separator: "\n")
        XCTAssertTrue(multiText.contains("@=hex(ffff0012):new_value"))
        XCTAssertFalse(multiText.contains("00,42,00,26,00"))
        XCTAssertFalse(multiText.contains("00,00,00,00"))
        XCTAssertTrue(multiText.contains("[System\\\\CurrentControlSet\\\\NextKey]"))
    }

    func testWindowsLaunchNixxesD3DMetalPreservesDXGIAndD3D12Proxy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusNixxesD3DHarness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        // Mock runtime dumping WINEDLLOVERRIDES, arguments, and PWD
        let runtimeURL = root.appendingPathComponent("SharedSupport/CrossOver/bin/wine")
        try FileManager.default.createDirectory(at: runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$WINEDLLOVERRIDES\" \"$*\" \"$PWD\"\n"
            .write(to: runtimeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtimeURL.path)

        let executableURL = root.appendingPathComponent("Spider-Man2.exe")
        try Data("fake exe".utf8).write(to: executableURL)

        // Also place a mock local d3d12.dll
        try Data("fake d3d12".utf8).write(to: root.appendingPathComponent("d3d12.dll"))

        let runtime = DetectedRuntime(
            id: UUID(),
            name: "CrossOver Wine",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "26.3",
            architecture: "arm64",
            status: "ready"
        )
        let prefix = WinePrefix(
            name: "Harness prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(
            title: "Marvel's Spider-Man 2",
            store: .local,
            storeApplicationID: "spiderman-2",
            installationURL: root,
            executableURL: executableURL,
            graphicsBackend: "d3dmetal"
        )

        let outcome = try await GameLaunchService().launchWindows(
            game: game,
            runtime: runtime,
            prefix: prefix
        )

        let output = outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 3)

        let envOverrides = parts[0]
        let rawArgs = parts[1]

        // 1. WINEDLLOVERRIDES contains all critical components:
        // - nvngx=d (disables DLSS crashes)
        // - dxgi=native,builtin (connects swapchain to D3DMetal with builtin fallback)
        // - d3d11,dxgi=native,builtin
        // - d3d12=native,builtin (loads local proxy shim)
        XCTAssertTrue(envOverrides.contains("nvngx=d"))
        XCTAssertTrue(envOverrides.contains("dxgi=native,builtin"))
        XCTAssertTrue(envOverrides.contains("d3d12=native,builtin"))

        // 2. CrossOver arguments contain consolidated --dll option matching overrides
        XCTAssertTrue(rawArgs.contains("--dll nvngx=d"))
        XCTAssertTrue(rawArgs.contains("dxgi=native,builtin"))
        XCTAssertTrue(rawArgs.contains("d3d12=native,builtin"))
        XCTAssertTrue(rawArgs.contains("-nolauncher"))
        XCTAssertEqual(outcome.exitStatus, 0)
    }

    func testWindowsLaunchNormalizesBareNativeDXGIAndD3D11ToBuiltinFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusBareOverrideHarness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        let runtimeURL = root.appendingPathComponent("SharedSupport/CrossOver/bin/wine")
        try FileManager.default.createDirectory(at: runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$WINEDLLOVERRIDES\" \"$*\" \"$PWD\"\n"
            .write(to: runtimeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtimeURL.path)

        let executableURL = root.appendingPathComponent("game.exe")
        try Data("fake exe".utf8).write(to: executableURL)

        let runtime = DetectedRuntime(
            id: UUID(),
            name: "CrossOver Wine",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "26.3",
            architecture: "arm64",
            status: "ready"
        )
        let prefix = WinePrefix(
            name: "Harness prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(
            title: "Generic DX12 Game",
            store: .local,
            storeApplicationID: "dx12-game",
            installationURL: root,
            executableURL: executableURL,
            graphicsBackend: "d3dmetal",
            customEnvironment: ["WINEDLLOVERRIDES": "dxgi=native;d3d12=n;vcruntime140=native"]
        )

        let outcome = try await GameLaunchService().launchWindows(
            game: game,
            runtime: runtime,
            prefix: prefix
        )

        let output = outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 3)

        let envOverrides = parts[0]
        let rawArgs = parts[1]

        // dxgi=native and d3d11=native and d3d12=n should always have ,builtin appended to avoid NTSTATUS 0xC0000135 (exit code 53)
        XCTAssertTrue(envOverrides.contains("dxgi=native,builtin"))
        XCTAssertTrue(envOverrides.contains("d3d12=native,builtin"))
        XCTAssertTrue(envOverrides.contains("vcruntime140=native"))
        XCTAssertTrue(rawArgs.contains("dxgi=native,builtin"))
        XCTAssertTrue(rawArgs.contains("d3d12=native,builtin"))
        XCTAssertEqual(outcome.exitStatus, 0)

        // Comprehensive direct unit test coverage for normalizeDllOverrides
        XCTAssertEqual(GameLaunchService.normalizeDllOverrides("dxgi=native"), "dxgi=native,builtin")
        XCTAssertEqual(GameLaunchService.normalizeDllOverrides("dxgi=n"), "dxgi=native,builtin")
        XCTAssertEqual(GameLaunchService.normalizeDllOverrides("d3d11=native"), "d3d11=native,builtin")
        XCTAssertEqual(GameLaunchService.normalizeDllOverrides("d3d11=n"), "d3d11=native,builtin")
        XCTAssertEqual(GameLaunchService.normalizeDllOverrides("d3d12=native"), "d3d12=native,builtin")
        XCTAssertEqual(GameLaunchService.normalizeDllOverrides("d3d12=n"), "d3d12=native,builtin")
        XCTAssertEqual(GameLaunchService.normalizeDllOverrides("d3d11,dxgi=native"), "d3d11,dxgi=native,builtin")
        XCTAssertEqual(GameLaunchService.normalizeDllOverrides("d3d12,d3d11,dxgi=n"), "d3d12,d3d11,dxgi=native,builtin")
        XCTAssertEqual(
            GameLaunchService.normalizeDllOverrides("dxgi=native;d3d11=native;dxgi=native,builtin"),
            "dxgi=native,builtin;d3d11=native,builtin;dxgi=native,builtin"
        )
        XCTAssertEqual(
            GameLaunchService.normalizeDllOverrides("vcruntime140=native;msvcp140=n;nvngx=d"),
            "vcruntime140=native;msvcp140=n;nvngx=d"
        )
        XCTAssertEqual(GameLaunchService.normalizeDllOverrides("dxgi=builtin;d3d11=b"), "dxgi=builtin;d3d11=b")
    }

    func testSyncDefaultBottleRegistry() throws {
        let bottleURL = URL(fileURLWithPath: "/Users/godjoel/Library/Application Support/Overcross/Prefixes/DefaultBottle")
        if FileManager.default.fileExists(atPath: bottleURL.appendingPathComponent("user.reg").path) {
            _ = try WineBottleService.syncBottleRegistry(prefixURL: bottleURL, retina: false)
            let content = try String(contentsOf: bottleURL.appendingPathComponent("user.reg"), encoding: .utf8)
            XCTAssertTrue(content.contains("\"DynamicResolutionTargetFPS\"=dword:00000000"))
            XCTAssertFalse(content.contains("\"DynamicResolutionTargetFPS\"=dword:0000001e"))
        }
    }

    func testCrossOverDLSSIsolationAndRestoration() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossOverDLSSIsolationTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let gptkDir = tempRoot.appendingPathComponent("lib64/apple_gptk/wine/x86_64-windows", isDirectory: true)
        let dxmtDir = tempRoot.appendingPathComponent("lib/dxmt/x86_64-windows", isDirectory: true)
        try FileManager.default.createDirectory(at: gptkDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dxmtDir, withIntermediateDirectories: true)

        let gptkDLL = gptkDir.appendingPathComponent("nvngx.dll")
        let dxmtDLL = dxmtDir.appendingPathComponent("nvngx.dll")
        try Data("gptk nvngx stub".utf8).write(to: gptkDLL)
        try Data("dxmt nvngx stub".utf8).write(to: dxmtDLL)

        // 1. Isolate
        let isolation = GameOptimizationService.isolateCrossOverDLSS(cxRootURL: tempRoot)
        XCTAssertEqual(isolation.isolatedPaths.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gptkDLL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dxmtDLL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gptkDir.appendingPathComponent("nvngx.dll.isolated").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dxmtDir.appendingPathComponent("nvngx.dll.isolated").path))

        // 2. Restore
        let restored = isolation.restore()
        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gptkDLL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dxmtDLL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gptkDir.appendingPathComponent("nvngx.dll.isolated").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dxmtDir.appendingPathComponent("nvngx.dll.isolated").path))

        // 3. Test recovery of orphaned .disabled or .isolated files
        let disabledFile = gptkDir.appendingPathComponent("nvngx.dll.disabled")
        try FileManager.default.moveItem(at: gptkDLL, to: disabledFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gptkDLL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: disabledFile.path))

        let globalRestored = GameOptimizationService.restoreAllIsolatedDLSSStubs(cxRootURL: tempRoot)
        XCTAssertTrue(globalRestored.contains(gptkDLL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gptkDLL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disabledFile.path))
    }

    func testNixxesLaunchInjectsNoStreamlineAndRestoresIsolation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusNixxesStreamlineHarness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try Data("registry".utf8).write(to: root.appendingPathComponent("system.reg"))

        let runtimeURL = root.appendingPathComponent("SharedSupport/CrossOver/bin/wine")
        try FileManager.default.createDirectory(at: runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s|%s\\n' \"$*\" \"$PWD\"\n"
            .write(to: runtimeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtimeURL.path)

        // Create mock GPTK nvngx stub under runtime root
        let gptkDir = root.appendingPathComponent("SharedSupport/CrossOver/lib64/apple_gptk/wine/x86_64-windows", isDirectory: true)
        try FileManager.default.createDirectory(at: gptkDir, withIntermediateDirectories: true)
        let stubURL = gptkDir.appendingPathComponent("nvngx.dll")
        try Data("gptk stub".utf8).write(to: stubURL)

        let executableURL = root.appendingPathComponent("Spider-Man2.exe")
        try Data("fake exe".utf8).write(to: executableURL)

        let runtime = DetectedRuntime(
            id: UUID(),
            name: "CrossOver Wine",
            executableURL: runtimeURL,
            winebootURL: nil,
            version: "26.3",
            architecture: "arm64",
            status: "ready"
        )
        let prefix = WinePrefix(
            name: "Harness prefix",
            url: root,
            runtimeURL: runtimeURL,
            architecture: .win64
        )
        let game = Game(
            title: "Marvel's Spider-Man 2",
            store: .local,
            storeApplicationID: "spiderman-2",
            installationURL: root,
            executableURL: executableURL
        )

        let outcome = try await GameLaunchService().launchWindows(
            game: game,
            runtime: runtime,
            prefix: prefix
        )

        let output = outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(output.contains("-nolauncher"))
        XCTAssertTrue(output.contains("-noStreamline"))
        // Check that isolation was cleanly restored after process execution finished
        XCTAssertTrue(FileManager.default.fileExists(atPath: stubURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gptkDir.appendingPathComponent("nvngx.dll.isolated").path))
    }

    func testBottleRegistryModernDriverVersionSync() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusDriverVersionHarness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let systemRegURL = root.appendingPathComponent("system.reg")
        let initialSystemReg = """
        WINE REGISTRY Version 2
        [System\\\\CurrentControlSet\\\\Control\\\\Class\\\\{4D36E968-E325-11CE-BFC1-08002BE10318}\\\\0000] 1793382166
        "DriverDate"="10-30-2020"
        "DriverDesc"="Old Compatibility Mode"
        "DriverVersion"="30.0.15.1233"

        [System\\\\CurrentControlSet\\\\Enum\\\\PCI\\\\VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00\\\\00000000] 1793382166
        "Class"="Display"
        "HardwareID"=str(7):"PCI\\\\VEN_106B&DEV_03F1\\0"
        """
        try initialSystemReg.write(to: systemRegURL, atomically: true, encoding: .utf8)

        _ = try WineBottleService.syncBottleRegistry(prefixURL: root, retina: false)

        let updated = try String(contentsOf: systemRegURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("\"DriverVersion\"=\"32.0.12011.1036\""))
        XCTAssertFalse(updated.contains("\"DriverVersion\"=\"30.0.15.1233\""))
        let expectedGPU = "AMD Radeon RX 7900 XTX"
        XCTAssertTrue(updated.contains("\"DriverDesc\"=\"\(expectedGPU)\""))
        XCTAssertTrue(updated.contains("\"HardwareInformation.MemorySize\"=dword:ffffffff"))
        XCTAssertTrue(updated.contains("Keyboard Layouts\\\\00000409"))
        XCTAssertTrue(updated.contains("VEN_1002&DEV_66AF"))
        XCTAssertTrue(updated.contains("VEN_106B&DEV_03F1"))
        XCTAssertTrue(updated.contains("Control\\\\Video\\\\"))
        XCTAssertTrue(updated.contains("MatchingDeviceId"))
        XCTAssertTrue(updated.contains("[System\\\\CurrentControlSet\\\\Enum\\\\PCI\\\\VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00\\\\00000000\\\\Properties\\\\{A8B865DD-2E3D-4094-AD97-E593A70C75D6}\\\\0008]"))
        XCTAssertTrue(updated.contains("[System\\\\CurrentControlSet\\\\Enum\\\\PCI\\\\VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00\\\\00000000\\\\Properties\\\\{A8B865DD-2E3D-4094-AD97-E593A70C75D6}\\\\0003]"))
        XCTAssertTrue(updated.contains("[System\\\\CurrentControlSet\\\\Enum\\\\PCI\\\\VEN_1002&DEV_66AF&SUBSYS_00000000&REV_00\\\\00000000\\\\Properties\\\\{A8B865DD-2E3D-4094-AD97-E593A70C75D6}\\\\0008]"))
        XCTAssertTrue(updated.contains("DeviceClasses\\\\{5B45201D-F2F2-4F3B-85BB-30FF1F953599}"))
    }

    func testModalPreflightEvaluatorRejectsNonWineAppsAndMatchesWineDialogs() {
        // 1. Non-Wine app windows with matching keywords must NEVER be treated as preflight dialogs
        let chromeEval = GameLaunchService.evaluateWindowForModalPreflight(
            ownerName: "Google Chrome",
            windowName: "AMD Radeon Graphics Driver Download - Chrome",
            bounds: (x: 50, y: 50, width: 800, height: 400),
            targetProcessName: "Spider-Man2.exe"
        )
        XCTAssertFalse(chromeEval.isDialog)
        XCTAssertFalse(chromeEval.isGameWindow)

        let terminalEval = GameLaunchService.evaluateWindowForModalPreflight(
            ownerName: "Terminal",
            windowName: "Error: build failed - warning: unresolved symbol",
            bounds: (x: 10, y: 10, width: 700, height: 350),
            targetProcessName: "Spider-Man2.exe"
        )
        XCTAssertFalse(terminalEval.isDialog)
        XCTAssertFalse(terminalEval.isGameWindow)

        let safariEval = GameLaunchService.evaluateWindowForModalPreflight(
            ownerName: "Safari",
            windowName: "SpiderMan2Fix / Releases",
            bounds: (x: 0, y: 0, width: 850, height: 480),
            targetProcessName: "Spider-Man2.exe"
        )
        XCTAssertFalse(safariEval.isDialog)
        XCTAssertFalse(safariEval.isGameWindow)

        // 2. Wine / CrossOver dialogs with driver warnings or alerts must be matched as dialogs
        let wineDriverEval = GameLaunchService.evaluateWindowForModalPreflight(
            ownerName: "wine64-preloader",
            windowName: "Old Driver detected",
            bounds: (x: 200, y: 200, width: 420, height: 220),
            targetProcessName: "Spider-Man2.exe"
        )
        XCTAssertTrue(wineDriverEval.isDialog)
        XCTAssertFalse(wineDriverEval.isGameWindow)

        let crossOverNoGPUEval = GameLaunchService.evaluateWindowForModalPreflight(
            ownerName: "CrossOver",
            windowName: "No installed graphics card detected",
            bounds: (x: 150, y: 150, width: 450, height: 200),
            targetProcessName: "Spider-Man2.exe"
        )
        XCTAssertTrue(crossOverNoGPUEval.isDialog)
        XCTAssertFalse(crossOverNoGPUEval.isGameWindow)

        let wineEmptyTitleDialogEval = GameLaunchService.evaluateWindowForModalPreflight(
            ownerName: "wine",
            windowName: "",
            bounds: (x: 100, y: 100, width: 350, height: 160),
            targetProcessName: "Spider-Man2.exe"
        )
        XCTAssertTrue(wineEmptyTitleDialogEval.isDialog)
        XCTAssertFalse(wineEmptyTitleDialogEval.isGameWindow)

        // 3. Full-resolution game windows must be recognized as game windows, not dialogs
        let gameWindowEval = GameLaunchService.evaluateWindowForModalPreflight(
            ownerName: "Spider-Man2.exe",
            windowName: "Marvel's Spider-Man 2",
            bounds: (x: 0, y: 0, width: 1440, height: 810),
            targetProcessName: "Spider-Man2.exe"
        )
        XCTAssertFalse(gameWindowEval.isDialog)
        XCTAssertTrue(gameWindowEval.isGameWindow)
    }

    func testDLSSRestorationPreservesRealStubWhenEmptyFileExists() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusDLSSZeroByteHarness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let gptkDir = tempRoot.appendingPathComponent("lib64/apple_gptk/wine/x86_64-windows", isDirectory: true)
        try FileManager.default.createDirectory(at: gptkDir, withIntermediateDirectories: true)

        let gptkDLL = gptkDir.appendingPathComponent("nvngx.dll")
        let isolatedDLL = gptkDir.appendingPathComponent("nvngx.dll.isolated")
        let realContent = "real original stub data"
        try Data(realContent.utf8).write(to: isolatedDLL)

        // Simulate an empty placeholder file having been created at the original path
        try Data().write(to: gptkDLL)
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: gptkDLL.path)[.size] as? UInt64), 0)

        let isolation = CrossOverDLSSIsolation(isolatedPaths: [(original: gptkDLL, isolated: isolatedDLL)])
        let restored = isolation.restore()

        XCTAssertTrue(restored.contains(gptkDLL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gptkDLL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolatedDLL.path))
        let restoredString = try String(contentsOf: gptkDLL, encoding: .utf8)
        XCTAssertEqual(restoredString, realContent)

        // Also verify .bak restoration
        let bakDLL = gptkDir.appendingPathComponent("nvngx.dll.bak")
        try FileManager.default.moveItem(at: gptkDLL, to: bakDLL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gptkDLL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakDLL.path))

        let globalRestored = GameOptimizationService.restoreAllIsolatedDLSSStubs(cxRootURL: tempRoot)
        XCTAssertTrue(globalRestored.contains(gptkDLL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gptkDLL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakDLL.path))
    }

    // MARK: - Spider-Man 2 & MacGameFix Tests

    func testSpiderMan2Detection() {
        XCTAssertTrue(GameOptimizationService.isSpiderMan2(title: "Marvel's Spider-Man 2", executableURL: nil))
        XCTAssertTrue(GameOptimizationService.isSpiderMan2(title: "Spider-Man 2", executableURL: nil))
        XCTAssertTrue(GameOptimizationService.isSpiderMan2(title: "Unknown", executableURL: URL(fileURLWithPath: "/Games/Spider-Man2.exe")))
        XCTAssertTrue(GameOptimizationService.isSpiderMan2(title: "Custom", executableURL: URL(fileURLWithPath: "/Games/Spider-Man 2.exe")))
        XCTAssertFalse(GameOptimizationService.isSpiderMan2(title: "Marvel's Spider-Man Remastered", executableURL: URL(fileURLWithPath: "/Games/Spider-Man.exe")))
        XCTAssertFalse(GameOptimizationService.isSpiderMan2(title: "Cyberpunk 2077", executableURL: URL(fileURLWithPath: "/Games/Cyberpunk2077.exe")))
    }

    func testSpiderMan2LegacyD3D12Neutralization() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusSM2LegacyD3D12-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let d3d12URL = tempRoot.appendingPathComponent("d3d12.dll")
        try Data("mock legacy macprotips d3d12 shim".utf8).write(to: d3d12URL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: d3d12URL.path))
        let neutralized = GameOptimizationService.neutralizeLegacyD3D12InSpiderMan2(at: tempRoot)
        XCTAssertTrue(neutralized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: d3d12URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("d3d12.dll.bak").path))

        // Neutralizing again when already absent should return false
        XCTAssertFalse(GameOptimizationService.neutralizeLegacyD3D12InSpiderMan2(at: tempRoot))
    }

    private func createMockSpiderMan2Executable(at url: URL, timestamp: UInt32 = 0x679b8cd0, sizeOfImage: UInt32 = 0x0ce54000) throws {
        var data = Data(count: 256)
        data[0] = 0x4D // M
        data[1] = 0x5A // Z
        let peOffset: UInt32 = 0x80
        withUnsafeBytes(of: peOffset.littleEndian) { data.replaceSubrange(0x3c..<0x40, with: $0) }
        data[Int(peOffset)] = 0x50 // P
        data[Int(peOffset) + 1] = 0x45 // E
        data[Int(peOffset) + 2] = 0x00
        data[Int(peOffset) + 3] = 0x00
        withUnsafeBytes(of: timestamp.littleEndian) { data.replaceSubrange((Int(peOffset) + 8)..<(Int(peOffset) + 12), with: $0) }
        withUnsafeBytes(of: sizeOfImage.littleEndian) { data.replaceSubrange((Int(peOffset) + 80)..<(Int(peOffset) + 84), with: $0) }
        try data.write(to: url)
    }

    func testSpiderMan2FixStatusVerification() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusSM2StatusVerification-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // 1. Not Spider-Man 2 (no Spider-Man2.exe)
        XCTAssertEqual(GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot), .notSpiderMan2)

        // 2. Spider-Man 2 executable present (valid PE), but amd_ags_x64.dll missing -> missing
        let exeURL = tempRoot.appendingPathComponent("Spider-Man2.exe")
        try createMockSpiderMan2Executable(at: exeURL)
        XCTAssertEqual(GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot), .missing)

        // 3. Stock amd_ags_x64.dll (no marker) and no real DLL -> missing
        let agsURL = tempRoot.appendingPathComponent("amd_ags_x64.dll")
        try Data("untouched original ags dll".utf8).write(to: agsURL)
        XCTAssertEqual(GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot), .missing)

        // 4. Proxy amd_ags_x64.dll with marker, but amd_ags_x64_real.dll missing -> broken
        try Data("proxy header sm2-tpose-fix.log trailing data".utf8).write(to: agsURL)
        if case .broken(let reason) = GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot) {
            XCTAssertTrue(reason.contains("amd_ags_x64_real.dll"))
        } else {
            XCTFail("Expected broken status when real DLL is missing")
        }

        // 5. Real DLL present, but sm2fix.ini missing -> broken
        let realAgsURL = tempRoot.appendingPathComponent("amd_ags_x64_real.dll")
        try Data("real ags dll".utf8).write(to: realAgsURL)
        if case .broken(let reason) = GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot) {
            XCTAssertTrue(reason.contains("sm2fix.ini"))
        } else {
            XCTFail("Expected broken status when sm2fix.ini is missing")
        }

        // 6. sm2fix.ini present, but shaders missing -> broken
        let iniURL = tempRoot.appendingPathComponent("sm2fix.ini")
        let iniContent = """
        # Spider-Man 2 T-Pose Fix
        game_build = 679b8cd0-0ce54000
        shaders = 125a4957ab64d24d 14902794dd7134e4 3d50acdb571dce22 9538ca33c087a84c
        mgvf_fog_barrier = 1
        """
        try iniContent.write(to: iniURL, atomically: true, encoding: .utf8)
        if case .broken(let reason) = GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot) {
            XCTAssertTrue(reason.contains("Missing shader dxil"))
        } else {
            XCTFail("Expected broken status when shaders are missing")
        }

        // 7. All 4 shaders present with DXBC header (>= 32 bytes) -> installed
        let shaders = ["125a4957ab64d24d", "14902794dd7134e4", "3d50acdb571dce22", "9538ca33c087a84c"]
        for shader in shaders {
            let shaderURL = tempRoot.appendingPathComponent("sm2fix-pool-\(shader).dxil")
            var dxbcData = Data("DXBC".utf8)
            dxbcData.append(Data(repeating: 0, count: 64))
            try dxbcData.write(to: shaderURL)
        }

        let status = GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot)
        XCTAssertEqual(status, .installed(build: "679b8cd0-0ce54000", fogBarrier: true))
    }

    func testSpiderMan2OptimizationIntegration() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusSM2OptimizationIntegration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let exeURL = tempRoot.appendingPathComponent("Spider-Man2.exe")
        try createMockSpiderMan2Executable(at: exeURL)

        // Mock conflicting legacy d3d12.dll
        let d3d12URL = tempRoot.appendingPathComponent("d3d12.dll")
        try Data("mock d3d12".utf8).write(to: d3d12URL)

        // Mock problematic libraries
        let dstorageURL = tempRoot.appendingPathComponent("dstorage.dll")
        let interposerURL = tempRoot.appendingPathComponent("sl.interposer.dll")
        try Data("dstorage".utf8).write(to: dstorageURL)
        try Data("interposer".utf8).write(to: interposerURL)

        // Set up valid MacGameFix installation
        let agsURL = tempRoot.appendingPathComponent("amd_ags_x64.dll")
        try Data("proxy header sm2-tpose-fix.log trailing".utf8).write(to: agsURL)
        let realAgsURL = tempRoot.appendingPathComponent("amd_ags_x64_real.dll")
        try Data("real ags".utf8).write(to: realAgsURL)
        let iniURL = tempRoot.appendingPathComponent("sm2fix.ini")
        let iniContent = "game_build = 679b8cd0-0ce54000\nshaders = 125a4957ab64d24d\nmgvf_fog_barrier = 1\n"
        try iniContent.write(to: iniURL, atomically: true, encoding: .utf8)
        let shaderURL = tempRoot.appendingPathComponent("sm2fix-pool-125a4957ab64d24d.dxil")
        var dxbcData = Data("DXBC".utf8)
        dxbcData.append(Data(repeating: 0, count: 64))
        try dxbcData.write(to: shaderURL)

        let game = Game(
            title: "Marvel's Spider-Man 2",
            store: .local,
            storeApplicationID: "sm2",
            installationURL: tempRoot,
            executableURL: exeURL,
            graphicsBackend: "d3dmetal"
        )

        let prefixURL = tempRoot.appendingPathComponent("Prefix")
        try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)

        let report = GameOptimizationService().optimize(game: game, prefixURL: prefixURL)

        // 1. DirectStorage neutralized and essential interposer preserved
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("dstorage.dll.bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstorageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: interposerURL.path))

        // 2. Legacy d3d12.dll neutralized
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("d3d12.dll.bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d3d12URL.path))

        // 3. MacGameFix verified in report details
        XCTAssertTrue(report.details.contains { $0.contains("Neutralized legacy d3d12.dll in favor of MacGameFix proxy") })
        XCTAssertTrue(report.details.contains { $0.contains("Verified MacGameFix active for Spider-Man 2") })
        XCTAssertNotNil(report.summary)
        XCTAssertTrue(report.summary!.contains("MacGameFix"))
    }

    func testSpiderMan2RegistryInputSync() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusSM2RegistryInput-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let userRegURL = tempRoot.appendingPathComponent("user.reg")
        let initialUserReg = """
        WINE REGISTRY Version 2
        [Software\\\\Wine\\\\Mac Driver] 1793052511
        "RetinaMode"="N"
        """
        try initialUserReg.write(to: userRegURL, atomically: true, encoding: .utf8)

        _ = try WineBottleService.syncBottleRegistry(prefixURL: tempRoot, retina: false)

        let updated = try String(contentsOf: userRegURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("[Software\\\\Insomniac Games\\\\Marvel's Spider-Man 2\\\\Input]"))
        XCTAssertTrue(updated.contains("\"EnableLibScePad\"=dword:00000001"))
        XCTAssertTrue(updated.contains("\"EnableWindowsGamingInput\"=dword:00000001"))
        XCTAssertTrue(updated.contains("\"ShowLauncher\"=dword:00000000"))
        XCTAssertTrue(updated.contains("\"FirstRun\"=dword:00000000"))
    }

    func testSpiderMan2PEParserValidatesSignatures() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusSM2PEParser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let testFile = tempRoot.appendingPathComponent("test.exe")

        // 1. Non-PE / zero filled
        try Data(repeating: 0, count: 512).write(to: testFile)
        XCTAssertNil(GameOptimizationService.readSpiderMan2GameBuild(from: testFile))

        // 2. Only "MZ" without valid PE header
        var badMZ = Data(repeating: 0, count: 512)
        badMZ[0] = 0x4D
        badMZ[1] = 0x5A
        try badMZ.write(to: testFile)
        XCTAssertNil(GameOptimizationService.readSpiderMan2GameBuild(from: testFile))

        // 3. Genuine PE format
        try createMockSpiderMan2Executable(at: testFile, timestamp: 0x679b8cd0, sizeOfImage: 0x0ce54000)
        XCTAssertEqual(GameOptimizationService.readSpiderMan2GameBuild(from: testFile), "679b8cd0-0ce54000")
    }

    func testSpiderMan2FixStatusRejectsCorruptedShaderAndBuildMismatch() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusSM2RejectsTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let exeURL = tempRoot.appendingPathComponent("Spider-Man2.exe")
        try createMockSpiderMan2Executable(at: exeURL, timestamp: 0x11112222, sizeOfImage: 0x33334444)

        let agsURL = tempRoot.appendingPathComponent("amd_ags_x64.dll")
        try Data("header sm2-tpose-fix.log trailing".utf8).write(to: agsURL)
        let realAgsURL = tempRoot.appendingPathComponent("amd_ags_x64_real.dll")
        try Data("real ags".utf8).write(to: realAgsURL)

        // 1. Build mismatch
        let iniURL = tempRoot.appendingPathComponent("sm2fix.ini")
        let mismatchIni = "game_build = 99999999-88888888\nshaders = 125a4957ab64d24d\n"
        try mismatchIni.write(to: iniURL, atomically: true, encoding: .utf8)

        var status = GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot)
        if case .broken(let reason) = status {
            XCTAssertTrue(reason.contains("Game build mismatch"))
        } else {
            XCTFail("Expected broken status for build mismatch, got \(status)")
        }

        // 2. Matching build, but corrupt shader (0 bytes)
        let matchingIni = "game_build = 11112222-33334444\nshaders = 125a4957ab64d24d\n"
        try matchingIni.write(to: iniURL, atomically: true, encoding: .utf8)
        let shaderURL = tempRoot.appendingPathComponent("sm2fix-pool-125a4957ab64d24d.dxil")
        try Data().write(to: shaderURL)

        status = GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot)
        if case .broken(let reason) = status {
            XCTAssertTrue(reason.contains("Damaged or incomplete shader dxil"))
        } else {
            XCTFail("Expected broken status for empty shader, got \(status)")
        }

        // 3. Shader with invalid magic
        try Data(repeating: 0x41, count: 64).write(to: shaderURL)
        status = GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot)
        if case .broken(let reason) = status {
            XCTAssertTrue(reason.contains("Damaged shader dxil"))
        } else {
            XCTFail("Expected broken status for non-DXBC shader, got \(status)")
        }
    }

    func testSpiderMan2Restore() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusSM2RestoreTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let exeURL = tempRoot.appendingPathComponent("Spider-Man2.exe")
        try createMockSpiderMan2Executable(at: exeURL)

        let liveProxy = tempRoot.appendingPathComponent("amd_ags_x64.dll")
        try Data("proxy marker sm2-tpose-fix.log".utf8).write(to: liveProxy)
        let realAgs = tempRoot.appendingPathComponent("amd_ags_x64_real.dll")
        try Data("real original ags content".utf8).write(to: realAgs)

        let d3d12Bak = tempRoot.appendingPathComponent("d3d12.dll.bak")
        try Data("original d3d12".utf8).write(to: d3d12Bak)

        let iniURL = tempRoot.appendingPathComponent("sm2fix.ini")
        try "game_build = 679b8cd0-0ce54000\nshaders = 125a4957ab64d24d\n".write(to: iniURL, atomically: true, encoding: .utf8)
        let shaderURL = tempRoot.appendingPathComponent("sm2fix-pool-125a4957ab64d24d.dxil")
        try Data(repeating: 0x20, count: 64).write(to: shaderURL)

        let (restored, details) = GameOptimizationService.restoreSpiderMan2Fix(at: tempRoot)
        XCTAssertTrue(restored)
        XCTAssertTrue(details.contains { $0.contains("Restored original amd_ags_x64.dll") })
        XCTAssertTrue(details.contains { $0.contains("Restored d3d12.dll from backup") })

        // Check restored filesystem state
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveProxy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: realAgs.path))
        let liveContent = try String(contentsOf: liveProxy, encoding: .utf8)
        XCTAssertEqual(liveContent, "real original ags content")

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("d3d12.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d3d12Bak.path))

        XCTAssertFalse(FileManager.default.fileExists(atPath: iniURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shaderURL.path))

        // Fix status should now be .missing
        XCTAssertEqual(GameOptimizationService.checkSpiderMan2FixStatus(at: tempRoot), .missing)
    }

    func testSpiderMan2OptimizationWithNilInstallationURL() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusSM2NilInstallURLTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let exeURL = tempRoot.appendingPathComponent("Spider-Man2.exe")
        try createMockSpiderMan2Executable(at: exeURL)

        // Place legacy d3d12
        let d3d12URL = tempRoot.appendingPathComponent("d3d12.dll")
        try Data("mock d3d12".utf8).write(to: d3d12URL)

        // Set up valid MacGameFix installation
        let agsURL = tempRoot.appendingPathComponent("amd_ags_x64.dll")
        try Data("proxy header sm2-tpose-fix.log trailing".utf8).write(to: agsURL)
        let realAgsURL = tempRoot.appendingPathComponent("amd_ags_x64_real.dll")
        try Data("real ags".utf8).write(to: realAgsURL)
        let iniURL = tempRoot.appendingPathComponent("sm2fix.ini")
        try "game_build = 679b8cd0-0ce54000\nshaders = 125a4957ab64d24d\nmgvf_fog_barrier = 1\n"
            .write(to: iniURL, atomically: true, encoding: .utf8)
        let shaderURL = tempRoot.appendingPathComponent("sm2fix-pool-125a4957ab64d24d.dxil")
        var dxbcData = Data("DXBC".utf8)
        dxbcData.append(Data(repeating: 0, count: 64))
        try dxbcData.write(to: shaderURL)

        // Game with installationURL == nil
        let game = Game(
            title: "Marvel's Spider-Man 2",
            store: .local,
            storeApplicationID: "sm2",
            installationURL: nil,
            executableURL: exeURL,
            graphicsBackend: "d3dmetal"
        )

        let prefixURL = tempRoot.appendingPathComponent("Prefix")
        try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)

        let report = GameOptimizationService().optimize(game: game, prefixURL: prefixURL)

        // Legacy d3d12 should still be neutralized
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("d3d12.dll.bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d3d12URL.path))
        XCTAssertTrue(report.details.contains { $0.contains("Verified MacGameFix active for Spider-Man 2") })
    }

    func testSpiderMan2TargetGameInstallationIntegrity() throws {
        let gameURL = URL(fileURLWithPath: "/Volumes/sata ssd 1/Applications/Marvel's Spider-Man 2")
        guard FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("Spider-Man2.exe").path) else {
            return
        }

        // Verify PE Build parsing on real executable
        let build = GameOptimizationService.readSpiderMan2GameBuild(from: gameURL.appendingPathComponent("Spider-Man2.exe"))
        XCTAssertEqual(build, "679b8cd0-0ce54000")

        // Verify MacGameFix status on real installation
        let status = GameOptimizationService.checkSpiderMan2FixStatus(at: gameURL)
        XCTAssertEqual(status, .installed(build: "679b8cd0-0ce54000", fogBarrier: true))

        // Verify conflicting legacy d3d12.dll is neutralized
        XCTAssertFalse(FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("d3d12.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("d3d12.dll.bak").path))

        // Verify real log exists from test launch if present
        let logURL = gameURL.appendingPathComponent("sm2-tpose-fix.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            let logContent = try String(contentsOf: logURL, encoding: .utf8)
            XCTAssertTrue(logContent.contains("Spider-Man 2 T-Pose Fix 1.3 (MGVF, on amd_ags_x64.dll)"))
            XCTAssertTrue(logContent.contains("Game build 679b8cd0-0ce54000 matches. Applying the fix (4 shaders), with the fog barrier."))
            XCTAssertTrue(logContent.contains("The vtable at"))
            XCTAssertTrue(logContent.contains("its objects call through a copy"))
        }
    }

    func testAtiadlxxDriverVersionPatching() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusAtiadlxxTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sys32 = root.appendingPathComponent("drive_c/windows/system32")
        let sys64 = root.appendingPathComponent("drive_c/windows/syswow64")
        try FileManager.default.createDirectory(at: sys32, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sys64, withIntermediateDirectories: true)

        let dll32 = sys32.appendingPathComponent("atiadlxx.dll")
        let dll64 = sys64.appendingPathComponent("atiadlxx.dll")
        let dummyLegacy = Data("HEADER_DATA_22.10.1\0_FOOTER_DATA".utf8)
        try dummyLegacy.write(to: dll32)
        try dummyLegacy.write(to: dll64)

        let patched = GameOptimizationService.patchAtiadlxxDriverVersion(in: root)
        XCTAssertTrue(patched)

        let content32 = try String(contentsOf: dll32, encoding: .isoLatin1)
        let content64 = try String(contentsOf: dll64, encoding: .isoLatin1)
        XCTAssertTrue(content32.contains("25.10.1\0"))
        XCTAssertFalse(content32.contains("22.10.1\0"))
        XCTAssertTrue(content64.contains("25.10.1\0"))
        XCTAssertFalse(content64.contains("22.10.1\0"))

        // Idempotent: second call returns false and doesn't modify
        let secondPatch = GameOptimizationService.patchAtiadlxxDriverVersion(in: root)
        XCTAssertFalse(secondPatch)

        // Also test upgrading from 24.12.1
        let dummy24 = Data("HEADER_DATA_24.12.1\0_FOOTER_DATA".utf8)
        try dummy24.write(to: dll32)
        let upgradePatch = GameOptimizationService.patchAtiadlxxDriverVersion(in: root)
        XCTAssertTrue(upgradePatch)
        let upgraded32 = try String(contentsOf: dll32, encoding: .isoLatin1)
        XCTAssertTrue(upgraded32.contains("25.10.1\0"))
        XCTAssertFalse(upgraded32.contains("24.12.1\0"))
    }

    func testCrossOverWinemacAppIconThreadSafetyPatching() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusWinemacTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let winemacDir = tempDir.appendingPathComponent("lib/wine/x86_64-unix")
        try FileManager.default.createDirectory(at: winemacDir, withIntermediateDirectories: true)

        let winemacURL = winemacDir.appendingPathComponent("winemac.so")
        let dummyData = Data([0x90, 0x90, 0x85, 0xc0, 0x74, 0x0f, 0xe8, 0x14, 0x01, 0x00, 0x00, 0x90])
        try dummyData.write(to: winemacURL)

        let patched = GameOptimizationService.patchCrossOverWinemacAppIconThreadSafety(in: tempDir)
        XCTAssertTrue(patched)

        let patchedData = try Data(contentsOf: winemacURL)
        XCTAssertEqual(patchedData[4], 0xeb)
        XCTAssertEqual(patchedData[5], 0x1a)

        // Idempotent: second call returns false
        let secondPatch = GameOptimizationService.patchCrossOverWinemacAppIconThreadSafety(in: tempDir)
        XCTAssertFalse(secondPatch)
    }

    #if canImport(AppKit)
    static func analyzeRenderedFrame(imagePath: String, threshold: Double = 0.05) -> (isNonBlack: Bool, nonBlackFraction: Double) {
        guard let img = NSImage(contentsOfFile: imagePath),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return (false, 0.0)
        }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 100, h > 100 else { return (false, 0.0) }

        let insetX = w / 10
        let insetY = h / 10
        var nonBlackCount = 0
        var totalSampled = 0
        let step = max(1, min(w, h) / 100)

        for y in stride(from: insetY, to: h - insetY, by: step) {
            for x in stride(from: insetX, to: w - insetX, by: step) {
                totalSampled += 1
                if let color = rep.colorAt(x: x, y: y) {
                    if color.redComponent > 0.08 || color.greenComponent > 0.08 || color.blueComponent > 0.08 {
                        nonBlackCount += 1
                    }
                }
            }
        }
        guard totalSampled > 0 else { return (false, 0.0) }
        let fraction = Double(nonBlackCount) / Double(totalSampled)
        return (fraction >= threshold, fraction)
    }
    #endif

    func runSpiderMan2LiveExecution(durationSeconds: Double = 120.0) async throws {
        let gameURL = URL(fileURLWithPath: "/Volumes/sata ssd 1/Applications/Marvel's Spider-Man 2")
        let exeURL = gameURL.appendingPathComponent("Spider-Man2.exe")
        guard FileManager.default.fileExists(atPath: exeURL.path) else {
            print("[LiveSM2] Spider-Man2.exe not found at \(exeURL.path)")
            return
        }

        let build = GameOptimizationService.readSpiderMan2GameBuild(from: exeURL)
        print("[LiveSM2] Real PE Build: \(build ?? "unknown")")

        let fixStatus = GameOptimizationService.checkSpiderMan2FixStatus(at: gameURL)
        print("[LiveSM2] MacGameFix Status: \(fixStatus)")

        let runtimeURL = URL(fileURLWithPath: "/Volumes/sata ssd 1/downloads/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        let runtime = DetectedRuntime(
            id: UUID(uuidString: "CBE5187A-9948-57BC-8928-CF6A89A0F64F")!,
            name: "CrossOver Wine (sata ssd 1 Downloads)",
            executableURL: runtimeURL,
            version: "Product Name: CrossOver\nPublic Version: 26.3.0",
            architecture: "x86_64",
            status: "Detected"
        )
        let prefixURL = URL(fileURLWithPath: "/Users/godjoel/Library/Application Support/Overcross/Prefixes/DefaultBottle")
        let prefix = WinePrefix(
            id: UUID(uuidString: "B7460E52-F3FC-43B7-9F0D-BF8E348F9FB3")!,
            name: "DefaultBottle",
            url: prefixURL,
            runtimeURL: runtimeURL,
            architecture: .win64,
            createdAt: Date(),
            status: "Verified Shared Gaming Bottle"
        )

        let game = Game(
            id: UUID(uuidString: "EBFC559E-5782-408A-8D25-3CB9BB0655C1")!,
            title: "Marvel's Spider-Man 2",
            store: .local,
            platform: .windows,
            storeApplicationID: nil,
            installationURL: gameURL,
            executableURL: exeURL,
            graphicsBackend: "d3dmetal",
            runtimeIdentifier: "CBE5187A-9948-57BC-8928-CF6A89A0F64F",
            prefixID: UUID(uuidString: "B7460E52-F3FC-43B7-9F0D-BF8E348F9FB3")!,
            metalHUDEnabled: true,
            msyncEnabled: true
        )

        print("[LiveSM2] Starting game launch via GameLaunchService...")
        let launchTask = Task {
            do {
                let outcome = try await GameLaunchService().launchWindows(
                    game: game,
                    runtime: runtime,
                    prefix: prefix
                )
                print("[LiveSM2] Launch completed. Exit: \(outcome.exitStatus), Summary: \(outcome.summary)")
            } catch {
                print("[LiveSM2] Launch ended: \(error.localizedDescription)")
            }
        }

        let startTime = Date()
        var observedGameWindow = false
        var observedSwapchain = false
        var observedNonBlackRender = false
        var capturedScreenshots: [String] = []
        var sm2PID: pid_t?

        while Date().timeIntervalSince(startTime) < durationSeconds {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let elapsed = Int(Date().timeIntervalSince(startTime))

            // 1. Check PID via pgrep
            if sm2PID == nil {
                let pipe = Pipe()
                let pgrep = Process()
                pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                pgrep.arguments = ["-f", "Spider-Man2.exe"]
                pgrep.standardOutput = pipe
                try? pgrep.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                pgrep.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                for line in output.components(separatedBy: "\n") {
                    if let pid = pid_t(line.trimmingCharacters(in: .whitespaces)) {
                        sm2PID = pid
                        print("[LiveSM2] Found Spider-Man2.exe PID: \(pid)")
                        fflush(stdout)
                        break
                    }
                }
            }

            // 2. Check window list
            #if canImport(CoreGraphics)
            if let windowInfoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
                for window in windowInfoList {
                    let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
                    let windowName = window[kCGWindowName as String] as? String ?? ""
                    let windowID = window[kCGWindowNumber as String] as? CGWindowID ?? 0
                    let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t

                    if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                       let h = boundsDict["Height"] as? Double,
                       let w = boundsDict["Width"] as? Double {
                        let eval = GameLaunchService.evaluateWindowForModalPreflight(
                            ownerName: ownerName,
                            windowName: windowName,
                            bounds: (x: 0, y: 0, width: w, height: h),
                            targetProcessName: "spider-man2"
                        )
                        let lowerOwner = ownerName.lowercased()
                        let isWineOrGame = (ownerPid != nil && sm2PID != nil && ownerPid == sm2PID) ||
                                           lowerOwner.contains("spider-man2") ||
                                           lowerOwner.contains("wine64-preloader") ||
                                           (lowerOwner.contains("wine") && !lowerOwner.contains("antigravity"))
                        let notHostApp = !lowerOwner.contains("antigravity") && !lowerOwner.contains("code")

                        if eval.isGameWindow && isWineOrGame && notHostApp {
                            observedGameWindow = true

                            #if canImport(AppKit)
                            if let pid = ownerPid ?? sm2PID, let app = NSRunningApplication(processIdentifier: pid) {
                                app.activate(options: .activateIgnoringOtherApps)
                            }
                            #endif

                            if elapsed % 4 == 0 {
                                print("[LiveSM2] [\(elapsed)s] Active Game Window: ID=\(windowID), Title='\(windowName)', Size=\(Int(w))x\(Int(h)), Owner='\(ownerName)' (PID \(ownerPid ?? 0))")
                                fflush(stdout)
                                let shotPath = "/tmp/sm2_render_\(elapsed)s.png"
                                let shotProc = Process()
                                shotProc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                                shotProc.arguments = ["-x", "-l\(windowID)", shotPath]
                                try? shotProc.run()
                                shotProc.waitUntilExit()
                                if FileManager.default.fileExists(atPath: shotPath),
                                   let attrs = try? FileManager.default.attributesOfItem(atPath: shotPath),
                                   let size = attrs[.size] as? UInt64, size > 1000 {
                                    capturedScreenshots.append(shotPath)
                                    #if canImport(AppKit)
                                    let analysis = Self.analyzeRenderedFrame(imagePath: shotPath)
                                    if analysis.isNonBlack {
                                        observedNonBlackRender = true
                                    }
                                    print("[LiveSM2] Captured rendered frame: \(shotPath) (\(size) bytes) - NonBlack: \(analysis.isNonBlack) (\(String(format: "%.1f%%", analysis.nonBlackFraction * 100)))")
                                    #else
                                    print("[LiveSM2] Captured rendered frame: \(shotPath) (\(size) bytes)")
                                    #endif
                                    fflush(stdout)
                                }

                                if elapsed == 20, let pid = ownerPid ?? sm2PID {
                                    print("[LiveSM2] Taking thread sample of PID \(pid)...")
                                    fflush(stdout)
                                    let sampleProc = Process()
                                    sampleProc.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                                    sampleProc.arguments = ["\(pid)", "2", "-file", "/tmp/sm2_sample.txt"]
                                    try? sampleProc.run()
                                }
                            }

                            // Advance past splash screens & title menu by synthesizing Enter/Space/KeypadEnter/E directly to game PID
                            if elapsed >= 10, let pid = ownerPid ?? sm2PID {
                                for keyCode: CGKeyCode in [36, 49, 76, 14] {
                                    if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
                                       let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                                        down.postToPid(pid)
                                        usleep(15_000)
                                        up.postToPid(pid)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            #endif

            // 3. Inspect game log
            let gameLogURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Marvel's Spider-Man 2/Marvel's Spider-Man 2.log")
            if FileManager.default.fileExists(atPath: gameLogURL.path),
               let logText = try? String(contentsOf: gameLogURL, encoding: .utf8) {
                if logText.contains("Swapchain native backbuffer") {
                    observedSwapchain = true
                }
            }

            if elapsed % 6 == 0 {
                let fixLogURL = gameURL.appendingPathComponent("sm2-tpose-fix.log")
                let fixLogSnippet = (try? String(contentsOf: fixLogURL, encoding: .utf8))?
                    .components(separatedBy: "\n").filter { !$0.isEmpty }.last ?? "no fix log"
                print("[LiveSM2] [\(elapsed)s] WindowActive: \(observedGameWindow), Swapchain: \(observedSwapchain), NonBlack: \(observedNonBlackRender), FixLog: \(fixLogSnippet)")
                fflush(stdout)
            }

            if observedGameWindow && observedSwapchain && observedNonBlackRender && capturedScreenshots.count >= 3 && elapsed >= 45 {
                print("[LiveSM2] Successfully verified 3D window rendering frames beyond loading screen over \(elapsed)s!")
                break
            }
        }

        print("[LiveSM2] Terminating test launch cleanly...")
        launchTask.cancel()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        WineBottleService.terminateBottleProcesses(prefixURL: prefix.url, runtime: runtime)

        XCTAssertTrue(observedGameWindow, "Expected game render window to be created and active")
        XCTAssertTrue(observedSwapchain, "Expected game to initialize swapchain and resolution")
        XCTAssertFalse(capturedScreenshots.isEmpty, "Expected at least one rendered frame screenshot to be captured")
        XCTAssertTrue(observedNonBlackRender, "Expected 3D window to render actual non-black graphics frames beyond loading screen")
    }

    func testSpiderMan2BypassDriverWarning() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusSM2BypassTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dummyExeURL = tempDir.appendingPathComponent("Spider-Man2.exe")
        // Create a buffer of at least 0x317c500 bytes with original call and branch bytes
        let totalSize = 0x317c500
        var dummyData = Data(count: totalSize)

        // Set original call bytes at 0x317c356: FF 15 AC E4 11 02
        let callOffset = 0x317c356
        let originalCall: [UInt8] = [0xff, 0x15, 0xac, 0xe4, 0x11, 0x02]
        dummyData.replaceSubrange(callOffset..<(callOffset + originalCall.count), with: originalCall)

        // Set original branch bytes at 0x317c460: 75 14
        let branchOffset = 0x317c460
        let originalBranch: [UInt8] = [0x75, 0x14]
        dummyData.replaceSubrange(branchOffset..<(branchOffset + originalBranch.count), with: originalBranch)

        try dummyData.write(to: dummyExeURL)

        // 1. First run: applies patch
        let patched = GameOptimizationService.bypassSpiderMan2DriverWarning(at: tempDir)
        XCTAssertTrue(patched, "Expected bypassSpiderMan2DriverWarning to apply patch")

        // Verify patched bytes in file
        let readBack = try Data(contentsOf: dummyExeURL)
        let patchedCall = Array(readBack[callOffset..<(callOffset + 6)])
        let expectedCall: [UInt8] = [0xb8, 0x01, 0x00, 0x00, 0x00, 0x90]
        XCTAssertEqual(patchedCall, expectedCall, "Expected mov eax, 1; nop at call offset")

        let patchedBranch = Array(readBack[branchOffset..<(branchOffset + 2)])
        let expectedBranch: [UInt8] = [0xeb, 0x14]
        XCTAssertEqual(patchedBranch, expectedBranch, "Expected jmp 0x14 at branch offset")

        // 2. Second run: idempotency check (already patched returns true)
        let alreadyPatched = GameOptimizationService.bypassSpiderMan2DriverWarning(at: tempDir)
        XCTAssertTrue(alreadyPatched, "Expected bypassSpiderMan2DriverWarning to be idempotent")
    }

    // MARK: - Proton & steamac Innovation Integration Tests

    func testTitleOptimizationRegistryRules() {
        // 1. Dragon's Dogma 2
        let dd2Rule = TitleOptimizationRegistry.rule(forAppID: "2054970")
        XCTAssertNotNil(dd2Rule)
        XCTAssertEqual(dd2Rule?.titleName, "Dragon's Dogma 2")
        XCTAssertEqual(dd2Rule?.vkd3dFeatureLevel, "12_1")
        XCTAssertEqual(dd2Rule?.vkd3dShaderModel, "6_6")
        XCTAssertEqual(dd2Rule?.recommendedBackend, .d3dmetal)

        // 2. Death's Door (Unity D3D11 -> DXMT)
        let ddRule = TitleOptimizationRegistry.rule(forAppID: "894020")
        XCTAssertNotNil(ddRule)
        XCTAssertEqual(ddRule?.recommendedBackend, .dxmt)
        XCTAssertEqual(ddRule?.dxvkAsync, true)

        // 3. Executable matching without appID
        let sm2Rule = TitleOptimizationRegistry.rule(forAppID: nil, executablePath: "/Volumes/Games/Spider-Man 2/Spider-Man2.exe")
        XCTAssertNotNil(sm2Rule)
        XCTAssertEqual(sm2Rule?.recommendedBackend, .d3dmetal)
        XCTAssertTrue(sm2Rule?.recommendedArguments.contains("-nolauncher") == true)
        XCTAssertTrue(sm2Rule?.recommendedArguments.contains("-nostreamline") == true)
        XCTAssertTrue(sm2Rule?.recommendedArguments.contains("-reducedtextureheap") == true)

        // 4. Forza Horizon Series (NVIDIA GPU Spoofing & VC++ overrides)
        let fh6Rule = TitleOptimizationRegistry.rule(forAppID: nil, executablePath: "/Volumes/Games/forza horizon 6/forzahorizon6.exe")
        XCTAssertNotNil(fh6Rule)
        XCTAssertEqual(fh6Rule?.titleName, "Forza Series")
        XCTAssertEqual(fh6Rule?.recommendedBackend, .d3dmetal)
        XCTAssertEqual(fh6Rule?.additionalEnvironment["D3DM_VENDOR_ID"], "0x10de")
        XCTAssertEqual(fh6Rule?.additionalEnvironment["D3DM_DEVICE_DESCRIPTION"], "NVIDIA GeForce RTX 4070")
        XCTAssertTrue(fh6Rule?.additionalEnvironment["WINEDLLOVERRIDES"]?.contains("concrt140") == true)

        // 5. Non-matching appID returns nil
        let nonMatch = TitleOptimizationRegistry.rule(forAppID: "99999999", executablePath: "unknown_game.exe")
        XCTAssertNil(nonMatch)
    }

    func testForzaAndAmdAgsGpuSpoofingDetection() throws {
        // 1. Direct Forza detection
        XCTAssertTrue(GameOptimizationService.requiresNvidiaGpuSpoofing(
            gameTitle: "Forza Horizon 6",
            executableURL: URL(fileURLWithPath: "/games/forza horizon 6/forzahorizon6.exe"),
            installationURL: nil
        ))

        // 2. Generic AMD AGS directory detection
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let agsFile = tempDir.appendingPathComponent("amd_ags_x64.dll")
        try "dummy_ags".write(to: agsFile, atomically: true, encoding: .utf8)

        XCTAssertTrue(GameOptimizationService.requiresNvidiaGpuSpoofing(
            gameTitle: "Generic D3D12 Title",
            executableURL: tempDir.appendingPathComponent("game.exe"),
            installationURL: tempDir
        ))

        // 3. Nixxes titles with MacGameFix proxy must not be spoofed as NVIDIA
        XCTAssertFalse(GameOptimizationService.requiresNvidiaGpuSpoofing(
            gameTitle: "Marvel's Spider-Man 2",
            executableURL: tempDir.appendingPathComponent("Spider-Man2.exe"),
            installationURL: tempDir
        ))
    }

    func testBundledAgilityD3D12CoreNeutralization() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let d3d12coreFile = tempDir.appendingPathComponent("d3d12core.dll")
        try "dummy_d3d12core".write(to: d3d12coreFile, atomically: true, encoding: .utf8)

        let service = GameOptimizationService()
        let neutralized = service.neutralizeProblematicLibraries(at: tempDir)
        XCTAssertTrue(neutralized.contains("d3d12core.dll"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d3d12coreFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("d3d12core.dll.bak").path))

        // Restoration should not restore d3d12core.dll
        let restored = service.restoreEssentialLibraries(at: tempDir)
        XCTAssertFalse(restored.contains("d3d12core.dll"))
    }

    func testMsvcRuntimeOverridesDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let concrtFile = tempDir.appendingPathComponent("concrt140.dll")
        try "dummy_concrt".write(to: concrtFile, atomically: true, encoding: .utf8)

        XCTAssertTrue(GameOptimizationService.requiresMsvcRuntimeOverrides(
            executableURL: tempDir.appendingPathComponent("game.exe"),
            installationURL: tempDir
        ))
    }

    func testTitleOptimizationCompatibilityProfileSelection() {
        let game = Game(
            id: UUID(),
            title: "Dragon's Dogma 2",
            store: .steam,
            platform: .windows,
            storeApplicationID: "2054970",
            ownershipEvidence: .steamLocalManifest,
            compatibilityStatus: .notTested,
            isFavorite: false,
            isHidden: false,
            categories: [],
            createdAt: Date(),
            customLaunchArguments: [],
            customEnvironment: [:]
        )

        let service = CompatibilityProfileSelectionService()
        let profile = service.verifiedProfile(for: game, profiles: [])
        XCTAssertNotNil(profile, "Expected CompatibilityProfileSelectionService to synthesize profile from TitleOptimizationRegistry")
        XCTAssertEqual(profile?.graphicsBackend, .d3dmetal)
        XCTAssertEqual(profile?.environment["VKD3D_FEATURE_LEVEL"], "12_1")
        XCTAssertEqual(profile?.environment["VKD3D_SHADER_MODEL"], "6_6")
        XCTAssertTrue(profile?.isVerified == true)
    }

    func testSteamworksBridgeService() {
        let env = SteamworksBridgeService.steamworksEnvironment(for: "1245620")
        XCTAssertEqual(env["SteamAppId"], "1245620")
        XCTAssertEqual(env["SteamGameId"], "1245620")
        XCTAssertEqual(env["STEAM_COMPAT_APP_ID"], "1245620")

        let overrides = SteamworksBridgeService.steamworksDllOverrides
        XCTAssertTrue(overrides.contains("steam_api"))
        XCTAssertTrue(overrides.contains("steam_api64"))
    }

    func testHIDPassthroughServiceAndControllerTuning() throws {
        XCTAssertTrue(HIDPassthroughService.isDualSense(vendorID: 0x054c, productID: 0x0ce6))
        XCTAssertTrue(HIDPassthroughService.isDualSense(vendorID: 0x054c, productID: 0x0df2))
        XCTAssertFalse(HIDPassthroughService.isDualSense(vendorID: 0x045e, productID: 0x028e))
        XCTAssertTrue(HIDPassthroughService.isPlayStationController(vendorID: 0x054c, productID: 0x09cc))

        let tempPrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusControllerTuningTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempPrefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempPrefix) }

        _ = try WineBottleService.syncBottleRegistry(prefixURL: tempPrefix, retina: false)
        XCTAssertTrue(WineBottleService.isControllerTuningEnabled(in: tempPrefix), "Expected controller DirectInput/XInput tuning to be written to user.reg")
    }

    func testGameProcessManagerFreezeAndThaw() {
        let manager = GameProcessManager.shared
        manager.clearAll()

        let dummyProcess = Process()
        dummyProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        dummyProcess.arguments = ["10"]
        try? dummyProcess.run()
        let pid = dummyProcess.processIdentifier
        defer {
            dummyProcess.terminate()
            dummyProcess.waitUntilExit()
            manager.unregister(pid: pid)
        }

        manager.register(process: dummyProcess, gameTitle: "Test Game")
        XCTAssertTrue(manager.activeGamePIDs().contains(pid))
        XCTAssertFalse(manager.isFrozen(pid: pid))

        // Freeze
        let frozen = manager.freezeProcess(pid: pid)
        XCTAssertTrue(frozen, "Expected freezeProcess to succeed for active process")
        XCTAssertTrue(manager.isFrozen(pid: pid))

        // Thaw
        let thawed = manager.thawProcess(pid: pid)
        XCTAssertTrue(thawed, "Expected thawProcess to succeed for frozen process")
        XCTAssertFalse(manager.isFrozen(pid: pid))

        manager.unregister(pid: pid)
        XCTAssertFalse(manager.activeGamePIDs().contains(pid))
    }

    func testWindowsLaunchInjectsProtonAndSteamacOptimizations() async throws {
        let tempPrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("LudusProtonOptimizationsLaunchTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempPrefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempPrefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempPrefix) }

        try """
        [System]
        "Installed"=dword:00000001
        """.write(to: tempPrefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)

        let runtimeScript = tempPrefix.appendingPathComponent("mock_wine.sh")
        try """
        #!/bin/sh
        echo "OVERCROSS_GRAPHICS_BACKEND=$OVERCROSS_GRAPHICS_BACKEND"
        echo "VKD3D_FEATURE_LEVEL=$VKD3D_FEATURE_LEVEL"
        echo "SteamAppId=$SteamAppId"
        echo "GST_PLUGIN_SYSTEM_PATH=$GST_PLUGIN_SYSTEM_PATH"
        exit 0
        """.write(to: runtimeScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtimeScript.path)

        let dummyGameExe = tempPrefix.appendingPathComponent("game.exe")
        try "dummy".write(to: dummyGameExe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dummyGameExe.path)

        let runtime = DetectedRuntime(
            id: UUID(),
            name: "Wine-CX Test",
            executableURL: runtimeScript,
            winebootURL: nil,
            version: "23.7.1",
            architecture: "arm64",
            status: "ready"
        )

        let prefix = WinePrefix(
            name: "default",
            url: tempPrefix,
            runtimeURL: runtimeScript,
            architecture: .win64
        )

        // 1. Dragon's Dogma 2 (AppID: 2054970) -> Should inject VKD3D_FEATURE_LEVEL=12_1 and SteamAppId
        let dd2Game = Game(
            id: UUID(),
            title: "Dragon's Dogma 2",
            store: .steam,
            platform: .windows,
            storeApplicationID: "2054970",
            ownershipEvidence: .steamLocalManifest,
            executableURL: dummyGameExe,
            graphicsBackend: "automatic",
            compatibilityStatus: .notTested,
            isFavorite: false,
            isHidden: false,
            categories: [],
            createdAt: Date(),
            customLaunchArguments: [],
            customEnvironment: [:]
        )

        let launchService = GameLaunchService()
        let outcome = try await launchService.launchWindows(
            game: dd2Game,
            runtime: runtime,
            prefix: prefix
        )

        XCTAssertTrue(outcome.standardOutput.contains("VKD3D_FEATURE_LEVEL=12_1"), "Expected launchWindows to inject VKD3D_FEATURE_LEVEL=12_1 for Dragon's Dogma 2")
        XCTAssertTrue(outcome.standardOutput.contains("OVERCROSS_GRAPHICS_BACKEND=d3dmetal"), "Expected launchWindows to select d3dmetal for Dragon's Dogma 2")
        XCTAssertTrue(outcome.standardOutput.contains("SteamAppId=2054970"), "Expected launchWindows to inject SteamAppId for Steam title")

        // 2. Death's Door (AppID: 894020) -> Should select DXMT
        let ddGame = Game(
            id: UUID(),
            title: "Death's Door",
            store: .steam,
            platform: .windows,
            storeApplicationID: "894020",
            ownershipEvidence: .steamLocalManifest,
            executableURL: dummyGameExe,
            graphicsBackend: "automatic",
            compatibilityStatus: .notTested,
            isFavorite: false,
            isHidden: false,
            categories: [],
            createdAt: Date(),
            customLaunchArguments: [],
            customEnvironment: [:]
        )

        let ddOutcome = try await launchService.launchWindows(
            game: ddGame,
            runtime: runtime,
            prefix: prefix
        )
        XCTAssertTrue(ddOutcome.standardOutput.contains("OVERCROSS_GRAPHICS_BACKEND=dxmt"), "Expected launchWindows to select dxmt for Death's Door")
    }
}


