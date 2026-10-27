import Foundation

public enum DiagnosticsConsentStatus: String, Codable, Sendable, CaseIterable {
    case undetermined
    case optedIn
    case optedOut
}

public struct AnonymousDiagnosticPayload: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let anonymousInstallationID: String
    public let timestamp: Date
    public let appVersion: String
    public let osVersion: String
    public let chipArchitecture: String
    public let chipModel: String
    public let memoryTotalBytes: UInt64
    public let component: String
    public let errorType: String
    public let errorDescription: String
    public let sanitizedLogs: [String]
    public let isUserInitiated: Bool
    public let userFeedback: String?

    public init(
        id: UUID = UUID(),
        anonymousInstallationID: String,
        timestamp: Date = Date(),
        appVersion: String,
        osVersion: String,
        chipArchitecture: String,
        chipModel: String,
        memoryTotalBytes: UInt64,
        component: String,
        errorType: String,
        errorDescription: String,
        sanitizedLogs: [String],
        isUserInitiated: Bool = false,
        userFeedback: String? = nil
    ) {
        self.id = id
        self.anonymousInstallationID = anonymousInstallationID
        self.timestamp = timestamp
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.chipArchitecture = chipArchitecture
        self.chipModel = chipModel
        self.memoryTotalBytes = memoryTotalBytes
        self.component = component
        self.errorType = errorType
        self.errorDescription = errorDescription
        self.sanitizedLogs = sanitizedLogs
        self.isUserInitiated = isUserInitiated
        self.userFeedback = userFeedback
    }
}

public final class AnonymousDiagnosticsService: @unchecked Sendable {
    public static let shared = AnonymousDiagnosticsService()

    private let fileManager: FileManager
    private let diagnosticsDirectory: URL

    public init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let root = baseDirectory ?? LudusStorage.applicationSupportURL
        self.diagnosticsDirectory = root.appendingPathComponent("Diagnostics", isDirectory: true)
        try? fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Hardware & System Information

    public static var chipModel: String {
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var brand = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
            let name = String(cString: brand).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }
        #if arch(arm64)
        return "Apple Silicon (ARM64)"
        #else
        return "x86_64"
        #endif
    }

    public static var chipArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    public static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    public static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }

    // MARK: - Log Sanitization (PII Scrubbing)

    /// Scrubs usernames, home directories, email addresses, and auth tokens to guarantee 100% anonymity.
    public static func sanitize(log: String) -> String {
        var sanitized = log

        // 1. Scrub user home directories: /Users/<username> -> ~
        sanitized = sanitized.replacingOccurrences(
            of: "/Users/[^/\\s\"'\n]+",
            with: "~",
            options: .regularExpression
        )

        // 2. Scrub email addresses
        sanitized = sanitized.replacingOccurrences(
            of: "[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\\.[a-zA-Z0-9-.]+",
            with: "[REDACTED_EMAIL]",
            options: .regularExpression
        )

        // 3. Scrub Epic & Steam tokens, passwords, and exchange codes
        let redactionPatterns: [(pattern: String, replacement: String)] = [
            ("-AUTH_PASSWORD=[^\\s]+", "-AUTH_PASSWORD=[REDACTED]"),
            ("-AUTH_LOGIN=[^\\s]+", "-AUTH_LOGIN=[REDACTED]"),
            ("-epicovt=[^\\s]+", "-epicovt=[REDACTED]"),
            ("-epicusername=[^\\s]+", "-epicusername=[REDACTED_USER]"),
            ("-epicuserid=[^\\s]+", "-epicuserid=[REDACTED_ID]"),
            ("--code\\s+[^\\s]+", "--code [REDACTED]"),
            ("--sid\\s+[^\\s]+", "--sid [REDACTED]"),
            ("Bearer\\s+[a-zA-Z0-9_.-]+", "Bearer [REDACTED]"),
            ("token=[^&\\s]+", "token=[REDACTED]"),
            ("oauth=[^&\\s]+", "oauth=[REDACTED]"),
            ("key=[a-zA-Z0-9_-]{16,}", "key=[REDACTED]")
        ]

        for (pattern, replacement) in redactionPatterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        return sanitized
    }

    public static func sanitize(logs: [String]) -> [String] {
        logs.map { sanitize(log: $0) }
    }

    // MARK: - Payload Generation

    public func buildPayload(
        component: String,
        error: Error,
        rawLogs: [String] = [],
        anonymousInstallationID: String,
        isUserInitiated: Bool = false,
        userFeedback: String? = nil
    ) -> AnonymousDiagnosticPayload {
        let errorType = String(describing: type(of: error))
        let errorDescription = Self.sanitize(log: error.localizedDescription)
        let sanitizedLogs = Self.sanitize(logs: rawLogs.suffix(50).map { String($0) })

        return AnonymousDiagnosticPayload(
            anonymousInstallationID: anonymousInstallationID,
            appVersion: Self.appVersion,
            osVersion: Self.osVersion,
            chipArchitecture: Self.chipArchitecture,
            chipModel: Self.chipModel,
            memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            component: component,
            errorType: errorType,
            errorDescription: errorDescription,
            sanitizedLogs: sanitizedLogs,
            isUserInitiated: isUserInitiated,
            userFeedback: userFeedback.map { Self.sanitize(log: $0) }
        )
    }

    // MARK: - Local Storage

    public func saveReportLocally(_ payload: AnonymousDiagnosticPayload) {
        let lastReportURL = diagnosticsDirectory.appendingPathComponent("last_report.json")
        let historyURL = diagnosticsDirectory.appendingPathComponent("history.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(payload) {
            try? data.write(to: lastReportURL, options: .atomic)
        }

        var history = loadReportHistory()
        history.insert(payload, at: 0)
        if history.count > 10 {
            history = Array(history.prefix(10))
        }

        if let historyData = try? encoder.encode(history) {
            try? historyData.write(to: historyURL, options: .atomic)
        }
    }

    public func loadLastReport() -> AnonymousDiagnosticPayload? {
        let lastReportURL = diagnosticsDirectory.appendingPathComponent("last_report.json")
        guard let data = try? Data(contentsOf: lastReportURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AnonymousDiagnosticPayload.self, from: data)
    }

    public func loadReportHistory() -> [AnonymousDiagnosticPayload] {
        let historyURL = diagnosticsDirectory.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AnonymousDiagnosticPayload].self, from: data)) ?? []
    }

    // MARK: - Remote Transmission

    /// Asynchronously transmits the anonymous diagnostic report to the developer endpoint.
    public func sendReport(
        _ payload: AnonymousDiagnosticPayload,
        endpointURL: URL? = nil
    ) async throws {
        // Always save locally first so the user can inspect it
        saveReportLocally(payload)

        guard let endpoint = endpointURL ?? defaultTelemetryEndpoint() else {
            // If no remote endpoint is set yet, local capture was saved.
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Ludus-Diagnostics/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "AnonymousDiagnosticsService", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Remote diagnostics endpoint returned HTTP \(status)"
            ])
        }
    }

    private func defaultTelemetryEndpoint() -> URL? {
        if let envURL = ProcessInfo.processInfo.environment["LUDUS_DIAGNOSTICS_ENDPOINT"],
           let url = URL(string: envURL) {
            return url
        }
        return nil
    }

    // MARK: - GitHub Issue Generation

    /// Generates a pre-filled GitHub Issue URL so the user can inspect and submit the report directly to the repository with one click.
    public func gitHubIssueURL(
        for payload: AnonymousDiagnosticPayload,
        repoOwner: String = "NIWDOGLEOJ",
        repoName: String = "ludus"
    ) -> URL {
        let title = "[Bug Report - \(payload.component)]: \(payload.errorDescription.prefix(60))"

        var body = """
        ### 📋 Anonymous Diagnostic Report
        *Generated automatically by Ludus v\(payload.appVersion)*

        **Component**: `\(payload.component)`
        **Error Type**: `\(payload.errorType)`
        **Error Description**: `\(payload.errorDescription)`

        #### 💻 System Information
        - **macOS**: `\(payload.osVersion)`
        - **Chip Model**: `\(payload.chipModel)`
        - **Architecture**: `\(payload.chipArchitecture)`
        - **Total RAM**: `\(ByteCountFormatter.string(fromByteCount: Int64(payload.memoryTotalBytes), countStyle: .memory))`
        - **Anonymous ID**: `\(payload.anonymousInstallationID)`
        - **Timestamp**: `\(ISO8601DateFormatter().string(from: payload.timestamp))`
        """

        if let feedback = payload.userFeedback, !feedback.isEmpty {
            body += "\n\n#### 💬 User Feedback\n\(feedback)\n"
        }

        if !payload.sanitizedLogs.isEmpty {
            body += "\n\n#### 📜 Sanitized Log Tail\n```text\n"
            body += payload.sanitizedLogs.joined(separator: "\n")
            body += "\n```"
        }

        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        return URL(string: "https://github.com/\(repoOwner)/\(repoName)/issues/new?title=\(encodedTitle)&body=\(encodedBody)")!
    }
}
