import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol TokenBarHTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> TokenBarHTTPResponse
}

struct TokenBarHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

struct CodexResetCreditsClient: Sendable {
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let transport: any TokenBarHTTPTransport
    private let now: @Sendable () -> Date

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 4,
        transport: any TokenBarHTTPTransport = EphemeralHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.environment = environment
        self.timeout = timeout
        self.transport = transport
        self.now = now
    }

    func fetch() async throws -> QuotaResetCreditsSnapshot? {
        let credentials = try CodexAuthStore.loadOAuthCredentials(environment: self.environment)
        let referenceDate = self.now()
        guard !credentials.needsRefresh(at: referenceDate) else { return nil }

        var request = URLRequest(
            url: Self.resetCreditsURL(environment: self.environment),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: self.timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("TokenBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let response: TokenBarHTTPResponse
        do {
            response = try await self.transport.response(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw CodexResetCreditsError.network(error.localizedDescription)
        }

        switch response.statusCode {
        case 200 ... 299:
            break
        case 401, 403:
            throw CodexResetCreditsError.unauthorized
        default:
            throw CodexResetCreditsError.server(response.statusCode)
        }

        let payload: ResetCreditsResponse
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(Self.decodeISO8601Date)
            payload = try decoder.decode(ResetCreditsResponse.self, from: response.data)
        } catch {
            throw CodexResetCreditsError.invalidResponse(error.localizedDescription)
        }
        guard payload.availableCount >= 0 else {
            throw CodexResetCreditsError.invalidResponse("available_count must not be negative")
        }

        let available = payload.credits.filter { credit in
            credit.status == "available" && (credit.expiresAt.map { $0 > referenceDate } ?? true)
        }
        let nextExpiration = available.compactMap(\.expiresAt).min()
        return QuotaResetCreditsSnapshot(
            availableCount: available.count,
            nextExpiresAt: nextExpiration)
    }

    static func resetCreditsURL(environment: [String: String]) -> URL {
        let configured = Self.configuredBaseURL(environment: environment)
        let normalized = Self.normalizedBaseURL(configured)
        return normalized.appending(path: "wham/rate-limit-reset-credits")
    }

    private static func configuredBaseURL(environment: [String: String]) -> String? {
        let home = CodexAuthStore.codexHomeURL(environment: environment)
        let configURL = home.appendingPathComponent("config.toml", isDirectory: false)
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let withoutComment = rawLine.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false).first ?? rawLine[...]
            let parts = withoutComment.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url"
            else {
                continue
            }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")
                   || value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }

    private static func normalizedBaseURL(_ configured: String?) -> URL {
        let fallback = URL(string: "https://chatgpt.com/backend-api")!
        guard var value = configured?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil
        else {
            return fallback
        }

        while value.hasSuffix("/") {
            value.removeLast()
        }
        if let host = components.host?.lowercased(),
           host == "chatgpt.com" || host == "chat.openai.com",
           !components.path.contains("/backend-api")
        {
            value += "/backend-api"
            components = URLComponents(string: value) ?? components
        }
        return components.url ?? fallback
    }

    private static func decodeISO8601Date(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        if let date = fractional.date(from: value) ?? seconds.date(from: value) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO-8601 date: \(value)")
    }
}

enum CodexResetCreditsError: LocalizedError, Sendable {
    case credentialsNotFound
    case invalidCredentials(String)
    case unauthorized
    case invalidResponse(String)
    case server(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            "Codex auth.json was not found."
        case let .invalidCredentials(message):
            "Codex auth.json is invalid: \(message)"
        case .unauthorized:
            "Codex authorization expired. Run Codex to sign in again."
        case let .invalidResponse(message):
            "Codex reset-credit response was invalid: \(message)"
        case let .server(status):
            "Codex reset-credit request failed with HTTP \(status)."
        case let .network(message):
            "Codex reset-credit request failed: \(message)"
        }
    }
}

struct CodexAuthCredentials: Sendable, Equatable {
    let accessToken: String
    let accountID: String?
    let lastRefresh: Date?

    func needsRefresh(at date: Date) -> Bool {
        guard let lastRefresh else { return true }
        return date.timeIntervalSince(lastRefresh) > 8 * 24 * 60 * 60
    }
}

enum CodexAuthStore {
    static func codexHomeURL(
        environment: [String: String],
        fileManager: FileManager = .default) -> URL
    {
        if let configured = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    static func loadOAuthCredentials(
        environment: [String: String],
        fileManager: FileManager = .default) throws -> CodexAuthCredentials
    {
        let url = self.codexHomeURL(environment: environment, fileManager: fileManager)
            .appendingPathComponent("auth.json", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodexResetCreditsError.credentialsNotFound
        }
        return try self.parse(data: Data(contentsOf: url))
    }

    static func parse(data: Data) throws -> CodexAuthCredentials {
        let object: [String: Any]
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexResetCreditsError.invalidCredentials("Expected a JSON object.")
            }
            object = dictionary
        } catch let error as CodexResetCreditsError {
            throw error
        } catch {
            throw CodexResetCreditsError.invalidCredentials(error.localizedDescription)
        }

        guard let tokens = object["tokens"] as? [String: Any],
              let accessToken = self.stringValue(tokens, snake: "access_token", camel: "accessToken"),
              self.stringValue(tokens, snake: "refresh_token", camel: "refreshToken") != nil
        else {
            throw CodexResetCreditsError.invalidCredentials("Missing OAuth tokens.")
        }
        let accountID = self.stringValue(tokens, snake: "account_id", camel: "accountId")
        let lastRefresh = (object["last_refresh"] as? String).flatMap(Self.parseISO8601Date)
        return CodexAuthCredentials(
            accessToken: accessToken,
            accountID: accountID,
            lastRefresh: lastRefresh)
    }

    private static func stringValue(
        _ dictionary: [String: Any],
        snake: String,
        camel: String) -> String?
    {
        for key in [snake, camel] {
            if let value = dictionary[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return value
            }
        }
        return nil
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: value)
    }
}

private struct ResetCreditsResponse: Decodable {
    let credits: [ResetCredit]
    let availableCount: Int

    private enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
    }
}

private struct ResetCredit: Decodable {
    let status: String
    let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case status
        case expiresAt = "expires_at"
    }
}

private final class EphemeralHTTPTransport: TokenBarHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let delegate = SameOriginRedirectDelegate()
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func response(for request: URLRequest) async throws -> TokenBarHTTPResponse {
        let (data, response) = try await self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return TokenBarHTTPResponse(data: data, statusCode: response.statusCode)
    }
}

final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let originalURL = task.originalRequest?.url,
              let redirectedURL = request.url,
              Self.allowsRedirect(from: originalURL, to: redirectedURL)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func allowsRedirect(from originalURL: URL, to redirectedURL: URL) -> Bool {
        originalURL.scheme?.lowercased() == "https"
            && redirectedURL.scheme?.lowercased() == "https"
            && Self.origin(of: originalURL) == Self.origin(of: redirectedURL)
    }

    private static func origin(of url: URL) -> String {
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : -1)
        return "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(port)"
    }
}
