import Foundation
import SwiftUI

struct QRGenScreen: View {
    @StateObject private var qrGenerator = QRCodeGenerator.shared
    @StateObject private var pairingManager = PairingManager.shared
    @StateObject private var serverConfiguration = ServerConfiguration.shared

    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var isValidating = false
    @State private var navigateToConnected = false

    #if DEBUG
    @ObserveInjection var forceRedraw
    #endif

    var body: some View {
        ZStack {
            MeshBackground()
                .ignoresSafeArea()

            HStack(spacing: 36) {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Point your phone at this QR code after both devices are pointed at your own server.")
                        .font(.custom("SF Pro Display", size: 34))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .lineSpacing(4)

                    instructionRow(number: "1", text: "Enter the self-hosted server URL.")
                    instructionRow(number: "2", text: "Paste the shared API key from the server.")
                    instructionRow(number: "3", text: "Save, then scan the QR code from Android.")

                    if let successMessage {
                        statusPill(text: successMessage, color: Color.green.opacity(0.85))
                    }

                    if let errorMessage {
                        statusPill(text: errorMessage, color: Color.red.opacity(0.85))
                    }
                }
                .frame(width: 300, alignment: .leading)

                VStack(spacing: 16) {
                    serverCard
                    qrCard
                }
                .frame(width: 220)
            }
            .frame(width: 590, height: 590)
        }
        .onAppear {
            serverURL = serverConfiguration.baseURL
            apiKey = serverConfiguration.apiKey
            if serverConfiguration.hasConfiguration {
                refreshQRCodeAndListener()
            }
        }
        .onDisappear {
            if !pairingManager.isPaired {
                pairingManager.stopListening()
            }
        }
        .onChange(of: pairingManager.isPaired) { oldValue, newValue in
            if oldValue == false && newValue == true {
                navigateToConnected = true
            }
        }
        .navigationDestination(isPresented: $navigateToConnected) {
            ConnectedScreen()
        }
        .enableInjection()
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Self-Hosted Server")
                .font(.custom("SF Pro Display", size: 20))
                .fontWeight(.bold)
                .foregroundColor(.white)

            TextField("http://192.168.1.10:8787", text: $serverURL)
                .textFieldStyle(.roundedBorder)

            SecureField("API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button(action: saveAndValidate) {
                    Text(isValidating ? "Checking..." : "Save")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isValidating)

                Button(action: refreshQRCodeAndListener) {
                    Text("Refresh QR")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!serverConfiguration.hasConfiguration)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.2))
        )
    }

    private var qrCard: some View {
        VStack(spacing: 12) {
            Text(pairingManager.isPaired ? "Paired" : "Waiting for Android")
                .font(.custom("SF Pro Display", size: 18))
                .fontWeight(.bold)
                .foregroundColor(.white)

            Group {
                if let qrImage = qrGenerator.qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                } else {
                    ProgressView()
                }
            }
            .frame(width: 150, height: 150)
            .padding(12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text(DeviceManager.shared.getFriendlyMacName())
                .font(.custom("SF Pro", size: 14))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.2))
        )
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.28))
                Text(number)
                    .font(.custom("SF Pro Display", size: 16))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            .frame(width: 34, height: 34)

            Text(text)
                .font(.custom("SF Pro", size: 18))
                .foregroundColor(Color.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusPill(text: String, color: Color) -> some View {
        Text(text)
            .font(.custom("SF Pro", size: 13))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(color))
    }

    private func saveAndValidate() {
        errorMessage = nil
        successMessage = nil

        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter both the server URL and API key."
            return
        }

        isValidating = true

        Task {
            do {
                try await ServerAPI.shared.validateConfiguration(baseURL: serverURL, apiKey: apiKey)
                await MainActor.run {
                    serverConfiguration.save(baseURL: serverURL, apiKey: apiKey)
                    successMessage = "Connected to your self-hosted server."
                    isValidating = false
                    refreshQRCodeAndListener()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isValidating = false
                }
            }
        }
    }

    private func refreshQRCodeAndListener() {
        guard serverConfiguration.hasConfiguration else { return }
        qrGenerator.generateQRCode()
        pairingManager.listenForPairing(macDeviceId: DeviceManager.shared.getDeviceId())
    }
}

#Preview {
    QRGenScreen()
}
