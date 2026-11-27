// ActivityDataService.swift
// ContribHeatmap companion app
//
// Stores the private GitHub token in Keychain and synchronizes the
// validated activity JSON into the shared App Group container.

import Foundation
import Security

// MARK: - Private Running Activity Repository

enum ActivityTokenStore {
    private static let service = "com.stheberga.githeatmap"
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

enum ActivitySyncError: LocalizedError, Sendable {
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
            if status == 401 || status == 403 {
                return "GitHub rejected the token. Check its repository access and Contents: read permission."
            }
            if status == 404 {
                return "GitHub could not find the private JSON file, or the token cannot access this repository."
            }
            return "GitHub returned HTTP \(status) while fetching activity data."
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
        request.setValue("GitHeatmap macOS app", forHTTPHeaderField: "User-Agent")
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
