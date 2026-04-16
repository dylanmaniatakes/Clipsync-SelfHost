import Combine
import Foundation

enum ConnectionMode: String, CaseIterable, Identifiable {
    case externalServer
    case directLink

    var id: String { rawValue }
}

final class ServerConfiguration: ObservableObject {
    static let shared = ServerConfiguration()

    private let modeKey = "connection_mode"
    private let baseURLKey = "server_base_url"
    private let apiKeyKey = "server_api_key"
    private let directPortKey = "direct_port"

    @Published private(set) var mode: ConnectionMode
    @Published private(set) var baseURL: String
    @Published private(set) var apiKey: String
    @Published private(set) var directPort: Int

    private init() {
        self.mode = ConnectionMode(
            rawValue: UserDefaults.standard.string(forKey: modeKey) ?? ""
        ) ?? .directLink
        self.baseURL = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        self.apiKey = KeychainManager.load(key: apiKeyKey) ?? ""
        let storedPort = UserDefaults.standard.integer(forKey: directPortKey)
        self.directPort = storedPort > 0 ? storedPort : 8787
    }

    var normalizedBaseURL: String {
        Self.normalizeBaseURL(baseURL)
    }

    var runtimeBaseURL: String {
        switch mode {
        case .externalServer:
            return normalizedBaseURL
        case .directLink:
            return "http://127.0.0.1:\(directPort)"
        }
    }

    var directCandidateBaseURLs: [String] {
        LocalAddressDetector.baseURLs(port: directPort)
    }

    var normalizedApiKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasConfiguration: Bool {
        switch mode {
        case .externalServer:
            return !normalizedBaseURL.isEmpty && !normalizedApiKey.isEmpty
        case .directLink:
            return directPort > 0 && !normalizedApiKey.isEmpty
        }
    }

    func save(baseURL: String, apiKey: String) {
        let normalizedURL = Self.normalizeBaseURL(baseURL)
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(ConnectionMode.externalServer.rawValue, forKey: modeKey)
        UserDefaults.standard.set(normalizedURL, forKey: baseURLKey)
        KeychainManager.save(key: apiKeyKey, value: normalizedKey)

        mode = .externalServer
        self.baseURL = normalizedURL
        self.apiKey = normalizedKey
    }

    func saveDirect(port: Int, apiKey: String) {
        let preservedExternalURL = Self.normalizeBaseURL(self.baseURL)
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(ConnectionMode.directLink.rawValue, forKey: modeKey)
        UserDefaults.standard.set(preservedExternalURL, forKey: baseURLKey)
        UserDefaults.standard.set(port, forKey: directPortKey)
        KeychainManager.save(key: apiKeyKey, value: normalizedKey)

        mode = .directLink
        self.baseURL = preservedExternalURL
        self.apiKey = normalizedKey
        self.directPort = port
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: modeKey)
        UserDefaults.standard.removeObject(forKey: baseURLKey)
        UserDefaults.standard.removeObject(forKey: directPortKey)
        KeychainManager.delete(key: apiKeyKey)
        mode = .directLink
        baseURL = ""
        apiKey = ""
        directPort = 8787
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
