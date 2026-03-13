import AppKit
import Combine
import CryptoKit
import Foundation

protocol OTPNotificationDelegate: AnyObject {
    var statusItem: NSStatusItem? { get }
}

final class OTPNotificationManager: ObservableObject {
    static let shared = OTPNotificationManager()

    @Published var lastOTPCode: String? = nil
    @Published var showOTPIndicator = false

    private var lastOTPTime: Date?
    private var pollTask: Task<Void, Never>?
    private var currentBubbleWindow: OTPBubbleWindow?

    weak var delegate: OTPNotificationDelegate?

    private var sharedSecretHex: String {
        UserDefaults.standard.string(forKey: "encryption_key") ?? Secrets.fallbackEncryptionKey
    }

    var hasRecentOTP: Bool {
        guard let lastTime = lastOTPTime, lastOTPCode != nil else { return false }
        return Date().timeIntervalSince(lastTime) < 60
    }

    private init() {}

    func startListening(retryCount: Int = 0) {
        guard let pairingId = PairingManager.shared.pairingId else {
            if retryCount < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.startListening(retryCount: retryCount + 1)
                }
            }
            return
        }

        stopListening()
        let macDeviceId = DeviceManager.shared.getDeviceId()

        pollTask = Task { [weak self] in
            guard let self else { return }
            var cursor = 0

            while !Task.isCancelled {
                do {
                    let response = try await ServerAPI.shared.fetchEvents(
                        pairingId: pairingId,
                        after: cursor,
                        type: "otp",
                        excludeDeviceId: macDeviceId
                    )
                    cursor = response.cursor

                    for event in response.events {
                        guard let encryptedOTP = event.encryptedOTP,
                              let decryptedOTP = self.decrypt(encryptedOTP),
                              self.lastOTPCode != decryptedOTP
                        else {
                            continue
                        }

                        await MainActor.run {
                            self.handleOTPDetected(otpCode: decryptedOTP)
                        }
                    }
                } catch ServerAPIError.notFound, ServerAPIError.pairingDeleted {
                    await MainActor.run {
                        PairingManager.shared.unpair()
                    }
                    return
                } catch {
                    print("OTP poll error: \(error)")
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func handleOTPDetected(otpCode: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(otpCode, forType: .string)

        lastOTPCode = otpCode
        lastOTPTime = Date()
        showOTPIndicator = true

        pingMenuBar(with: otpCode)
        NSSound(named: "Tink")?.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.showOTPIndicator = false
        }
    }

    func reshowLastBubble() {
        guard let otpCode = lastOTPCode, hasRecentOTP else { return }
        pingMenuBar(with: otpCode)
    }

    private func pingMenuBar(with otpCode: String) {
        guard let appDelegate = delegate, let button = appDelegate.statusItem?.button else {
            return
        }

        button.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak button] in
            button?.contentTintColor = nil
        }

        currentBubbleWindow?.contentView = nil
        currentBubbleWindow?.close()
        currentBubbleWindow = nil

        let bubbleWindow = OTPBubbleWindow(otpCode: otpCode, statusItemButton: button)
        currentBubbleWindow = bubbleWindow
        bubbleWindow.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            self?.currentBubbleWindow?.contentView = nil
            self?.currentBubbleWindow?.close()
            self?.currentBubbleWindow = nil
        }

        animateMenuBarIcon(button: button)
    }

    private func animateMenuBarIcon(button: NSStatusBarButton) {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 1.2, 0.9, 1.1, 1.0]
        animation.keyTimes = [0, 0.2, 0.4, 0.6, 0.8]
        animation.duration = 0.5
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        button.layer?.add(animation, forKey: "bounce")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak button] in
            button?.layer?.removeAnimation(forKey: "bounce")
        }
    }

    func stopListening() {
        pollTask?.cancel()
        pollTask = nil
    }

    deinit {
        stopListening()
    }

    private func decrypt(_ base64String: String) -> String? {
        guard let data = Data(base64Encoded: base64String) else { return nil }

        do {
            let keyData = hexToData(hex: sharedSecretHex)
            let key = SymmetricKey(data: keyData)
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            return String(data: decryptedData, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func hexToData(hex: String) -> Data {
        var data = Data()
        var temp = ""
        for char in hex {
            temp.append(char)
            if temp.count == 2 {
                if let byte = UInt8(temp, radix: 16) {
                    data.append(byte)
                }
                temp = ""
            }
        }
        return data
    }
}
