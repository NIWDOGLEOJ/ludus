import SwiftUI
@testable import OvercrossCore

struct DiagnosticsConsentSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSamplePreview = false

    var body: some View {
        VStack(spacing: 24) {
            // Header with Gradient Icon
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.purple, Color.indigo, Color.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)
                    
                    Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text("Help Improve Ludus")
                    .font(.title2.weight(.bold))

                Text("Anonymous Diagnostics & Bug Reporting")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Explanatory Cards
            VStack(alignment: .leading, spacing: 14) {
                benefitRow(
                    icon: "lock.shield.fill",
                    color: .green,
                    title: "100% Anonymous & Private",
                    subtitle: "No usernames, emails, passwords, game keys, or personal files are ever collected. Personal paths are stripped before sending."
                )

                benefitRow(
                    icon: "bolt.badge.automatic.fill",
                    color: .purple,
                    title: "Automatic Failure Reports",
                    subtitle: "When a game fails to start or an unexpected error occurs, sanitized logs and error codes are sent so the developer can fix bugs quickly."
                )

                benefitRow(
                    icon: "slider.horizontal.3",
                    color: .blue,
                    title: "You are Always in Control",
                    subtitle: "You can change your preference, inspect last sent reports, or reset your anonymous ID at any time in Settings."
                )
            }
            .padding(16)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            // View sample link
            Button {
                showSamplePreview = true
            } label: {
                Label("View Sample Diagnostic Report", systemImage: "doc.text.magnifyingglass")
                    .font(.footnote)
            }
            .buttonStyle(.link)

            // Action Buttons
            HStack(spacing: 14) {
                Button("Don't Share") {
                    appModel.setDiagnosticsConsent(optIn: false)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

                Button("Share Anonymous Reports") {
                    appModel.setDiagnosticsConsent(optIn: true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
        .sheet(isPresented: $showSamplePreview) {
            DiagnosticReportPreviewSheet(
                payload: appModel.sampleOrLastDiagnosticPayload()
            )
        }
    }

    private func benefitRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DiagnosticReportPreviewSheet: View {
    let payload: AnonymousDiagnosticPayload
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostic Report Preview")
                        .font(.headline)
                    Text("This is the exact sanitized JSON payload sent to the developer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jsonString, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy JSON", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ScrollView {
                Text(jsonString)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
        .padding(20)
        .frame(width: 580, height: 460)
    }

    private var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(payload),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
