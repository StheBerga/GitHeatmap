// ContributionService.swift
// ContribHeatmapWidget
//
// Fetches contributions from https://github-contributions-api.jogruber.de/v4/{username}
// The original deno.dev endpoint was sunset July 2026; this replacement is the live API.

import Foundation

/// Validated, percent-encoded GitHub username.
struct GitHubUsername: Sendable {
    let rawValue: String
    let encoded: String

    /// Allowed characters in a GitHub username: alphanumeric + hyphen, 1–39 chars.
    /// We construct the regex locally inside init to avoid storing a non-Sendable
    /// Regex<Substring> as a static property (Swift 6 strict concurrency).
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 39 else { return nil }
        // Local regex literal – not stored, so no Sendable / global-mutable-state issue.
        let validRegex = /^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?$|^[a-zA-Z0-9]$/
        guard (try? validRegex.wholeMatch(in: trimmed)) != nil else { return nil }
        rawValue = trimmed
        // Percent-encoding for safe URL construction (hyphens are already safe)
        encoded  = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
    }
}

// MARK: - Service Actor

actor ContributionService {

    static let shared = ContributionService()

    private let baseURL = "https://github-contributions-api.jogruber.de/v4/"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 10
        config.timeoutIntervalForResource = 10
        // Disable caching – WidgetKit provides its own timeline.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config)
    }

    /// Fetches raw contribution days for `username`, sorted ascending by date.
    /// Throws `ContributionError` on any failure.
    func fetch(username: String) async throws -> [ContributionDay] {
        guard let validated = GitHubUsername(username) else {
            throw ContributionError.invalidUsername
        }

        let urlString = baseURL + validated.encoded + "?y=last"
        guard let url = URL(string: urlString) else {
            throw ContributionError.invalidUsername
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw ContributionError.network(error)
        }

        if let httpResponse = response as? HTTPURLResponse {
            let status = httpResponse.statusCode
            guard (200..<300).contains(status) else {
                throw ContributionError.badStatus(status)
            }
        }

        let apiResponse: APIResponse
        do {
            let decoder = JSONDecoder()
            apiResponse = try decoder.decode(APIResponse.self, from: data)
        } catch {
            throw ContributionError.decoding(error)
        }

        guard !apiResponse.contributions.isEmpty else {
            throw ContributionError.empty
        }

        let isoParser = Self.makeISOParser()
        let days: [ContributionDay] = apiResponse.contributions.compactMap { api in
            guard let date = isoParser.date(from: api.date) else { return nil }
            return ContributionDay(
                date: date,
                count: max(0, api.count),
                level: .none,   // level is recomputed by HeatmapGridBuilder
                isFuture: false
            )
        }.sorted { $0.date < $1.date }

        return days
    }

    // MARK: - Helpers

    private static func makeISOParser() -> DateFormatter {
        let f = DateFormatter()
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.calendar   = Calendar(identifier: .gregorian)
        f.timeZone   = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}


// MARK: - Private Running Activity Repository

import Security

enum ActivityTokenStore {
    private static let service = "com.stheberga.GitHeatmap"
    private static let account = "running-heatmap-data"

    static func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActivitySyncError.missingToken }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw ActivitySyncError.keychain(status) }
        } else if update != errSecSuccess {
            throw ActivitySyncError.keychain(update)
        }
    }

    static func load() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            if status == errSecItemNotFound { throw ActivitySyncError.missingToken }
            throw ActivitySyncError.keychain(status)
        }
        return token
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ActivitySyncError.keychain(status)
        }
    }
}

private struct GitHubContentsResponse: Decodable {
    let content: String
    let encoding: String
}

enum ActivitySyncError: LocalizedError {
    case missingToken
    case invalidResponse
    case httpStatus(Int)
    case invalidBase64
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Add a GitHub read-only token in GitHeatmap before syncing."
        case .invalidResponse:
            return "GitHub returned an unexpected response for activity_data.json."
        case .httpStatus(let status):
            return status == 401 || status == 403
                ? "GitHub rejected the token. Check its repository access and Contents: read permission."
                : "GitHub returned HTTP \(status) while fetching activity data."
        case .invalidBase64:
            return "GitHub returned activity data that could not be decoded."
        case .keychain(let status):
            return "Could not access the macOS Keychain (status \(status))."
        }
    }
}

actor ActivityDataService {
    static let shared = ActivityDataService()

    private let fileURL = URL(string:
        "https://api.github.com/repos/StheBerga/running-heatmap-data/contents/data/activity_data.json"
    )!

    func sync() async throws -> ActivityDataDocument {
        let token = try ActivityTokenStore.load()
        var request = URLRequest(url: fileURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ActivitySyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ActivitySyncError.httpStatus(http.statusCode)
        }

        let contents = try JSONDecoder().decode(GitHubContentsResponse.self, from: data)
        guard contents.encoding == "base64",
              let jsonData = Data(
                base64Encoded: contents.content.replacingOccurrences(of: "\n", with: ""),
                options: .ignoreUnknownCharacters
              ) else {
            throw ActivitySyncError.invalidBase64
        }

        let document = try JSONDecoder().decode(ActivityDataDocument.self, from: jsonData)
        try document.validate()
        try ActivityDataCache.save(document)
        return document
    }
}
