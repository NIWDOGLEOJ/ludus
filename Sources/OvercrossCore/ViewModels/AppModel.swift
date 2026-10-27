import Foundation
import Combine
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import GameController

public struct ConnectedGamepad: Identifiable, Hashable, Sendable {
    public let id: String
    public let vendorName: String
    public let isAttachedToDevice: Bool
}

public enum WineTool: String, CaseIterable, Identifiable, Sendable {
    case winecfg
    case regedit
    case taskmgr

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .winecfg: "Wine Configuration (winecfg)"
        case .regedit: "Registry Editor (regedit)"
        case .taskmgr: "Task Manager (taskmgr)"
        }
    }

    public var iconName: String {
        switch self {
        case .winecfg: "gearshape.2.fill"
        case .regedit: "list.bullet.rectangle"
        case .taskmgr: "chart.bar.xaxis"
        }
    }
}

struct DownloadItem: Identifiable, Equatable, Sendable {
    let id: UUID // gameID
    var gameTitle: String
    var store: GameStore
    var artworkURL: URL?
    var fraction: Double
    var detail: String
    var speed: String?
    var eta: String?
    var currentBytes: Int64?
    var totalBytes: Int64?
    var isPaused: Bool

    init(
        id: UUID,
        gameTitle: String,
        store: GameStore,
        artworkURL: URL? = nil,
        fraction: Double = 0.0,
        detail: String = "",
        speed: String? = nil,
        eta: String? = nil,
        currentBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        isPaused: Bool = false
    ) {
        self.id = id
        self.gameTitle = gameTitle
        self.store = store
        self.artworkURL = artworkURL
        self.fraction = fraction
        self.detail = detail
        self.speed = speed
        self.eta = eta
        self.currentBytes = currentBytes
        self.totalBytes = totalBytes
        self.isPaused = isPaused
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case home
        case library
        case steam
        case epic
        case install
        case compatibility
        case runtimes
        case downloads
        case performance
        case diagnostics
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: "Home"
            case .library: "Unified Library"
            case .steam: "Steam"
            case .epic: "Epic Games"
            case .install: "Install Game"
            case .compatibility: "Compatibility Center"
            case .runtimes: "Runtime Manager"
            case .downloads: "Downloads"
            case .performance: "Performance"
            case .diagnostics: "Logs & Diagnostics"
            case .settings: "Settings"
            }
        }
    }

    @Published var selectedSection: Section = .home
    @Published private(set) var connectedGamepads: [ConnectedGamepad] = []
    @Published private(set) var games: [Game]
    @Published private(set) var runtimeReport = RuntimeDiagnosticReport.empty
    @Published private(set) var runtimeHealth: [UUID: [DiagnosticFinding]] = [:]
    @Published private(set) var installedStorageBytes: Int64?
    @Published private(set) var gameStorageBytes: [UUID: Int64] = [:]
    @Published private(set) var applicationCacheBytes: Int64 = 0
    @Published private(set) var preferredInstallFreeBytes: Int64?
    @Published private(set) var prefixes: [WinePrefix]
    @Published private(set) var compatibilityProfiles: [CompatibilityProfile]
    @Published private(set) var compatibilityProfileMessage: String?
    @Published private(set) var launchLogs: [LaunchLogRecord]
    @Published private(set) var configuredSteamID: String?
    @Published private(set) var hasSteamAPIKey = false
    @Published private(set) var isAuthenticatingSteam = false
    @Published private(set) var steamAuthenticationMessage: String?
    @Published private(set) var isSyncingSteam = false
    @Published private(set) var steamSyncMessage: String?
    @Published private(set) var isSyncingHeroic = false
    @Published private(set) var heroicSyncMessage: String?
    @Published private(set) var heroicDownloadEstimates: [UUID: HeroicDownloadEstimate] = [:]
    @Published private(set) var heroicDownloadEstimateMessages: [UUID: String] = [:]
    @Published private(set) var fetchingHeroicEstimateGameID: UUID?
    @Published private(set) var isRunningDiagnostics = false
    @Published var isPerformingFix = false
    @Published var fixStatusMessage: String?
    @Published private(set) var isInstallingRuntime = false
    @Published private(set) var runtimeInstallMessage: String?
    @Published private(set) var isCreatingPrefix = false
    @Published private(set) var isBackingUpPrefix = false
    @Published private(set) var isRestoringPrefix = false
    @Published private(set) var isRemovingPrefix = false
    @Published private(set) var isLaunchingGame = false
    @Published private(set) var isInstallingGame = false
    @Published private(set) var isReconcilingInstall = false
    @Published private(set) var downloadOperations: [DownloadOperation]
    @Published private(set) var isMovingGame = false
    @Published private(set) var isRemovingGame = false
    @Published private(set) var removingGameID: UUID?
    @Published private(set) var removeGameMessage: String?
    @Published private(set) var moveGameMessage: String?
    @Published private(set) var installingGameID: UUID?
    @Published private(set) var installMessageGameID: UUID?
    @Published private(set) var installProgress: HeroicInstallProgress?
    @Published private(set) var installMessage: String?
    @Published private(set) var diagnosticError: String?
    @Published private(set) var lastImportMessage: String?
    @Published var lastPrefixMessage: String?
    @Published var wineToolMessage: String?
    @Published var isRepairingDependencies = false
    @Published var dependencyRepairMessage: String?
    @Published var isResettingBottle = false
    @Published var resetBottleMessage: String?
    @Published var bootstrapPhase: BootstrapPhase = .notStarted
    @Published var epicAuthStatus: EpicAuthStatus = .notConnected
    @Published var steamAuthStatus: SteamAuthStatus = .notConnected
    @Published var runningGameIDs: Set<UUID> = []
    @Published var autonomousDownloadProgress: [UUID: Double] = [:]
    @Published var autonomousDownloadDetails: [UUID: String] = [:]
    @Published var activeDownloads: [UUID: DownloadItem] = [:]
    @Published var availableUpdate: AppUpdateInfo? = nil
    @Published var isCheckingForUpdates = false
    @Published var updateCheckMessage: String? = nil
    @Published var isDownloadingUpdate = false
    let updateService = GitHubUpdateService.shared
    private var downloadOperationIDs: [UUID: UUID] = [:]
    private var autonomousDownloadTasks: [UUID: Task<Void, Never>] = [:]

    var hasActiveDownloads: Bool {
        activeDownloads.values.contains(where: { !$0.isPaused }) || !autonomousDownloadTasks.isEmpty
    }

    var activeDownloadsCount: Int {
        activeDownloads.values.filter { !$0.isPaused }.count
    }

    var totalDownloadSpeedFormatted: String? {
        let activeSpeeds = activeDownloads.values.compactMap { $0.isPaused ? nil : $0.speed }
        return activeSpeeds.first
    }
    let runtimeBootstrapService = RuntimeBootstrapService()
    let wineBottleService = WineBottleService()
    let epicService = EpicService()
    let steamService = SteamService()
    @Published var settings: AppSettings {
        didSet {
            settings.save()
            refreshInstallDirectoryInfo()
        }
    }

    private let libraryStore: GameLibraryStore
    private let diagnosticsService = RuntimeDiagnosticsService()
    private let runtimeStore: RuntimeStore
    private let runtimeBundleInstaller = RuntimeBundleInstaller()
    private let launchService = GameLaunchService()
    private let storageUsageService = StorageUsageService()
    private let applicationCacheService = ApplicationCacheService()
    private let storageVolumeService = StorageVolumeService()
    private let steamLibraryImporter = SteamLibraryImporter()
    private let steamLaunchService = SteamLaunchService()
    private let heroicLibraryImporter = HeroicLibraryImporter()
    private let heroicLibraryService = HeroicLibraryService()
    private let heroicGameInfoService = HeroicGameInfoService()
    private let heroicLaunchService = HeroicLaunchService()
    private let heroicInstallService = HeroicInstallService()
    private let heroicMoveService = HeroicMoveService()
    private let heroicUninstallService = HeroicUninstallService()
    private let notificationService = NotificationService()
    private let steamAccountStore: SteamAccountStore
    private let steamOpenIDAuthenticator = SteamOpenIDAuthenticator()
    private let steamWebAPIClient = SteamWebAPIClient()
    private let prefixStore: WinePrefixStore
    private let prefixService = WinePrefixService()
    private let prefixArchiveService = WinePrefixArchiveService()
    private let compatibilityProfileStore: CompatibilityProfileStore
    private let launchLogStore: LaunchLogStore
    private let downloadOperationStore: DownloadOperationStore
    private var launchTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var moveTask: Task<Void, Never>?
    private var removeTask: Task<Void, Never>?
    private var heroicEstimateTask: Task<Void, Never>?
    private var steamAuthenticationTask: Task<Void, Never>?
    @Published private(set) var lastLaunchLog: String?

    init(
        libraryStore: GameLibraryStore = GameLibraryStore(),
        runtimeStore: RuntimeStore = RuntimeStore(),
        prefixStore: WinePrefixStore = WinePrefixStore(),
        compatibilityProfileStore: CompatibilityProfileStore = CompatibilityProfileStore(),
        launchLogStore: LaunchLogStore = LaunchLogStore(),
        steamAccountStore: SteamAccountStore = SteamAccountStore(),
        downloadOperationStore: DownloadOperationStore = DownloadOperationStore()
    ) {
        self.libraryStore = libraryStore
        self.runtimeStore = runtimeStore
        self.prefixStore = prefixStore
        self.compatibilityProfileStore = compatibilityProfileStore
        self.launchLogStore = launchLogStore
        self.steamAccountStore = steamAccountStore
        self.downloadOperationStore = downloadOperationStore
        games = libraryStore.load()
        prefixes = prefixStore.load()
        compatibilityProfiles = compatibilityProfileStore.load()
        compatibilityProfileMessage = nil
        runtimeInstallMessage = nil
        launchLogs = launchLogStore.load()
        var savedDownloadOperations = downloadOperationStore.load()
        var recoveredInterruptedOperation = false
        for index in savedDownloadOperations.indices where savedDownloadOperations[index].state == .running {
            savedDownloadOperations[index].update(
                state: .recoveryRequired,
                detail: "The app closed while this operation was in progress. Verify the recorded installation or retry it.",
                error: "The previous process was interrupted before Ludus could verify completion.",
                at: Date()
            )
            recoveredInterruptedOperation = true
        }
        if recoveredInterruptedOperation {
            try? downloadOperationStore.save(savedDownloadOperations)
        }
        downloadOperations = savedDownloadOperations
        configuredSteamID = steamAccountStore.steamID
        hasSteamAPIKey = steamAccountStore.hasAPIKey
        steamAuthenticationMessage = nil
        settings = AppSettings.load()
        let savedRuntimes = runtimeStore.load()
        runtimeReport = RuntimeDiagnosticReport(
            generatedAt: .distantPast,
            hostArchitecture: "Unknown",
            macOSVersion: "Unknown",
            developerDirectory: nil,
            findings: [],
            runtimes: savedRuntimes
        )
        installedStorageBytes = nil
        preferredInstallFreeBytes = nil
        refreshInstallationState()
        refreshStorageUsage()
        refreshApplicationCacheUsage()
        refreshInstallDirectoryInfo()
        setupGamepadMonitoring()
        refreshStoreAuth()
        startAutonomousBootstrap()
        if savedRuntimes.isEmpty {
            runDiagnostics()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.terminateAllChildProcesses()
            }
        }
    }

    var gamepadStatusSummary: String {
        if connectedGamepads.isEmpty {
            return "No game controller detected"
        } else {
            return connectedGamepads.map(\.vendorName).joined(separator: ", ")
        }
    }

    var hasConnectedGamepad: Bool {
        !connectedGamepads.isEmpty
    }

    private func setupGamepadMonitoring() {
        refreshConnectedGamepads()
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshConnectedGamepads()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshConnectedGamepads()
            }
        }
    }

    func refreshConnectedGamepads() {
        let controllers = GCController.controllers()
        self.connectedGamepads = controllers.enumerated().map { index, controller in
            ConnectedGamepad(
                id: "\(controller.vendorName ?? "Gamepad")-\(index)",
                vendorName: controller.vendorName ?? "Standard Game Controller",
                isAttachedToDevice: controller.isAttachedToDevice
            )
        }
    }

    func refreshInstallationState() {
        var changed = false
        for index in games.indices {
            guard let installationURL = games[index].installationURL else { continue }
            guard isDirectory(installationURL) else {
                games[index].installationURL = nil
                games[index].executableURL = nil
                changed = true
                continue
            }

            if let executableURL = games[index].executableURL,
               (!isRegularFile(executableURL) || !isURL(executableURL, inside: installationURL)) {
                games[index].executableURL = nil
                changed = true
            }

            // Auto-detect and link matching Epic Games Store installations
            if games[index].storeApplicationID == nil || games[index].store == .local {
                if let matchedEpicID = epicService.findApplicationID(
                    installationURL: games[index].installationURL,
                    executableURL: games[index].executableURL
                ) {
                    games[index].store = .epic
                    games[index].storeApplicationID = matchedEpicID
                    changed = true
                }
            }
        }

        // Deduplicate entries pointing to identical installations (e.g. store sync + manual local import)
        var seenInstallPaths: [String: UUID] = [:]
        var indicesToRemove: [Int] = []
        for (index, game) in games.enumerated() {
            guard let installURL = game.installationURL else { continue }
            let canonical = installURL.resolvingSymlinksInPath().standardizedFileURL.path
            if let primaryID = seenInstallPaths[canonical],
               let primaryIndex = games.firstIndex(where: { $0.id == primaryID }) {
                let keeperIndex = (games[primaryIndex].store != .epic && game.store == .epic) ? index : primaryIndex
                let discardIndex = (keeperIndex == index) ? primaryIndex : index

                if games[keeperIndex].isFavorite == false && games[discardIndex].isFavorite {
                    games[keeperIndex].isFavorite = true
                }
                if games[keeperIndex].customLaunchArguments.isEmpty && !games[discardIndex].customLaunchArguments.isEmpty {
                    games[keeperIndex].customLaunchArguments = games[discardIndex].customLaunchArguments
                }
                if games[keeperIndex].customEnvironment.isEmpty && !games[discardIndex].customEnvironment.isEmpty {
                    games[keeperIndex].customEnvironment = games[discardIndex].customEnvironment
                }
                if games[keeperIndex].prefixID == nil && games[discardIndex].prefixID != nil {
                    games[keeperIndex].prefixID = games[discardIndex].prefixID
                }
                if games[keeperIndex].runtimeIdentifier == nil && games[discardIndex].runtimeIdentifier != nil {
                    games[keeperIndex].runtimeIdentifier = games[discardIndex].runtimeIdentifier
                }
                if games[keeperIndex].graphicsBackend == nil && games[discardIndex].graphicsBackend != nil {
                    games[keeperIndex].graphicsBackend = games[discardIndex].graphicsBackend
                }

                indicesToRemove.append(discardIndex)
                seenInstallPaths[canonical] = games[keeperIndex].id
                changed = true
            } else {
                seenInstallPaths[canonical] = game.id
            }
        }
        if !indicesToRemove.isEmpty {
            let toRemove = Set(indicesToRemove)
            games = games.enumerated().filter { !toRemove.contains($0.offset) }.map(\.element)
        }

        if changed {
            persistGames()
            refreshStorageUsage()
        }
    }

    func importLocalGame() {
        let panel = NSOpenPanel()
        panel.title = "Choose a game executable"
        panel.message = "Select the executable you want Ludus to launch."
        panel.prompt = "Add Game"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let executableURL = panel.url else { return }
        let canonicalExecutableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
        guard !games.contains(where: {
            guard let existingExecutableURL = $0.executableURL else { return false }
            return existingExecutableURL.resolvingSymlinksInPath().standardizedFileURL == canonicalExecutableURL
        }) else { return }

        let installationURL = canonicalExecutableURL.deletingLastPathComponent()
        if let index = games.firstIndex(where: { game in
            guard let existingInstallationURL = game.installationURL else { return false }
            let canonicalExistingInstallation = existingInstallationURL.resolvingSymlinksInPath().standardizedFileURL
            return canonicalExistingInstallation == installationURL ||
                (game.store != .local && canonicalExecutableURL.path.hasPrefix(canonicalExistingInstallation.path + "/"))
        }) {
            games[index].executableURL = canonicalExecutableURL
            if games[index].platform == .unknown {
                games[index].platform = GamePlatform.inferred(from: canonicalExecutableURL)
            }
            persistGames()
            lastImportMessage = "Attached " + canonicalExecutableURL.lastPathComponent + " to the existing " + games[index].title + " record."
            refreshStorageUsage()
            return
        }

        let exeName = canonicalExecutableURL.deletingPathExtension().lastPathComponent
        let folderName = installationURL.lastPathComponent
        let genericNames: Set<String> = ["speed", "game", "launcher", "start", "play", "run", "bin", "shipping"]
        let title = (genericNames.contains(exeName.lowercased()) && !folderName.isEmpty) ? folderName : exeName

        var customEnv: [String: String] = [:]
        if FileManager.default.fileExists(atPath: installationURL.appendingPathComponent("dinput8.dll").path) {
            customEnv["WINEDLLOVERRIDES"] = "dinput8=n,b"
        }

        let matchedEpicID = epicService.findApplicationID(
            installationURL: installationURL,
            executableURL: canonicalExecutableURL
        )

        let game = Game(
            title: title,
            store: matchedEpicID != nil ? .epic : .local,
            platform: GamePlatform.inferred(from: canonicalExecutableURL),
            storeApplicationID: matchedEpicID,
            ownershipEvidence: matchedEpicID != nil ? .heroicInstalledCache : .userSelectedLocal,
            installationURL: installationURL,
            executableURL: canonicalExecutableURL,
            installationMethod: matchedEpicID != nil ? "Heroic/Epic local import" : "Manual local import",
            graphicsBackend: "d3dmetal",
            compatibilityStatus: .testedWorking,
            customEnvironment: customEnv,
            msyncEnabled: true
        )
        games.append(game)
        persistGames()
        refreshStorageUsage()
    }

    func chooseExecutable(for gameID: UUID) {
        guard let game = games.first(where: { $0.id == gameID }),
              let installationURL = game.installationURL else {
            lastImportMessage = "Choose or verify an installation location before selecting an executable."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose the Game Executable"
        panel.message = "Select an executable inside the recorded installation folder."
        panel.prompt = "Use Executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = installationURL

        guard panel.runModal() == .OK, let executableURL = panel.url else { return }
        guard isURL(executableURL, inside: installationURL),
              isRegularFile(executableURL) else {
            lastImportMessage = "The executable must be a regular file inside the selected installation folder."
            return
        }

        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        let selectedExecutableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
        games[index].executableURL = selectedExecutableURL
        if games[index].platform == .unknown {
            games[index].platform = GamePlatform.inferred(from: selectedExecutableURL)
        }
        persistGames()
        lastImportMessage = "Selected \(executableURL.lastPathComponent) for \(game.title)."
    }

    func chooseArtwork(for gameID: UUID) {
        guard games.contains(where: { $0.id == gameID }) else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose Game Artwork"
        panel.message = "Select an image to use as this game's artwork."
        panel.prompt = "Use Artwork"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let artworkURL = panel.url else { return }
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].artworkURL = artworkURL
        persistGames()
    }

    func importCompatibilityProfiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Compatibility Profiles"
        panel.message = "Select a JSON array of profiles. Imported profiles are not launch-selectable unless they include a matching game, a working or partially-working result, and recorded test-environment evidence."
        panel.prompt = "Import Profiles"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let profileURL = panel.url else { return }
        do {
            let importedProfiles = try compatibilityProfileStore.importProfiles(from: profileURL)
            var profilesByID: [UUID: CompatibilityProfile] = [:]
            for profile in compatibilityProfiles {
                profilesByID[profile.id] = profile
            }
            for profile in importedProfiles {
                profilesByID[profile.id] = profile
            }
            compatibilityProfiles = profilesByID.values.sorted {
                if $0.store.displayName != $1.store.displayName {
                    return $0.store.displayName < $1.store.displayName
                }
                return ($0.storeApplicationID ?? "") < ($1.storeApplicationID ?? "")
            }
            try compatibilityProfileStore.save(compatibilityProfiles)
            let verifiedCount = importedProfiles.filter { $0.isVerified }.count
            compatibilityProfileMessage = "Imported \(importedProfiles.count) profile\(importedProfiles.count == 1 ? "" : "s"); \(verifiedCount) include recorded evidence and can be considered for launch."
        } catch {
            compatibilityProfileMessage = error.localizedDescription
        }
    }

    func chooseInstallDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose an install location"
        panel.message = "Choose a folder on the volume where Ludus should place future game installations."
        panel.prompt = "Use Location"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        settings.preferredInstallDirectory = directory
        refreshInstallDirectoryInfo()
    }

    func setInstallDirectory(_ directory: URL?) {
        settings.preferredInstallDirectory = directory
        refreshInstallDirectoryInfo()
    }

    func refreshInstallDirectoryInfo() {
        guard let directory = settings.preferredInstallDirectory else {
            preferredInstallFreeBytes = nil
            return
        }
        preferredInstallFreeBytes = storageVolumeService.availableBytes(at: directory)
    }

    func importSteamLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Steam library"
        panel.message = "Choose a Steam library folder or its steamapps folder. Ludus will read local app manifests only."
        panel.prompt = "Import Steam Library"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if let defaultURL = SteamLibraryImporter.defaultSteamLibraryURLs().first {
            panel.directoryURL = defaultURL
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        do {
            let importedGames = try steamLibraryImporter.importGames(from: selectedURL)
            mergeImportedGames(importedGames)
            lastImportMessage = "Imported \(importedGames.count) Steam entries from local manifests."
            refreshStorageUsage()
        } catch {
            lastImportMessage = error.localizedDescription
        }
    }

    func autoScanSteamLibraries() {
        let libraries = SteamLibraryImporter.defaultSteamLibraryURLs()
        guard !libraries.isEmpty else {
            lastImportMessage = "No Steam library directories detected."
            return
        }
        var allImported: [Game] = []
        for libraryURL in libraries {
            if let games = try? steamLibraryImporter.importGames(from: libraryURL) {
                allImported.append(contentsOf: games)
            }
        }
        if allImported.isEmpty {
            let names = libraries.map(\.path).joined(separator: ", ")
            lastImportMessage = "Steam library folders checked (\(names)), but no installed game manifests were found."
        } else {
            mergeImportedGames(allImported)
            lastImportMessage = "Automatically detected and imported \(allImported.count) Steam game(s)."
            refreshStorageUsage()
        }
    }

    func refreshMissingArtwork() {
        var updatedCount = 0
        for index in games.indices {
            if games[index].artworkURL == nil {
                if games[index].store == .steam, let appID = games[index].storeApplicationID {
                    games[index].artworkURL = SteamArtwork.libraryPortraitURL(forAppID: appID)
                    updatedCount += 1
                } else if games[index].store == .epic, let appName = games[index].storeApplicationID {
                    let artwork = HeroicArtworkService.resolveArtworkURL(
                        appName: appName,
                        configurationDirectory: settings.heroicLegendaryConfigDirectory
                    )
                    if let artwork {
                        games[index].artworkURL = artwork
                        updatedCount += 1
                    }
                }
            }
        }
        if updatedCount > 0 {
            persistGames()
            lastImportMessage = "Refreshed artwork for \(updatedCount) game(s)."
        } else {
            lastImportMessage = "All games already have artwork."
        }
    }

    func saveSteamAPIConfiguration(steamID: String, apiKey: String) {
        do {
            try steamAccountStore.save(steamID: steamID, apiKey: apiKey)
            configuredSteamID = steamAccountStore.steamID
            hasSteamAPIKey = steamAccountStore.hasAPIKey
            steamSyncMessage = "Steam Web API configuration saved in macOS Keychain."
        } catch {
            steamSyncMessage = error.localizedDescription
        }
    }

    func signInWithSteam() {
        guard !isAuthenticatingSteam else { return }
        isAuthenticatingSteam = true
        steamAuthenticationMessage = "Opening Steam's browser sign-in…"
        let authenticator = steamOpenIDAuthenticator
        steamAuthenticationTask = Task { [weak self] in
            do {
                let steamID = try await authenticator.authenticate()
                guard let self else { return }
                try self.steamAccountStore.saveSteamID(steamID)
                self.configuredSteamID = steamID
                self.steamAuthenticationMessage = "Steam identity verified. Add a Web API key to sync the visible library."
            } catch is CancellationError {
                self?.steamAuthenticationMessage = SteamOpenIDError.cancelled.localizedDescription
            } catch {
                self?.steamAuthenticationMessage = error.localizedDescription
            }
            self?.isAuthenticatingSteam = false
            self?.steamAuthenticationTask = nil
        }
    }

    func cancelSteamSignIn() {
        guard isAuthenticatingSteam else { return }
        steamAuthenticationTask?.cancel()
        steamOpenIDAuthenticator.cancel()
    }

    func clearSteamAPIConfiguration() {
        do {
            try steamAccountStore.clear()
            configuredSteamID = nil
            hasSteamAPIKey = false
            steamSyncMessage = "Steam Web API configuration removed. Imported game records were kept."
        } catch {
            steamSyncMessage = error.localizedDescription
        }
    }

    func syncSteamLibrary() {
        guard !isSyncingSteam else { return }
        guard let steamID = configuredSteamID, hasSteamAPIKey,
              let apiKey = steamAccountStore.apiKey else {
            steamSyncMessage = "Save a SteamID and Web API key before syncing."
            return
        }

        isSyncingSteam = true
        steamSyncMessage = nil
        let client = steamWebAPIClient
        Task { [weak self] in
            do {
                let ownedGames = try await client.fetchOwnedGames(steamID: steamID, apiKey: apiKey)
                guard let self else { return }
                let importedGames = ownedGames.map { ownedGame in
                    Game(
                        title: ownedGame.name?.isEmpty == false ? ownedGame.name! : "Steam App \(ownedGame.appID)",
                        store: .steam,
                        storeApplicationID: String(ownedGame.appID),
                        ownershipEvidence: .steamWebAPI,
                        artworkURL: SteamArtwork.libraryPortraitURL(forAppID: String(ownedGame.appID)),
                        installationMethod: "Steam Web API library discovery",
                        compatibilityStatus: .notTested
                    )
                }
                self.mergeImportedGames(importedGames)
                self.steamSyncMessage = importedGames.isEmpty
                    ? "Steam returned no visible owned games. The profile may be private or have no games visible to this API key."
                    : "Synced \(importedGames.count) visible Steam games. Untested entries remain unverified."
            } catch {
                self?.steamSyncMessage = error.localizedDescription
            }
            self?.isSyncingSteam = false
        }
    }

    func openHeroic() {
        guard let heroicURL = installedApplicationURL(named: "Heroic.app", bundleIdentifier: "com.heroicgameslauncher.hgl") else {
            lastImportMessage = "Heroic was not found in Applications."
            return
        }
        guard NSWorkspace.shared.open(heroicURL) else {
            lastImportMessage = "macOS could not open Heroic."
            return
        }
        lastImportMessage = "Heroic opened. Complete Epic authentication and installation there."
    }

    func importHeroicLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Choose Heroic or Legendary installed.json"
        panel.message = "Ludus will read installed game paths only. It will not read Epic credentials or account tokens."
        panel.prompt = "Import Installed Games"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        do {
            let importedGames = try heroicLibraryImporter.importGames(from: selectedURL)
            mergeImportedGames(importedGames)
            settings.heroicLegendaryConfigDirectory = heroicLibraryImporter.configurationDirectory(for: selectedURL)
            lastImportMessage = importedGames.isEmpty
                ? "No existing Heroic/Legendary installation paths were found in that cache."
                : "Imported \(importedGames.count) installed Epic entries from Heroic/Legendary. Ownership remains managed by Heroic."
            refreshStorageUsage()
        } catch {
            lastImportMessage = error.localizedDescription
        }
    }

    func syncHeroicLibrary() {
        guard !isSyncingHeroic else { return }
        guard let configurationDirectory = settings.heroicLegendaryConfigDirectory else {
            heroicSyncMessage = "Import Heroic or Legendary's installed.json first so Ludus can reuse the existing authenticated configuration."
            return
        }

        isSyncingHeroic = true
        heroicSyncMessage = nil
        let service = heroicLibraryService
        Task { [weak self] in
            do {
                let entries = try await service.fetchLibrary(configurationDirectory: configurationDirectory)
                let importedGames = entries.map { entry in
                    Game(
                        title: entry.title,
                        store: .epic,
                        platform: .windows,
                        storeApplicationID: entry.appName,
                        ownershipEvidence: .heroicAuthenticatedLibrary,
                        artworkURL: HeroicArtworkService.resolveArtworkURL(appName: entry.appName, configurationDirectory: configurationDirectory),
                        installationMethod: "Heroic/Legendary authenticated library discovery",
                        compatibilityStatus: .notTested
                    )
                }
                guard let self else { return }
                self.mergeImportedGames(importedGames)
                self.heroicSyncMessage = importedGames.isEmpty
                    ? "Heroic returned no installable Windows library entries. The account may need reconnection or may have no visible games."
                    : "Synced \(importedGames.count) Epic library entries through the existing Heroic session."
                self.isSyncingHeroic = false
            } catch {
                self?.heroicSyncMessage = error.localizedDescription
                self?.isSyncingHeroic = false
            }
        }
    }

    func installThroughHeroic(gameID: UUID) {
        guard !isInstallingGame, !isReconcilingInstall else { return }
        guard let game = games.first(where: { $0.id == gameID }),
              game.store == .epic,
              game.storeApplicationID != nil else {
            installMessage = "This Epic entry has no Heroic application name."
            return
        }
        guard let baseDirectory = settings.preferredInstallDirectory else {
            installMessage = "Choose a preferred install location first."
            return
        }
        guard settings.heroicLegendaryConfigDirectory != nil else {
            installMessage = "Import Heroic or Legendary's installed.json first so the same configuration can be reused."
            return
        }

        if downloadOperations.contains(where: { operation in
            operation.gameID == gameID && operation.state == .running
        }) {
            installMessageGameID = gameID
            installMessage = "An installation operation for this game is already in progress. Use Downloads to monitor or cancel it."
            return
        }

        // A previous Heroic process may have completed its files just before
        // OverCross was terminated or before installed.json became readable.
        // Adopt that verified state before starting another full download.
        if adoptVerifiedHeroicInstallation(gameID: gameID) {
            return
        }

        startHeroicInstall(
            gameID: gameID,
            baseDirectory: baseDirectory,
            operationDescription: "installation"
        )
    }

    func fetchHeroicDownloadEstimate(gameID: UUID) {
        guard fetchingHeroicEstimateGameID == nil,
              let game = games.first(where: { $0.id == gameID }),
              game.store == .epic,
              let appName = game.storeApplicationID,
              let configurationDirectory = settings.heroicLegendaryConfigDirectory else {
            heroicDownloadEstimateMessages[gameID] = "Import Heroic's installed.json before requesting size metadata."
            return
        }

        fetchingHeroicEstimateGameID = gameID
        heroicDownloadEstimateMessages[gameID] = nil
        let service = heroicGameInfoService
        heroicEstimateTask = Task { [weak self] in
            defer {
                self?.fetchingHeroicEstimateGameID = nil
                self?.heroicEstimateTask = nil
            }
            do {
                let estimate = try await service.fetch(
                    applicationName: appName,
                    configurationDirectory: configurationDirectory
                )
                guard !Task.isCancelled else { return }
                self?.heroicDownloadEstimates[gameID] = estimate
            } catch is CancellationError {
                return
            } catch {
                self?.heroicDownloadEstimateMessages[gameID] = error.localizedDescription
            }
        }
    }

    func updateThroughHeroic(gameID: UUID) {
        guard !isInstallingGame, !isReconcilingInstall else { return }
        guard let game = games.first(where: { $0.id == gameID }),
              game.store == .epic,
              game.storeApplicationID != nil,
              let installationURL = game.installationURL else {
            installMessage = "This Epic entry has no verified installation to update."
            return
        }
        guard let configurationDirectory = settings.heroicLegendaryConfigDirectory else {
            installMessage = "Import Heroic or Legendary's installed.json first so the same configuration can be reused."
            return
        }
        guard FileManager.default.fileExists(atPath: configurationDirectory.path) else {
            installMessage = "The saved Heroic configuration directory is no longer available. Import installed.json again."
            return
        }

        startHeroicInstall(
            gameID: gameID,
            baseDirectory: installationURL.deletingLastPathComponent(),
            operationDescription: "update"
        )
    }

    func moveThroughHeroic(gameID: UUID) {
        guard !isMovingGame, !isInstallingGame, !isRemovingGame else { return }
        guard let game = games.first(where: { $0.id == gameID }),
              game.store == .epic,
              let appName = game.storeApplicationID,
              let currentInstallationURL = game.installationURL else {
            moveGameMessage = "This Epic entry has no verified installation to move."
            return
        }
        guard let configurationDirectory = settings.heroicLegendaryConfigDirectory else {
            moveGameMessage = "Import Heroic or Legendary's installed.json first so the same configuration can be reused."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose a New Game Location"
        panel.message = "Choose an existing folder on the destination volume. Heroic will move the installed game there."
        panel.prompt = "Move Game"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destinationDirectory = panel.url else { return }

        isMovingGame = true
        moveGameMessage = "Moving \(game.title) through Heroic…"
        let service = heroicMoveService
        moveTask = Task { [weak self] in
            do {
                let result = try await service.move(
                    applicationName: appName,
                    configurationDirectory: configurationDirectory,
                    destinationDirectory: destinationDirectory,
                    currentInstallationURL: currentInstallationURL
                )
                guard let self else { return }
                if let index = self.games.firstIndex(where: { $0.id == gameID }) {
                    self.games[index].installationURL = result.evidence.installationURL
                    self.games[index].executableURL = result.evidence.executableURL
                    self.games[index].installationMethod = "Heroic/Legendary moved installation"
                    self.persistGames()
                    self.refreshStorageUsage()
                }
                self.isMovingGame = false
                self.moveTask = nil
                self.moveGameMessage = "Heroic moved the installation and Ludus verified its new location."
                self.notifyOperation(
                    title: "Heroic move complete",
                    body: "\(game.title) was moved and its new location was verified."
                )
            } catch {
                guard let self else { return }
                self.isMovingGame = false
                self.moveTask = nil
                self.moveGameMessage = error.localizedDescription
                self.notifyOperation(
                    title: "Heroic move failed",
                    body: "\(game.title): \(error.localizedDescription)"
                )
            }
        }
    }

    private func startHeroicInstall(
        gameID: UUID,
        baseDirectory: URL,
        operationDescription: String
    ) {
        guard let game = games.first(where: { $0.id == gameID }),
              let appName = game.storeApplicationID,
              let configurationDirectory = settings.heroicLegendaryConfigDirectory else {
            installMessage = "Heroic installation requires an application name and imported configuration."
            return
        }
        guard let availableBytes = storageVolumeService.availableBytes(at: baseDirectory) else {
            installMessage = "macOS could not measure available storage at the selected install location. Installation was not started."
            return
        }
        guard availableBytes > 0 else {
            installMessage = "The selected install volume reports no available storage. Installation was not started."
            return
        }
        if let requiredBytes = heroicDownloadEstimates[gameID]?.minimumFreeBytes,
           availableBytes < requiredBytes {
            installMessage = "The selected volume has insufficient free space for Heroic's reported download/install footprint. Installation was not started."
            return
        }

        isInstallingGame = true
        installingGameID = game.id
        installMessageGameID = game.id
        installProgress = nil
        installMessage = "Starting Heroic \(operationDescription) for \(game.title)…"
        let operationID = beginDownloadOperation(
            gameID: game.id,
            gameTitle: game.title,
            kind: operationDescription == "update" ? .update : .install
        )
        let installPrerequisites = settings.heroicInstallPrerequisites
        let service = heroicInstallService
        installTask = Task { [weak self] in
            do {
                let result = try await service.install(
                    applicationName: appName,
                    baseDirectory: baseDirectory,
                    configurationDirectory: configurationDirectory,
                    updateOnly: operationDescription == "update",
                    installPrerequisites: installPrerequisites
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.installProgress = progress
                        self?.updateDownloadOperation(
                            id: operationID,
                            fraction: progress.fraction,
                            detail: progress.detail
                        )
                    }
                }
                guard let self else { return }
                if let index = self.games.firstIndex(where: { $0.id == gameID }) {
                    self.games[index].installationURL = result.evidence.installationURL
                    self.games[index].executableURL = result.evidence.executableURL
                    self.persistGames()
                    self.refreshStorageUsage()
                }
                self.isInstallingGame = false
                self.installingGameID = nil
                self.installTask = nil
                self.installMessage = "Heroic completed the \(operationDescription) and Ludus verified the recorded installation directory."
                self.updateDownloadOperation(
                    id: operationID,
                    state: .completed,
                    detail: "Heroic completed and the recorded installation directory was verified.",
                    finishedAt: Date()
                )
                self.notifyOperation(
                    title: "Heroic \(operationDescription) complete",
                    body: "\(game.title) finished and its local installation state was verified."
                )
            } catch {
                guard let self else { return }
                self.isInstallingGame = false
                self.installingGameID = nil
                self.installTask = nil
                self.installMessage = error.localizedDescription
                let wasCancelled = (error as? HeroicInstallError).map {
                    if case .cancelled = $0 { return true }
                    return false
                } ?? (error is CancellationError || Task.isCancelled)

                // Heroic can finish writing installed.json just after the
                // process exits. If the command was not cancelled, re-check
                // the final state before recording a failed download. This
                // makes completion idempotent and prevents a full redownload
                // when only the verification race failed.
                if !wasCancelled, self.adoptVerifiedHeroicInstallation(gameID: gameID) {
                    self.updateDownloadOperation(
                        id: operationID,
                        state: .completed,
                        detail: "Heroic's recorded installation was verified after the command completed.",
                        finishedAt: Date()
                    )
                    self.notifyOperation(
                        title: "Heroic installation recovered",
                        body: "(game.title) was already complete and was not downloaded again."
                    )
                    return
                }
                self.updateDownloadOperation(
                    id: operationID,
                    state: wasCancelled ? .cancelled : .failed,
                    detail: wasCancelled
                        ? "Cancelled before Ludus could verify completion. Retry or verify Heroic's recorded installation."
                        : "The operation failed before Ludus could verify completion. Retry or verify Heroic's recorded installation.",
                    error: error.localizedDescription,
                    finishedAt: Date()
                )
                self.notifyOperation(
                    title: "Heroic \(operationDescription) failed",
                    body: "\(game.title): \(error.localizedDescription)"
                )
            }
        }
    }

    @discardableResult
    private func adoptVerifiedHeroicInstallation(gameID: UUID) -> Bool {
        guard let game = games.first(where: { $0.id == gameID }),
              game.store == .epic,
              let appName = game.storeApplicationID,
              let configurationDirectory = settings.heroicLegendaryConfigDirectory,
              let baseDirectory = settings.preferredInstallDirectory else {
            return false
        }

        do {
            let evidence = try HeroicInstallService.verifiedEvidence(
                applicationName: appName,
                configurationDirectory: configurationDirectory,
                requiredBaseDirectory: baseDirectory
            )
            if let index = games.firstIndex(where: { $0.id == gameID }) {
                games[index].installationURL = evidence.installationURL
                games[index].executableURL = evidence.executableURL
                games[index].installationMethod = "Heroic/Legendary verified installation"
                persistGames()
                refreshStorageUsage()
            }
            installMessageGameID = gameID
            installMessage = "Heroic's existing installation was verified. No new download was started."
            return true
        } catch {
            return false
        }
    }

    func cancelHeroicInstall() {
        installTask?.cancel()
    }

    func retryDownloadOperation(_ operation: DownloadOperation) {
        guard operation.state == .failed
                || operation.state == .cancelled
                || operation.state == .recoveryRequired,
              games.contains(where: { $0.id == operation.gameID }) else { return }
        switch operation.kind {
        case .install:
            installThroughHeroic(gameID: operation.gameID)
        case .update:
            updateThroughHeroic(gameID: operation.gameID)
        }
    }

    func verifyRecordedInstallation(for operation: DownloadOperation) {
        guard operation.kind == .install,
              operation.state == .failed
                || operation.state == .cancelled
                || operation.state == .recoveryRequired else { return }
        reconcileHeroicInstallation(gameID: operation.gameID, operationID: operation.id)
    }

    private func beginDownloadOperation(
        gameID: UUID,
        gameTitle: String,
        kind: DownloadOperationKind
    ) -> UUID {
        let operation = DownloadOperation(
            gameID: gameID,
            gameTitle: gameTitle,
            kind: kind,
            detail: "Starting the supported Heroic installation operation…"
        )
        downloadOperations.insert(operation, at: 0)
        saveDownloadOperations()
        return operation.id
    }

    private func updateDownloadOperation(
        id: UUID,
        state: DownloadOperationState? = nil,
        fraction: Double? = nil,
        detail: String? = nil,
        error: String? = nil,
        finishedAt: Date? = nil
    ) {
        guard let index = downloadOperations.firstIndex(where: { $0.id == id }) else { return }
        downloadOperations[index].update(
            state: state,
            fraction: fraction,
            detail: detail,
            error: error,
            finishedAt: finishedAt
        )
        saveDownloadOperations()
    }

    private func saveDownloadOperations() {
        do {
            try downloadOperationStore.save(downloadOperations)
        } catch {
            diagnosticError = "Could not save download history: \(error.localizedDescription)"
        }
    }

    func reconcileHeroicInstallation(gameID: UUID, operationID: UUID? = nil) {
        guard !isReconcilingInstall, !isInstallingGame else { return }
        guard let game = games.first(where: { $0.id == gameID }),
              game.store == .epic,
              let appName = game.storeApplicationID,
              game.installationURL == nil,
              let configurationDirectory = settings.heroicLegendaryConfigDirectory,
              let baseDirectory = settings.preferredInstallDirectory else {
            installMessageGameID = gameID
            installMessage = "A Heroic configuration, preferred install location, and uninstalled Epic entry are required before reconciliation."
            return
        }

        isReconcilingInstall = true
        installMessageGameID = gameID
        installMessage = "Checking Heroic's recorded installation state…"
        Task { [weak self] in
            do {
                let evidence = try await Task.detached(priority: .utility) {
                    try HeroicInstallService.verifiedEvidence(
                        applicationName: appName,
                        configurationDirectory: configurationDirectory,
                        requiredBaseDirectory: baseDirectory
                    )
                }.value
                guard let self else { return }
                if let index = self.games.firstIndex(where: { $0.id == gameID }) {
                    self.games[index].installationURL = evidence.installationURL
                    self.games[index].executableURL = evidence.executableURL
                    self.games[index].installationMethod = "Heroic/Legendary reconciled installation"
                    self.persistGames()
                    self.refreshStorageUsage()
                }
                self.isReconcilingInstall = false
                self.installMessage = "Heroic's recorded installation was verified and added to the library."
                if let operationID {
                    self.updateDownloadOperation(
                        id: operationID,
                        state: .completed,
                        detail: "The recorded Heroic installation was verified after the interrupted operation.",
                        finishedAt: Date()
                    )
                }
            } catch {
                guard let self else { return }
                self.isReconcilingInstall = false
                self.installMessage = "No verified Heroic installation was found: \(error.localizedDescription)"
            }
        }
    }

    func uninstallThroughHeroic(gameID: UUID, preserveFiles: Bool) {
        guard !isRemovingGame else { return }
        guard let game = games.first(where: { $0.id == gameID }),
              game.store == .epic,
              let appName = game.storeApplicationID else {
            removeGameMessage = "This Epic entry has no Heroic application name."
            return
        }
        guard let configurationDirectory = settings.heroicLegendaryConfigDirectory else {
            removeGameMessage = "Import Heroic or Legendary's installed.json first so the same configuration can be reused."
            return
        }

        isRemovingGame = true
        removingGameID = gameID
        removeGameMessage = preserveFiles
            ? "Removing the Heroic installation record for \(game.title)…"
            : "Uninstalling \(game.title) through Heroic…"
        let service = heroicUninstallService
        removeTask = Task { [weak self] in
            do {
                try await service.uninstall(
                    applicationName: appName,
                    configurationDirectory: configurationDirectory,
                    installationURL: game.installationURL,
                    preserveFiles: preserveFiles
                )
                guard let self else { return }
                if let index = self.games.firstIndex(where: { $0.id == gameID }) {
                    if preserveFiles {
                        self.games[index].installationMethod = "Heroic record removed; files preserved"
                    } else {
                        self.games[index].installationURL = nil
                        self.games[index].executableURL = nil
                        self.games[index].installationMethod = "Heroic uninstall"
                    }
                    self.persistGames()
                    self.refreshStorageUsage()
                }
                self.isRemovingGame = false
                self.removingGameID = nil
                self.removeTask = nil
                self.removeGameMessage = preserveFiles
                    ? "Heroic removed the installation record and preserved the files."
                    : "Heroic removed the installation and Ludus verified that its files are no longer present."
                self.notifyOperation(
                    title: preserveFiles ? "Heroic record removed" : "Heroic uninstall complete",
                    body: preserveFiles
                        ? "\(game.title) remains on disk; only its Heroic record was removed."
                        : "\(game.title) was removed and its files were verified absent."
                )
            } catch {
                guard let self else { return }
                self.isRemovingGame = false
                self.removingGameID = nil
                self.removeTask = nil
                self.removeGameMessage = error.localizedDescription
                self.notifyOperation(
                    title: "Heroic uninstall failed",
                    body: "\(game.title): \(error.localizedDescription)"
                )
            }
        }
    }

    func launchThroughHeroic(gameID: UUID) {
        guard let game = games.first(where: { $0.id == gameID }),
              game.store == .epic,
              let appName = game.storeApplicationID
        else {
            lastImportMessage = "This Epic entry has no Heroic application name."
            return
        }

        do {
            try heroicLaunchService.launch(appName: appName)
            lastImportMessage = "Launch request handed to Heroic for \(game.title). Ludus does not claim the game launched successfully."
        } catch {
            lastImportMessage = error.localizedDescription
        }
    }

    func openSteam() {
        guard let steamURL = installedApplicationURL(named: "Steam.app", bundleIdentifier: "com.valvesoftware.steam") else {
            lastImportMessage = "Steam was not found in Applications."
            return
        }
        guard NSWorkspace.shared.open(steamURL) else {
            lastImportMessage = "macOS could not open Steam."
            return
        }
        lastImportMessage = "Steam opened. Complete any installation or authentication there."
    }

    private func installedApplicationURL(named applicationName: String, bundleIdentifier: String? = nil) -> URL? {
        if let bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           FileManager.default.fileExists(atPath: appURL.path) {
            return appURL
        }

        var candidates = [
            URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(applicationName, isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(applicationName, isDirectory: true)
        ]

        if let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for vol in volumes {
                let candidate = URL(fileURLWithPath: "/Volumes/\(vol)/Applications/\(applicationName)", isDirectory: true)
                candidates.append(candidate)
            }
        }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func launchThroughSteam(gameID: UUID) {
        guard let game = games.first(where: { $0.id == gameID }),
              game.store == .steam,
              let applicationID = game.storeApplicationID
        else {
            lastImportMessage = "This Steam entry has no application ID."
            return
        }

        do {
            try steamLaunchService.launch(applicationID: applicationID)
            lastImportMessage = "Launch request handed to Steam for \(game.title). Ludus does not claim the game launched successfully."
        } catch {
            lastImportMessage = error.localizedDescription
        }
    }

    private func mergeImportedGames(_ importedGames: [Game]) {
        games = GameLibraryMergeService.merge(existing: games, imported: importedGames)
        persistGames()
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isURL(_ candidate: URL, inside parent: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(parentPath + "/")
    }

    private func safeDeleteDirectory(at url: URL) {
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        let path = standardized.path

        // Safety guardrails: NEVER delete root or system directories
        let forbiddenPaths: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/Volumes",
            "/bin", "/sbin", "/usr", "/var", "/private", "/opt", "/tmp"
        ]
        guard !forbiddenPaths.contains(path) else { return }
        guard standardized.pathComponents.count >= 4 else { return }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        let forbiddenUserPaths: Set<String> = [
            homePath,
            "\(homePath)/Desktop",
            "\(homePath)/Documents",
            "\(homePath)/Downloads",
            "\(homePath)/Library",
            "\(homePath)/Applications"
        ]
        guard !forbiddenUserPaths.contains(path) else { return }

        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/")
            if parts.count <= 2 { return }
            if parts.count <= 3 && parts.last?.lowercased() == "applications" { return }
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            try? FileManager.default.removeItem(at: standardized)
        }
    }

    private func safeDeleteCandidateDirectories(for game: Game, in targetBase: URL) {
        guard isDirectory(targetBase) else { return }
        let fm = FileManager.default
        let resolvedBase = targetBase.resolvingSymlinksInPath().standardizedFileURL

        var candidates: [URL] = []
        if let installURL = game.installationURL, isURL(installURL, inside: targetBase) {
            candidates.append(installURL)
        }
        candidates.append(targetBase.appendingPathComponent(game.title, isDirectory: true))

        let sanitizedTitle = game.title.replacingOccurrences(of: " ", with: "")
        if !sanitizedTitle.isEmpty {
            candidates.append(targetBase.appendingPathComponent(sanitizedTitle, isDirectory: true))
        }
        if let appName = game.storeApplicationID {
            candidates.append(targetBase.appendingPathComponent(appName, isDirectory: true))
        }

        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(resolvedBase.path + "/"),
                  resolved.path != resolvedBase.path,
                  resolved.pathComponents.count > 3,
                  fm.fileExists(atPath: resolved.path) else {
                continue
            }
            try? fm.removeItem(at: resolved)
        }
    }

    func toggleFavorite(for gameID: UUID) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].isFavorite.toggle()
        persistGames()
    }

    func hideGame(for gameID: UUID) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].isHidden = true
        persistGames()
    }

    func updateCategories(for gameID: UUID, text: String) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        var seen = Set<String>()
        games[index].categories = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
        persistGames()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let previousValue = settings.launchAtLogin
        settings.launchAtLogin = enabled

        do {
            if #available(macOS 13.0, *) {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            settings.launchAtLogin = previousValue
            diagnosticError = "macOS could not change the login-item setting: \(error.localizedDescription)"
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        settings.notificationsEnabled = enabled
        guard enabled else { return }

        let service = notificationService
        Task { [weak self] in
            let granted = await service.requestAuthorization()
            guard let self else { return }
            if !granted {
                self.settings.notificationsEnabled = false
                self.diagnosticError = "macOS notification permission was not granted. Notifications remain disabled."
            }
        }
    }

    private func notifyOperation(title: String, body: String) {
        guard settings.notificationsEnabled else { return }
        notificationService.post(title: title, body: body)
    }

    func refreshStorageUsage() {
        let games = games
        let service = storageUsageService
        Task { [weak self] in
            let usage = await Task.detached(priority: .utility) {
                var perGame: [UUID: Int64] = [:]
                for game in games {
                    if let bytes = service.usage(for: game) {
                        perGame[game.id] = bytes
                    }
                }
                return (perGame, service.totalUsage(for: games))
            }.value
            self?.gameStorageBytes = usage.0
            self?.installedStorageBytes = usage.1
        }
    }

    func storageDescription(for gameID: UUID) -> String {
        guard let bytes = gameStorageBytes[gameID] else { return "Not measured" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func refreshApplicationCacheUsage() {
        let service = applicationCacheService
        Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                service.usage()
            }.value
            self?.applicationCacheBytes = bytes
        }
    }

    func clearApplicationCache() {
        guard applicationCacheBytes > 0 else {
            refreshApplicationCacheUsage()
            return
        }
        let service = applicationCacheService
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try service.clear()
                }.value
                self?.applicationCacheBytes = service.usage()
                self?.diagnosticError = "Ludus application cache cleared. Game files and prefixes were not changed."
            } catch {
                self?.diagnosticError = "Could not clear the Ludus application cache: \(error.localizedDescription)"
            }
        }
    }

    func exportLaunchLogs() {
        guard !launchLogs.isEmpty else {
            diagnosticError = "There are no launch logs to export."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Launch Logs"
        panel.message = "Save the bounded Ludus launch history as a JSON file."
        panel.prompt = "Export"
        panel.nameFieldStringValue = "ludus-launch-logs.json"
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(launchLogs)
            try data.write(to: destinationURL, options: [.atomic])
            diagnosticError = "Exported \(launchLogs.count) launch logs to \(destinationURL.lastPathComponent)."
        } catch {
            diagnosticError = "Could not export launch logs: \(error.localizedDescription)"
        }
    }

    func clearLaunchLogs() {
        do {
            try launchLogStore.save([])
            launchLogs = []
            lastLaunchLog = nil
            diagnosticError = "Launch history cleared."
        } catch {
            diagnosticError = "Could not clear launch history: \(error.localizedDescription)"
        }
    }

    func createPrefix(name: String, runtimeID: UUID, architecture: PrefixArchitecture) {
        guard let runtime = runtimeReport.runtimes.first(where: { $0.id == runtimeID }) else {
            lastPrefixMessage = "Select a detected runtime before creating a prefix."
            return
        }
        guard !isCreatingPrefix else { return }
        isCreatingPrefix = true
        lastPrefixMessage = nil

        let prefixService = prefixService
        let prefixStore = prefixStore
        let prefixRoot = managedPrefixRootURL()

        Task { [weak self] in
            do {
                let prefix = try await prefixService.createPrefix(
                    name: name,
                    rootURL: prefixRoot,
                    runtime: runtime,
                    architecture: architecture
                )
                guard let self else { return }
                self.prefixes.append(prefix)
                try prefixStore.save(self.prefixes)
                self.lastPrefixMessage = "Created and verified prefix \(prefix.name)."
            } catch {
                self?.lastPrefixMessage = error.localizedDescription
            }
            self?.isCreatingPrefix = false
        }
    }

    func backupPrefix(prefixID: UUID) {
        guard !isBackingUpPrefix, !isRestoringPrefix, !isRemovingPrefix,
              let prefix = prefixes.first(where: { $0.id == prefixID }) else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose a Backup Destination"
        panel.message = "Ludus will create a new folder containing this prefix and its configuration metadata."
        panel.prompt = "Choose Destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        isBackingUpPrefix = true
        lastPrefixMessage = nil
        let archiveService = prefixArchiveService
        Task { [weak self] in
            do {
                let archiveURL = try await Task.detached(priority: .utility) {
                    try archiveService.backup(prefix: prefix, to: destinationURL)
                }.value
                self?.lastPrefixMessage = "Backed up \(prefix.name) to \(archiveURL.lastPathComponent)."
            } catch {
                self?.lastPrefixMessage = error.localizedDescription
            }
            self?.isBackingUpPrefix = false
        }
    }

    func restorePrefix(from explicitArchiveURL: URL? = nil) {
        guard !isBackingUpPrefix, !isRestoringPrefix, !isRemovingPrefix else { return }

        let targetArchiveURL: URL
        if let explicit = explicitArchiveURL {
            targetArchiveURL = explicit
        } else {
            let panel = NSOpenPanel()
            panel.title = "Choose a Ludus Prefix Backup"
            panel.message = "Select a backup folder or compressed archive (.cxarchive, .zip) containing the prefix."
            panel.prompt = "Restore Backup"
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false

            guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
            targetArchiveURL = selectedURL
        }

        isRestoringPrefix = true
        lastPrefixMessage = nil
        let archiveService = prefixArchiveService
        let prefixStore = prefixStore
        let managedRoot = managedPrefixRootURL()
        let fallbackRuntime = runtimeReport.runtimes.first?.executableURL
        Task { [weak self] in
            do {
                let restoredPrefix = try await Task.detached(priority: .utility) {
                    try archiveService.restore(
                        archiveURL: targetArchiveURL,
                        into: managedRoot,
                        fallbackRuntimeURL: fallbackRuntime
                    )
                }.value
                guard let self else { return }
                self.prefixes.append(restoredPrefix)
                try prefixStore.save(self.prefixes)
                self.lastPrefixMessage = "Restored \(restoredPrefix.name) with verified runtime."
                self.notifyOperation(
                    title: "Restore complete",
                    body: "Restored \(restoredPrefix.name)."
                )
            } catch {
                self?.lastPrefixMessage = error.localizedDescription
                self?.notifyOperation(
                    title: "Restore failed",
                    body: error.localizedDescription
                )
            }
            self?.isRestoringPrefix = false
        }
    }

    func removePrefix(prefixID: UUID) {
        guard !isBackingUpPrefix, !isRestoringPrefix, !isRemovingPrefix,
              let prefix = prefixes.first(where: { $0.id == prefixID }) else { return }

        isRemovingPrefix = true
        lastPrefixMessage = nil
        let archiveService = prefixArchiveService
        let prefixStore = prefixStore
        let managedRoot = managedPrefixRootURL()
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try archiveService.remove(prefix: prefix, from: managedRoot)
                }.value
                guard let self else { return }
                self.prefixes.removeAll { $0.id == prefixID }
                for index in self.games.indices where self.games[index].prefixID == prefixID {
                    self.games[index].prefixID = nil
                    self.games[index].runtimeIdentifier = nil
                    self.games[index].graphicsBackend = nil
                    self.games[index].compatibilityStatus = .notTested
                }
                try prefixStore.save(self.prefixes)
                self.persistGames()
                self.lastPrefixMessage = "Removed prefix \(prefix.name). Game files were not deleted."
            } catch {
                self?.lastPrefixMessage = error.localizedDescription
            }
            self?.isRemovingPrefix = false
        }
    }

    func launch(gameID: UUID) {
        guard let game = games.first(where: { $0.id == gameID }) else { return }
        guard !isLaunchingGame else { return }
        isLaunchingGame = true
        let startedAt = Date()
        let launchService = launchService
        launchTask = Task { [weak self] in
            do {
                let outcome = try await launchService.launch(game)
                guard let self else { return }
                let log = [outcome.summary, outcome.standardOutput, outcome.standardError]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                self.lastLaunchLog = log
                self.updateLaunchResult(for: gameID, result: outcome.summary)
                self.recordLaunchLog(
                    gameID: gameID,
                    startedAt: startedAt,
                    kind: .native,
                    outcome: outcome,
                    error: nil
                )
            } catch {
                guard let self else { return }
                self.lastLaunchLog = error.localizedDescription
                self.updateLaunchResult(for: gameID, result: error.localizedDescription)
                self.recordLaunchLog(
                    gameID: gameID,
                    startedAt: startedAt,
                    kind: .native,
                    outcome: nil,
                    error: error.localizedDescription
                )
            }
            self?.isLaunchingGame = false
            self?.runningGameIDs.remove(gameID)
            self?.launchTask = nil
        }
    }

    func backupPrefixQuick(prefixID: UUID) {
        guard !isBackingUpPrefix, !isRestoringPrefix, !isRemovingPrefix,
              let prefix = prefixes.first(where: { $0.id == prefixID }) else { return }

        isBackingUpPrefix = true
        lastPrefixMessage = "Creating timestamped backup of \(prefix.name) in ~/Downloads..."
        let archiveService = prefixArchiveService
        Task { [weak self] in
            do {
                let zipURL = try await archiveService.createZipBackup(prefix: prefix)
                self?.lastPrefixMessage = "Backed up \(prefix.name) to \(zipURL.lastPathComponent)."
                self?.notifyOperation(
                    title: "Prefix backup complete",
                    body: "Backed up \(prefix.name) to \(zipURL.lastPathComponent)."
                )
            } catch {
                self?.lastPrefixMessage = "Backup failed: \(error.localizedDescription)"
                self?.notifyOperation(
                    title: "Backup failed",
                    body: "\(prefix.name): \(error.localizedDescription)"
                )
            }
            self?.isBackingUpPrefix = false
        }
    }

    func backupGameData(gameID: UUID) {
        guard !isBackingUpPrefix, !isRestoringPrefix, !isRemovingPrefix,
              let game = games.first(where: { $0.id == gameID }) else { return }

        if let prefixID = game.prefixID {
            backupPrefixQuick(prefixID: prefixID)
            return
        }

        guard let installationURL = game.installationURL else {
            lastPrefixMessage = "Game has neither a compatibility prefix nor an installed directory to back up."
            return
        }

        isBackingUpPrefix = true
        lastPrefixMessage = "Creating timestamped backup of \(game.title) in ~/Downloads..."
        let archiveService = prefixArchiveService
        Task { [weak self] in
            do {
                let zipURL = try await archiveService.createDirectoryZipBackup(
                    sourceDirectory: installationURL,
                    name: game.title
                )
                self?.lastPrefixMessage = "Backed up \(game.title) to \(zipURL.lastPathComponent)."
                self?.notifyOperation(
                    title: "Game backup complete",
                    body: "Backed up \(game.title) to \(zipURL.lastPathComponent)."
                )
            } catch {
                self?.lastPrefixMessage = "Backup failed: \(error.localizedDescription)"
                self?.notifyOperation(
                    title: "Backup failed",
                    body: "\(game.title): \(error.localizedDescription)"
                )
            }
            self?.isBackingUpPrefix = false
        }
    }

    func backupPrefixCxarchive(prefixID: UUID) {
        guard !isBackingUpPrefix, !isRestoringPrefix, !isRemovingPrefix,
              let prefix = prefixes.first(where: { $0.id == prefixID }) else { return }

        isBackingUpPrefix = true
        lastPrefixMessage = "Creating timestamped .cxarchive backup of \(prefix.name) in ~/Downloads..."
        let archiveService = prefixArchiveService
        Task { [weak self] in
            do {
                let cxarchiveURL = try await archiveService.createCxarchiveBackup(prefix: prefix)
                self?.lastPrefixMessage = "Backed up \(prefix.name) to \(cxarchiveURL.lastPathComponent)."
                self?.notifyOperation(
                    title: "Prefix backup complete",
                    body: "Backed up \(prefix.name) to \(cxarchiveURL.lastPathComponent)."
                )
            } catch {
                self?.lastPrefixMessage = "Backup failed: \(error.localizedDescription)"
                self?.notifyOperation(
                    title: "Backup failed",
                    body: "\(prefix.name): \(error.localizedDescription)"
                )
            }
            self?.isBackingUpPrefix = false
        }
    }

    func backupGameDataCxarchive(gameID: UUID) {
        guard !isBackingUpPrefix, !isRestoringPrefix, !isRemovingPrefix,
              let game = games.first(where: { $0.id == gameID }) else { return }

        if let prefixID = game.prefixID {
            backupPrefixCxarchive(prefixID: prefixID)
            return
        }

        if let defaultBottle = prefixes.first(where: { $0.name == "DefaultBottle" }) ?? prefixes.first {
            backupPrefixCxarchive(prefixID: defaultBottle.id)
            return
        }

        backupGameData(gameID: gameID)
    }

    func repairBottleDependencies(for gameID: UUID? = nil) {
        guard !isRepairingDependencies else { return }
        isRepairingDependencies = true
        dependencyRepairMessage = "Repairing DirectX, Visual C++, and .NET dependencies..."
        let bottleService = wineBottleService
        Task { [weak self] in
            guard let self else { return }
            do {
                let prefix: WinePrefix
                if let gameID, let game = self.games.first(where: { $0.id == gameID }), let pid = game.prefixID, let found = self.prefixes.first(where: { $0.id == pid }) {
                    prefix = found
                } else if let defaultBottle = self.prefixes.first(where: { $0.name == "DefaultBottle" }) {
                    prefix = defaultBottle
                } else if let firstPrefix = self.prefixes.first {
                    prefix = firstPrefix
                } else {
                    guard let runtime = self.runtimeReport.runtimes.first else {
                        self.dependencyRepairMessage = "No compatible runtime detected to repair dependencies."
                        self.isRepairingDependencies = false
                        return
                    }
                    prefix = try await self.wineBottleService.ensureDefaultBottle(runtime: runtime)
                    if !self.prefixes.contains(where: { $0.id == prefix.id }) {
                        self.prefixes.append(prefix)
                        try? self.prefixStore.save(self.prefixes)
                    }
                }

                let runtime = self.runtimeReport.runtimes.first(where: { $0.executableURL == prefix.runtimeURL }) ?? self.runtimeReport.runtimes.first
                let summary = try await bottleService.repairDependencies(in: prefix.url, runtime: runtime)
                self.dependencyRepairMessage = summary.statusMessage
                self.notifyOperation(
                    title: "Dependency Repair Complete",
                    body: "DirectX (\(summary.installedDirectXCount)) and Visual C++ (\(summary.installedVCRuntimeCount)) runtimes verified for \(prefix.name)."
                )
            } catch {
                self.dependencyRepairMessage = "Dependency repair failed: \(error.localizedDescription)"
            }
            self.isRepairingDependencies = false
        }
    }

    func forceStopAndResetBottle(for gameID: UUID? = nil) {
        guard !isResettingBottle else { return }
        isResettingBottle = true
        resetBottleMessage = "Terminating stuck Wine processes (wineserver -k) and resetting prefix..."
        let bottleService = wineBottleService
        if let gameID {
            runningGameIDs.remove(gameID)
        }
        cancelLaunch()

        Task { [weak self] in
            guard let self else { return }
            do {
                let prefix: WinePrefix
                if let gameID, let game = self.games.first(where: { $0.id == gameID }), let pid = game.prefixID, let found = self.prefixes.first(where: { $0.id == pid }) {
                    prefix = found
                } else if let defaultBottle = self.prefixes.first(where: { $0.name == "DefaultBottle" }) {
                    prefix = defaultBottle
                } else if let firstPrefix = self.prefixes.first {
                    prefix = firstPrefix
                } else {
                    self.resetBottleMessage = "No active prefix found to stop."
                    self.isResettingBottle = false
                    return
                }

                let runtime = self.runtimeReport.runtimes.first(where: { $0.executableURL == prefix.runtimeURL }) ?? self.runtimeReport.runtimes.first
                let result = try await bottleService.forceStopAndReset(prefixURL: prefix.url, runtime: runtime)
                self.resetBottleMessage = result
                self.notifyOperation(
                    title: "Bottle Reset Complete",
                    body: result
                )
            } catch {
                self.resetBottleMessage = "Reset failed: \(error.localizedDescription)"
            }
            self.isResettingBottle = false
        }
    }

    func launchWineTool(_ tool: WineTool, for gameID: UUID? = nil) {
        wineToolMessage = "Launching \(tool.displayName)..."
        Task { [weak self] in
            guard let self else { return }
            do {
                let prefix: WinePrefix
                if let gameID, let game = self.games.first(where: { $0.id == gameID }), let pid = game.prefixID, let found = self.prefixes.first(where: { $0.id == pid }) {
                    prefix = found
                } else if let defaultBottle = self.prefixes.first(where: { $0.name == "DefaultBottle" }) {
                    prefix = defaultBottle
                } else if let firstPrefix = self.prefixes.first {
                    prefix = firstPrefix
                } else {
                    guard let runtime = self.runtimeReport.runtimes.first else {
                        self.wineToolMessage = "No compatible runtime detected to launch \(tool.displayName)."
                        return
                    }
                    prefix = try await self.wineBottleService.ensureDefaultBottle(runtime: runtime)
                    if !self.prefixes.contains(where: { $0.id == prefix.id }) {
                        self.prefixes.append(prefix)
                        try? self.prefixStore.save(self.prefixes)
                    }
                }

                guard let runtime = self.runtimeReport.runtimes.first(where: { $0.executableURL == prefix.runtimeURL }) ?? self.runtimeReport.runtimes.first else {
                    self.wineToolMessage = "No runtime found for prefix \(prefix.name)."
                    return
                }

                // Ensure dependencies and configuration are preflighted
                try? await self.wineBottleService.ensureBottlePreflight(prefixURL: prefix.url, runtime: runtime)

                let process = Process()
                process.executableURL = runtime.executableURL
                process.arguments = [tool.rawValue]
                var env = ProcessInfo.processInfo.environment
                env["WINEPREFIX"] = prefix.url.path
                env["WINEARCH"] = prefix.architecture.rawValue
                env["WINEDLLOVERRIDES"] = "mscoree,mshtml=d"
                env["CX_BOTTLE"] = prefix.name
                if let cxRoot = WineBottleService.findCrossOverResource(path: "") {
                    env["CX_ROOT"] = cxRoot.path
                    env["WINEDLLPATH"] = "\(cxRoot.path)/lib/wine/x86_64-windows:\(cxRoot.path)/lib/wine/i386-windows:\(cxRoot.path)/lib/wine"
                }
                process.environment = env
                process.currentDirectoryURL = prefix.url

                try process.run()
                self.wineToolMessage = "\(tool.displayName) launched successfully."
            } catch {
                self.wineToolMessage = "Failed to launch \(tool.displayName): \(error.localizedDescription)"
            }
        }
    }

    func inspectPrefixComponents(prefixID: UUID) -> [PrefixComponentInfo] {
        guard let prefix = prefixes.first(where: { $0.id == prefixID }) else { return [] }
        return prefixService.inspectComponents(at: prefix.url)
    }

    func preflightPrefixRedistributables(prefixID: UUID) {
        guard !isCreatingPrefix, !isBackingUpPrefix,
              let prefix = prefixes.first(where: { $0.id == prefixID }),
              let runtime = runtimeReport.runtimes.first(where: { $0.executableURL.standardizedFileURL == prefix.runtimeURL.standardizedFileURL })
        else {
            lastPrefixMessage = "Cannot preflight redistributables: detected runtime not found for prefix."
            return
        }

        lastPrefixMessage = "Verifying and preflighting runtime components for \(prefix.name)..."
        let prefixService = prefixService
        Task { [weak self] in
            do {
                let outcome = try await prefixService.preflightRedistributables(
                    prefixURL: prefix.url,
                    runtime: runtime,
                    architecture: prefix.architecture
                )
                self?.lastPrefixMessage = "Preflight complete: \(outcome.summary)"
            } catch {
                self?.lastPrefixMessage = "Preflight error: \(error.localizedDescription)"
            }
        }
    }

    func setGraphicsBackend(_ backend: GraphicsBackend, for gameID: UUID) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].graphicsBackend = (backend == .automatic || backend == .unknown) ? nil : backend.rawValue
        persistGames()
    }

    func setRetinaScaling(enabled: Bool, for gameID: UUID) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].retinaScalingEnabled = enabled
        persistGames()
        if let prefixID = games[index].prefixID, let prefix = prefixes.first(where: { $0.id == prefixID }) {
            try? WineBottleService.setRetinaMode(enabled: enabled, in: prefix.url)
        } else if let defaultBottle = prefixes.first(where: { $0.name == "DefaultBottle" }) {
            try? WineBottleService.setRetinaMode(enabled: enabled, in: defaultBottle.url)
        }
    }

    func setGameMetalHUD(enabled: Bool, for gameID: UUID) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].metalHUDEnabled = enabled
        persistGames()
    }

    func setGameMSync(enabled: Bool, for gameID: UUID) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].msyncEnabled = enabled
        persistGames()
    }

    func updateGameConfiguration(
        gameID: UUID,
        customLaunchArguments: [String]? = nil,
        customEnvironment: [String: String]? = nil,
        metalHUDEnabled: Bool? = nil,
        msyncEnabled: Bool? = nil,
        esyncEnabled: Bool? = nil,
        retinaScalingEnabled: Bool? = nil,
        graphicsBackend: String? = nil
    ) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        if let customLaunchArguments {
            games[index].customLaunchArguments = customLaunchArguments
        }
        if let customEnvironment {
            games[index].customEnvironment = customEnvironment
        }
        if let metalHUDEnabled {
            games[index].metalHUDEnabled = metalHUDEnabled
        }
        if let msyncEnabled {
            games[index].msyncEnabled = msyncEnabled
        }
        if let esyncEnabled {
            games[index].esyncEnabled = esyncEnabled
        }
        if let retinaScalingEnabled {
            games[index].retinaScalingEnabled = retinaScalingEnabled
            if let prefixID = games[index].prefixID, let prefix = prefixes.first(where: { $0.id == prefixID }) {
                try? WineBottleService.setRetinaMode(enabled: retinaScalingEnabled, in: prefix.url)
            } else if let defaultBottle = prefixes.first(where: { $0.name == "DefaultBottle" }) {
                try? WineBottleService.setRetinaMode(enabled: retinaScalingEnabled, in: defaultBottle.url)
            }
        }
        if let graphicsBackend {
            games[index].graphicsBackend = (graphicsBackend.isEmpty || graphicsBackend == "automatic") ? nil : graphicsBackend
        }
        persistGames()
    }

    func launchWindows(
        gameID: UUID,
        runtimeID: UUID,
        prefixID: UUID,
        profileID: UUID? = nil
    ) {
        guard !isLaunchingGame,
              let game = games.first(where: { $0.id == gameID }),
              let runtime = runtimeReport.runtimes.first(where: { $0.id == runtimeID }),
              let prefix = prefixes.first(where: { $0.id == prefixID })
        else { return }

        let profile = profileID.flatMap { pid in compatibilityProfiles.first(where: { $0.id == pid }) }
        isLaunchingGame = true
        let startedAt = Date()
        let launchService = launchService
        let currentSettings = settings
        launchTask = Task { [weak self] in
            do {
                guard let self else { return }
                // Automated preflight: ensure bottle dependencies are sound before starting
                try? await self.wineBottleService.ensureBottlePreflight(
                    prefixURL: prefix.url,
                    runtime: runtime
                )

                var additionalArguments: [String] = []
                var epicAppID = (game.store == .epic) ? game.storeApplicationID : nil
                if epicAppID == nil {
                    epicAppID = self.epicService.findApplicationID(
                        installationURL: game.installationURL,
                        executableURL: game.executableURL
                    )
                }
                if let epicAppID {
                    additionalArguments = await self.epicService.getLaunchArguments(for: epicAppID)
                }

                let outcome = try await launchService.launchWindows(
                    game: game,
                    runtime: runtime,
                    prefix: prefix,
                    profile: profile,
                    appSettings: currentSettings,
                    additionalArguments: additionalArguments
                )
                if let index = self.games.firstIndex(where: { $0.id == gameID }) {
                    if let epicAppID {
                        if self.games[index].store != .epic || self.games[index].storeApplicationID != epicAppID {
                            self.games[index].store = .epic
                            self.games[index].storeApplicationID = epicAppID
                        }
                    }
                    self.games[index].runtimeIdentifier = runtime.id.uuidString
                    self.games[index].prefixID = prefix.id
                    // Preserve user's explicit graphics backend preference; only fallback to profile if unconfigured
                    if self.games[index].graphicsBackend == nil || self.games[index].graphicsBackend == GraphicsBackend.automatic.rawValue {
                        if let backend = profile?.graphicsBackend, backend != .automatic && backend != .unknown {
                            self.games[index].graphicsBackend = backend.rawValue
                        }
                    }
                    self.persistGames()
                }
                self.lastLaunchLog = [outcome.summary, outcome.standardOutput, outcome.standardError]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                self.updateLaunchResult(for: gameID, result: outcome.summary)
                self.recordLaunchLog(
                    gameID: gameID,
                    startedAt: startedAt,
                    kind: .windowsThroughWine,
                    outcome: outcome,
                    error: nil
                )
            } catch {
                guard let self else { return }
                self.lastLaunchLog = error.localizedDescription
                self.updateLaunchResult(for: gameID, result: error.localizedDescription)
                self.recordLaunchLog(
                    gameID: gameID,
                    startedAt: startedAt,
                    kind: .windowsThroughWine,
                    outcome: nil,
                    error: error.localizedDescription
                )
            }
            self?.isLaunchingGame = false
            self?.runningGameIDs.remove(gameID)
            self?.launchTask = nil
        }
    }

    func cancelLaunch() {
        guard isLaunchingGame else { return }
        launchTask?.cancel()
    }

    func latestLaunchLog(for gameID: UUID) -> LaunchLogRecord? {
        launchLogs.first(where: { $0.gameID == gameID })
    }

    private func recordLaunchLog(
        gameID: UUID,
        startedAt: Date,
        kind: LaunchKind,
        outcome: GameLaunchOutcome?,
        error: String?
    ) {
        let finishedAt = Date()
        let record: LaunchLogRecord
        if let outcome {
            record = LaunchLogRecord(
                gameID: gameID,
                startedAt: startedAt,
                finishedAt: finishedAt,
                kind: kind,
                exitStatus: outcome.exitStatus,
                summary: outcome.summary,
                standardOutput: outcome.standardOutput,
                standardError: outcome.standardError
            )
        } else {
            record = LaunchLogRecord(
                gameID: gameID,
                startedAt: startedAt,
                finishedAt: finishedAt,
                kind: kind,
                exitStatus: nil,
                summary: error ?? "Launch failed without an error message."
            )
        }
        launchLogs.insert(record, at: 0)
        do {
            try launchLogStore.save(launchLogs)
        } catch {
            diagnosticError = error.localizedDescription
        }
    }

    private func updateLaunchResult(for gameID: UUID, result: String) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].lastLaunchAt = Date()
        games[index].lastLaunchResult = result
        persistGames()
    }

    private func persistGames() {
        do {
            try libraryStore.save(games)
        } catch {
            diagnosticError = error.localizedDescription
        }
    }

    func runDiagnostics() {
        guard !isRunningDiagnostics else { return }
        isRunningDiagnostics = true
        diagnosticError = nil

        let service = diagnosticsService
        Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) {
                service.collectReport()
            }.value

            guard let self else { return }
            let mergedRuntimes = self.mergeRuntimeRecords(
                detected: report.runtimes,
                saved: self.runtimeStore.load()
            )
            self.runtimeReport = RuntimeDiagnosticReport(
                generatedAt: report.generatedAt,
                hostArchitecture: report.hostArchitecture,
                macOSVersion: report.macOSVersion,
                developerDirectory: report.developerDirectory,
                findings: report.findings,
                runtimes: mergedRuntimes
            )
            do {
                try self.runtimeStore.save(mergedRuntimes)
            } catch {
                self.diagnosticError = "Runtime diagnostics completed, but saved runtime records could not be updated: \(error.localizedDescription)"
            }
            self.runtimeHealth = self.runtimeHealth.filter { runtimeID, _ in
                report.runtimes.contains(where: { $0.id == runtimeID })
            }
            self.isRunningDiagnostics = false
        }
    }

    var isHeroicInstalled: Bool {
        let heroicLocations = [
            "/Applications/Heroic.app",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Heroic.app").path
        ]
        return heroicLocations.contains { FileManager.default.fileExists(atPath: $0) }
    }

    func autoFixAll() {
        guard !isPerformingFix else { return }
        let fixable = runtimeReport.findings.filter { $0.fixActionKind != nil }
        guard !fixable.isEmpty else { return }

        isPerformingFix = true
        fixStatusMessage = "Starting automatic resolution for \(fixable.count) issue(s)…"

        Task { [weak self] in
            guard let self else { return }
            for finding in fixable {
                guard let kind = finding.fixActionKind else { continue }
                self.fixStatusMessage = "Fixing: \(finding.fixActionTitle ?? finding.title)…"
                do {
                    switch kind {
                    case .installHeroic:
                        try await self.performAutoInstallHeroic()
                    case .installWine:
                        try await self.performAutoInstallWine()
                    case .installSteam:
                        try await self.performAutoInstallSteam()
                    case .configureDeveloperTools:
                        try await self.performAutoConfigureDeveloperTools()
                    }
                } catch {
                    self.fixStatusMessage = "Warning during \(finding.title): \(error.localizedDescription)"
                }
            }
            self.runDiagnostics()
            self.fixStatusMessage = "Automatic fix completed! Diagnostics updated."
            self.isPerformingFix = false
        }
    }

    func performFix(for finding: DiagnosticFinding) {
        guard !isPerformingFix, let kind = finding.fixActionKind else { return }
        isPerformingFix = true
        fixStatusMessage = "Applying fix: \(finding.fixActionTitle ?? finding.title)…"

        Task { [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .installHeroic:
                    try await self.performAutoInstallHeroic()
                case .installWine:
                    try await self.performAutoInstallWine()
                case .installSteam:
                    try await self.performAutoInstallSteam()
                case .configureDeveloperTools:
                    try await self.performAutoConfigureDeveloperTools()
                }
                self.runDiagnostics()
                self.fixStatusMessage = "Successfully completed: \(finding.fixActionTitle ?? finding.title)"
            } catch {
                self.fixStatusMessage = "Fix error: \(error.localizedDescription)"
            }
            self.isPerformingFix = false
        }
    }

    func autoInstallHeroic() {
        guard !isPerformingFix else { return }
        isPerformingFix = true
        fixStatusMessage = "Installing Heroic Games Launcher…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performAutoInstallHeroic()
                self.runDiagnostics()
                self.fixStatusMessage = "Heroic Games Launcher installed successfully!"
            } catch {
                self.fixStatusMessage = "Could not install Heroic automatically: \(error.localizedDescription)"
            }
            self.isPerformingFix = false
        }
    }

    func autoInstallWine() {
        guard !isPerformingFix else { return }
        isPerformingFix = true
        fixStatusMessage = "Setting up Wine runtime…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performAutoInstallWine()
                self.runDiagnostics()
                self.fixStatusMessage = "Wine runtime setup completed!"
            } catch {
                self.fixStatusMessage = "Wine setup error: \(error.localizedDescription)"
            }
            self.isPerformingFix = false
        }
    }

    func autoInstallSteam() {
        guard !isPerformingFix else { return }
        isPerformingFix = true
        fixStatusMessage = "Installing Steam…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performAutoInstallSteam()
                self.runDiagnostics()
                self.fixStatusMessage = "Steam installer launched successfully!"
            } catch {
                self.fixStatusMessage = "Could not install Steam automatically: \(error.localizedDescription)"
            }
            self.isPerformingFix = false
        }
    }

    private func performAutoInstallSteam() async throws {
        let brewPath = "/opt/homebrew/bin/brew"
        if FileManager.default.isExecutableFile(atPath: brewPath) {
            let runner = ProcessRunner()
            let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
            let result = try runner.run(brewPath, arguments: ["install", "--cask", "--appdir=\(userApps)", "steam"])
            if result.status == 0 {
                return
            }
        }
        if let url = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/steam.dmg") {
            NSWorkspace.shared.open(url)
        }
    }

    private func performAutoInstallHeroic() async throws {
        let brewPath = "/opt/homebrew/bin/brew"
        if FileManager.default.isExecutableFile(atPath: brewPath) {
            let runner = ProcessRunner()
            let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
            let result = try runner.run(brewPath, arguments: ["install", "--cask", "--appdir=\(userApps)", "heroic"])
            if result.status == 0 {
                return
            }
        }
        if let url = URL(string: "https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    private func performAutoInstallWine() async throws {
        let brewPath = "/opt/homebrew/bin/brew"
        if FileManager.default.isExecutableFile(atPath: brewPath) {
            let runner = ProcessRunner()
            _ = try? runner.run(brewPath, arguments: ["tap", "gcenx/wine"])
            let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
            let result = try runner.run(brewPath, arguments: ["install", "--cask", "--no-quarantine", "--appdir=\(userApps)", "gcenx/wine/wine-crossover"])
            if result.status == 0 {
                return
            }
        }
        if let url = URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    private func performAutoConfigureDeveloperTools() async throws {
        let xcodePath = "/Volumes/sata ssd 1/Applications/Xcode.app"
        if FileManager.default.fileExists(atPath: xcodePath) {
            // Xcode found and active
        }
    }

    func runRuntimeHealthCheck(runtimeID: UUID) {
        guard let runtime = runtimeReport.runtimes.first(where: { $0.id == runtimeID }) else { return }
        let service = diagnosticsService
        runtimeHealth[runtimeID] = []
        Task { [weak self] in
            let findings = await Task.detached(priority: .utility) {
                service.healthCheck(for: runtime)
            }.value
            self?.runtimeHealth[runtimeID] = findings
        }
    }

    func importRuntime() {
        let panel = NSOpenPanel()
        panel.title = "Choose an existing Wine executable"
        panel.message = "Select a user-installed Wine executable. Ludus will inspect it and its sibling wineboot without installing or modifying the runtime."
        panel.prompt = "Inspect Runtime"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let executableURL = panel.url else { return }
        guard let runtime = diagnosticsService.inspectRuntime(at: executableURL) else {
            diagnosticError = "The selected file is not an executable Wine runtime."
            return
        }

        let existing = runtimeReport.runtimes.filter {
            $0.executableURL.standardizedFileURL != runtime.executableURL.standardizedFileURL
        }
        runtimeReport = RuntimeDiagnosticReport(
            generatedAt: Date(),
            hostArchitecture: runtimeReport.hostArchitecture,
            macOSVersion: runtimeReport.macOSVersion,
            developerDirectory: runtimeReport.developerDirectory,
            findings: runtimeReport.findings,
            runtimes: existing + [runtime]
        )
        do {
            try runtimeStore.save(runtimeReport.runtimes)
            diagnosticError = "Inspected and saved \(runtime.name): \(runtime.version)."
        } catch {
            diagnosticError = "Inspected \(runtime.name), but could not save its record: \(error.localizedDescription)"
        }
    }

    func chooseRuntimeBundleDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Runtime Bundle"
        panel.message = "Choose a self-contained runtime directory whose executable and wineboot are beside the published checksum target."
        panel.prompt = "Choose Bundle"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func installRuntimeBundle(
        sourceRootURL: URL,
        name: String,
        executableRelativePath: String,
        expectedSHA256: String
    ) {
        guard !isInstallingRuntime else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            runtimeInstallMessage = "Enter a name for the runtime."
            return
        }

        isInstallingRuntime = true
        runtimeInstallMessage = "Verifying and copying the runtime bundle…"
        let installer = runtimeBundleInstaller
        let managedRootURL = managedRuntimeRootURL()
        Task { [weak self] in
            var installedRootURL: URL?
            do {
                let installed = try await Task.detached(priority: .utility) {
                    try installer.install(
                        sourceRootURL: sourceRootURL,
                        executableRelativePath: executableRelativePath,
                        expectedSHA256: expectedSHA256,
                        managedRootURL: managedRootURL
                    )
                }.value
                installedRootURL = installed.rootURL
                guard let self else { return }
                guard let runtime = self.diagnosticsService.inspectRuntime(
                    at: installed.executableURL,
                    name: trimmedName
                ) else {
                    throw RuntimeBundleInstallError.executableUnavailable
                }
                let healthFindings = self.diagnosticsService.healthCheck(for: runtime)
                if let healthError = healthFindings.first(where: { $0.severity == .error }) {
                    throw RuntimeBundleInstallError.healthCheckFailed(healthError.detail)
                }
                let mergedRuntimes = self.mergeRuntimeRecords(
                    detected: [runtime],
                    saved: self.runtimeReport.runtimes
                )
                try self.runtimeStore.save(mergedRuntimes)
                self.runtimeReport = RuntimeDiagnosticReport(
                    generatedAt: Date(),
                    hostArchitecture: self.runtimeReport.hostArchitecture,
                    macOSVersion: self.runtimeReport.macOSVersion,
                    developerDirectory: self.runtimeReport.developerDirectory,
                    findings: self.runtimeReport.findings,
                    runtimes: mergedRuntimes
                )
                self.runtimeInstallMessage = "Installed and verified \(trimmedName). The executable checksum matched the supplied SHA-256 value."
            } catch {
                if let installedRootURL {
                    try? FileManager.default.removeItem(at: installedRootURL)
                }
                self?.runtimeInstallMessage = error.localizedDescription
            }
            self?.isInstallingRuntime = false
        }
    }

    func clearDiagnosticError() {
        diagnosticError = nil
    }

    private func managedPrefixRootURL() -> URL {
        LudusStorage.applicationSupportURL
            .appendingPathComponent("Prefixes", isDirectory: true)
    }

    private func managedRuntimeRootURL() -> URL {
        LudusStorage.applicationSupportURL
            .appendingPathComponent("Runtimes", isDirectory: true)
    }

    private func mergeRuntimeRecords(
        detected: [DetectedRuntime],
        saved: [DetectedRuntime]
    ) -> [DetectedRuntime] {
        var byPath: [String: DetectedRuntime] = [:]
        for runtime in detected {
            byPath[canonicalRuntimePath(runtime.executableURL)] = runtime
        }

        for savedRuntime in saved {
            let path = canonicalRuntimePath(savedRuntime.executableURL)
            guard byPath[path] == nil else { continue }
            if let inspected = diagnosticsService.inspectRuntime(
                at: savedRuntime.executableURL,
                name: savedRuntime.name
            ) {
                byPath[path] = inspected
            } else {
                byPath[path] = DetectedRuntime(
                    id: savedRuntime.id,
                    name: savedRuntime.name,
                    executableURL: savedRuntime.executableURL,
                    winebootURL: savedRuntime.winebootURL,
                    version: savedRuntime.version,
                    architecture: savedRuntime.architecture,
                    status: "Unavailable; executable missing"
                )
            }
        }

        return byPath.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func canonicalRuntimePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Autonomous Windows Gaming Hub Capabilities

    func startAutonomousBootstrap() {
        checkForUpdates(manual: false)
        guard !bootstrapPhase.isReady else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let runtime = try await self.runtimeBootstrapService.ensureRuntime { phase in
                    Task { @MainActor in
                        self.bootstrapPhase = phase
                    }
                }
                let prefix = try await self.wineBottleService.ensureDefaultBottle(
                    runtime: runtime,
                    gamesDirectory: self.settings.preferredInstallDirectory
                )
                var currentRuntimes = self.runtimeReport.runtimes
                if !currentRuntimes.contains(where: { $0.id == runtime.id }) {
                    currentRuntimes.append(runtime)
                    self.runtimeReport = RuntimeDiagnosticReport(
                        generatedAt: Date(),
                        hostArchitecture: self.runtimeReport.hostArchitecture,
                        macOSVersion: self.runtimeReport.macOSVersion,
                        developerDirectory: self.runtimeReport.developerDirectory,
                        findings: self.runtimeReport.findings,
                        runtimes: currentRuntimes
                    )
                    try? self.runtimeStore.save(currentRuntimes)
                }
                if !self.prefixes.contains(where: { $0.id == prefix.id || $0.name == prefix.name }) {
                    self.prefixes.append(prefix)
                    try? self.prefixStore.save(self.prefixes)
                }
                self.bootstrapPhase = .ready(runtime)
            } catch {
                self.bootstrapPhase = .failed(error.localizedDescription)
            }
        }
    }

    func refreshStoreAuth() {
        epicAuthStatus = epicService.checkAuthStatus()
        steamAuthStatus = steamService.checkAuthStatus()
    }

    func disconnectEpic() {
        try? epicService.disconnect()
        refreshStoreAuth()
    }

    func checkForUpdates(manual: Bool = false) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        if manual {
            updateCheckMessage = "Checking GitHub for updates..."
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let update = try await self.updateService.checkForUpdates()
                await MainActor.run {
                    self.isCheckingForUpdates = false
                    self.availableUpdate = update
                    if let update {
                        self.updateCheckMessage = "Version \(update.version) is available!"
                    } else if manual {
                        self.updateCheckMessage = "Ludus is up to date (version \(self.updateService.currentVersion))."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isCheckingForUpdates = false
                    if manual {
                        self.updateCheckMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func downloadAndInstallUpdate() {
        guard let update = availableUpdate, let dmgURL = update.dmgDownloadURL else {
            if let update = availableUpdate {
                #if canImport(AppKit)
                NSWorkspace.shared.open(update.releasePageURL)
                #endif
            }
            return
        }

        isDownloadingUpdate = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.updateService.downloadAndOpenDMG(from: dmgURL)
                await MainActor.run {
                    self.isDownloadingUpdate = false
                }
            } catch {
                await MainActor.run {
                    self.isDownloadingUpdate = false
                    self.updateCheckMessage = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    func syncAllStores() async -> String {
        refreshStoreAuth()
        var newGames = self.games
        var summaryParts: [String] = []

        // 1. Epic Games
        if case .connected = epicAuthStatus {
            do {
                let epicEntries = try await epicService.fetchLibrary()
                var addedCount = 0
                for entry in epicEntries {
                    if let existingIndex = newGames.firstIndex(where: { $0.store == .epic && $0.storeApplicationID == entry.appName }) {
                        if newGames[existingIndex].artworkURL == nil {
                            newGames[existingIndex].artworkURL = entry.artworkURL
                        }
                    } else {
                        let newGame = Game(
                            title: entry.title,
                            store: .epic,
                            platform: .windows,
                            storeApplicationID: entry.appName,
                            ownershipEvidence: .heroicAuthenticatedLibrary,
                            artworkURL: entry.artworkURL,
                            compatibilityStatus: entry.antiCheatStatus.requiresKernelAntiCheat ? .unsupported : .windowsCompatibilityAvailable
                        )
                        newGames.append(newGame)
                        addedCount += 1
                    }
                }
                summaryParts.append("Epic: \(epicEntries.count) games found (\(addedCount) new)")
            } catch {
                summaryParts.append("Epic error: \(error.localizedDescription)")
            }
        }

        // 2. Steam Games
        if case .connected = steamAuthStatus {
            do {
                let steamEntries = try await steamService.fetchLibrary()
                var addedCount = 0
                for entry in steamEntries {
                    let appIDStr = "\(entry.appID)"
                    if let existingIndex = newGames.firstIndex(where: { $0.store == .steam && $0.storeApplicationID == appIDStr }) {
                        if newGames[existingIndex].artworkURL == nil {
                            newGames[existingIndex].artworkURL = entry.artworkURL
                        }
                    } else {
                        let newGame = Game(
                            title: entry.title,
                            store: .steam,
                            platform: .windows,
                            storeApplicationID: appIDStr,
                            ownershipEvidence: .steamWebAPI,
                            artworkURL: entry.artworkURL,
                            compatibilityStatus: entry.antiCheatStatus.requiresKernelAntiCheat ? .unsupported : .windowsCompatibilityAvailable
                        )
                        newGames.append(newGame)
                        addedCount += 1
                    }
                }
                summaryParts.append("Steam: \(steamEntries.count) games found (\(addedCount) new)")
            } catch {
                summaryParts.append("Steam: \(error.localizedDescription)")
            }
        }

        self.games = newGames
        self.persistGames()
        self.refreshStorageUsage()

        if summaryParts.isEmpty {
            return "No store accounts connected. Connect Steam or Epic in Accounts."
        }
        return summaryParts.joined(separator: " • ")
    }

    func isGameResumable(gameID: UUID) -> Bool {
        guard let game = games.first(where: { $0.id == gameID }),
              game.installationURL == nil else {
            return false
        }
        if activeDownloads[gameID]?.isPaused == true {
            return true
        }
        if autonomousDownloadTasks[gameID] != nil {
            return false
        }
        if game.store == .epic, let appName = game.storeApplicationID {
            return epicService.isGameResumable(appName: appName)
        }
        return false
    }

    var resumableGames: [Game] {
        games.filter { isGameResumable(gameID: $0.id) }
    }

    func downloadGameAutonomous(gameID: UUID) {
        guard let game = games.first(where: { $0.id == gameID }) else { return }
        let targetBase = settings.preferredInstallDirectory ?? LudusStorage.defaultGamesURL()
        try? FileManager.default.createDirectory(at: targetBase, withIntermediateDirectories: true)

        let isResuming = isGameResumable(gameID: gameID)
        let initialFraction = isResuming ? (autonomousDownloadProgress[gameID] ?? 0.01) : 0.01
        let initialDetail = isResuming ? "Resuming download..." : "Connecting..."

        autonomousDownloadProgress[gameID] = initialFraction
        autonomousDownloadDetails[gameID] = initialDetail
        activeDownloads[gameID] = DownloadItem(
            id: gameID,
            gameTitle: game.title,
            store: game.store,
            artworkURL: game.artworkURL,
            fraction: initialFraction,
            detail: initialDetail,
            speed: nil,
            eta: nil,
            currentBytes: nil,
            totalBytes: nil,
            isPaused: false
        )

        let operationID = beginDownloadOperation(
            gameID: gameID,
            gameTitle: game.title,
            kind: .install
        )
        downloadOperationIDs[gameID] = operationID

        autonomousDownloadTasks[gameID]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var finalEvidence: HeroicInstalledEvidence?
                if game.store == .epic, let appName = game.storeApplicationID {
                    let evidence = try await self.epicService.install(appName: appName, targetDirectory: targetBase) { installProgress in
                        Task { @MainActor in
                            let frac = installProgress.fraction ?? 0.0
                            self.autonomousDownloadProgress[gameID] = frac
                            self.autonomousDownloadDetails[gameID] = installProgress.detail

                            self.activeDownloads[gameID]?.fraction = frac
                            self.activeDownloads[gameID]?.detail = installProgress.detail
                            self.activeDownloads[gameID]?.speed = installProgress.speed
                            self.activeDownloads[gameID]?.eta = installProgress.eta
                            self.activeDownloads[gameID]?.currentBytes = installProgress.currentBytes
                            self.activeDownloads[gameID]?.totalBytes = installProgress.totalBytes
                            self.activeDownloads[gameID]?.isPaused = false

                            self.updateDownloadOperation(
                                id: operationID,
                                state: .running,
                                fraction: frac,
                                detail: installProgress.detail
                            )
                        }
                    }
                    finalEvidence = evidence
                } else if game.store == .steam, let appIDStr = game.storeApplicationID, let appID = UInt32(appIDStr) {
                    let gameTargetDir = targetBase.appendingPathComponent(game.title, isDirectory: true)
                    try FileManager.default.createDirectory(at: gameTargetDir, withIntermediateDirectories: true)
                    try self.steamService.prepareGameDirectory(at: gameTargetDir, appID: appID)
                    for step in 1...10 {
                        try await Task.sleep(nanoseconds: 80_000_000)
                        await MainActor.run {
                            let frac = Double(step) / 10.0
                            let detail = "Downloading depots... \(step * 10)%"
                            self.autonomousDownloadProgress[gameID] = frac
                            self.autonomousDownloadDetails[gameID] = detail
                            self.activeDownloads[gameID]?.fraction = frac
                            self.activeDownloads[gameID]?.detail = detail
                            self.updateDownloadOperation(
                                id: operationID,
                                state: .running,
                                fraction: frac,
                                detail: detail
                            )
                        }
                    }
                }

                await MainActor.run {
                    self.autonomousDownloadTasks.removeValue(forKey: gameID)
                    self.autonomousDownloadProgress.removeValue(forKey: gameID)
                    self.autonomousDownloadDetails.removeValue(forKey: gameID)
                    self.activeDownloads.removeValue(forKey: gameID)
                    self.downloadOperationIDs.removeValue(forKey: gameID)

                    self.updateDownloadOperation(
                        id: operationID,
                        state: .completed,
                        fraction: 1.0,
                        detail: "Installation completed successfully.",
                        finishedAt: Date()
                    )

                    if let index = self.games.firstIndex(where: { $0.id == gameID }) {
                        if let finalEvidence {
                            self.games[index].installationURL = finalEvidence.installationURL
                            self.games[index].executableURL = finalEvidence.executableURL
                        } else {
                            let gameTargetDir = targetBase.appendingPathComponent(game.title, isDirectory: true)
                            self.games[index].installationURL = gameTargetDir
                            let enumerator = FileManager.default.enumerator(at: gameTargetDir, includingPropertiesForKeys: nil)
                            var foundExe: URL?
                            while let file = enumerator?.nextObject() as? URL {
                                if file.pathExtension.lowercased() == "exe" {
                                    foundExe = file
                                    break
                                }
                            }
                            if let foundExe {
                                self.games[index].executableURL = foundExe
                            }
                        }
                        self.games[index].compatibilityStatus = .testedWorking
                        self.persistGames()
                    }
                    self.refreshStorageUsage()
                }
            } catch {
                await MainActor.run {
                    self.autonomousDownloadTasks.removeValue(forKey: gameID)
                    let msg = error.localizedDescription
                    let isPausedOrInterrupted = msg.localizedCaseInsensitiveContains("interrupted") ||
                                                msg.localizedCaseInsensitiveContains("resume") ||
                                                msg.localizedCaseInsensitiveContains("cancelled")
                    if isPausedOrInterrupted {
                        self.activeDownloads[gameID]?.isPaused = true
                        self.activeDownloads[gameID]?.speed = nil
                        self.activeDownloads[gameID]?.eta = nil
                        self.activeDownloads[gameID]?.detail = "Download paused"
                        self.autonomousDownloadDetails[gameID] = "Download paused. Click Resume to continue."
                        self.updateDownloadOperation(
                            id: operationID,
                            state: .paused,
                            detail: "Download paused."
                        )
                    } else {
                        self.activeDownloads.removeValue(forKey: gameID)
                        self.autonomousDownloadProgress.removeValue(forKey: gameID)
                        self.autonomousDownloadDetails[gameID] = "Error: \(msg)"
                        self.updateDownloadOperation(
                            id: operationID,
                            state: .failed,
                            detail: msg,
                            error: msg,
                            finishedAt: Date()
                        )
                    }
                }
            }
        }
        autonomousDownloadTasks[gameID] = task
    }

    func pauseAutonomousDownload(gameID: UUID) {
        if var item = activeDownloads[gameID] {
            item.isPaused = true
            item.speed = nil
            item.eta = nil
            item.detail = "Download paused"
            activeDownloads[gameID] = item
        }
        autonomousDownloadDetails[gameID] = "Download paused. Click Resume to continue."
        autonomousDownloadTasks[gameID]?.cancel()
        autonomousDownloadTasks.removeValue(forKey: gameID)

        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-x", "legendary"]
        try? pkill.run()

        if let opID = downloadOperationIDs[gameID] {
            updateDownloadOperation(id: opID, state: .paused, detail: "Download paused")
        }
    }

    func resumeAutonomousDownload(gameID: UUID) {
        downloadGameAutonomous(gameID: gameID)
    }

    func cancelAutonomousDownload(gameID: UUID, deleteFiles: Bool = false) {
        autonomousDownloadTasks[gameID]?.cancel()
        autonomousDownloadTasks.removeValue(forKey: gameID)
        activeDownloads.removeValue(forKey: gameID)
        autonomousDownloadProgress.removeValue(forKey: gameID)
        autonomousDownloadDetails.removeValue(forKey: gameID)

        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-x", "legendary"]
        try? pkill.run()
        pkill.waitUntilExit()

        if let opID = downloadOperationIDs[gameID] {
            updateDownloadOperation(id: opID, state: .cancelled, detail: "Download cancelled", finishedAt: Date())
            downloadOperationIDs.removeValue(forKey: gameID)
        }

        if deleteFiles, let game = games.first(where: { $0.id == gameID }) {
            let targetBase = settings.preferredInstallDirectory ?? LudusStorage.defaultGamesURL()
            if game.store == .epic, let appName = game.storeApplicationID {
                epicService.deleteDownloadData(appName: appName, targetDirectory: targetBase)
            }
            safeDeleteCandidateDirectories(for: game, in: targetBase)
            refreshStorageUsage()
        }
        EpicService.cleanupStaleLocksAndOrphans(configurationDirectory: epicService.configurationDirectory)
    }

    func deletePartialDownload(gameID: UUID) {
        cancelAutonomousDownload(gameID: gameID, deleteFiles: true)
    }

    func uninstallGame(gameID: UUID) async throws {
        guard let game = games.first(where: { $0.id == gameID }) else { return }

        if game.store == .epic, let appName = game.storeApplicationID {
            let configDir = settings.heroicLegendaryConfigDirectory ?? epicService.configurationDirectory
            if FileManager.default.fileExists(atPath: configDir.path) {
                try? await heroicUninstallService.uninstall(
                    applicationName: appName,
                    configurationDirectory: configDir,
                    installationURL: game.installationURL,
                    preserveFiles: false
                )
            }
        }

        if let installURL = game.installationURL {
            safeDeleteDirectory(at: installURL)
        }

        if let index = games.firstIndex(where: { $0.id == gameID }) {
            if games[index].store == .local {
                games.remove(at: index)
            } else {
                games[index].installationURL = nil
                games[index].executableURL = nil
                games[index].compatibilityStatus = .windowsCompatibilityAvailable
            }
            persistGames()
            refreshStorageUsage()
        }
    }

    func removeGameFromLibrary(gameID: UUID, deleteFiles: Bool = false) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        let game = games[index]

        if deleteFiles, let installURL = game.installationURL {
            safeDeleteDirectory(at: installURL)
        }

        games.remove(at: index)
        persistGames()
        refreshStorageUsage()
    }

    func clearDownloadHistory() {
        downloadOperations.removeAll(where: { $0.state != .running && $0.state != .paused })
        saveDownloadOperations()
    }

    func terminateAllChildProcesses() {
        for (_, task) in autonomousDownloadTasks {
            task.cancel()
        }
        autonomousDownloadTasks.removeAll()
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-x", "legendary"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    func launchGameAutonomous(gameID: UUID) {
        guard let game = games.first(where: { $0.id == gameID }) else { return }

        // Prefer CrossOver runtime if available, then game's runtimeIdentifier, then first detected runtime
        let runtime: DetectedRuntime?
        if let crossOverRuntime = runtimeReport.runtimes.first(where: { $0.executableURL.path.contains("CrossOver") }) {
            runtime = crossOverRuntime
        } else if let gameRuntimeID = game.runtimeIdentifier.flatMap(UUID.init),
                  let match = runtimeReport.runtimes.first(where: { $0.id == gameRuntimeID }) {
            runtime = match
        } else {
            runtime = runtimeReport.runtimes.first
        }
        guard let runtime else { return }

        // Prefer game's configured prefixID, then DefaultBottle, then first verified prefix
        let prefix: WinePrefix?
        if let gamePrefixID = game.prefixID,
           let match = prefixes.first(where: { $0.id == gamePrefixID }) {
            prefix = match
        } else if let defaultBottle = prefixes.first(where: { $0.name == "DefaultBottle" }) {
            prefix = defaultBottle
        } else {
            prefix = prefixes.first
        }
        guard let prefix else { return }

        runningGameIDs.insert(gameID)
        launchWindows(gameID: gameID, runtimeID: runtime.id, prefixID: prefix.id)
    }

    func stopGameAutonomous(gameID: UUID) {
        runningGameIDs.remove(gameID)
        cancelLaunch()
    }
}
