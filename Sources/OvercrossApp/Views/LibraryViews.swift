import SwiftUI
import AppKit
@testable import OvercrossCore

struct LibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var searchText = ""
    @State private var selectedStore: GameStore?
    @State private var favoritesOnly = false
    @State private var selectedCompatibility: LibraryCompatibilityFilter = .all
    @State private var selectedInstallation: LibraryInstallationFilter = .all
    @State private var selectedSort: LibrarySortOption = .alphabetical

    private var visibleGames: [Game] {
        let filteredGames = appModel.games.filter { game in
            !game.isHidden &&
            (searchText.isEmpty || game.title.localizedCaseInsensitiveContains(searchText)) &&
            (selectedStore == nil || game.store == selectedStore) &&
            (!favoritesOnly || game.isFavorite) &&
            selectedCompatibility.matches(game) &&
            selectedInstallation.matches(game)
        }

        return filteredGames.sorted { left, right in
            switch selectedSort {
            case .alphabetical:
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            case .recentlyPlayed:
                let leftDate = left.lastLaunchAt ?? .distantPast
                let rightDate = right.lastLaunchAt ?? .distantPast
                if leftDate == rightDate {
                    return left.title.localizedStandardCompare(right.title) == .orderedAscending
                }
                return leftDate > rightDate
            case .installationStatus:
                let leftInstalled = left.installationURL != nil
                let rightInstalled = right.installationURL != nil
                if leftInstalled != rightInstalled {
                    return leftInstalled && !rightInstalled
                }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                SectionHeader(title: "Unified Library", subtitle: "Real imported entries from Steam, Epic Games, or local executables.")
                Spacer()
                Button {
                    appModel.autoScanSteamLibraries()
                } label: {
                    Label("Sync All Local Steam Libraries", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                Button {
                    appModel.refreshMissingArtwork()
                } label: {
                    Label("Refresh Artwork", systemImage: "photo")
                }
                .buttonStyle(.bordered)
                Button {
                    appModel.importLocalGame()
                } label: {
                    Label("Add local game", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            if let message = appModel.lastImportMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.purple)
            }

            HStack(alignment: .center, spacing: 10) {
                TextField("Search games", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 320)
                Picker("Store", selection: $selectedStore) {
                    Text("All stores").tag(GameStore?.none)
                    ForEach(GameStore.allCases) { store in
                        Text(store.displayName).tag(GameStore?.some(store))
                    }
                }
                .frame(width: 145)
                Picker("Compatibility", selection: $selectedCompatibility) {
                    ForEach(LibraryCompatibilityFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .frame(width: 175)
                Picker("Installation", selection: $selectedInstallation) {
                    ForEach(LibraryInstallationFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .frame(width: 135)
                Picker("Sort", selection: $selectedSort) {
                    ForEach(LibrarySortOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .frame(width: 145)
                Toggle("Favorites", isOn: $favoritesOnly)
                    .toggleStyle(.checkbox)
            }

            if visibleGames.isEmpty {
                EmptyStateCard(
                    icon: "books.vertical.fill",
                    title: "No matching games",
                    message: appModel.games.isEmpty
                        ? "Add a locally installed executable or connect a supported store integration when it is available."
                        : "Try a different search or filter."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleGames) { game in
                            NavigationLink(value: game.id) {
                                GameRow(game: game)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(32)
        .navigationTitle("Unified Library")
        .navigationDestination(for: UUID.self) { gameID in
            GameDetailView(gameID: gameID)
        }
    }
}

private enum LibrarySortOption: String, CaseIterable, Identifiable {
    case alphabetical
    case recentlyPlayed
    case installationStatus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alphabetical: "Alphabetical"
        case .recentlyPlayed: "Recently played"
        case .installationStatus: "Installation status"
        }
    }
}

private enum LibraryInstallationFilter: String, CaseIterable, Identifiable {
    case all
    case installed
    case notInstalled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All installs"
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        }
    }

    func matches(_ game: Game) -> Bool {
        switch self {
        case .all: true
        case .installed: game.installationURL != nil
        case .notInstalled: game.installationURL == nil
        }
    }
}

private enum LibraryCompatibilityFilter: Hashable, Identifiable, CaseIterable {
    case all
    case status(CompatibilityStatus)

    static var allCases: [LibraryCompatibilityFilter] {
        [.all] + CompatibilityStatus.allCases.map(Self.status)
    }

    var id: String {
        switch self {
        case .all: "all"
        case .status(let status): status.rawValue
        }
    }

    var displayName: String {
        switch self {
        case .all: "All compatibility"
        case .status(let status): status.displayName
        }
    }

    func matches(_ game: Game) -> Bool {
        switch self {
        case .all: true
        case .status(let status): game.compatibilityStatus == status
        }
    }
}

private struct GameRow: View {
    let game: Game

    var body: some View {
        HStack(spacing: 14) {
            GameArtworkView(url: game.artworkURL)
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(game.title).font(.headline)
                    if game.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                }
                Text("\(game.store.displayName) · \(game.platform.displayName) · \(game.compatibilityStatus.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: game.executableURL == nil ? "questionmark.circle" : "play.circle")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct GameArtworkView: View {
    let url: URL?

    var body: some View {
        if let url {
            if url.isFileURL {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    placeholder
                }
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.purple.opacity(0.25))
            .overlay {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(.purple)
            }
    }
}

enum TriStateSetting: String, CaseIterable, Identifiable {
    case systemDefault = "Default"
    case enabled = "Force On"
    case disabled = "Force Off"

    var id: String { rawValue }

    var boolValue: Bool? {
        switch self {
        case .systemDefault: return nil
        case .enabled: return true
        case .disabled: return false
        }
    }

    static func from(bool: Bool?) -> TriStateSetting {
        switch bool {
        case .none: return .systemDefault
        case .some(true): return .enabled
        case .some(false): return .disabled
        }
    }
}

struct GameDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    let gameID: UUID
    @State private var selectedRuntimeID: UUID?
    @State private var selectedPrefixID: UUID?
    @State private var selectedProfileID: UUID?
    @State private var categoriesText = ""
    @State private var showHeroicUninstallDialog = false
    @State private var customArgsText = ""
    @State private var customEnvText = ""
    @State private var metalHUDMode: TriStateSetting = .systemDefault
    @State private var msyncMode: TriStateSetting = .systemDefault
    @State private var esyncMode: TriStateSetting = .systemDefault
    @State private var retinaMode: TriStateSetting = .systemDefault
    @State private var selectedBackend: GraphicsBackend = .automatic

    private var game: Game? {
        appModel.games.first(where: { $0.id == gameID })
    }

    var body: some View {
        Group {
            if let game {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        SectionHeader(title: game.title, subtitle: "\(game.store.displayName) · \(game.platform.displayName) · \(game.compatibilityStatus.displayName)")
                        if game.store == .epic {
                            epicLaunchControls(for: game)
                        } else if game.store == .steam {
                            steamLaunchControls(for: game)
                            if game.executableURL?.pathExtension.lowercased() == "exe" {
                                windowsLaunchControls(for: game)
                            }
                        } else if game.executableURL?.pathExtension.lowercased() == "exe" {
                            windowsLaunchControls(for: game)
                        } else {
                            HStack {
                                if appModel.isLaunchingGame {
                                    Button {
                                        appModel.cancelLaunch()
                                    } label: {
                                        Label("Cancel launch", systemImage: "stop.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else {
                                    Button {
                                        appModel.launch(gameID: game.id)
                                    } label: {
                                        Label("Launch", systemImage: "play.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(game.executableURL == nil)
                                }

                                Button {
                                    appModel.toggleFavorite(for: game.id)
                                } label: {
                                    Label(game.isFavorite ? "Unfavorite" : "Favorite", systemImage: game.isFavorite ? "star.slash" : "star")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    appModel.hideGame(for: game.id)
                                } label: {
                                    Label("Hide from library", systemImage: "eye.slash")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        if game.executableURL == nil, game.installationURL != nil {
                            Button {
                                appModel.chooseExecutable(for: game.id)
                            } label: {
                                Label("Choose executable", systemImage: "doc.badge.gearshape")
                            }
                            .buttonStyle(.bordered)
                        }
                        HStack(spacing: 14) {
                            GameArtworkView(url: game.artworkURL)
                                .frame(width: 96, height: 96)
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    appModel.chooseArtwork(for: game.id)
                                } label: {
                                    Label(game.artworkURL == nil ? "Choose artwork" : "Replace artwork", systemImage: "photo")
                                }
                                .buttonStyle(.bordered)
                                if game.artworkURL == nil {
                                    Button {
                                        appModel.refreshMissingArtwork()
                                    } label: {
                                        Label("Fetch Artwork Online", systemImage: "sparkles")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        gamePerformanceSection(game)
                        detailSection(game)
                    }
                    .padding(32)
                }
            } else {
                EmptyStateCard(icon: "exclamationmark.triangle", title: "Game unavailable", message: "This library entry no longer exists.")
                    .padding(32)
            }
        }
        .navigationTitle(game?.title ?? "Game")
        .confirmationDialog(
            "Remove \(game?.title ?? "game") from Heroic?",
            isPresented: $showHeroicUninstallDialog,
            titleVisibility: .visible
        ) {
            Button("Remove Heroic record, keep files") {
                appModel.uninstallThroughHeroic(gameID: gameID, preserveFiles: true)
            }
            Button("Uninstall and delete game files", role: .destructive) {
                appModel.uninstallThroughHeroic(gameID: gameID, preserveFiles: false)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The first option removes only Heroic's installation record. The destructive option asks Heroic to delete the game files; Ludus will not report success unless the files are gone.")
        }
        .onAppear {
            if let game {
                if selectedRuntimeID == nil {
                    selectedRuntimeID = game.runtimeIdentifier.flatMap { UUID(uuidString: $0) } ?? appModel.runtimeReport.runtimes.first?.id
                }
                if selectedPrefixID == nil {
                    selectedPrefixID = game.prefixID
                }
                if selectedProfileID == nil {
                    selectedProfileID = verifiedProfiles(for: game).first?.id
                }
                categoriesText = game.categories.joined(separator: ", ")
                customArgsText = game.customLaunchArguments.joined(separator: " ")
                customEnvText = game.customEnvironment.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                metalHUDMode = TriStateSetting.from(bool: game.metalHUDEnabled)
                msyncMode = TriStateSetting.from(bool: game.msyncEnabled)
                esyncMode = TriStateSetting.from(bool: game.esyncEnabled)
                retinaMode = TriStateSetting.from(bool: game.retinaScalingEnabled)
                selectedBackend = game.graphicsBackend.flatMap { GraphicsBackend(rawValue: $0) } ?? .automatic
            }
        }
        .onChange(of: selectedRuntimeID) { _, _ in
            selectedPrefixID = nil
        }
    }

    private func gamePerformanceSection(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apple Silicon & Launch Controls").font(.title2.weight(.semibold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Metal HUD").font(.caption).foregroundStyle(.secondary)
                    Picker("Metal HUD", selection: $metalHUDMode) {
                        ForEach(TriStateSetting.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("MSync (Apple Silicon)").font(.caption).foregroundStyle(.secondary)
                    Picker("MSync", selection: $msyncMode) {
                        ForEach(TriStateSetting.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("ESync").font(.caption).foregroundStyle(.secondary)
                    Picker("ESync", selection: $esyncMode) {
                        ForEach(TriStateSetting.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Retina / HiDPI").font(.caption).foregroundStyle(.secondary)
                    Picker("Retina", selection: $retinaMode) {
                        ForEach(TriStateSetting.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("DirectX Backend").font(.caption).foregroundStyle(.secondary)
                    Picker("Backend", selection: $selectedBackend) {
                        Text("Automatic").tag(GraphicsBackend.automatic)
                        Text("D3DMetal").tag(GraphicsBackend.d3dmetal)
                        Text("DXVK").tag(GraphicsBackend.dxvk)
                        Text("DXMT").tag(GraphicsBackend.dxmt)
                    }
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Custom Launch Arguments").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. -dx11 -windowed -novid", text: $customArgsText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Custom Environment Overrides").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. VKD3D_CONFIG=dxr11 FOO=BAR", text: $customEnvText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Save Launch Configuration") {
                    let parsedArgs = Self.parseLaunchArguments(customArgsText)
                    let parsedEnv = Self.parseEnvironmentOverrides(customEnvText)
                    appModel.updateGameConfiguration(
                        gameID: game.id,
                        customLaunchArguments: parsedArgs,
                        customEnvironment: parsedEnv,
                        metalHUDEnabled: metalHUDMode.boolValue,
                        msyncEnabled: msyncMode.boolValue,
                        esyncEnabled: esyncMode.boolValue,
                        retinaScalingEnabled: retinaMode.boolValue,
                        graphicsBackend: selectedBackend == .automatic ? nil : selectedBackend.rawValue
                    )
                }
                .buttonStyle(.borderedProminent)

                if game.prefixID != nil || selectedPrefixID != nil || game.installationURL != nil {
                    Button {
                        if let prefixID = game.prefixID ?? selectedPrefixID {
                            appModel.backupPrefixQuick(prefixID: prefixID)
                        } else {
                            appModel.backupGameData(gameID: game.id)
                        }
                    } label: {
                        Label("Backup Prefix & Save Data", systemImage: "archivebox.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.isBackingUpPrefix)
                }
            }

            if appModel.isBackingUpPrefix {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Creating backup in ~/Downloads…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = appModel.lastPrefixMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }

    private func detailSection(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Game details").font(.title2.weight(.semibold))
            DetailRow(label: "Store", value: game.store.displayName)
            DetailRow(label: "Platform", value: game.platform.displayName)
            DetailRow(label: "Ownership evidence", value: game.ownershipEvidence.displayName)
            DetailRow(label: "Installation", value: game.installationURL?.path ?? "Not installed")
            DetailRow(label: "Storage usage", value: game.installationURL == nil ? "Not installed" : appModel.storageDescription(for: game.id))
            DetailRow(label: "Installation method", value: game.installationMethod ?? "Not recorded")
            DetailRow(label: "Executable", value: game.executableURL?.path ?? "Not selected")
            DetailRow(label: "Runtime", value: game.runtimeIdentifier ?? "Not configured")
            DetailRow(label: "Prefix", value: game.prefixID.flatMap { id in appModel.prefixes.first(where: { $0.id == id })?.name } ?? "Not configured")
            DetailRow(label: "Graphics backend", value: game.graphicsBackend ?? "Not configured")
            HStack(spacing: 10) {
                TextField("Categories, separated by commas", text: $categoriesText)
                    .textFieldStyle(.roundedBorder)
                Button("Save categories") {
                    appModel.updateCategories(for: game.id, text: categoriesText)
                }
                .buttonStyle(.bordered)
            }
            DetailRow(label: "Last launch", value: game.lastLaunchResult ?? "No launch recorded")
            DetailRow(label: "Verified profile", value: verifiedProfile(for: game)?.testResult.displayName ?? "No exact verified profile")
            if let launchLog = appModel.latestLaunchLog(for: game.id) {
                Text("Latest launch log · \(launchLog.kind.displayName)")
                    .font(.headline)
                    .padding(.top, 8)
                Text(launchLog.combinedText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }

    private func verifiedProfile(for game: Game) -> CompatibilityProfile? {
        CompatibilityProfileSelectionService().verifiedProfile(
            for: game,
            profiles: appModel.compatibilityProfiles
        )
    }

    private func verifiedProfiles(for game: Game) -> [CompatibilityProfile] {
        guard let appID = game.storeApplicationID else { return [] }
        return appModel.compatibilityProfiles.filter {
            $0.store == game.store &&
            $0.storeApplicationID == appID &&
            $0.isVerified
        }
    }

    private static func parseLaunchArguments(_ text: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        var quoteChar: Character = "\""

        for char in text {
            if char == "\"" || char == "'" {
                if inQuotes && char == quoteChar {
                    inQuotes = false
                } else if !inQuotes {
                    inQuotes = true
                    quoteChar = char
                } else {
                    current.append(char)
                }
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }

    private static func parseEnvironmentOverrides(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        let items = parseLaunchArguments(text)
        for item in items {
            let parts = item.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                var val = String(parts[1])
                if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                    val = String(val.dropFirst().dropLast())
                }
                if !key.isEmpty {
                    env[key] = val
                }
            }
        }
        return env
    }

    @ViewBuilder
    private func epicLaunchControls(for game: Game) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Epic launch configuration")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    appModel.toggleFavorite(for: game.id)
                } label: {
                    Label(game.isFavorite ? "Unfavorite" : "Favorite", systemImage: game.isFavorite ? "star.slash" : "star")
                }
                .buttonStyle(.bordered)
                Button {
                    appModel.hideGame(for: game.id)
                } label: {
                    Label("Hide from library", systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)
            }

            if game.installationURL == nil {
                if appModel.settings.heroicLegendaryConfigDirectory != nil,
                   appModel.settings.preferredInstallDirectory != nil {
                    Button {
                        appModel.installThroughHeroic(gameID: game.id)
                    } label: {
                        Label("Install with Heroic", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(game.storeApplicationID == nil || appModel.isInstallingGame)
                } else {
                    Button {
                        appModel.openHeroic()
                    } label: {
                        Label("Continue in Heroic", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button {
                    appModel.launchThroughHeroic(gameID: game.id)
                } label: {
                    Label("Launch through Heroic", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .disabled(game.storeApplicationID == nil || appModel.isLaunchingGame)
                if appModel.settings.heroicLegendaryConfigDirectory != nil {
                    Button {
                        appModel.updateThroughHeroic(gameID: game.id)
                    } label: {
                        Label("Update with Heroic", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.isInstallingGame || appModel.isMovingGame || appModel.isRemovingGame)
                    Button {
                        appModel.moveThroughHeroic(gameID: game.id)
                    } label: {
                        Label("Move installation", systemImage: "folder.badge.arrow.forward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.isInstallingGame || appModel.isMovingGame || appModel.isRemovingGame)
                }
                Button(role: .destructive) {
                    showHeroicUninstallDialog = true
                } label: {
                    Label("Remove or uninstall", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(appModel.isInstallingGame || appModel.isMovingGame || appModel.isRemovingGame)
            }

            if appModel.installingGameID == game.id {
                HStack(spacing: 10) {
                    if let fraction = appModel.installProgress?.fraction {
                        ProgressView(value: fraction)
                            .frame(width: 150)
                    } else {
                        ProgressView()
                    }
                    Text(appModel.installProgress?.detail ?? "Installing through Heroic…")
                        .font(.caption)
                        .lineLimit(2)
                    Button("Cancel") {
                        appModel.cancelHeroicInstall()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if appModel.removingGameID == game.id {
                ProgressView(appModel.removeGameMessage ?? "Removing through Heroic…")
            } else if appModel.removeGameMessage != nil {
                Text(appModel.removeGameMessage ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appModel.isMovingGame {
                ProgressView(appModel.moveGameMessage ?? "Moving through Heroic…")
            } else if appModel.moveGameMessage != nil {
                Text(appModel.moveGameMessage ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Heroic remains responsible for Epic authentication, entitlement checks, Wine/prefix settings, DRM, and the actual game process. Ludus can invoke Heroic's supported Legendary library/install commands but records only verified local state and command outcomes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func steamLaunchControls(for game: Game) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Steam launch configuration")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    appModel.toggleFavorite(for: game.id)
                } label: {
                    Label(game.isFavorite ? "Unfavorite" : "Favorite", systemImage: game.isFavorite ? "star.slash" : "star")
                }
                .buttonStyle(.bordered)
                Button {
                    appModel.hideGame(for: game.id)
                } label: {
                    Label("Hide from library", systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)
            }

            Button {
                appModel.launchThroughSteam(gameID: game.id)
            } label: {
                Label(
                    game.installationURL == nil ? "Continue in Steam" : "Launch through Steam",
                    systemImage: "arrow.up.forward.app"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(game.storeApplicationID == nil || appModel.isLaunchingGame)

            Text("Steam remains responsible for authentication, entitlement checks, DRM, updates, and the store launch. A separate Wine action appears below only when an executable, runtime, prefix, and verified profile are available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func windowsLaunchControls(for game: Game) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Windows launch configuration")
                    .font(.title2.weight(.semibold))
                Spacer()
                if game.store == .steam, game.storeApplicationID != nil {
                    Button {
                        appModel.launchThroughSteam(gameID: game.id)
                    } label: {
                        Label("Open in Steam", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    appModel.toggleFavorite(for: game.id)
                } label: {
                    Label(game.isFavorite ? "Unfavorite" : "Favorite", systemImage: game.isFavorite ? "star.slash" : "star")
                }
                .buttonStyle(.bordered)
                Button {
                    appModel.hideGame(for: game.id)
                } label: {
                    Label("Hide from library", systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)
            }

            Picker("Runtime", selection: $selectedRuntimeID) {
                Text("Select runtime").tag(UUID?.none)
                ForEach(appModel.runtimeReport.runtimes) { runtime in
                    Text(runtime.name).tag(UUID?.some(runtime.id))
                }
            }

            let matchingPrefixes = appModel.prefixes.filter { prefix in
                guard let selectedRuntimeID,
                      let runtime = appModel.runtimeReport.runtimes.first(where: { $0.id == selectedRuntimeID })
                else { return false }
                return prefix.runtimeURL.standardizedFileURL == runtime.executableURL.standardizedFileURL
            }
            Picker("Prefix", selection: $selectedPrefixID) {
                Text("Select prefix").tag(UUID?.none)
                ForEach(matchingPrefixes) { prefix in
                    Text("\(prefix.name) (\(prefix.architecture.displayName))").tag(UUID?.some(prefix.id))
                }
            }

            let matchingProfiles = verifiedProfiles(for: game)
            if matchingProfiles.isEmpty {
                Label("No exact verified compatibility profile is available for this game.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Verified profile", selection: $selectedProfileID) {
                    Text("Select profile").tag(UUID?.none)
                    ForEach(matchingProfiles) { profile in
                        Text("\(profile.testResult.displayName) · \(profile.graphicsBackend.displayName)")
                            .tag(UUID?.some(profile.id))
                    }
                }

                if let selectedProfileID,
                   let selectedProfile = matchingProfiles.first(where: { $0.id == selectedProfileID }) {
                    CompatibilityProfileEvidenceView(profile: selectedProfile)
                }
            }

            Button {
                if appModel.isLaunchingGame {
                    appModel.cancelLaunch()
                } else {
                    guard let selectedRuntimeID, let selectedPrefixID else { return }
                    appModel.launchWindows(
                        gameID: game.id,
                        runtimeID: selectedRuntimeID,
                        prefixID: selectedPrefixID,
                        profileID: selectedProfileID
                    )
                }
            } label: {
                Label(
                    appModel.isLaunchingGame ? "Cancel launch" : "Launch through Wine",
                    systemImage: appModel.isLaunchingGame ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appModel.isLaunchingGame && (
                selectedRuntimeID == nil ||
                selectedPrefixID == nil
            ))
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }
}

private struct CompatibilityProfileEvidenceView: View {
    let profile: CompatibilityProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile evidence")
                .font(.headline)

            DetailRow(label: "Test result", value: profile.testResult.displayName)
            DetailRow(label: "Test environment", value: profile.testEnvironment ?? "Not recorded")
            DetailRow(
                label: "Last verified",
                value: profile.lastVerifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not recorded"
            )

            if let requiredLauncher = profile.requiredLauncher, !requiredLauncher.isEmpty {
                DetailRow(label: "Required launcher", value: requiredLauncher)
            }

            if !profile.dependencies.isEmpty {
                EvidenceList(title: "Dependencies", items: profile.dependencies)
            }

            if !profile.knownWorkarounds.isEmpty {
                EvidenceList(title: "Known workarounds", items: profile.knownWorkarounds)
            }

            if !profile.knownIssues.isEmpty {
                EvidenceList(title: "Known issues", items: profile.knownIssues)
            }

            if !profile.launchArguments.isEmpty {
                EvidenceList(title: "Launch arguments", items: profile.launchArguments)
            }

            if !profile.environment.isEmpty {
                DetailRow(label: "Environment overrides", value: "\(profile.environment.count) recorded")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct EvidenceList: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout.weight(.semibold))
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StoreView: View {
    @EnvironmentObject private var appModel: AppModel
    let store: GameStore
    @State private var steamIDText = ""
    @State private var steamAPIKeyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: store.displayName, subtitle: "Store authentication and library import are isolated from the compatibility engine.")
            if store == .steam {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Authorized Steam library discovery")
                        .font(.title2.weight(.semibold))
                    Text("Use Steam's browser sign-in to verify your SteamID without giving Ludus your password. Visible-library sync still requires a user-provided Web API key, stored only in macOS Keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            appModel.signInWithSteam()
                        } label: {
                            Label("Sign in with Steam", systemImage: "person.badge.key")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appModel.isAuthenticatingSteam)
                        if appModel.isAuthenticatingSteam {
                            Button("Cancel") {
                                appModel.cancelSteamSignIn()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if let message = appModel.steamAuthenticationMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    TextField("64-bit SteamID", text: $steamIDText)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Steam Web API key", text: $steamAPIKeyText)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save API configuration") {
                            appModel.saveSteamAPIConfiguration(steamID: steamIDText, apiKey: steamAPIKeyText)
                            steamAPIKeyText = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(steamIDText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || steamAPIKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Sync visible library") {
                            appModel.syncSteamLibrary()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!appModel.hasSteamAPIKey || appModel.configuredSteamID == nil || appModel.isSyncingSteam)
                        if appModel.hasSteamAPIKey {
                            Button("Remove configuration", role: .destructive) {
                                appModel.clearSteamAPIConfiguration()
                                steamAPIKeyText = ""
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if appModel.isSyncingSteam {
                        ProgressView("Syncing visible Steam games…")
                    }
                    if let message = appModel.steamSyncMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Button {
                            appModel.openSteam()
                        } label: {
                            Label("Open installed Steam", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            appModel.autoScanSteamLibraries()
                        } label: {
                            Label("Sync All Local Steam Libraries", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            appModel.refreshMissingArtwork()
                        } label: {
                            Label("Refresh Missing Artwork", systemImage: "photo")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            appModel.importSteamLibrary()
                        } label: {
                            Label("Import local Steam library…", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("The handoff opens the user-installed Steam application. The local importer reads selected Steam app manifests from disk; it does not sign in, call the Steam Web API, or claim ownership beyond local installation evidence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let message = appModel.lastImportMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            } else if store == .epic {
                VStack(alignment: .leading, spacing: 12) {
                    if appModel.isHeroicInstalled {
                        Button {
                            appModel.openHeroic()
                        } label: {
                            Label("Open installed Heroic", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            appModel.autoInstallHeroic()
                        } label: {
                            Label("Auto-Install Heroic Games Launcher", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appModel.isPerformingFix)
                    }
                    HStack {
                        Button {
                            appModel.importHeroicLibrary()
                        } label: {
                            Label("Import Heroic installed games", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            appModel.refreshMissingArtwork()
                        } label: {
                            Label("Refresh Missing Artwork", systemImage: "photo")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button {
                        appModel.syncHeroicLibrary()
                    } label: {
                        Label("Sync authenticated Epic library", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.settings.heroicLegendaryConfigDirectory == nil || appModel.isSyncingHeroic)
                    if appModel.isSyncingHeroic {
                        ProgressView("Refreshing Epic library through Heroic…")
                    }
                    if let message = appModel.heroicSyncMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("Authentication remains in the user-installed Heroic session. Ludus reuses only the selected configuration directory, never asks for an Epic password, and never stores a reusable Epic token.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let message = appModel.lastImportMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            }
            let hasStoreEntries = appModel.games.contains { $0.store == store }
            EmptyStateCard(
                icon: store == .steam ? "s.circle.fill" : "e.circle.fill",
                title: hasStoreEntries ? "Account connection is external" : "Not connected",
                message: hasStoreEntries
                    ? "Local entries are available, but account authentication and ownership remain managed by the supported store or Heroic workflow."
                    : store == .epic
                        ? "Import Heroic's installed.json first, then sync the existing authenticated Heroic session. Ludus will never ask for or store your Epic password."
                        : "Sign in through Steam's browser flow or use the local-library import. Ludus will never ask for or store your Steam password directly."
            )
            Spacer()
        }
        .padding(32)
        .navigationTitle(store.displayName)
        .onAppear {
            if store == .steam, steamIDText.isEmpty {
                steamIDText = appModel.configuredSteamID ?? ""
            }
        }
        .onChange(of: appModel.configuredSteamID) { _, steamID in
            if store == .steam, let steamID {
                steamIDText = steamID
            }
        }
    }
}

struct InstallGameView: View {
    @EnvironmentObject private var appModel: AppModel

    private var installableGames: [Game] {
        appModel.games
            .filter { !$0.isHidden && $0.installationURL == nil && $0.store != .local }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeader(title: "Install Game", subtitle: "Use a supported launcher path, observe real output when available, and verify local state before launch.")
                installLocationSection
                if installableGames.isEmpty {
                    EmptyStateCard(
                        icon: "arrow.down.circle.fill",
                        title: "No uninstalled store entries",
                        message: "Import a Steam library or an Epic installed cache first. Ludus will not invent an installable game or display placeholder download progress."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Owned or imported entries awaiting installation")
                            .font(.title2.weight(.semibold))
                        ForEach(installableGames) { game in
                            installableGameRow(game)
                        }
                    }
                }
                importRefreshSection
                Spacer()
            }
            .padding(32)
        }
        .navigationTitle("Install Game")
    }

    private var installLocationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preferred install location").font(.title2.weight(.semibold))
            Text(appModel.settings.preferredInstallDirectory?.path ?? "Not configured")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let freeBytes = appModel.preferredInstallFreeBytes {
                Text("Available: \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Available space has not been measured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                appModel.chooseInstallDirectory()
            } label: {
                Label("Choose install location", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            Text("For Heroic installs this becomes Legendary's base path. Steam installs remain controlled by Steam's own library settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                "Allow Legendary to run prerequisite installers",
                isOn: $appModel.settings.heroicInstallPrerequisites
            )
            .toggleStyle(.switch)
            Text("Disabled by default. When disabled, Ludus passes Legendary's --no-install flag and will not run bundled prerequisite installers during an Epic operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Heroic configuration: \(appModel.settings.heroicLegendaryConfigDirectory?.path ?? "Import installed.json to enable the local install bridge")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }

    private func installableGameRow(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.headline)
                    Text("\(game.store.displayName) · \(game.compatibilityStatus.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if game.store == .steam {
                    Button {
                        appModel.launchThroughSteam(gameID: game.id)
                    } label: {
                        Label("Continue in Steam", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(game.storeApplicationID == nil)
                } else if game.store == .epic {
                    if appModel.settings.heroicLegendaryConfigDirectory != nil,
                       appModel.settings.preferredInstallDirectory != nil {
                        Button {
                            appModel.installThroughHeroic(gameID: game.id)
                        } label: {
                            Label("Install with Heroic", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appModel.isInstallingGame || appModel.isReconcilingInstall)
                    } else {
                        Button {
                            appModel.openHeroic()
                        } label: {
                            Label("Continue in Heroic", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            if game.store == .epic {
                if let estimate = appModel.heroicDownloadEstimates[game.id] {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill.badge.timemachine")
                            .foregroundStyle(.secondary)
                        if let downloadBytes = estimate.downloadBytes {
                            Text("Download: " + ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file))
                        }
                        if let diskBytes = estimate.diskBytes {
                            Text("Disk: " + ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file))
                        }
                        Spacer()
                        Button("Refresh size") {
                            appModel.fetchHeroicDownloadEstimate(gameID: game.id)
                        }
                        .buttonStyle(.bordered)
                        .disabled(appModel.fetchingHeroicEstimateGameID != nil)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        Button {
                            appModel.fetchHeroicDownloadEstimate(gameID: game.id)
                        } label: {
                            Label("Check expected size", systemImage: "ruler")
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            appModel.settings.heroicLegendaryConfigDirectory == nil ||
                            appModel.fetchingHeroicEstimateGameID != nil
                        )
                        if appModel.fetchingHeroicEstimateGameID == game.id {
                            ProgressView()
                                .controlSize(.small)
                            Text("Reading Heroic metadata…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let message = appModel.heroicDownloadEstimateMessages[game.id] {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if appModel.installingGameID == game.id {
                HStack(spacing: 10) {
                    if let fraction = appModel.installProgress?.fraction {
                        ProgressView(value: fraction)
                            .frame(width: 150)
                    } else {
                        ProgressView()
                    }
                    Text(appModel.installProgress?.detail ?? "Installing through Heroic…")
                        .font(.caption)
                        .lineLimit(2)
                    Button("Cancel") {
                        appModel.cancelHeroicInstall()
                    }
                    .buttonStyle(.bordered)
                }
            }
            if game.installationURL == nil,
               appModel.settings.heroicLegendaryConfigDirectory != nil {
                Button {
                    appModel.reconcileHeroicInstallation(gameID: game.id)
                } label: {
                    Label("Re-check Heroic installation state", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(appModel.isInstallingGame || appModel.isReconcilingInstall)
            }
            if appModel.isReconcilingInstall, appModel.installMessageGameID == game.id {
                ProgressView("Checking Heroic's recorded installation…")
            }
            Text("Ludus records an Epic installation only after Heroic reports it and installed.json verifies a non-empty directory. Steam remains an external handoff; use the refresh actions below when its state changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if appModel.installMessageGameID == game.id, let installMessage = appModel.installMessage {
                Text(installMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var importRefreshSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Refresh local installation evidence")
                .font(.title2.weight(.semibold))
            HStack {
                Button {
                    appModel.importSteamLibrary()
                } label: {
                    Label("Re-import Steam manifests", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button {
                    appModel.importHeroicLibrary()
                } label: {
                    Label("Re-import Heroic installed games", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            if let message = appModel.lastImportMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CompatibilityCenterView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                SectionHeader(title: "Compatibility Center", subtitle: "Profiles make support boundaries and required configuration visible before changes are applied.")
                Spacer()
                Button {
                    appModel.importCompatibilityProfiles()
                } label: {
                    Label("Import profiles", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            VStack(alignment: .leading, spacing: 14) {
                CompatibilityRow(title: "Not tested", detail: "Untested must remain distinct from working.", color: .gray)
                CompatibilityRow(title: "Verified working", detail: "Requires a recorded test result and environment.", color: .green)
                CompatibilityRow(title: "Known issues", detail: "Shows blockers without hiding the game.", color: .orange)
                CompatibilityRow(title: "Unsupported", detail: "Used for known DRM, anti-cheat, or technical blockers.", color: .red)
            }
            .padding(20)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            Text("Stored profiles: \(appModel.compatibilityProfiles.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message = appModel.compatibilityProfileMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if appModel.compatibilityProfiles.isEmpty {
                Text("No compatibility profiles are stored. Import a reviewed JSON profile list; profiles become launch-selectable only after a matching game, a working or partially-working result, and recorded test-environment evidence exist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.compatibilityProfiles) { profile in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(profile.store.displayName) · \(profile.storeApplicationID ?? "No app ID")")
                            .font(.headline)
                        Text("\(profile.testResult.displayName) · \(profile.graphicsBackend.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(profile.isVerified ? "Recorded evidence available" : "Not launch-selectable: test-environment evidence is incomplete")
                            .font(.caption2)
                            .foregroundStyle(profile.isVerified ? .green : .orange)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Spacer()
        }
        .padding(32)
        .navigationTitle("Compatibility Center")
    }
}

private struct CompatibilityRow: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
