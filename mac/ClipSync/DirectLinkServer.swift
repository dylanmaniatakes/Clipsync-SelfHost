import Combine
import Foundation
import Network

private struct DirectPairing: Codable {
    let pairingId: String
    let macDeviceId: String
    let macDeviceName: String
    let androidDeviceId: String
    let androidDeviceName: String
    let sessionId: String
    let status: String
    let createdAt: Int64
    let updatedAt: Int64
}

private struct DirectEvent: Codable {
    let id: Int
    let pairingId: String
    let type: String
    let sourceDeviceId: String
    let sourceDeviceName: String
    let content: String?
    let encryptedOTP: String?
    let timestamp: Int64
}

private struct DirectState: Codable {
    var nextCursor: Int
    var pairings: [DirectPairing]
    var events: [DirectEvent]
}

private struct DirectHTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data
}

private struct DirectHTTPResponse {
    let statusCode: Int
    let body: Data
    let contentType: String

    init(statusCode: Int, body: Data, contentType: String = "application/json; charset=utf-8") {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
    }
}

private actor DirectLinkStore {
    private let fileURL: URL
    private let retentionMs: Int64 = 8 * 60 * 60 * 1000
    private var state: DirectState

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.state = Self.load(from: fileURL)
        compact()
        save()
    }

    func createPairing(
        macDeviceId: String,
        macDeviceName: String,
        androidDeviceId: String,
        androidDeviceName: String,
        sessionId: String
    ) -> DirectPairing {
        deactivatePairings(macDeviceId: macDeviceId, androidDeviceId: androidDeviceId)

        let now = currentTime()
        let pairing = DirectPairing(
            pairingId: makeId(prefix: "pairing"),
            macDeviceId: macDeviceId,
            macDeviceName: macDeviceName,
            androidDeviceId: androidDeviceId,
            androidDeviceName: androidDeviceName,
            sessionId: sessionId,
            status: "active",
            createdAt: now,
            updatedAt: now
        )

        state.pairings.append(pairing)
        save()
        return pairing
    }

    func latestPairing(for macDeviceId: String, sessionId: String) -> DirectPairing? {
        state.pairings
            .filter { $0.macDeviceId == macDeviceId && $0.status == "active" }
            .filter { sessionId.isEmpty ? true : $0.sessionId == sessionId }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    func pairing(_ pairingId: String) -> DirectPairing? {
        state.pairings.first { $0.pairingId == pairingId }
    }

    func deletePairing(_ pairingId: String) -> DirectPairing? {
        guard let index = state.pairings.firstIndex(where: { $0.pairingId == pairingId }) else {
            return nil
        }

        let existing = state.pairings[index]
        if existing.status != "active" {
            return existing
        }

        let deleted = DirectPairing(
            pairingId: existing.pairingId,
            macDeviceId: existing.macDeviceId,
            macDeviceName: existing.macDeviceName,
            androidDeviceId: existing.androidDeviceId,
            androidDeviceName: existing.androidDeviceName,
            sessionId: existing.sessionId,
            status: "deleted",
            createdAt: existing.createdAt,
            updatedAt: currentTime()
        )

        state.pairings[index] = deleted
        state.events.removeAll { $0.pairingId == pairingId }
        save()
        return deleted
    }

    func addEvent(
        pairingId: String,
        type: String,
        sourceDeviceId: String,
        sourceDeviceName: String,
        content: String?,
        encryptedOTP: String?
    ) -> (DirectEvent?, String?) {
        guard let pairingIndex = state.pairings.firstIndex(where: { $0.pairingId == pairingId }) else {
            return (nil, "not_found")
        }

        guard state.pairings[pairingIndex].status == "active" else {
            return (nil, "deleted")
        }

        let event = DirectEvent(
            id: state.nextCursor,
            pairingId: pairingId,
            type: type,
            sourceDeviceId: sourceDeviceId,
            sourceDeviceName: sourceDeviceName,
            content: content,
            encryptedOTP: encryptedOTP,
            timestamp: currentTime()
        )

        state.nextCursor += 1
        state.events.append(event)

        let pairing = state.pairings[pairingIndex]
        state.pairings[pairingIndex] = DirectPairing(
            pairingId: pairing.pairingId,
            macDeviceId: pairing.macDeviceId,
            macDeviceName: pairing.macDeviceName,
            androidDeviceId: pairing.androidDeviceId,
            androidDeviceName: pairing.androidDeviceName,
            sessionId: pairing.sessionId,
            status: pairing.status,
            createdAt: pairing.createdAt,
            updatedAt: currentTime()
        )

        compact()
        save()
        return (event, nil)
    }

    func listEvents(
        pairingId: String,
        after: Int,
        type: String,
        excludeDeviceId: String
    ) -> ([DirectEvent], Int, String?) {
        guard let pairing = state.pairings.first(where: { $0.pairingId == pairingId }) else {
            return ([], 0, "not_found")
        }

        guard pairing.status == "active" else {
            return ([], 0, "deleted")
        }

        let currentCursor = max(0, state.nextCursor - 1)
        let events = state.events
            .filter { $0.pairingId == pairingId }
            .filter { $0.id > after }
            .filter { type.isEmpty ? true : $0.type == type }
            .filter { excludeDeviceId.isEmpty ? true : $0.sourceDeviceId != excludeDeviceId }
            .sorted { $0.id < $1.id }

        let nextCursor = events.last?.id ?? currentCursor
        return (events, nextCursor, nil)
    }

    func clearClipboardEvents(pairingId: String) -> (Int, String?) {
        guard let pairing = state.pairings.first(where: { $0.pairingId == pairingId }) else {
            return (0, "not_found")
        }

        guard pairing.status == "active" else {
            return (0, "deleted")
        }

        let before = state.events.count
        state.events.removeAll { $0.pairingId == pairingId && $0.type == "clipboard" }
        let deleted = before - state.events.count
        save()
        return (deleted, nil)
    }

    private func deactivatePairings(macDeviceId: String, androidDeviceId: String) {
        let now = currentTime()
        state.pairings = state.pairings.map { pairing in
            guard pairing.status == "active",
                  pairing.macDeviceId == macDeviceId || pairing.androidDeviceId == androidDeviceId else {
                return pairing
            }

            return DirectPairing(
                pairingId: pairing.pairingId,
                macDeviceId: pairing.macDeviceId,
                macDeviceName: pairing.macDeviceName,
                androidDeviceId: pairing.androidDeviceId,
                androidDeviceName: pairing.androidDeviceName,
                sessionId: pairing.sessionId,
                status: "deleted",
                createdAt: pairing.createdAt,
                updatedAt: now
            )
        }

        let inactive = Set(state.pairings.filter { $0.status != "active" }.map(\.pairingId))
        state.events.removeAll { inactive.contains($0.pairingId) }
    }

    private func compact() {
        let cutoff = currentTime() - retentionMs
        let activePairingIds = Set(state.pairings.filter { $0.status == "active" }.map(\.pairingId))

        state.pairings.removeAll { pairing in
            pairing.status != "active" && pairing.updatedAt < cutoff
        }

        state.events.removeAll { event in
            event.timestamp < cutoff || !activePairingIds.contains(event.pairingId)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save direct-link store: \(error)")
        }
    }

    private static func load(from fileURL: URL) -> DirectState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(DirectState.self, from: data) else {
            return DirectState(nextCursor: 1, pairings: [], events: [])
        }
        return state
    }

    private func currentTime() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func makeId(prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }
}

final class DirectLinkServer: ObservableObject {
    static let shared = DirectLinkServer()

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var boundPort: Int?

    private let queue = DispatchQueue(label: "com.clipsync.directlink.server")
    private let store: DirectLinkStore
    private var listener: NWListener?

    private init() {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipSync", isDirectory: true)
            .appendingPathComponent("DirectLink", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClipSyncDirectLink", isDirectory: true)
        self.store = DirectLinkStore(fileURL: baseDirectory.appendingPathComponent("store.json"))
    }

    func startIfNeeded() {
        guard ServerConfiguration.shared.mode == .directLink else {
            stop()
            return
        }
        start(port: ServerConfiguration.shared.directPort)
    }

    func restart() {
        let existingListener = listener
        listener = nil
        existingListener?.cancel()
        DispatchQueue.main.async {
            self.isRunning = false
            self.boundPort = nil
        }
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startIfNeeded()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.boundPort = nil
        }
    }

    private func start(port: Int) {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            DispatchQueue.main.async { self.errorMessage = "Invalid direct-link port." }
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self.isRunning = true
                        self.errorMessage = nil
                        self.boundPort = port
                    }
                case .failed(let error):
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.errorMessage = error.localizedDescription
                        self.boundPort = nil
                    }
                case .cancelled:
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.boundPort = nil
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
                self.isRunning = false
                self.boundPort = nil
            }
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                print("Direct-link receive error: \(error)")
                connection.cancel()
                return
            }

            var updatedBuffer = buffer
            if let data, !data.isEmpty {
                updatedBuffer.append(data)
            }

            if let request = self.parseRequest(from: updatedBuffer) {
                Task {
                    let response = await self.process(request: request)
                    let payload = self.serialize(response: response)
                    connection.send(content: payload, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: updatedBuffer)
        }
    }

    private func parseRequest(from data: Data) -> DirectHTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestLineParts = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let target = String(requestLineParts[1])
        let components: URLComponents?
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            components = URLComponents(string: target)
        } else {
            components = URLComponents(string: "http://direct\(target)")
        }

        let queryItems = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        return DirectHTTPRequest(
            method: String(requestLineParts[0]),
            path: components?.path ?? target,
            queryItems: queryItems,
            headers: headers,
            body: body
        )
    }

    private func process(request: DirectHTTPRequest) async -> DirectHTTPResponse {
        if request.method == "GET", request.path == "/health" {
            return jsonResponse(statusCode: 200, payload: [
                "ok": true,
                "serverTime": Int(Date().timeIntervalSince1970 * 1000)
            ])
        }

        if request.method == "GET", request.path == "/api/v1/server" {
            guard isAuthorized(request) else {
                return errorResponse(statusCode: 401, message: "Unauthorized")
            }
            return jsonResponse(statusCode: 200, payload: ["ok": true])
        }

        guard isAuthorized(request) else {
            return errorResponse(statusCode: 401, message: "Unauthorized")
        }

        let parts = request.path.split(separator: "/").map(String.init)

        if request.method == "POST", request.path == "/api/v1/pairings" {
            guard let body = jsonBody(request),
                  let macDeviceId = requiredString(body["macDeviceId"]),
                  let macDeviceName = requiredString(body["macDeviceName"]),
                  let androidDeviceId = requiredString(body["androidDeviceId"]),
                  let androidDeviceName = requiredString(body["androidDeviceName"]) else {
                return errorResponse(statusCode: 400, message: "Invalid pairing payload")
            }

            let sessionId = requiredString(body["sessionId"]) ?? ""
            let pairing = await store.createPairing(
                macDeviceId: macDeviceId,
                macDeviceName: macDeviceName,
                androidDeviceId: androidDeviceId,
                androidDeviceName: androidDeviceName,
                sessionId: sessionId
            )
            return jsonResponse(statusCode: 201, payload: ["pairing": pairing.dictionaryValue])
        }

        if request.method == "GET",
           parts.count == 5,
           parts[0] == "api", parts[1] == "v1", parts[2] == "pairings", parts[3] == "by-mac" {
            let pairing = await store.latestPairing(
                for: parts[4],
                sessionId: request.queryItems["sessionId"] ?? ""
            )
            return jsonResponse(statusCode: 200, payload: ["pairing": pairing?.dictionaryValue ?? NSNull()])
        }

        guard parts.count >= 4,
              parts[0] == "api", parts[1] == "v1", parts[2] == "pairings" else {
            return errorResponse(statusCode: 404, message: "Not found")
        }

        let pairingId = parts[3]

        if request.method == "GET", parts.count == 4 {
            guard let pairing = await store.pairing(pairingId) else {
                return errorResponse(statusCode: 404, message: "Pairing not found")
            }
            if pairing.status != "active" {
                return errorResponse(statusCode: 410, message: "Pairing deleted")
            }
            return jsonResponse(statusCode: 200, payload: ["pairing": pairing.dictionaryValue])
        }

        if request.method == "DELETE", parts.count == 4 {
            guard let pairing = await store.deletePairing(pairingId) else {
                return errorResponse(statusCode: 404, message: "Pairing not found")
            }
            return jsonResponse(statusCode: 200, payload: ["pairing": pairing.dictionaryValue])
        }

        if request.method == "POST", parts.count == 5, parts[4] == "clipboard" {
            guard let body = jsonBody(request),
                  let sourceDeviceId = requiredString(body["sourceDeviceId"]),
                  let content = requiredString(body["content"]) else {
                return errorResponse(statusCode: 400, message: "Invalid clipboard payload")
            }

            let sourceDeviceName = requiredString(body["sourceDeviceName"]) ?? ""
            let (event, errorCode) = await store.addEvent(
                pairingId: pairingId,
                type: "clipboard",
                sourceDeviceId: sourceDeviceId,
                sourceDeviceName: sourceDeviceName,
                content: content,
                encryptedOTP: nil
            )
            if errorCode == "not_found" {
                return errorResponse(statusCode: 404, message: "Pairing not found")
            }
            if errorCode == "deleted" {
                return errorResponse(statusCode: 410, message: "Pairing deleted")
            }
            return jsonResponse(statusCode: 201, payload: ["event": event?.dictionaryValue ?? NSNull()])
        }

        if request.method == "DELETE", parts.count == 5, parts[4] == "clipboard" {
            let (deleted, errorCode) = await store.clearClipboardEvents(pairingId: pairingId)
            if errorCode == "not_found" {
                return errorResponse(statusCode: 404, message: "Pairing not found")
            }
            if errorCode == "deleted" {
                return errorResponse(statusCode: 410, message: "Pairing deleted")
            }
            return jsonResponse(statusCode: 200, payload: ["deleted": deleted])
        }

        if request.method == "POST", parts.count == 5, parts[4] == "otp" {
            guard let body = jsonBody(request),
                  let sourceDeviceId = requiredString(body["sourceDeviceId"]),
                  let encryptedOTP = requiredString(body["encryptedOTP"]) else {
                return errorResponse(statusCode: 400, message: "Invalid OTP payload")
            }

            let sourceDeviceName = requiredString(body["sourceDeviceName"]) ?? ""
            let (event, errorCode) = await store.addEvent(
                pairingId: pairingId,
                type: "otp",
                sourceDeviceId: sourceDeviceId,
                sourceDeviceName: sourceDeviceName,
                content: nil,
                encryptedOTP: encryptedOTP
            )
            if errorCode == "not_found" {
                return errorResponse(statusCode: 404, message: "Pairing not found")
            }
            if errorCode == "deleted" {
                return errorResponse(statusCode: 410, message: "Pairing deleted")
            }
            return jsonResponse(statusCode: 201, payload: ["event": event?.dictionaryValue ?? NSNull()])
        }

        if request.method == "GET", parts.count == 5, parts[4] == "events" {
            let after = Int(request.queryItems["after"] ?? "") ?? 0
            let type = request.queryItems["type"] ?? ""
            let excludeDeviceId = request.queryItems["excludeDeviceId"] ?? ""
            let (events, cursor, errorCode) = await store.listEvents(
                pairingId: pairingId,
                after: after,
                type: type,
                excludeDeviceId: excludeDeviceId
            )
            if errorCode == "not_found" {
                return errorResponse(statusCode: 404, message: "Pairing not found")
            }
            if errorCode == "deleted" {
                return errorResponse(statusCode: 410, message: "Pairing deleted")
            }
            return jsonResponse(
                statusCode: 200,
                payload: ["events": events.map(\.dictionaryValue), "cursor": cursor]
            )
        }

        return errorResponse(statusCode: 404, message: "Not found")
    }

    private func isAuthorized(_ request: DirectHTTPRequest) -> Bool {
        request.headers["x-clipsync-key"] == ServerConfiguration.shared.normalizedApiKey
    }

    private func jsonBody(_ request: DirectHTTPRequest) -> [String: Any]? {
        guard !request.body.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
    }

    private func requiredString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func jsonResponse(statusCode: Int, payload: [String: Any]) -> DirectHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return DirectHTTPResponse(statusCode: statusCode, body: body)
    }

    private func errorResponse(statusCode: Int, message: String) -> DirectHTTPResponse {
        jsonResponse(statusCode: statusCode, payload: ["error": message])
    }

    private func serialize(response: DirectHTTPResponse) -> Data {
        let reasonPhrase: String = switch response.statusCode {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 410: "Gone"
        default: "Error"
        }

        var header = "HTTP/1.1 \(response.statusCode) \(reasonPhrase)\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"

        var data = Data(header.utf8)
        data.append(response.body)
        return data
    }
}

private extension Encodable {
    var dictionaryValue: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}
