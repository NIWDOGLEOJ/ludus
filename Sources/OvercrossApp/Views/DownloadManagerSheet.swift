import SwiftUI
import AppKit
@testable import OvercrossCore

struct DownloadManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @State private var gameToDelete: Game?
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()

            // Main Content Area
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Active Downloads Section
                    if !activeOrPausedDownloads.isEmpty {
                        activeDownloadsSection
                    }

                    // Resumable Downloads on Disk (not in active map)
                    let externalResumables = unmonitoredResumableGames
                    if !externalResumables.isEmpty {
                        resumableDiskSection(games: externalResumables)
                    }

                    // Empty state if nothing active or resumable
                    if activeOrPausedDownloads.isEmpty && externalResumables.isEmpty {
                        emptyActiveStateView
                    }

                    // Recent History Section
                    let history = appModel.downloadOperations.filter { $0.state != .running && $0.state != .paused }
                    if !history.isEmpty {
                        recentHistorySection(history: history)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Delete Download Data?", isPresented: $showDeleteConfirmation, presenting: gameToDelete) { game in
            Button("Cancel", role: .cancel) {
                gameToDelete = nil
            }
            Button("Delete Files & Reset", role: .destructive) {
                appModel.deletePartialDownload(gameID: game.id)
                gameToDelete = nil
            }
        } message: { game in
            Text("Are you sure you want to delete the partial download files for \"\(game.title)\"? This will permanently free up disk space on your drive and reset the download.")
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                Text("Download Manager")
                    .font(.headline)

                if appModel.hasActiveDownloads {
                    Text("\(appModel.activeDownloadsCount) active download\(appModel.activeDownloadsCount == 1 ? "" : "s")" + (appModel.totalDownloadSpeedFormatted.map { " • \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No active transfers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !appModel.downloadOperations.filter({ $0.state != .running && $0.state != .paused }).isEmpty {
                Button("Clear History") {
                    appModel.clearDownloadHistory()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var activeOrPausedDownloads: [DownloadItem] {
        Array(appModel.activeDownloads.values).sorted { $0.gameTitle < $1.gameTitle }
    }

    private var unmonitoredResumableGames: [Game] {
        appModel.resumableGames.filter { game in
            !appModel.activeDownloads.keys.contains(game.id)
        }
    }

    private var activeDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Active Transfers")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            ForEach(activeOrPausedDownloads) { item in
                activeDownloadCard(item: item)
            }
        }
    }

    private func activeDownloadCard(item: DownloadItem) -> some View {
        HStack(spacing: 16) {
            // Artwork Thumbnail
            if let artwork = item.artworkURL {
                AsyncImage(url: artwork) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        fallbackArtwork
                    }
                }
                .frame(width: 56, height: 74)
                .cornerRadius(8)
                .clipped()
            } else {
                fallbackArtwork
                    .frame(width: 56, height: 74)
                    .cornerRadius(8)
            }

            // Info & Progress
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.gameTitle)
                        .font(.headline)
                        .lineLimit(1)

                    Label(item.store.displayName, systemImage: item.store == .steam ? "s.circle.fill" : "e.circle.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.store == .steam ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                        .foregroundStyle(item.store == .steam ? Color.blue : Color.purple)
                        .cornerRadius(4)

                    Spacer()

                    // State Tag
                    if item.isPaused {
                        Text("PAUSED")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .cornerRadius(5)
                    } else {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 8, height: 8)
                            Text("DOWNLOADING")
                                .font(.caption2.bold())
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.2))
                        .foregroundStyle(.purple)
                        .cornerRadius(5)
                    }
                }

                // Progress Bar
                ProgressView(value: item.fraction, total: 1.0)
                    .tint(item.isPaused ? .orange : .purple)

                // Transfer Stats & Detail
                HStack {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(item.fraction * 100))%")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(item.isPaused ? .orange : .purple)
                }
            }

            Divider()
                .frame(height: 50)

            // Action Buttons
            HStack(spacing: 8) {
                if item.isPaused {
                    Button {
                        appModel.resumeAutonomousDownload(gameID: item.id)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                } else {
                    Button {
                        appModel.pauseAutonomousDownload(gameID: item.id)
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Delete / Cancel Button
                Button {
                    if let game = appModel.games.first(where: { $0.id == item.id }) {
                        gameToDelete = game
                        showDeleteConfirmation = true
                    } else {
                        appModel.cancelAutonomousDownload(gameID: item.id, deleteFiles: false)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Cancel and delete partial download")
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(item.isPaused ? Color.orange.opacity(0.3) : Color.purple.opacity(0.2), lineWidth: 1)
        )
    }

    private func resumableDiskSection(games: [Game]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Saved On Disk (Ready to Resume)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ForEach(games) { game in
                HStack(spacing: 16) {
                    if let artwork = game.artworkURL {
                        AsyncImage(url: artwork) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                fallbackArtwork
                            }
                        }
                        .frame(width: 48, height: 64)
                        .cornerRadius(6)
                        .clipped()
                    } else {
                        fallbackArtwork
                            .frame(width: 48, height: 64)
                            .cornerRadius(6)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.title)
                            .font(.headline)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Image(systemName: "pause.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Download interrupted or paused. Verified chunks are preserved on disk.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        appModel.downloadGameAutonomous(gameID: game.id)
                    } label: {
                        Label("Resume Download", systemImage: "arrow.clockwise.circle.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)

                    Button {
                        gameToDelete = game
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Delete partial files to free disk space")
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .cornerRadius(10)
            }
        }
    }

    private var emptyActiveStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("No Active Downloads")
                .font(.headline)
            Text("When you download games from Epic Games or Steam, real-time speeds, ETA, and progress will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private func recentHistorySection(history: [DownloadOperation]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Operations")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            ForEach(history.prefix(15)) { op in
                HStack(spacing: 12) {
                    Image(systemName: historyIcon(for: op.state))
                        .font(.headline)
                        .foregroundStyle(historyColor(for: op.state))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(op.gameTitle)
                            .font(.subheadline.bold())
                        Text(op.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(op.state.displayName)
                            .font(.caption2.bold())
                            .foregroundStyle(historyColor(for: op.state))
                        Text(op.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                .cornerRadius(8)
            }
        }
    }

    private var fallbackArtwork: some View {
        ZStack {
            Color.purple.opacity(0.15)
            Image(systemName: "gamecontroller.fill")
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }

    private func historyIcon(for state: DownloadOperationState) -> String {
        switch state {
        case .running: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .recoveryRequired: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private func historyColor(for state: DownloadOperationState) -> Color {
        switch state {
        case .running: .purple
        case .paused: .orange
        case .completed: .green
        case .cancelled: .secondary
        case .failed, .recoveryRequired: .red
        }
    }
}
