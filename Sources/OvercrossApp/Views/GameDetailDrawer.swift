import SwiftUI
import AppKit
@testable import OvercrossCore

struct GameDetailDrawer: View {
    let gameID: UUID
    @EnvironmentObject private var appModel: AppModel
    let onClose: () -> Void
    @State private var showUninstallAlert = false
    @State private var showDeleteDataAlert = false
    @State private var showRemoveLocalAlert = false
    @State private var showForceStopAlert = false

    var body: some View {
        if let game = appModel.games.first(where: { $0.id == gameID }) {
            drawerContent(for: game)
        } else {
            VStack {
                Text("Game not found")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 380)
        }
    }

    private func drawerContent(for game: Game) -> some View {
        let isDownloading = appModel.autonomousDownloadProgress[game.id] != nil
        let isPlaying = appModel.runningGameIDs.contains(game.id)
        let isInstalled = game.installationURL != nil
        let isResumable = appModel.isGameResumable(gameID: game.id)
        let antiCheat = AntiCheatRegistry.inspect(title: game.title, storeApplicationID: game.storeApplicationID)

        return VStack(alignment: .leading, spacing: 0) {
            // Header Image
            ZStack(alignment: .topTrailing) {
                if let url = game.artworkURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            fallbackHeader
                        }
                    }
                    .frame(height: 200)
                    .clipped()
                } else {
                    fallbackHeader
                        .frame(height: 200)
                }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.8))
                        .shadow(radius: 4)
                        .padding(12)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Title and Badges
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.title)
                            .font(.title2.bold())
                            .lineLimit(2)

                        HStack(spacing: 8) {
                            // Store badge
                            Label(game.store.displayName, systemImage: game.store == .steam ? "s.circle.fill" : "e.circle.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(game.store == .steam ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                                .foregroundStyle(game.store == .steam ? Color.blue : Color.purple)
                                .cornerRadius(6)

                            // Platform badge
                            Label("Windows", systemImage: "macwindow")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(6)

                            if isInstalled {
                                Label("Installed", systemImage: "checkmark.circle.fill")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.green.opacity(0.2))
                                    .foregroundStyle(.green)
                                    .cornerRadius(6)
                            }
                        }
                    }

                    // Anti-Cheat Warning
                    if antiCheat.requiresKernelAntiCheat, let warning = antiCheat.warningMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Anti-Cheat Notice")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.yellow)
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.yellow.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
                        )
                        .cornerRadius(8)
                    }

                    // Action Controls
                    actionControls(
                        for: game,
                        isPlaying: isPlaying,
                        isDownloading: isDownloading,
                        isInstalled: isInstalled,
                        isResumable: isResumable
                    )

                    if !isPlaying, let result = game.lastLaunchResult, !result.isEmpty {
                        lastLaunchNotice(result: result)
                    }

                    Divider()

                    // Compatibility & Graphics Translation Settings
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Compatibility Settings")
                            .font(.headline)

                        // 1. 1-Click Graphics Backend Selector
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Graphics Backend")
                                .font(.subheadline.weight(.medium))
                            Picker("Graphics Backend", selection: Binding(
                                get: { game.resolvedGraphicsBackend },
                                set: { appModel.setGraphicsBackend($0, for: game.id) }
                            )) {
                                Text("Automatic").tag(GraphicsBackend.automatic)
                                Text("D3DMetal").tag(GraphicsBackend.d3dmetal)
                                Text("DXVK").tag(GraphicsBackend.dxvk)
                                Text("DXMT").tag(GraphicsBackend.dxmt)
                            }
                            .pickerStyle(.segmented)

                            Text(backendDescription(for: game.resolvedGraphicsBackend, game: game))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        // 4. High-Resolution / Retina Display Mode Toggle
                        Toggle(isOn: Binding(
                            get: { game.retinaScalingEnabled ?? false },
                            set: { appModel.setRetinaScaling(enabled: $0, for: game.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("High-Resolution (Retina Mode)")
                                    .font(.subheadline)
                                Text("Sharp HiDPI scaling in prefix registry (HKCU\\Software\\Wine\\Mac Driver)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Apple Silicon Metal HUD Toggle
                        Toggle(isOn: Binding(
                            get: { game.metalHUDEnabled ?? false },
                            set: { appModel.setGameMetalHUD(enabled: $0, for: game.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Metal Performance HUD")
                                    .font(.subheadline)
                                Text("Display real-time FPS, frame time, and Apple Silicon GPU utilization")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // MSync Fast Synchronization Toggle
                        Toggle(isOn: Binding(
                            get: { game.msyncEnabled ?? true },
                            set: { appModel.setGameMSync(enabled: $0, for: game.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MSync Fast Synchronization")
                                    .font(.subheadline)
                                Text("Apple Silicon Mach-based synchronization for maximum frame rates")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            Image(systemName: "gamecontroller.fill")
                                .foregroundStyle(.purple)
                            Text("Game Controller:")
                                .font(.subheadline)
                            Spacer()
                            Text(appModel.gamepadStatusSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    .cornerRadius(8)

                    // Bottle Maintenance, Dependencies & Tools
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Bottle & Tools Maintenance")
                            .font(.headline)

                        // 2. Automated Redistributable & Dependency Repair
                        Button {
                            appModel.repairBottleDependencies(for: game.id)
                        } label: {
                            HStack {
                                Image(systemName: "wrench.and.screwdriver.fill")
                                Text(appModel.isRepairingDependencies ? "Repairing Dependencies…" : "Repair Game Dependencies")
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .disabled(appModel.isRepairingDependencies)

                        // Automated Game Optimization
                        Button {
                            appModel.optimizeGameSettings(for: game.id)
                        } label: {
                            HStack {
                                Image(systemName: "wand.and.stars")
                                Text("Auto-Optimize Memory & DLLs")
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)

                        if let repairMsg = appModel.dependencyRepairMessage {
                            Text(repairMsg)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }

                        // 5. Save Game & Prefix Backup (.cxarchive / zip)
                        HStack(spacing: 8) {
                            Button {
                                appModel.backupGameDataCxarchive(gameID: game.id)
                            } label: {
                                Label("Backup (.cxarchive)", systemImage: "archivebox.fill")
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .disabled(appModel.isBackingUpPrefix)

                            Button {
                                appModel.restorePrefix()
                            } label: {
                                Label("Restore", systemImage: "arrow.clockwise.icloud.fill")
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .disabled(appModel.isRestoringPrefix)
                        }

                        if let prefixMsg = appModel.lastPrefixMessage {
                            Text(prefixMsg)
                                .font(.caption2)
                                .foregroundStyle(.purple)
                                .lineLimit(2)
                        }

                        // 6. Advanced Wine Tools Menu
                        Menu {
                            ForEach(WineTool.allCases) { tool in
                                Button {
                                    appModel.launchWineTool(tool, for: game.id)
                                } label: {
                                    Label(tool.displayName, systemImage: tool.iconName)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "gearshape.2.fill")
                                Text("Launch Wine Tools")
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .menuStyle(.borderlessButton)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(6)

                        if let toolMsg = appModel.wineToolMessage {
                            Text(toolMsg)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        // 3. Force Stop & Clean Reset Bottle
                        Button(role: .destructive) {
                            showForceStopAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                Text(appModel.isResettingBottle ? "Resetting Bottle…" : "Force Stop & Reset Bottle")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .disabled(appModel.isResettingBottle)

                        if let resetMsg = appModel.resetBottleMessage {
                            Text(resetMsg)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        if let installURL = game.installationURL {
                            Button {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: installURL.path)
                            } label: {
                                Label("Open Game Directory", systemImage: "folder")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    .cornerRadius(8)
                }
                .padding(20)
            }
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Uninstall \(game.title)?", isPresented: $showUninstallAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) {
                Task {
                    try? await appModel.uninstallGame(gameID: game.id)
                }
            }
        } message: {
            Text("Are you sure you want to uninstall \"\(game.title)\"? This will remove the game files from your drive.")
        }
        .alert("Delete Download Data?", isPresented: $showDeleteDataAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Files & Reset", role: .destructive) {
                appModel.deletePartialDownload(gameID: game.id)
            }
        } message: {
            Text("Are you sure you want to delete the partial download files for \"\(game.title)\"? This will permanently free up disk space on your drive and reset the download.")
        }
        .confirmationDialog("Remove \"\(game.title)\"?", isPresented: $showRemoveLocalAlert) {
            Button("Remove from Library Only") {
                appModel.removeGameFromLibrary(gameID: game.id, deleteFiles: false)
            }
            Button("Delete Game Files & Remove", role: .destructive) {
                appModel.removeGameFromLibrary(gameID: game.id, deleteFiles: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose whether to keep or delete the game files on disk.")
        }
        .alert("Force Stop & Reset Bottle?", isPresented: $showForceStopAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Force Stop & Reset", role: .destructive) {
                appModel.forceStopAndResetBottle(for: game.id)
            }
        } message: {
            Text("Are you sure you want to force stop all Wine processes for \"\(game.title)\"? This will cleanly terminate wineserver (-k) and reset the bottle state.")
        }
    }

    @ViewBuilder
    private func actionControls(
        for game: Game,
        isPlaying: Bool,
        isDownloading: Bool,
        isInstalled: Bool,
        isResumable: Bool
    ) -> some View {
        VStack(spacing: 10) {
            if isPlaying {
                playingControl(game: game)
            } else if isDownloading {
                downloadingControl(game: game)
            } else if isInstalled {
                installedControl(game: game)
            } else if isResumable {
                resumableControl(game: game)
            } else if game.store == .local {
                localControl(game: game)
            } else {
                uninstalledDownloadControl(game: game)
            }
        }
    }

    private func playingControl(game: Game) -> some View {
        VStack(spacing: 8) {
            if appModel.isLaunchingGame {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting game in Wine...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Game is Running")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
                .padding(.vertical, 2)
            }

            Button {
                appModel.stopGameAutonomous(gameID: game.id)
            } label: {
                HStack {
                    Image(systemName: "stop.circle.fill")
                    Text(appModel.isLaunchingGame ? "Cancel Launch" : "Stop Game")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private func lastLaunchNotice(result: String) -> some View {
        let isError = result.lowercased().contains("exited with status") && !result.lowercased().contains("status 0")
            || result.lowercased().contains("error") || result.lowercased().contains("failed")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(isError ? .orange : .secondary)
                Text(isError ? "Last Launch Note" : "Last Launch Status")
                    .font(.caption.bold())
                    .foregroundStyle(isError ? .orange : .secondary)
            }
            Text(result)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }

    private func downloadingControl(game: Game) -> some View {
        let fraction = appModel.autonomousDownloadProgress[game.id] ?? 0.0
        let detail = appModel.autonomousDownloadDetails[game.id] ?? "Downloading..."
        return VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: fraction, total: 1.0)
                .progressViewStyle(.linear)
                .tint(.purple)

            HStack {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.caption.bold().monospacedDigit())
            }

            HStack(spacing: 8) {
                Button {
                    appModel.pauseAutonomousDownload(gameID: game.id)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)

                Button {
                    appModel.cancelAutonomousDownload(gameID: game.id, deleteFiles: false)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func installedControl(game: Game) -> some View {
        VStack(spacing: 10) {
            Button {
                appModel.launchGameAutonomous(gameID: game.id)
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

            Button(role: .destructive) {
                showUninstallAlert = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text(game.store == .local ? "Uninstall / Remove" : "Uninstall Game")
                }
                .font(.subheadline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    private func resumableControl(game: Game) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
                Text("Download Paused")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }

            Text(appModel.autonomousDownloadDetails[game.id] ?? "Previous progress saved on disk. Click Resume to continue.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    appModel.resumeAutonomousDownload(gameID: game.id)
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text("Resume Download")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Button {
                    showDeleteDataAlert = true
                } label: {
                    Image(systemName: "trash")
                        .font(.headline)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Delete Partial Download Data to free disk space")
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
    }

    private func localControl(game: Game) -> some View {
        VStack(spacing: 10) {
            Button {
                appModel.chooseExecutable(for: game.id)
            } label: {
                HStack {
                    Image(systemName: "folder.badge.gearshape")
                    Text("Locate Executable")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

            Button(role: .destructive) {
                showRemoveLocalAlert = true
            } label: {
                HStack {
                    Image(systemName: "minus.circle")
                    Text("Remove from Library")
                }
                .font(.subheadline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    private func uninstalledDownloadControl(game: Game) -> some View {
        Button {
            appModel.downloadGameAutonomous(gameID: game.id)
        } label: {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                Text("Download Game")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
    }

    private var fallbackHeader: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple.opacity(0.4), Color.blue.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private func backendDescription(for backend: GraphicsBackend, game: Game) -> String {
        switch backend {
        case .automatic:
            let effective = game.resolvedGraphicsBackend(appSettings: appModel.settings)
            if effective != .automatic {
                return "Automatic: Cascades to default \(effective.displayName)."
            }
            return "CrossOver and Ludus automatically select the optimal translation layer."
        case .d3dmetal:
            return "Apple GPTK Direct3D to Metal translation layer (optimal for DX11/DX12)."
        case .dxvk:
            return "Vulkan-based Direct3D translator via MoltenVK (optimal for DX9-DX11)."
        case .dxmt:
            return "Direct3D 11 to Metal direct translator for macOS."
        case .native:
            return "Native macOS renderer."
        case .moltenVK:
            return "Vulkan translation layer via MoltenVK."
        case .unknown:
            return "Custom user-configured environment."
        }
    }
}
