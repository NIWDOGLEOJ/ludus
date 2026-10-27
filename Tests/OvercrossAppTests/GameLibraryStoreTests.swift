import Foundation
@testable import OvercrossCore

final class GameLibraryStoreTests: XCTestCase, @unchecked Sendable {
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
}

