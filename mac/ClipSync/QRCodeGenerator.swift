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

    private var sharedSecretHex: String {
        if let savedKey = UserDefaults.standard.string(forKey: "encryption_key"), !savedKey.isEmpty {
            return savedKey
        }

        let newKey = generateRandomHexKey()
        UserDefaults.standard.set(newKey, forKey: "encryption_key")
        return newKey
    }

    func generateQRCode() {
        let newSessionId = generateSessionId()
        sessionId = newSessionId

        let payload: [String: String] = [
            "macId": DeviceManager.shared.getDeviceId(),
            "deviceName": DeviceManager.shared.getMacName(),
            "secret": sharedSecretHex,
            "sessionId": newSessionId
        ]

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
            return Secrets.fallbackEncryptionKey
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
