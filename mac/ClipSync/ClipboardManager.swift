import AppKit
import Combine
import CryptoKit
import Foundation

final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published var history: [ClipboardItem] = []
    @Published var isSyncPaused: Bool = false
    @Published var lastSyncedTime: Date?

    var syncToMac: Bool {
        UserDefaults.standard.bool(forKey: "syncToMac")
    }

    var syncFromMac: Bool {
        UserDefaults.standard.bool(forKey: "syncFromMac")
    }

    private let pasteboard = NSPasteboard.general
    private var timer: DispatchSourceTimer?
    private var clipboardTask: Task<Void, Never>?
    private var lastChangeCount = 0
    private var lastCopiedText: String = ""
    private var ignoreNextChange = false

    private var sharedSecretHex: String {
        UserDefaults.standard.string(forKey: "encryption_key") ?? Secrets.fallbackEncryptionKey
    }

    func startMonitoring() {
        if isSyncPaused { return }
        stopMonitoring()

        lastChangeCount = pasteboard.changeCount

        let queue = DispatchQueue(label: "com.clipsync.clipboard.monitor", qos: .userInitiated)
        let newTimer = DispatchSource.makeTimerSource(queue: queue)

        newTimer.schedule(deadline: .now(), repeating: .milliseconds(300), leeway: .milliseconds(50))
        newTimer.setEventHandler { [weak self] in
            self?.checkClipboard()
        }

        newTimer.resume()
        timer = newTimer
    }

    func toggleSync() {
        isSyncPaused.toggle()
        if isSyncPaused {
            stopMonitoring()
            stopListening()
        } else {
            startMonitoring()
            listenForAndroidClipboard()
        }
    }

    func pullClipboard() {
        stopListening()
        listenForAndroidClipboard()
    }

    func clearHistory() {
        history.removeAll()
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
    }

    private func checkClipboard() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        if ignoreNextChange {
            ignoreNextChange = false
            return
        }

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        guard text != lastCopiedText else { return }
        lastCopiedText = text
        guard syncFromMac else { return }

        uploadClipboard(text: text)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.history.first?.content == text { return }

            self.history.insert(
                ClipboardItem(
                    content: text,
                    timestamp: Date(),
                    deviceName: "Mac",
                    direction: .sent
                ),
                at: 0
            )
            self.lastSyncedTime = Date()
        }
    }

    private func uploadClipboard(text: String) {
        guard let pairingId = PairingManager.shared.pairingId else { return }
        guard let encryptedContent = encrypt(text) else { return }

        Task {
            do {
                try await ServerAPI.shared.sendClipboard(
                    pairingId: pairingId,
                    sourceDeviceId: DeviceManager.shared.getDeviceId(),
                    sourceDeviceName: DeviceManager.shared.getFriendlyMacName(),
                    content: encryptedContent
                )
            } catch {
                print("Error uploading clipboard: \(error)")
            }
        }
    }

    func listenForAndroidClipboard(retryCount: Int = 0) {
        guard let pairingId = PairingManager.shared.pairingId else {
            if retryCount < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.listenForAndroidClipboard(retryCount: retryCount + 1)
                }
            }
            return
        }

        stopListening()
        let macDeviceId = DeviceManager.shared.getDeviceId()

        clipboardTask = Task { [weak self] in
            guard let self else { return }
            var cursor = 0

            while !Task.isCancelled {
                if self.isSyncPaused || !self.syncToMac {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                do {
                    let response = try await ServerAPI.shared.fetchEvents(
                        pairingId: pairingId,
                        after: cursor,
                        type: "clipboard",
                        excludeDeviceId: macDeviceId
                    )
                    cursor = response.cursor

                    for event in response.events {
                        guard let encryptedContent = event.content else { continue }
                        let content = self.decrypt(encryptedContent) ?? encryptedContent
                        guard content != self.lastCopiedText else { continue }

                        await MainActor.run {
                            self.ignoreNextChange = true
                            self.pasteboard.clearContents()
                            self.pasteboard.setString(content, forType: .string)
                            self.lastCopiedText = content

                            if self.history.first?.content != content {
                                self.history.insert(
                                    ClipboardItem(
                                        content: content,
                                        timestamp: Date(),
                                        deviceName: PairingManager.shared.pairedDeviceName,
                                        direction: .received
                                    ),
                                    at: 0
                                )
                            }

                            self.lastSyncedTime = Date()
                        }
                    }
                } catch ServerAPIError.notFound, ServerAPIError.pairingDeleted {
                    await MainActor.run {
                        PairingManager.shared.unpair()
                    }
                    return
                } catch {
                    print("Clipboard poll error: \(error)")
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopListening() {
        clipboardTask?.cancel()
        clipboardTask = nil
    }

    private func encrypt(_ string: String) -> String? {
        guard let data = string.data(using: .utf8) else { return nil }

        do {
            let keyData = hexToData(hex: sharedSecretHex)
            let key = SymmetricKey(data: keyData)
            let sealedBox = try AES.GCM.seal(data, using: key)
            return sealedBox.combined?.base64EncodedString()
        } catch {
            return nil
        }
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
