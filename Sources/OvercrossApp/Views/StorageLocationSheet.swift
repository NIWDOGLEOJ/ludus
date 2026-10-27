import SwiftUI
import AppKit
@testable import OvercrossCore

struct StorageLocationSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Game Storage Location")
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

            VStack(alignment: .leading, spacing: 12) {
                Text("Windows games from Steam and Epic are downloaded into this folder. You can store games on your Mac's internal drive or an external SSD.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.purple)
                    Text(currentLocationPath)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                if let free = appModel.preferredInstallFreeBytes {
                    Text("Free Space: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Select External SSD or Folder...") {
                        selectFolder()
                    }
                    Spacer()
                    Button("Reset to Default") {
                        let defaultURL = LudusStorage.defaultGamesURL()
                        appModel.setInstallDirectory(defaultURL)
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480, height: 280)
    }

    private var currentLocationPath: String {
        appModel.settings.preferredInstallDirectory?.path ??
        LudusStorage.defaultGamesURL().path
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Storage Location"

        if panel.runModal() == .OK, let selectedURL = panel.url {
            appModel.setInstallDirectory(selectedURL)
        }
    }
}
