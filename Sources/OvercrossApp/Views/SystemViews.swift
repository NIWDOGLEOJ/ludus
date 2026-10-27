import SwiftUI
@testable import OvercrossCore

struct RuntimeManagerView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var newPrefixName = ""
    @State private var selectedRuntimeID: UUID?
    @State private var selectedArchitecture: PrefixArchitecture = .win64
    @State private var pendingRemovalID: UUID?
    @State private var pendingRemovalName = ""
    @State private var showRuntimeBundleImport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    SectionHeader(title: "Runtime Manager", subtitle: "Runtime and prefix changes require a detected executable and explicit user action.")
                    Spacer()
                    Button {
                        appModel.runDiagnostics()
                    } label: {
                        Label("Refresh runtimes", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.isRunningDiagnostics)
                    Button {
                        appModel.importRuntime()
                    } label: {
                        Label("Inspect existing runtime", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        showRuntimeBundleImport = true
                    } label: {
                        Label("Install verified bundle", systemImage: "shippingbox.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.isInstallingRuntime)
                }

                runtimeSection
                prefixSection
                Spacer()
            }
            .padding(32)
        }
        .navigationTitle("Runtime Manager")
        .sheet(isPresented: $showRuntimeBundleImport) {
            RuntimeBundleImportView()
                .environmentObject(appModel)
        }
        .confirmationDialog(
            "Remove \(pendingRemovalName)?",
            isPresented: Binding(
                get: { pendingRemovalID != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRemovalID = nil
                        pendingRemovalName = ""
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Prefix", role: .destructive) {
                if let pendingRemovalID {
                    appModel.removePrefix(prefixID: pendingRemovalID)
                }
                self.pendingRemovalID = nil
                self.pendingRemovalName = ""
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes only the managed prefix directory. Game files outside the prefix will not be deleted. Create a backup first if you may need this environment later.")
        }
        .onAppear {
            if selectedRuntimeID == nil {
                selectedRuntimeID = appModel.runtimeReport.runtimes.first?.id
            }
        }
        .onChange(of: appModel.runtimeReport.runtimes) { _, runtimes in
            if selectedRuntimeID == nil || !runtimes.contains(where: { $0.id == selectedRuntimeID }) {
                selectedRuntimeID = runtimes.first?.id
            }
        }
    }

    @ViewBuilder
    private var runtimeSection: some View {
        if appModel.runtimeReport.runtimes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                EmptyStateCard(icon: "shippingbox.fill", title: "No detected runtimes", message: "A Wine compatibility runtime is required to play Windows games on macOS.")
                Button {
                    appModel.autoInstallWine()
                } label: {
                    Label("Auto-Install Wine Runtime", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.isPerformingFix)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Detected runtimes").font(.title2.weight(.semibold))
                ForEach(appModel.runtimeReport.runtimes) { runtime in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(runtime.name).font(.headline)
                            Spacer()
                            Button {
                                appModel.runRuntimeHealthCheck(runtimeID: runtime.id)
                            } label: {
                                Label("Health check", systemImage: "stethoscope")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Text("\(runtime.version) · \(runtime.architecture) · \(runtime.status)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(runtime.executableURL.path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let winebootURL = runtime.winebootURL {
                            Text("wineboot: \(winebootURL.path)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let findings = appModel.runtimeHealth[runtime.id], !findings.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(findings) { finding in
                                    RuntimeHealthFindingView(finding: finding)
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    @ViewBuilder
    private var prefixSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Prefixes").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    appModel.restorePrefix()
                } label: {
                    Label("Restore backup", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.bordered)
                .disabled(appModel.isBackingUpPrefix || appModel.isRestoringPrefix || appModel.isRemovingPrefix)
            }
            if appModel.runtimeReport.runtimes.contains(where: { $0.winebootURL != nil }) {
                Picker("Runtime", selection: $selectedRuntimeID) {
                    Text("Select runtime").tag(UUID?.none)
                    ForEach(appModel.runtimeReport.runtimes.filter { $0.winebootURL != nil }) { runtime in
                        Text(runtime.name).tag(UUID?.some(runtime.id))
                    }
                }
                TextField("New prefix name", text: $newPrefixName)
                    .textFieldStyle(.roundedBorder)
                Picker("Architecture", selection: $selectedArchitecture) {
                    ForEach(PrefixArchitecture.allCases) { architecture in
                        Text(architecture.displayName).tag(architecture)
                    }
                }
                Button {
                    guard let selectedRuntimeID else { return }
                    appModel.createPrefix(name: newPrefixName, runtimeID: selectedRuntimeID, architecture: selectedArchitecture)
                    newPrefixName = ""
                } label: {
                    Label("Create and verify prefix", systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPrefixName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedRuntimeID == nil || appModel.isCreatingPrefix || appModel.isBackingUpPrefix || appModel.isRestoringPrefix || appModel.isRemovingPrefix)
            } else {
                Text("Prefix creation is unavailable until diagnostics finds a runtime with a matching wineboot executable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if appModel.isCreatingPrefix {
                ProgressView("Initializing prefix…")
            }
            if appModel.isBackingUpPrefix {
                ProgressView("Backing up prefix…")
            }
            if appModel.isRestoringPrefix {
                ProgressView("Restoring prefix…")
            }
            if appModel.isRemovingPrefix {
                ProgressView("Removing prefix…")
            }
            if let message = appModel.lastPrefixMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let message = appModel.runtimeInstallMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(appModel.prefixes) { prefix in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(prefix.name).font(.headline)
                        Spacer()
                        Button {
                            appModel.backupPrefixQuick(prefixID: prefix.id)
                        } label: {
                            Label("Quick Zip Backup", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appModel.isBackingUpPrefix || appModel.isRestoringPrefix || appModel.isRemovingPrefix)

                        Button {
                            appModel.preflightPrefixRedistributables(prefixID: prefix.id)
                        } label: {
                            Label("Verify Components", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appModel.isBackingUpPrefix || appModel.isRestoringPrefix || appModel.isRemovingPrefix)

                        Button {
                            appModel.backupPrefix(prefixID: prefix.id)
                        } label: {
                            Label("Back up to...", systemImage: "archivebox")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appModel.isBackingUpPrefix || appModel.isRestoringPrefix || appModel.isRemovingPrefix)

                        Button(role: .destructive) {
                            pendingRemovalID = prefix.id
                            pendingRemovalName = prefix.name
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appModel.isBackingUpPrefix || appModel.isRestoringPrefix || appModel.isRemovingPrefix)
                    }
                    Text("\(prefix.architecture.displayName) · \(prefix.status)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(prefix.url.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    PrefixComponentStatusView(prefixID: prefix.id)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct RuntimeBundleImportView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL: URL?
    @State private var runtimeName = "Verified runtime"
    @State private var executableRelativePath = "bin/wine"
    @State private var expectedSHA256 = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install verified runtime bundle")
                .font(.title2.weight(.semibold))
            Text("Ludus does not download or redistribute runtime binaries. Choose a self-contained bundle you obtained from a trusted source and enter that source's published SHA-256 for the runtime executable.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Text(sourceURL?.path ?? "No bundle selected")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Button("Choose folder") {
                    sourceURL = appModel.chooseRuntimeBundleDirectory()
                }
            }
            TextField("Runtime name", text: $runtimeName)
                .textFieldStyle(.roundedBorder)
            TextField("Executable path inside bundle", text: $executableRelativePath)
                .textFieldStyle(.roundedBorder)
            TextField("Published SHA-256", text: $expectedSHA256)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            if appModel.isInstallingRuntime {
                ProgressView("Verifying runtime bundle…")
            }
            if let message = appModel.runtimeInstallMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Install and verify") {
                    guard let sourceURL else { return }
                    appModel.installRuntimeBundle(
                        sourceRootURL: sourceURL,
                        name: runtimeName,
                        executableRelativePath: executableRelativePath,
                        expectedSHA256: expectedSHA256
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    sourceURL == nil ||
                    runtimeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    executableRelativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    appModel.isInstallingRuntime
                )
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

private struct RuntimeHealthFindingView: View {
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title)
                    .font(.caption.weight(.semibold))
                Text(finding.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Downloads", subtitle: "Only actual store or runtime operations will be represented here.")
            if appModel.isInstallingRuntime {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Verified runtime bundle", systemImage: "shippingbox.and.arrow.down.fill")
                        .font(.title2.weight(.semibold))
                    ProgressView()
                    Text(appModel.runtimeInstallMessage ?? "Verifying and copying the selected runtime bundle…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(18)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            } else if appModel.isInstallingGame,
                      let operation = appModel.downloadOperations.first(where: { $0.state == .running }) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(operation.gameTitle, systemImage: "arrow.down.circle.fill")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Button("Cancel", role: .cancel) {
                            appModel.cancelHeroicInstall()
                        }
                        .buttonStyle(.bordered)
                    }
                    if let fraction = operation.fraction {
                        ProgressView(value: fraction)
                        Text("\(Int(fraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    Text(operation.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(18)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            } else if appModel.downloadOperations.filter({ $0.state != .running }).isEmpty {
                EmptyStateCard(icon: "tray.full.fill", title: "No active downloads", message: "Progress indicators will be driven by real installation operations, not timers or placeholder values.")
            }

            let history = appModel.downloadOperations.filter { $0.state != .running }
            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent operations")
                        .font(.headline)
                    ForEach(history.prefix(20)) { operation in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Label(operation.gameTitle, systemImage: icon(for: operation.state))
                                    .font(.headline)
                                Spacer()
                                Text(operation.state.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: operation.state))
                            }
                            Text("\(operation.kind.displayName) · \(operation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(operation.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let error = operation.error, !error.isEmpty {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                            if operation.state == .failed || operation.state == .cancelled || operation.state == .recoveryRequired {
                                HStack {
                                    if operation.kind == .install {
                                        Button("Verify recorded installation") {
                                            appModel.verifyRecordedInstallation(for: operation)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    Button("Retry through Heroic") {
                                        appModel.retryDownloadOperation(operation)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(14)
                        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            Spacer()
        }
        .padding(32)
        .navigationTitle("Downloads")
    }

    private func icon(for state: DownloadOperationState) -> String {
        switch state {
        case .running: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .recoveryRequired: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private func color(for state: DownloadOperationState) -> Color {
        switch state {
        case .running: .accentColor
        case .paused: .orange
        case .completed: .green
        case .cancelled: .secondary
        case .failed, .recoveryRequired: .red
        }
    }
}

struct PerformanceView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var snapshot: PerformanceSnapshot?
    private let snapshotService = PerformanceSnapshotService()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Performance", subtitle: "Monitoring is opt-in and remains disabled by default.")
            Toggle("Enable lightweight performance monitoring", isOn: $appModel.settings.performanceMonitoringEnabled)
                .toggleStyle(.switch)
            if appModel.settings.performanceMonitoringEnabled {
                if let snapshot {
                    HStack(spacing: 16) {
                        MetricCard(
                            title: "Ludus memory",
                            value: memoryValue(snapshot.processResidentMemoryBytes),
                            detail: "Current resident memory",
                            icon: "memorychip"
                        )
                        MetricCard(
                            title: "Physical memory",
                            value: memoryValue(snapshot.physicalMemoryBytes),
                            detail: "Host capacity",
                            icon: "desktopcomputer"
                        )
                        MetricCard(
                            title: "System uptime",
                            value: uptimeValue(snapshot.systemUptime),
                            detail: "Reported by macOS",
                            icon: "clock"
                        )
                    }
                    Text("Last sampled \(snapshot.capturedAt.formatted(date: .omitted, time: .standard)). These are observations, not a game-performance benchmark.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Collecting local metrics…")
                }
            } else {
                EmptyStateCard(
                    icon: "waveform.path.ecg",
                    title: "Monitoring is disabled",
                    message: "Enable it to sample Ludus memory, host memory capacity, and system uptime while this page is open."
                )
            }
            Spacer()
        }
        .padding(32)
        .navigationTitle("Performance")
        .task(id: appModel.settings.performanceMonitoringEnabled) {
            snapshot = nil
            guard appModel.settings.performanceMonitoringEnabled else { return }
            while !Task.isCancelled {
                let service = snapshotService
                let nextSnapshot = await Task.detached(priority: .utility) {
                    service.collect()
                }.value
                guard !Task.isCancelled else { return }
                snapshot = nextSnapshot
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func memoryValue(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func uptimeValue(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "Unavailable"
    }
}

struct PrefixComponentStatusView: View {
    @EnvironmentObject private var appModel: AppModel
    let prefixID: UUID
    @State private var components: [PrefixComponentInfo] = []
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                let installedCount = components.filter(\.isInstalled).count
                Text("Runtime components: \(installedCount)/\(components.count) verified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isExpanded ? "Hide" : "Inspect") {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.purple)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(components) { comp in
                        HStack(spacing: 6) {
                            Image(systemName: comp.isInstalled ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(comp.isInstalled ? .green : .orange)
                            Text(comp.name)
                                .font(.caption2)
                            Spacer()
                            Text(comp.category)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onAppear {
            components = appModel.inspectPrefixComponents(prefixID: prefixID)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showCacheClearConfirmation = false

    var body: some View {
        Form {
            Section("Software Updates") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ludus Version \(appModel.updateService.currentVersion)")
                            .font(.headline)
                        if let message = appModel.updateCheckMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Checks GitHub for new releases and updates automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if appModel.isCheckingForUpdates {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if appModel.availableUpdate != nil {
                        Button("Update Now") {
                            appModel.downloadAndInstallUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    } else {
                        Button("Check for Updates") {
                            appModel.checkForUpdates(manual: true)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Section("General") {
                Toggle("Enable lightweight performance monitoring", isOn: $appModel.settings.performanceMonitoringEnabled)
                Toggle(
                    "Launch Ludus at login",
                    isOn: Binding(
                        get: { appModel.settings.launchAtLogin },
                        set: { appModel.setLaunchAtLogin($0) }
                    )
                )
                Toggle(
                    "Notify me about store operations",
                    isOn: Binding(
                        get: { appModel.settings.notificationsEnabled },
                        set: { appModel.setNotificationsEnabled($0) }
                    )
                )
                if let error = appModel.diagnosticError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Apple Silicon & Gaming Controls") {
                Toggle("Enable Metal Performance HUD (MTL_HUD_ENABLED=1)", isOn: $appModel.settings.metalHUDEnabled)
                Text("Displays Apple's native real-time HUD with FPS, frame pacing, GPU utilization, and resolution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Enable MSync (WINEMSYNC=1)", isOn: $appModel.settings.msyncEnabled)
                Text("Fast Mach-port synchronization optimal for Apple Silicon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Enable ESync (WINEESYNC=1)", isOn: $appModel.settings.esyncEnabled)
                Text("Eventfd synchronization fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Default DirectX backend", selection: $appModel.settings.defaultGraphicsBackend) {
                    Text("Automatic").tag(GraphicsBackend.automatic)
                    Text("D3DMetal (Apple Game Porting Toolkit)").tag(GraphicsBackend.d3dmetal)
                    Text("DXVK (Vulkan)").tag(GraphicsBackend.dxvk)
                    Text("DXMT (Direct3D to Metal)").tag(GraphicsBackend.dxmt)
                }

                Toggle("Enable Retina / High-DPI Scaling (WINE_ENABLE_RETINA=1)", isOn: $appModel.settings.retinaScalingEnabled)
                Text("Enables high-resolution rendering on built-in Retina and 4K/5K displays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Game Controller") {
                HStack {
                    Label(
                        appModel.hasConnectedGamepad ? "Game Controller Connected" : "No Game Controller Detected",
                        systemImage: "gamecontroller.fill"
                    )
                    .foregroundStyle(appModel.hasConnectedGamepad ? .green : .secondary)
                    Spacer()
                    Text(appModel.gamepadStatusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Install locations") {
                Text(appModel.settings.preferredInstallDirectory?.path ?? "Not configured")
                    .foregroundStyle(.secondary)
                if let freeBytes = appModel.preferredInstallFreeBytes {
                    Text("Available: \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }
                Button("Choose install location") {
                    appModel.chooseInstallDirectory()
                }
            }
            Section("Epic installation safety") {
                Toggle(
                    "Allow Legendary to run prerequisite installers",
                    isOn: $appModel.settings.heroicInstallPrerequisites
                )
                Text("Disabled by default. Enable this only when you explicitly want Legendary to run the prerequisites supplied by the game installer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Storage cleanup") {
                HStack {
                    Text("Ludus application cache")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: appModel.applicationCacheBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                Button("Clear application cache", role: .destructive) {
                    showCacheClearConfirmation = true
                }
                .disabled(appModel.applicationCacheBytes == 0)
                Text("Only files inside Ludus's own cache directory are removed. Game installations, prefixes, runtimes, logs, and settings are not touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 540, minHeight: 480, idealHeight: 560)
        .padding()
        .confirmationDialog(
            "Clear Ludus application cache?",
            isPresented: $showCacheClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                appModel.clearApplicationCache()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes only files owned by Ludus in its application cache. Your games and compatibility environments will remain unchanged.")
        }
    }
}
