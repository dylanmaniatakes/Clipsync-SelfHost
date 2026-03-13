import Combine
import Foundation

final class ServerConfiguration: ObservableObject {
    static let shared = ServerConfiguration()

    private let baseURLKey = "server_base_url"
    private let apiKeyKey = "server_api_key"

    @Published private(set) var baseURL: String
    @Published private(set) var apiKey: String

    private init() {
        self.baseURL = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        self.apiKey = KeychainManager.load(key: apiKeyKey) ?? ""
    }

    var normalizedBaseURL: String {
        Self.normalizeBaseURL(baseURL)
    }

    var normalizedApiKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasConfiguration: Bool {
        !normalizedBaseURL.isEmpty && !normalizedApiKey.isEmpty
    }

    func save(baseURL: String, apiKey: String) {
        let normalizedURL = Self.normalizeBaseURL(baseURL)
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(normalizedURL, forKey: baseURLKey)
        KeychainManager.save(key: apiKeyKey, value: normalizedKey)

        self.baseURL = normalizedURL
        self.apiKey = normalizedKey
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: baseURLKey)
        KeychainManager.delete(key: apiKeyKey)
        baseURL = ""
        apiKey = ""
    }

    static func normalizeBaseURL(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: " ", with: "")
            .pipe { value in
                guard !value.isEmpty else { return "" }
                if value.hasPrefix("http://") || value.hasPrefix("https://") {
                    return value
                }
                return "http://\(value)"
            }
    }
}

private extension String {
    func pipe(_ transform: (String) -> String) -> String {
        transform(self)
    }
}
