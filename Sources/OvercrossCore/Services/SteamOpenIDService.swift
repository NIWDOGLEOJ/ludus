import AppKit
import AuthenticationServices
import Darwin
import Foundation
import Network

enum SteamOpenIDError: LocalizedError, Sendable {
    case invalidCallback
    case authenticationRejected
    case invalidSteamID
    case verificationFailed
    case requestFailed(String)
    case sessionAlreadyRunning
    case couldNotStart
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            "Steam returned an incomplete or unexpected authentication callback."
        case .authenticationRejected:
            "Steam authentication was rejected or cancelled."
        case .invalidSteamID:
            "Steam returned a callback without a valid numeric SteamID."
        case .verificationFailed:
            "Steam could not verify the delegated authentication response."
        case let .requestFailed(message):
            "Steam authentication verification failed: \(message)"
        case .sessionAlreadyRunning:
            "A Steam authentication session is already running."
        case .couldNotStart:
            "macOS could not start the Steam browser authentication session."
        case .cancelled:
            "Steam authentication was cancelled."
        }
    }
}

struct SteamOpenIDService: Sendable {
    static let callbackScheme = "overcross"
    static let callbackURL = URL(string: "overcross://steam-auth")!
    private static let endpoint = URL(string: "https://steamcommunity.com/openid/login")!
    private static let claimedIdentifier = "http://specs.openid.net/auth/2.0/identifier_select"

    static func authorizationURL(returnToURL: URL = callbackURL, realmURL: URL? = nil) throws -> URL {
        let realm = realmURL?.absoluteString ?? "\(returnToURL.scheme ?? callbackScheme)://"
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "openid.ns", value: "http://specs.openid.net/auth/2.0"),
            URLQueryItem(name: "openid.mode", value: "checkid_setup"),
            URLQueryItem(name: "openid.return_to", value: returnToURL.absoluteString),
            URLQueryItem(name: "openid.realm", value: realm),
            URLQueryItem(name: "openid.identity", value: claimedIdentifier),
            URLQueryItem(name: "openid.claimed_id", value: claimedIdentifier)
        ]
        guard let url = components?.url else {
            throw SteamOpenIDError.invalidCallback
        }
        return url
    }

    func verifyCallback(
        _ callbackURL: URL,
        expectedReturnTo: String? = nil,
        expectedRealm: String? = nil
    ) async throws -> String {
        let validated = try Self.validatedCallback(
            callbackURL,
            expectedReturnTo: expectedReturnTo,
            expectedRealm: expectedRealm
        )
        let items = validated.items
        let steamID = validated.steamID

        var verificationItems = items.filter { $0.name != "openid.mode" }
        verificationItems.append(URLQueryItem(name: "openid.mode", value: "check_authentication"))
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let postBodyString = Self.encodeFormParameters(verificationItems)
        request.httpBody = postBodyString.data(using: .utf8)
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SteamOpenIDError.requestFailed(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SteamOpenIDError.verificationFailed
        }
        let verificationResponse = String(data: data, encoding: .utf8) ?? ""
        guard verificationResponse
            .split(whereSeparator: \.isNewline)
            .contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "is_valid:true" }) else {
            throw SteamOpenIDError.verificationFailed
        }
        return steamID
    }

    static func formUrlEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    static func encodeFormParameters(_ items: [URLQueryItem]) -> String {
        items.map { item in
            let name = formUrlEncode(item.name)
            let value = formUrlEncode(item.value ?? "")
            return "\(name)=\(value)"
        }.joined(separator: "&")
    }

    static func validatedCallback(
        _ callbackURL: URL,
        expectedReturnTo: String? = nil,
        expectedRealm: String? = nil
    ) throws -> (steamID: String, items: [URLQueryItem]) {
        let isCustomScheme = callbackURL.scheme == Self.callbackScheme && callbackURL.host == "steam-auth"
        let isLoopback = callbackURL.scheme == "http" && callbackURL.host == "127.0.0.1" && callbackURL.path == "/callback"
        guard isCustomScheme || isLoopback else {
            throw SteamOpenIDError.invalidCallback
        }
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if values["openid.mode"] == "cancel" {
            throw SteamOpenIDError.cancelled
        }
        guard values["openid.ns"] == "http://specs.openid.net/auth/2.0",
              values["openid.mode"] == "id_res",
              let endpointValue = values["openid.op_endpoint"],
              let endpoint = URL(string: endpointValue),
              endpoint.scheme == "https",
              endpoint.host == "steamcommunity.com",
              endpoint.path == "/openid/login" else {
            throw SteamOpenIDError.authenticationRejected
        }

        if let expectedReturnTo {
            guard values["openid.return_to"] == expectedReturnTo else {
                throw SteamOpenIDError.authenticationRejected
            }
        } else if isCustomScheme {
            guard values["openid.return_to"] == Self.callbackURL.absoluteString,
                  values["openid.realm"] == "\(Self.callbackScheme)://" else {
                throw SteamOpenIDError.authenticationRejected
            }
        }

        if let expectedRealm, let realmValue = values["openid.realm"] {
            guard realmValue == expectedRealm else {
                throw SteamOpenIDError.authenticationRejected
            }
        }

        let steamID = try Self.steamID(fromClaimedID: values["openid.claimed_id"])
        return (steamID: steamID, items: items)
    }

    static func steamID(fromClaimedID claimedID: String?) throws -> String {
        guard let claimedID,
              let url = URL(string: claimedID),
              url.host == "steamcommunity.com",
              url.pathComponents.count == 4,
              url.pathComponents[1] == "openid",
              url.pathComponents[2] == "id",
              let steamID = UInt64(url.pathComponents[3]),
              steamID > 0 else {
            throw SteamOpenIDError.invalidSteamID
        }
        return String(steamID)
    }
}

final class SteamLoopbackListener: @unchecked Sendable {
    private let serverFd: Int32
    let port: UInt16
    private var isCancelled = false
    private let lock = NSLock()

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SteamOpenIDError.couldNotStart
        }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw SteamOpenIDError.couldNotStart
        }

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw SteamOpenIDError.couldNotStart
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var boundAddr = sockaddr_in()
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw SteamOpenIDError.couldNotStart
        }

        let assignedPort = UInt16(bigEndian: boundAddr.sin_port)
        guard assignedPort > 0 else {
            close(fd)
            throw SteamOpenIDError.couldNotStart
        }

        self.serverFd = fd
        self.port = assignedPort
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SteamOpenIDError.cancelled)
                    return
                }

                while true {
                    let clientFd = accept(self.serverFd, nil, nil)
                    if clientFd < 0 {
                        self.lock.lock()
                        let cancelled = self.isCancelled
                        self.lock.unlock()
                        if cancelled {
                            continuation.resume(throwing: SteamOpenIDError.cancelled)
                        } else {
                            continuation.resume(throwing: SteamOpenIDError.couldNotStart)
                        }
                        return
                    }

                    var buffer = [UInt8](repeating: 0, count: 16384)
                    let bytesRead = read(clientFd, &buffer, buffer.count)
                    guard bytesRead > 0,
                          let requestString = String(bytes: buffer[..<bytesRead], encoding: .utf8),
                          let firstLine = requestString.components(separatedBy: "\r\n").first,
                          firstLine.hasPrefix("GET ") else {
                        close(clientFd)
                        continue
                    }

                    let pathAndQuery = firstLine.dropFirst(4).components(separatedBy: " ").first ?? ""
                    if !pathAndQuery.hasPrefix("/callback") {
                        let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        notFound.withCString { _ = write(clientFd, $0, strlen($0)) }
                        close(clientFd)
                        continue
                    }

                    let fullURLString = "http://127.0.0.1:\(self.port)\(pathAndQuery)"
                    guard let callbackURL = URL(string: fullURLString) else {
                        close(clientFd)
                        self.cancel()
                        continuation.resume(throwing: SteamOpenIDError.invalidCallback)
                        return
                    }

                    let html = """
                    <!DOCTYPE html>
                    <html>
                    <head><meta charset="utf-8"><title>Ludus - Steam Authentication</title></head>
                    <body style="font-family: -apple-system, sans-serif; text-align: center; padding: 60px; background: #16161e; color: #fff;">
                        <h2 style="color: #4ade80;">✓ Authentication Received</h2>
                        <p>You can close this tab and return to Ludus.</p>
                    </body>
                    </html>
                    """
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    response.withCString { ptr in
                        _ = write(clientFd, ptr, strlen(ptr))
                    }
                    close(clientFd)
                    self.cancel()
                    continuation.resume(returning: callbackURL)
                    return
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return }
        isCancelled = true
        close(serverFd)
    }

    deinit {
        cancel()
    }
}

@MainActor
final class SteamOpenIDAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let service = SteamOpenIDService()
    private var session: ASWebAuthenticationSession?
    private var loopbackListener: SteamLoopbackListener?
    private var continuation: CheckedContinuation<String, Error>?

    func authenticate() async throws -> String {
        guard continuation == nil else {
            throw SteamOpenIDError.sessionAlreadyRunning
        }

        let listener = try SteamLoopbackListener()
        self.loopbackListener = listener
        let port = listener.port
        let returnTo = URL(string: "http://127.0.0.1:\(port)/callback")!
        let realm = URL(string: "http://127.0.0.1:\(port)/")!
        let url = try SteamOpenIDService.authorizationURL(returnToURL: returnTo, realmURL: realm)

        return try await withTaskCancellationHandler(operation: {
            NSWorkspace.shared.open(url)
            let callbackURL = try await listener.waitForCallback()
            return try await service.verifyCallback(
                callbackURL,
                expectedReturnTo: returnTo.absoluteString,
                expectedRealm: realm.absoluteString
            )
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        })
    }

    func cancel() {
        loopbackListener?.cancel()
        loopbackListener = nil
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? NSWindow(
            contentRect: .zero,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
    }
}
