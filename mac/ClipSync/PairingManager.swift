import Combine
import Foundation

final class PairingManager: ObservableObject {
    static let shared = PairingManager()

    @Published var isPaired: Bool = UserDefaults.standard.string(forKey: "current_pairing_id") != nil
    @Published var pairedDeviceName: String = UserDefaults.standard.string(forKey: "paired_device_name") ?? ""
    @Published var pairingId: String? = UserDefaults.standard.string(forKey: "current_pairing_id")
    @Published var isSetupComplete: Bool = UserDefaults.standard.bool(forKey: "is_setup_complete")
    @Published var pairingError: String? = nil

    private var pairingTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    func listenForPairing(macDeviceId: String, sessionId: String) {
        guard !isPaired else { return }

        stopListening()

        DispatchQueue.main.async {
            self.pairingError = nil
        }

        pairingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled && !self.isPaired {
                do {
                    if let pairing = try await ServerAPI.shared.fetchLatestPairing(
                        for: macDeviceId,
                        sessionId: sessionId
                    ) {
                        self.processPairing(pairing)
                        return
                    }
                } catch let error as ServerAPIError {
                    await MainActor.run {
                        self.pairingError = error.localizedDescription
                    }
                } catch {
                    await MainActor.run {
                        self.pairingError = error.localizedDescription
                    }
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func processPairing(_ pairing: ServerPairing) {
        DispatchQueue.main.async {
            self.pairingId = pairing.pairingId
            self.pairedDeviceName = pairing.androidDeviceName
            self.isPaired = true
            self.pairingError = nil
        }

        UserDefaults.standard.set(pairing.pairingId, forKey: "current_pairing_id")
        UserDefaults.standard.set(pairing.androidDeviceName, forKey: "paired_device_name")

        startMonitoringPairingStatus(pairingId: pairing.pairingId)
        stopListening()
    }

    func startMonitoringPairingStatus(pairingId: String) {
        monitorTask?.cancel()

        monitorTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    _ = try await ServerAPI.shared.getPairing(pairingId)
                } catch ServerAPIError.notFound, ServerAPIError.pairingDeleted {
                    self.unpair()
                    return
                } catch {
                    // Ignore transient network errors and try again on the next pass.
                }

                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopListening() {
        pairingTask?.cancel()
        pairingTask = nil
    }

    func clearPairing(
        onSuccess: @escaping () -> Void = {},
        onFailure: @escaping (Error) -> Void = { _ in }
    ) {
        guard let pairingId else {
            unpair()
            DispatchQueue.main.async {
                onSuccess()
            }
            return
        }

        Task { [weak self] in
            do {
                try await ServerAPI.shared.deletePairing(pairingId)
                await MainActor.run {
                    self?.unpair()
                    onSuccess()
                }
            } catch ServerAPIError.notFound, ServerAPIError.pairingDeleted {
                await MainActor.run {
                    self?.unpair()
                    onSuccess()
                }
            } catch {
                await MainActor.run {
                    self?.unpair()
                    onFailure(error)
                }
            }
        }
    }

    func unpair() {
        stopListening()
        monitorTask?.cancel()
        monitorTask = nil

        DispatchQueue.main.async {
            self.isPaired = false
            self.pairedDeviceName = ""
            self.pairingId = nil
            self.isSetupComplete = false
            self.pairingError = nil
        }

        UserDefaults.standard.removeObject(forKey: "current_pairing_id")
        UserDefaults.standard.removeObject(forKey: "paired_device_name")
        UserDefaults.standard.removeObject(forKey: "is_setup_complete")
        UserDefaults.standard.removeObject(forKey: "encryption_key")

        ClipboardManager.shared.clearHistory()
        ClipboardManager.shared.stopMonitoring()
        ClipboardManager.shared.stopListening()
        OTPNotificationManager.shared.stopListening()
    }

    func restorePairing() {
        if let savedPairingId = UserDefaults.standard.string(forKey: "current_pairing_id"),
           let savedDeviceName = UserDefaults.standard.string(forKey: "paired_device_name") {

            let currentBootTime = getCurrentBootTime()
            let savedBootTime = UserDefaults.standard.double(forKey: "last_boot_time")

            if abs(currentBootTime - savedBootTime) > 120 {
                unpair()
                return
            }

            pairingId = savedPairingId
            pairedDeviceName = savedDeviceName
            isPaired = true
            isSetupComplete = UserDefaults.standard.bool(forKey: "is_setup_complete")
            startMonitoringPairingStatus(pairingId: savedPairingId)
        }
    }

    func completeSetup() {
        DispatchQueue.main.async {
            self.isSetupComplete = true
        }
        UserDefaults.standard.set(true, forKey: "is_setup_complete")
        UserDefaults.standard.set(getCurrentBootTime(), forKey: "last_boot_time")
    }

    private func getCurrentBootTime() -> TimeInterval {
        Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    }
}
