import SwiftUI
import AppKit
@testable import OvercrossCore

enum StoreFilter: String, CaseIterable, Identifiable {
    case all = "All Windows"
    case installed = "Installed"
    case local = "Local"
    case epic = "Epic Games"
    case steam = "Steam"

    var id: String { rawValue }
}

struct MainLibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var searchQuery = ""
    @State private var selectedFilter: StoreFilter = .all
    @State private var selectedGameID: UUID?
    @State private var showAccountsSheet = false
    @State private var showStorageSheet = false
    @State private var showDownloadsSheet = false

    var body: some View {
        HStack(spacing: 0) {
            // Main Library Grid Canvas
            VStack(spacing: 0) {
                // Minimal Top Bar
                topControlBar

                Divider()

                // Update Banner (if a GitHub update is available)
                if let update = appModel.availableUpdate {
                    updateBanner(update)
                }

                // Bootstrap Banner (if actively provisioning dependencies)
                if !appModel.bootstrapPhase.isReady && appModel.bootstrapPhase != .notStarted {
                    bootstrapBanner
                }

                // Game Poster Grid
                ScrollView {
                    if filteredGames.isEmpty {
                        emptyStateView
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 20)],
                            spacing: 24
                        ) {
                            ForEach(filteredGames) { game in
                                GameCardView(
                                    game: game,
                                    isSelected: selectedGameID == game.id,
                                    isDownloading: appModel.autonomousDownloadProgress[game.id] != nil,
                                    downloadFraction: appModel.autonomousDownloadProgress[game.id] ?? 0.0,
                                    isPlaying: appModel.runningGameIDs.contains(game.id),
                                    isResumable: appModel.isGameResumable(gameID: game.id)
                                )
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        selectedGameID = game.id
                                    }
                                }
                            }
                        }
                        .padding(24)
                    }
                }
            }

            // Sliding Game Detail Drawer
            if let selectedGameID {
                Divider()
                GameDetailDrawer(gameID: selectedGameID) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        self.selectedGameID = nil
                    }
                }
                .transition(.move(edge: .trailing))
            }
        }
        .sheet(isPresented: $showAccountsSheet) {
            AccountsSheet()
        }
        .sheet(isPresented: $showStorageSheet) {
            StorageLocationSheet()
        }
        .sheet(isPresented: $showDownloadsSheet) {
            DownloadManagerSheet()
        }
        .onAppear {
            appModel.startAutonomousBootstrap()
            appModel.refreshStoreAuth()
            if appModel.games.isEmpty && (appModel.epicAuthStatus != .notConnected || appModel.steamAuthStatus != .notConnected) {
                Task {
                    await appModel.syncAllStores()
                }
            }
        }
    }

    private var topControlBar: some View {
        HStack(spacing: 16) {
            // Brand & Status
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Ludus")
                    .font(.title2.bold())

                // Status indicator
                if appModel.bootstrapPhase.isReady {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
            }

            Spacer()

            // Filter Segmented Control
            Picker("Filter", selection: $selectedFilter) {
                ForEach(StoreFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)

            // Search Field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Windows games...", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .frame(width: 220)

            // Storage Location Button
            Button {
                showStorageSheet = true
            } label: {
                Image(systemName: "internaldrive.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Storage Location")

            // Download Manager Button
            Button {
                showDownloadsSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: appModel.hasActiveDownloads ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.headline)
                        .foregroundStyle(appModel.hasActiveDownloads ? .purple : .secondary)

                    if appModel.hasActiveDownloads {
                        Text("\(appModel.activeDownloadsCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.2))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())

                        if let speed = appModel.totalDownloadSpeedFormatted {
                            Text(speed)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, appModel.hasActiveDownloads ? 10 : 8)
                .padding(.vertical, 6)
                .background(appModel.hasActiveDownloads ? Color.purple.opacity(0.12) : Color.clear)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .help("Download Manager")

            // Quick Sync Button
            Button {
                Task {
                    await appModel.syncAllStores()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Sync Store Libraries")

            // Add Local Game Button
            Button {
                appModel.importLocalGame()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Game")
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .help("Add Local Windows Game (.exe)")

            // Accounts Button
            Button {
                showAccountsSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                    Text("Accounts")
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.purple.opacity(0.15))
                .foregroundStyle(.purple)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func updateBanner(_ update: AppUpdateInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.purple)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Ludus \(update.version) is available")
                    .font(.subheadline.bold())
                Text(update.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appModel.isDownloadingUpdate {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Downloading DMG…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    appModel.downloadAndInstallUpdate()
                } label: {
                    Text("Update Now")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)

                Button {
                    NSWorkspace.shared.open(update.releasePageURL)
                } label: {
                    Text("Release Notes")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    withAnimation {
                        appModel.availableUpdate = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.purple.opacity(0.12))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.purple.opacity(0.3)),
            alignment: .bottom
        )
    }

    private var bootstrapBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text(appModel.bootstrapPhase.statusDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.1))
    }

    private var filteredGames: [Game] {
        appModel.games
            .filter { game in
                // Only Windows games or unassigned that can run under Wine
                game.platform == .windows || game.platform == .unknown
            }
            .filter { game in
                switch selectedFilter {
                case .all: return true
                case .installed: return game.installationURL != nil
                case .local: return game.store == .local
                case .epic: return game.store == .epic
                case .steam: return game.store == .steam
                }
            }
            .filter { game in
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                return game.title.localizedCaseInsensitiveContains(searchQuery)
            }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 56))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("No Games Found")
                .font(.title3.bold())

            if appModel.epicAuthStatus != .notConnected || appModel.steamAuthStatus != .notConnected {
                Text("Your store account is connected. Click below to scan and load your Windows games into the library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                Button {
                    Task {
                        await appModel.syncAllStores()
                    }
                } label: {
                    Label("Sync Game Library", systemImage: "arrow.clockwise")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            } else {
                Text("Connect your Steam or Epic Games account from the Accounts button to view and download your Windows games.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                Button {
                    showAccountsSheet = true
                } label: {
                    Label("Connect Accounts", systemImage: "person.badge.plus")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GameCardView: View {
    @EnvironmentObject private var appModel: AppModel
    let game: Game
    let isSelected: Bool
    let isDownloading: Bool
    let downloadFraction: Double
    let isPlaying: Bool
    let isResumable: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Poster Art
            ZStack(alignment: .bottom) {
                if let url = game.artworkURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(2/3, contentMode: .fill)
                        default:
                            placeholderArt
                        }
                    }
                } else {
                    placeholderArt
                }

                // Overlay Status Badge
                VStack {
                    HStack {
                        // Store pill
                        Text(game.store == .steam ? "STEAM" : "EPIC")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)

                        Spacer()

                        // Anti-cheat warning dot
                        let antiCheat = AntiCheatRegistry.inspect(title: game.title, storeApplicationID: game.storeApplicationID)
                        if antiCheat.requiresKernelAntiCheat {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .padding(4)
                                .background(.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                    }
                    .padding(8)

                    Spacer()

                    if isDownloading {
                        ProgressView(value: downloadFraction, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(.purple)
                            .padding(8)
                            .background(.black.opacity(0.7))
                    } else if isPlaying {
                        HStack {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("PLAYING")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.75))
                    } else if game.installationURL != nil {
                        Text("INSTALLED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(.black.opacity(0.75))
                    } else if isResumable {
                        HStack(spacing: 4) {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 8))
                            Text("PAUSED")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.orange)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.75))
                    }
                }
            }
            .aspectRatio(2/3, contentMode: .fit)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.purple : (isHovered ? Color.white.opacity(0.4) : Color.clear), lineWidth: 2)
            )
            .shadow(color: isSelected ? Color.purple.opacity(0.4) : Color.black.opacity(0.2), radius: isSelected ? 8 : 4)

            // Title
            Text(game.title)
                .font(.subheadline.bold())
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if isPlaying {
                Button("Stop Game") {
                    appModel.stopGameAutonomous(gameID: game.id)
                }
            } else if game.installationURL != nil {
                Button("Play") {
                    appModel.launchGameAutonomous(gameID: game.id)
                }
                if let url = game.installationURL {
                    Button("Open Game Directory") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                    }
                }
                Divider()
                Button(role: .destructive) {
                    Task { try? await appModel.uninstallGame(gameID: game.id) }
                } label: {
                    Label("Uninstall Game", systemImage: "trash")
                }
            } else if isDownloading {
                Button("Pause Download") {
                    appModel.pauseAutonomousDownload(gameID: game.id)
                }
                Button("Cancel Download", role: .destructive) {
                    appModel.cancelAutonomousDownload(gameID: game.id, deleteFiles: false)
                }
            } else if isResumable {
                Button("Resume Download") {
                    appModel.resumeAutonomousDownload(gameID: game.id)
                }
                Button("Delete Download Data", role: .destructive) {
                    appModel.deletePartialDownload(gameID: game.id)
                }
            } else {
                Button("Download Game") {
                    appModel.downloadGameAutonomous(gameID: game.id)
                }
            }

            if game.store == .local {
                Divider()
                Button(role: .destructive) {
                    appModel.removeGameFromLibrary(gameID: game.id, deleteFiles: false)
                } label: {
                    Label("Remove from Library", systemImage: "minus.circle")
                }
            }
        }
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.3), Color.blue.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Image(systemName: "gamecontroller")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.4))
                Text(game.title)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .aspectRatio(2/3, contentMode: .fill)
    }
}
