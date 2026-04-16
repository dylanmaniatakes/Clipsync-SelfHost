import Combine
import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

final class QRCodeGenerator: ObservableObject {
    static let shared = QRCodeGenerator()

    @Published var qrImage: NSImage?
    @Published var pairingCode: String = ""
    @Published private(set) var sessionId: String = ""

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()
    private let serverConfiguration = ServerConfiguration.shared

    private var sharedSecretHex: String {
        if let savedKey = KeychainManager.load(key: "encryption_key"), !savedKey.isEmpty {
            return savedKey
        }

        let newKey = generateRandomHexKey()
        KeychainManager.save(key: "encryption_key", value: newKey)
        return newKey
    }

    func generateQRCode() {
        let newSessionId = generateSessionId()
        sessionId = newSessionId

        var payload: [String: Any] = [
            "macId": DeviceManager.shared.getDeviceId(),
            "deviceName": DeviceManager.shared.getMacName(),
            "secret": sharedSecretHex,
            "sessionId": newSessionId
        ]

        if serverConfiguration.mode == .directLink {
            let directURLs = serverConfiguration.directCandidateBaseURLs
            payload["serverUrl"] = directURLs.first ?? ""
            payload["directUrls"] = directURLs
            payload["hostCandidates"] = DeviceManager.shared.getNetworkHostCandidates()
            payload["apiKey"] = serverConfiguration.normalizedApiKey
            payload["connectionMode"] = "direct"
        }

        guard
            let jsonData = try? JSONSerialization.data(withJSONObject: payload),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            return
        }

        pairingCode = jsonString
        filter.setValue(Data(jsonString.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else {
            return
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return
        }

        qrImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height)
        )
    }

    private func generateRandomHexKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            // SecRandomCopyBytes failure is extremely unlikely; derive 32 bytes from two UUIDs.
            let fallback = (UUID().uuid, UUID().uuid)
            let b = [fallback.0.0, fallback.0.1, fallback.0.2, fallback.0.3,
                     fallback.0.4, fallback.0.5, fallback.0.6, fallback.0.7,
                     fallback.0.8, fallback.0.9, fallback.0.10, fallback.0.11,
                     fallback.0.12, fallback.0.13, fallback.0.14, fallback.0.15,
                     fallback.1.0, fallback.1.1, fallback.1.2, fallback.1.3,
                     fallback.1.4, fallback.1.5, fallback.1.6, fallback.1.7,
                     fallback.1.8, fallback.1.9, fallback.1.10, fallback.1.11,
                     fallback.1.12, fallback.1.13, fallback.1.14, fallback.1.15]
            return b.map { String(format: "%02hhX", $0) }.joined()
        }

        return bytes.map { String(format: "%02hhX", $0) }.joined()
    }

    private func generateSessionId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }

        return bytes.map { String(format: "%02hhX", $0) }.joined()
    }
}
