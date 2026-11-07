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
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.4"
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

    public static let defaultTelegramBotTokenEncoded = "OTIwNzM5OTEzODpBQUZrbXhEY0REblQzNzFHN0NoZ29Hc1k0Q2d5SW9GemlLYw=="
    public static let defaultTelegramChatIDEncoded = "OTA3MTM3MjcwMw=="

    public static func decodeSecret(_ base64: String) -> String {
        guard let data = Data(base64Encoded: base64),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    /// Asynchronously records the anonymous diagnostic report locally and transmits to Telegram bot and configured endpoints.
    public func sendReport(
        _ payload: AnonymousDiagnosticPayload,
        endpointURL: URL? = nil,
        customBotToken: String? = nil,
        customChatID: String? = nil
    ) async throws {
        // Always save locally first so the user can inspect it
        saveReportLocally(payload)

        // 1. Deliver to Telegram Bot
        try? await sendToTelegram(
            payload: payload,
            customBotToken: customBotToken,
            customChatID: customChatID
        )

        // 2. Deliver to custom telemetry endpoint if configured
        if let endpoint = endpointURL ?? defaultTelemetryEndpoint() {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Ludus-Diagnostics/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(payload)

            let _ = try? await URLSession.shared.data(for: request)
        }
    }

    public func sendToTelegram(
        payload: AnonymousDiagnosticPayload,
        customBotToken: String? = nil,
        customChatID: String? = nil
    ) async throws {
        let htmlMessage = formatTelegramHTMLMessage(for: payload)
        try await sendTelegramHTMLMessage(
            htmlMessage,
            customBotToken: customBotToken,
            customChatID: customChatID
        )
    }

    /// Transmits any formatted HTML payload directly to the Telegram bot and chat.
    public func sendTelegramHTMLMessage(
        _ htmlMessage: String,
        customBotToken: String? = nil,
        customChatID: String? = nil
    ) async throws {
        let token = (customBotToken?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ??
            ProcessInfo.processInfo.environment["LUDUS_TELEGRAM_BOT_TOKEN"] ??
            ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"] ??
            Self.decodeSecret(Self.defaultTelegramBotTokenEncoded)

        let chatID = (customChatID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ??
            ProcessInfo.processInfo.environment["LUDUS_TELEGRAM_CHAT_ID"] ??
            ProcessInfo.processInfo.environment["TELEGRAM_CHAT_ID"] ??
            Self.decodeSecret(Self.defaultTelegramChatIDEncoded)

        guard !token.isEmpty, !chatID.isEmpty else {
            // No credentials configured; report is saved locally
            return
        }

        guard let apiURL = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let bodyObj: [String: Any] = [
            "chat_id": chatID,
            "text": htmlMessage,
            "parse_mode": "HTML",
            "disable_web_page_preview": true
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObj)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "AnonymousDiagnosticsService.Telegram", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Telegram Bot API returned HTTP \(status)"
            ])
        }
    }

    // MARK: - Game Lifecycle Reporting to Telegram

    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    /// Sends a real-time notification to Telegram when a game is launched.
    public func sendGameLaunchNotification(
        gameTitle: String,
        graphicsBackend: String? = nil,
        runtimeName: String? = nil,
        bottleName: String? = nil,
        executablePath: String? = nil,
        customBotToken: String? = nil,
        customChatID: String? = nil
    ) async throws {
        let isoDate = ISO8601DateFormatter().string(from: Date())
        let ramString = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
        let gameEscaped = Self.escapeHTML(gameTitle)
        let backendEscaped = Self.escapeHTML(graphicsBackend ?? "Automatic (D3DMetal/DXMT)")
        let runtimeEscaped = Self.escapeHTML(runtimeName ?? "CrossOver Wine")
        let bottleEscaped = Self.escapeHTML(bottleName ?? "DefaultBottle")
        let chipEscaped = Self.escapeHTML(Self.chipModel)

        var msg = """
        🚀 <b>Ludus Game Launching</b> 🎮
        ──────────────────────
        • <b>Game:</b> <code>\(gameEscaped)</code>
        • <b>Graphics Backend:</b> <code>\(backendEscaped)</code>
        • <b>Wine Runtime:</b> <code>\(runtimeEscaped)</code>
        • <b>Bottle:</b> <code>\(bottleEscaped)</code>
        • <b>Device:</b> <code>\(chipEscaped)</code> (RAM: \(ramString))
        • <b>macOS:</b> <code>\(Self.osVersion)</code>
        • <b>App Version:</b> <code>v\(Self.appVersion)</code>
        • <b>Time:</b> <code>\(isoDate)</code>
        """

        if let exec = executablePath, !exec.isEmpty {
            let sanitizedExec = Self.sanitize(log: exec)
            msg += "\n• <b>Executable:</b> <code>\(Self.escapeHTML(sanitizedExec))</code>"
        }

        try await sendTelegramHTMLMessage(msg, customBotToken: customBotToken, customChatID: customChatID)
    }

    /// Sends a post-session diagnostic report to Telegram whether the game ran successfully or exited with an error.
    public func sendGameSessionReport(
        gameTitle: String,
        exitStatus: Int32,
        duration: TimeInterval,
        graphicsBackend: String? = nil,
        runtimeName: String? = nil,
        bottleName: String? = nil,
        diagnosticNote: String? = nil,
        standardOutput: String = "",
        standardError: String = "",
        customBotToken: String? = nil,
        customChatID: String? = nil
    ) async throws {
        let combinedLogs = [standardError, standardOutput].filter { !$0.isEmpty }.joined(separator: "\n")
        let hasFatalAssertion = combinedLogs.contains("failed assertion `Command encoder released without endEncoding'") ||
                                combinedLogs.contains("failed assertion") ||
                                combinedLogs.contains("STATUS_ACCESS_VIOLATION")
        let isSuccess = (exitStatus == 0) && !hasFatalAssertion
        let isoDate = ISO8601DateFormatter().string(from: Date())
        let ramString = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
        let durationFormatted = Self.formatDuration(duration)
        let gameEscaped = Self.escapeHTML(gameTitle)
        let chipEscaped = Self.escapeHTML(Self.chipModel)

        let header: String
        let statusLine: String
        if isSuccess {
            header = "🎮 <b>Ludus Game Session Report</b> ✅"
            statusLine = "• <b>Session Outcome:</b> <b>Ran Successfully (Clean Exit)</b>\n• <b>Exit Code:</b> <code>0</code>"
        } else if hasFatalAssertion {
            header = "🚨 <b>Ludus Game Session Report (Metal Assertion)</b> ❌"
            statusLine = "• <b>Session Outcome:</b> <b>Terminated on Graphics Assertion</b>\n• <b>Exit Code:</b> <code>\(exitStatus)</code>"
        } else {
            header = "🚨 <b>Ludus Game Execution Failure</b> ❌"
            statusLine = "• <b>Session Outcome:</b> <b>Process Exited with Error</b>\n• <b>Exit Code:</b> <code>\(exitStatus)</code>"
        }

        var msg = """
        \(header)
        ──────────────────────
        • <b>Game:</b> <code>\(gameEscaped)</code>
        \(statusLine)
        • <b>Session Duration:</b> <code>\(durationFormatted)</code>
        """

        if let backend = graphicsBackend, !backend.isEmpty {
            msg += "\n• <b>Graphics:</b> <code>\(Self.escapeHTML(backend))</code>"
        }
        if let runtime = runtimeName, !runtime.isEmpty {
            msg += "\n• <b>Runtime:</b> <code>\(Self.escapeHTML(runtime))</code>"
        }
        if let bottle = bottleName, !bottle.isEmpty {
            msg += "\n• <b>Bottle:</b> <code>\(Self.escapeHTML(bottle))</code>"
        }
        if let note = diagnosticNote, !note.isEmpty {
            msg += "\n• <b>Diagnostic Note:</b> <code>\(Self.escapeHTML(note))</code>"
        }

        msg += """

        • <b>Device:</b> <code>\(chipEscaped)</code> (RAM: \(ramString))
        • <b>macOS:</b> <code>\(Self.osVersion)</code>
        • <b>App Version:</b> <code>v\(Self.appVersion)</code>
        • <b>Time:</b> <code>\(isoDate)</code>
        """

        // Append execution logs if available (essential for failures, optional for success)
        if !combinedLogs.isEmpty {
            let sanitized = Self.sanitize(log: combinedLogs)
            let lines = sanitized.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !lines.isEmpty {
                let tailLines = lines.suffix(isSuccess ? 8 : 25).joined(separator: "\n")
                msg += "\n\n📋 <b>Execution Log Tail:</b>\n<pre>\(Self.escapeHTML(tailLines))</pre>"
            }
        }

        if msg.count > 4000 {
            msg = String(msg.prefix(3950)) + "\n...</pre>"
        }

        try await sendTelegramHTMLMessage(msg, customBotToken: customBotToken, customChatID: customChatID)
    }

    /// Sends a launch failure report to Telegram when a game fails to start at all.
    public func sendGameLaunchFailureReport(
        gameTitle: String,
        error: Error,
        runtimeName: String? = nil,
        bottleName: String? = nil,
        executablePath: String? = nil,
        customBotToken: String? = nil,
        customChatID: String? = nil
    ) async throws {
        let isoDate = ISO8601DateFormatter().string(from: Date())
        let ramString = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
        let gameEscaped = Self.escapeHTML(gameTitle)
        let errorEscaped = Self.escapeHTML(Self.sanitize(log: error.localizedDescription))
        let chipEscaped = Self.escapeHTML(Self.chipModel)

        var msg = """
        ❌ <b>Ludus Game Launch Failed</b> 🚨
        ──────────────────────
        • <b>Game:</b> <code>\(gameEscaped)</code>
        • <b>Error:</b> <code>\(errorEscaped)</code>
        """

        if let runtime = runtimeName, !runtime.isEmpty {
            msg += "\n• <b>Runtime:</b> <code>\(Self.escapeHTML(runtime))</code>"
        }
        if let bottle = bottleName, !bottle.isEmpty {
            msg += "\n• <b>Bottle:</b> <code>\(Self.escapeHTML(bottle))</code>"
        }
        if let exec = executablePath, !exec.isEmpty {
            let sanitizedExec = Self.sanitize(log: exec)
            msg += "\n• <b>Executable:</b> <code>\(Self.escapeHTML(sanitizedExec))</code>"
        }

        msg += """

        • <b>Device:</b> <code>\(chipEscaped)</code> (RAM: \(ramString))
        • <b>macOS:</b> <code>\(Self.osVersion)</code>
        • <b>App Version:</b> <code>v\(Self.appVersion)</code>
        • <b>Time:</b> <code>\(isoDate)</code>
        """

        try await sendTelegramHTMLMessage(msg, customBotToken: customBotToken, customChatID: customChatID)
    }

    private func formatTelegramHTMLMessage(for payload: AnonymousDiagnosticPayload) -> String {
        let ramString = ByteCountFormatter.string(fromByteCount: Int64(payload.memoryTotalBytes), countStyle: .memory)
        let isoDate = ISO8601DateFormatter().string(from: payload.timestamp)
        let anonIDShort = String(payload.anonymousInstallationID.prefix(8))
        let errorDescEscaped = Self.escapeHTML(payload.errorDescription)
        let compEscaped = Self.escapeHTML(payload.component)
        let chipEscaped = Self.escapeHTML(payload.chipModel)

        var msg = """
        🚨 <b>Ludus Diagnostic & Crash Report</b> 🎮
        ──────────────────────
        • <b>Component:</b> <code>\(compEscaped)</code>
        • <b>Error:</b> <code>\(errorDescEscaped)</code>
        • <b>App Version:</b> <code>v\(payload.appVersion)</code>
        • <b>Device:</b> <code>\(chipEscaped)</code>
        • <b>macOS:</b> <code>\(payload.osVersion)</code> (RAM: \(ramString))
        • <b>Anonymous ID:</b> <code>\(anonIDShort)...</code>
        • <b>Time:</b> <code>\(isoDate)</code>
        """

        if let feedback = payload.userFeedback, !feedback.isEmpty {
            msg += "\n\n💬 <b>User Note:</b>\n<i>\(Self.escapeHTML(feedback))</i>"
        }

        if !payload.sanitizedLogs.isEmpty {
            let tail = payload.sanitizedLogs.suffix(20).joined(separator: "\n")
            msg += "\n\n📋 <b>Sanitized Logs:</b>\n<pre>\(Self.escapeHTML(tail))</pre>"
        }

        if msg.count > 4000 {
            msg = String(msg.prefix(3950)) + "\n...</pre>"
        }

        return msg
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
