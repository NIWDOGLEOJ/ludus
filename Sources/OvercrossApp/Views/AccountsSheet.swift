import SwiftUI
import AppKit
@testable import OvercrossCore

struct AccountsSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var steamIDInput = ""
    @State private var steamAPIKeyInput = ""
    @State private var epicAuthCodeInput = ""
    @State private var statusMessage: String?
    @State private var isSyncing = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Connected Store Accounts")
                    .font(.title2.bold())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    // Epic Games Section
                    epicSection

                    Divider()

                    // Steam Section
                    steamSection
                }
                .padding()
            }

            if let statusMessage {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.purple)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(10)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(6)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            // Footer
            HStack {
                Button("Sync All Stores") {
                    Task {
                        isSyncing = true
                        statusMessage = "Syncing libraries with connected stores..."
                        let result = await appModel.syncAllStores()
                        isSyncing = false
                        statusMessage = result
                    }
                }
                .disabled(isSyncing)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 540, height: 620)
        .onAppear {
            appModel.refreshStoreAuth()
            if let steamID = appModel.steamService.steamID {
                steamIDInput = steamID
            }
            if let apiKey = appModel.steamService.apiKey {
                steamAPIKeyInput = apiKey
            }
        }
    }

    private var epicSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "e.circle.fill")
                    .font(.title)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading) {
                    Text("Epic Games Store")
                        .font(.headline)
                    Text("Direct Windows game downloading via embedded Legendary engine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case let .connected(name) = appModel.epicAuthStatus {
                    Label(name, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                }
            }

            if case .connected = appModel.epicAuthStatus {
                HStack {
                    Text("Connected and ready for in-app downloads.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync Library") {
                        Task {
                            isSyncing = true
                            statusMessage = "Syncing Epic Games library..."
                            let result = await appModel.syncAllStores()
                            isSyncing = false
                            statusMessage = result
                        }
                    }
                    Button("Disconnect") {
                        appModel.disconnectEpic()
                        statusMessage = "Epic Games account disconnected."
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. Click below to sign in with your Epic Games account in your browser:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        NSWorkspace.shared.open(appModel.epicService.oauthLoginURL())
                    } label: {
                        Label("Sign in with Epic Games in Browser", systemImage: "safari")
                            .font(.headline)
                    }

                    Text("2. Copy the authorization code (or the full redirect URL / JSON) from your browser and paste it here:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Paste authorization code, URL, or JSON", text: $epicAuthCodeInput)
                            .textFieldStyle(.roundedBorder)

                        Button("Connect") {
                            Task {
                                do {
                                    let name = try await appModel.epicService.submitAuthCode(epicAuthCodeInput)
                                    appModel.refreshStoreAuth()
                                    let syncResult = await appModel.syncAllStores()
                                    statusMessage = "Connected as \(name). \(syncResult)"
                                    epicAuthCodeInput = ""
                                } catch {
                                    statusMessage = "Epic authentication error: \(error.localizedDescription)"
                                }
                            }
                        }
                        .disabled(epicAuthCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
        }
    }

    private var steamSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "s.circle.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Steam")
                        .font(.headline)
                    Text("Direct Windows library discovery and depot downloading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case let .connected(steamID) = appModel.steamAuthStatus {
                    Label("ID: \(steamID)", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                }
            }

            if case let .connected(steamID) = appModel.steamAuthStatus {
                VStack(alignment: .leading, spacing: 10) {
                    if appModel.steamService.hasAPIKey {
                        HStack {
                            Label("Web API Key Configured", systemImage: "key.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Sync Library") {
                                Task {
                                    isSyncing = true
                                    statusMessage = "Syncing Steam library..."
                                    let res = await appModel.syncAllStores()
                                    isSyncing = false
                                    statusMessage = res
                                }
                            }
                            Button("Disconnect") {
                                try? appModel.steamService.disconnect()
                                appModel.refreshStoreAuth()
                                steamAPIKeyInput = ""
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                Text("Steam Web API Key is required to fetch games from Steam servers.")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.yellow)
                            }

                            Button {
                                NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/dev/apikey")!)
                            } label: {
                                Label("Get Free Steam Web API Key (steamcommunity.com/dev/apikey)", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }

                            HStack {
                                SecureField("Paste Steam Web API Key here", text: $steamAPIKeyInput)
                                    .textFieldStyle(.roundedBorder)

                                Button("Save Key & Sync") {
                                    do {
                                        try appModel.steamService.saveAccount(steamID: steamID, apiKey: steamAPIKeyInput)
                                        appModel.refreshStoreAuth()
                                        Task {
                                            isSyncing = true
                                            let res = await appModel.syncAllStores()
                                            isSyncing = false
                                            statusMessage = res
                                        }
                                    } catch {
                                        statusMessage = "Error: \(error.localizedDescription)"
                                    }
                                }
                                .disabled(steamAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .buttonStyle(.borderedProminent)
                            }

                            HStack {
                                Spacer()
                                Button("Disconnect Steam") {
                                    try? appModel.steamService.disconnect()
                                    appModel.refreshStoreAuth()
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(Color.yellow.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Enter your 64-bit SteamID (found on your profile link or steamid.io):")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("SteamID64 (e.g. 76561198000000000)", text: $steamIDInput)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("2. Enter your Steam Web API Key:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Get Free API Key") {
                            NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/dev/apikey")!)
                        }
                        .font(.caption)
                    }

                    SecureField("Steam Web API Key (required to query games)", text: $steamAPIKeyInput)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Spacer()
                        Button("Connect Steam") {
                            do {
                                try appModel.steamService.saveAccount(steamID: steamIDInput, apiKey: steamAPIKeyInput)
                                appModel.refreshStoreAuth()
                                Task {
                                    isSyncing = true
                                    let res = await appModel.syncAllStores()
                                    isSyncing = false
                                    statusMessage = res
                                }
                            } catch {
                                statusMessage = "Steam connection error: \(error.localizedDescription)"
                            }
                        }
                        .disabled(steamIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
        }
    }
}
