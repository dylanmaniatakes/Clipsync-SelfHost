import Foundation

struct ServerPairing: Codable {
    let pairingId: String
    let macDeviceId: String
    let macDeviceName: String
    let androidDeviceId: String
    let androidDeviceName: String
    let status: String
    let createdAt: Int64
    let updatedAt: Int64
}

struct ServerEvent: Codable {
    let id: Int
    let pairingId: String
    let type: String
    let sourceDeviceId: String
    let sourceDeviceName: String
    let content: String?
    let encryptedOTP: String?
    let timestamp: Int64
}

struct ServerInfoResponse: Codable {
    let ok: Bool
    let host: String
    let port: Int
}

struct PairingEnvelope: Codable {
    let pairing: ServerPairing?
}

struct EventsEnvelope: Codable {
    let events: [ServerEvent]
    let cursor: Int
}

struct EmptyResponse: Codable {}

enum ServerAPIError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case unauthorized
    case notFound
    case pairingDeleted
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Server URL or API key is missing."
        case .invalidURL:
            return "The server URL is invalid."
        case .unauthorized:
            return "The server rejected the API key."
        case .notFound:
            return "The requested resource was not found."
        case .pairingDeleted:
            return "This pairing no longer exists on the server."
        case .invalidResponse:
            return "The server returned an unexpected response."
        case let .server(message):
            return message
        }
    }
}

final class ServerAPI {
    static let shared = ServerAPI()

    private let session: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: configuration)
    }

    func validateCurrentConfiguration() async throws {
        let config = ServerConfiguration.shared
        try await validateConfiguration(baseURL: config.normalizedBaseURL, apiKey: config.normalizedApiKey)
    }

    func validateConfiguration(baseURL: String, apiKey: String) async throws {
        let _: ServerInfoResponse = try await request(
            baseURL: baseURL,
            apiKey: apiKey,
            path: "/api/v1/server",
            method: "GET"
        )
    }

    func fetchLatestPairing(for macDeviceId: String, sessionId: String) async throws -> ServerPairing? {
        let path = "/api/v1/pairings/by-mac/\(macDeviceId)"
        let response: PairingEnvelope = try await request(
            path: path,
            method: "GET",
            queryItems: [URLQueryItem(name: "sessionId", value: sessionId)]
        )
        return response.pairing
    }

    func getPairing(_ pairingId: String) async throws -> ServerPairing {
        let response: PairingEnvelope = try await request(
            path: "/api/v1/pairings/\(pairingId)",
            method: "GET"
        )
        guard let pairing = response.pairing else {
            throw ServerAPIError.invalidResponse
        }
        return pairing
    }

    func deletePairing(_ pairingId: String) async throws {
        let _: PairingEnvelope = try await request(
            path: "/api/v1/pairings/\(pairingId)",
            method: "DELETE"
        )
    }

    func sendClipboard(
        pairingId: String,
        sourceDeviceId: String,
        sourceDeviceName: String,
        content: String
    ) async throws {
        let body: [String: Any] = [
            "sourceDeviceId": sourceDeviceId,
            "sourceDeviceName": sourceDeviceName,
            "content": content
        ]

        let _: EmptyResponse = try await request(
            path: "/api/v1/pairings/\(pairingId)/clipboard",
            method: "POST",
            body: body
        )
    }

    func fetchEvents(
        pairingId: String,
        after cursor: Int,
        type: String,
        excludeDeviceId: String
    ) async throws -> EventsEnvelope {
        try await request(
            path: "/api/v1/pairings/\(pairingId)/events",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "after", value: String(cursor)),
                URLQueryItem(name: "type", value: type),
                URLQueryItem(name: "excludeDeviceId", value: excludeDeviceId)
            ]
        )
    }

    private func request<T: Decodable>(
        baseURL: String? = nil,
        apiKey: String? = nil,
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> T {
        let config = ServerConfiguration.shared
        let resolvedBaseURL = baseURL ?? config.normalizedBaseURL
        let resolvedAPIKey = apiKey ?? config.normalizedApiKey

        guard !resolvedBaseURL.isEmpty, !resolvedAPIKey.isEmpty else {
            throw ServerAPIError.notConfigured
        }

        guard var components = URLComponents(string: resolvedBaseURL) else {
            throw ServerAPIError.invalidURL
        }

        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw ServerAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(resolvedAPIKey, forHTTPHeaderField: "X-ClipSync-Key")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServerAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw ServerAPIError.unauthorized
        case 404:
            throw ServerAPIError.notFound
        case 410:
            throw ServerAPIError.pairingDeleted
        default:
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["error"] as? String,
               !message.isEmpty {
                throw ServerAPIError.server(message)
            }
            throw ServerAPIError.server("Server returned HTTP \(httpResponse.statusCode).")
        }

        return try decoder.decode(T.self, from: data)
    }
}
