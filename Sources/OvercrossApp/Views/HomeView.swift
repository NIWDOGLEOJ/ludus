import SwiftUI
@testable import OvercrossCore

struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel

    private var needsDownloadRecovery: Bool {
        appModel.downloadOperations.contains {
            $0.state == .recoveryRequired || $0.state == .failed || $0.state == .cancelled
        }
    }

    private var recentlyPlayed: [Game] {
        appModel.games
            .filter { $0.lastLaunchAt != nil && !$0.isHidden }
            .sorted { ($0.lastLaunchAt ?? .distantPast) > ($1.lastLaunchAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    private var recentlyAdded: [Game] {
        appModel.games
            .filter { !$0.isHidden }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(5)
            .map { $0 }
    }

    private var installedGames: [Game] {
        appModel.games
            .filter { !$0.isHidden && $0.installationURL != nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .prefix(5)
            .map { $0 }
    }

    private var compatibilityAlerts: [Game] {
        appModel.games
            .filter {
                !$0.isHidden &&
                ($0.compatibilityStatus == .knownIssues ||
                 $0.compatibilityStatus == .unsupported ||
                 $0.compatibilityStatus == .partiallyWorking)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                statusCards
                librarySections
                quickStart
            }
            .padding(32)
        }
        .navigationTitle("Home")
        .onAppear {
            appModel.refreshInstallationState()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Good to see you.")
                .font(.largeTitle.weight(.bold))
            Text("A focused home for the games you legitimately own and can actually run.")
                .foregroundStyle(.secondary)
        }
    }

    private var statusCards: some View {
        HStack(spacing: 16) {
            MetricCard(title: "Games", value: "\(appModel.games.count)", detail: "Imported library entries", icon: "square.grid.2x2")
            MetricCard(
                title: "Downloads",
                value: appModel.isInstallingGame || appModel.isInstallingRuntime
                    ? "Active"
                    : needsDownloadRecovery ? "Recovery" : "None",
                detail: appModel.isInstallingGame
                    ? "Heroic installation in progress"
                    : appModel.isInstallingRuntime
                        ? "Runtime bundle verification in progress"
                        : needsDownloadRecovery
                            ? "A previous Heroic operation needs review"
                            : "No download service is active",
                icon: "arrow.down.circle"
            )
            MetricCard(title: "Installed storage", value: storageValue, detail: "Measured from imported game paths", icon: "internaldrive")
            MetricCard(title: "Runtime", value: runtimeValue, detail: "Run diagnostics for host status", icon: "checkmark.shield")
            MetricCard(
                title: "Controller",
                value: appModel.hasConnectedGamepad ? "Connected" : "None",
                detail: appModel.gamepadStatusSummary,
                icon: "gamecontroller.fill"
            )
        }
    }

    @ViewBuilder
    private var librarySections: some View {
        if appModel.games.isEmpty {
            EmptyStateCard(
                icon: "gamecontroller.fill",
                title: "Your library is ready to connect",
                message: "Add a locally installed executable or connect a supported store integration to import real ownership data. Ludus intentionally does not show placeholder games."
            )
        } else {
            VStack(alignment: .leading, spacing: 18) {
                GameStrip(title: "Recently played", games: recentlyPlayed, emptyMessage: "No launch has been recorded yet.")
                GameStrip(title: "Installed games", games: installedGames, emptyMessage: "No installed game paths have been verified yet.")
                GameStrip(title: "Recently added", games: recentlyAdded, emptyMessage: "No visible games have been added.")
                compatibilityAlertSection
                runtimeHealthSection
            }
        }
    }

    private var compatibilityAlertSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Compatibility alerts")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !compatibilityAlerts.isEmpty {
                    Button("Review") {
                        appModel.selectedSection = .compatibility
                    }
                    .buttonStyle(.bordered)
                }
            }
            if compatibilityAlerts.isEmpty {
                Text("No known-issue, unsupported, or partially working statuses are recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(compatibilityAlerts) { game in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(game.title)
                            .font(.headline)
                        Spacer()
                        Text(game.compatibilityStatus.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var runtimeHealthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Runtime health")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Run diagnostics") {
                    appModel.selectedSection = .diagnostics
                    appModel.runDiagnostics()
                }
                .buttonStyle(.bordered)
            }
            Text(runtimeHealthDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start here")
                .font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                ActionTile(title: "Run diagnostics", subtitle: "Check Apple Silicon and runtimes", icon: "stethoscope") {
                    appModel.selectedSection = .diagnostics
                    appModel.runDiagnostics()
                }
                ActionTile(title: "Review compatibility", subtitle: "Understand support boundaries", icon: "checkmark.shield") {
                    appModel.selectedSection = .compatibility
                }
            }
        }
    }

    private var storageValue: String {
        guard let bytes = appModel.installedStorageBytes else { return "Not measured" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var runtimeValue: String {
        if appModel.runtimeReport.findings.isEmpty { return "Not checked" }
        return appModel.runtimeReport.hasErrors ? "Attention" : "Checked"
    }

    private var runtimeHealthDetail: String {
        if appModel.runtimeReport.findings.isEmpty {
            return "Runtime health has not been checked yet."
        }
        if appModel.runtimeReport.runtimes.isEmpty {
            return "No compatible Wine runtime was detected. Add or inspect a user-installed runtime before testing Windows games."
        }
        let count = appModel.runtimeReport.runtimes.count
        return "\(count) compatible runtime\(count == 1 ? "" : "s") detected. Review Runtime Manager for versions, architectures, wineboot availability, and health findings."
    }
}

private struct GameStrip: View {
    let title: String
    let games: [Game]
    let emptyMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.weight(.semibold))
            if games.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(games) { game in
                    HStack(spacing: 12) {
                        Image(systemName: "gamecontroller.fill")
                            .foregroundStyle(.purple)
                            .frame(width: 24)
                        Text(game.title).font(.headline)
                        Spacer()
                        Text(game.store.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}
