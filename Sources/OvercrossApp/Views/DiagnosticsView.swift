import SwiftUI
@testable import OvercrossCore

struct DiagnosticsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showClearLogsConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    SectionHeader(title: "Logs & Diagnostics", subtitle: "Read-only host checks for the initial foundation. No logs or system information leave this Mac.")
                    Spacer()
                    if appModel.runtimeReport.findings.contains(where: { $0.fixActionKind != nil }) {
                        Button {
                            appModel.autoFixAll()
                        } label: {
                            Label("Fix All Issues", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(appModel.isPerformingFix || appModel.isRunningDiagnostics)
                    }
                    Button(role: .destructive) {
                        appModel.forceStopAndResetBottle()
                    } label: {
                        Label(appModel.isResettingBottle ? "Resetting…" : "Force Stop & Reset", systemImage: "arrow.counterclockwise.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(appModel.isResettingBottle)

                    Button {
                        appModel.runDiagnostics()
                    } label: {
                        Label("Run diagnostics", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.isRunningDiagnostics || appModel.isPerformingFix)
                }

                if appModel.isPerformingFix {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text(appModel.fixStatusMessage ?? "Applying automatic fix…")
                            .font(.callout)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                } else if let message = appModel.fixStatusMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(message)
                            .font(.callout)
                        Spacer()
                        Button("Dismiss") {
                            appModel.fixStatusMessage = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }

                if let resetMsg = appModel.resetBottleMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text(resetMsg)
                            .font(.callout)
                        Spacer()
                        Button("Dismiss") {
                            appModel.resetBottleMessage = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(12)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }

                summary

                if appModel.isRunningDiagnostics {
                    ProgressView("Checking host and available runtimes…")
                } else if appModel.runtimeReport.findings.isEmpty {
                    EmptyStateCard(icon: "stethoscope", title: "Diagnostics have not run", message: "Run the check to inspect Apple Silicon, developer tools, and selected existing runtime locations.")
                } else {
                    findings
                }

                if !appModel.launchLogs.isEmpty {
                    launchHistory
                }
            }
            .padding(32)
        }
        .navigationTitle("Logs & Diagnostics")
        .confirmationDialog(
            "Clear launch history?",
            isPresented: $showClearLogsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                appModel.clearLaunchLogs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Ludus's saved launch records. It does not remove games or files.")
        }
    }

    private var summary: some View {
        HStack(spacing: 16) {
            MetricCard(title: "Architecture", value: appModel.runtimeReport.hostArchitecture, detail: "Reported by uname", icon: "cpu")
            MetricCard(title: "macOS", value: appModel.runtimeReport.macOSVersion, detail: "Reported by sw_vers", icon: "desktopcomputer")
            MetricCard(title: "Runtimes", value: "\(appModel.runtimeReport.runtimes.count)", detail: "Detected on this Mac", icon: "shippingbox")
        }
    }

    private var findings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Findings")
                .font(.title2.weight(.semibold))
            ForEach(appModel.runtimeReport.findings) { finding in
                DiagnosticFindingRow(finding: finding)
            }
            if appModel.runtimeReport.generatedAt != .distantPast {
                Text("Generated \(appModel.runtimeReport.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private var launchHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent launch history")
                .font(.title2.weight(.semibold))
            HStack {
                Button {
                    appModel.exportLaunchLogs()
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showClearLogsConfirmation = true
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            ForEach(Array(appModel.launchLogs.prefix(10))) { log in
                let gameTitle = appModel.games.first(where: { $0.id == log.gameID })?.title ?? "Unknown game"
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(gameTitle).font(.headline)
                        Spacer()
                        Text(log.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(log.summary)
                        .font(.callout)
                    Text(log.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct DiagnosticFindingRow: View {
    @EnvironmentObject private var appModel: AppModel
    let finding: DiagnosticFinding

    private var color: Color {
        switch finding.severity {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    private var icon: String {
        switch finding.severity {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title).font(.headline)
                Text(finding.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle = finding.fixActionTitle {
                Button {
                    appModel.performFix(for: finding)
                } label: {
                    Label(actionTitle, systemImage: "wrench.and.screwdriver.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(appModel.isPerformingFix)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}
