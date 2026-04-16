// DeviceManager.swift
// Manages the stable device identity for this Mac instance and provides
// human-readable device names used in pairing and Firestore documents.

import Foundation
import IOKit

// MARK: - DeviceManager

class DeviceManager {
    static let shared = DeviceManager()

    private let deviceIdKey = "mac_device_id"

    // MARK: - Identity

    /// Returns the persisted device UUID, generating and saving one on first call.
    func getDeviceId() -> String {
        if let existingId = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existingId
        }

        let deviceId = UUID().uuidString
        UserDefaults.standard.set(deviceId, forKey: deviceIdKey)
        return deviceId
    }


    /// Returns the macOS host name (e.g. "John's MacBook Pro").
    func getMacName() -> String {
        return Host.current().localizedName ?? "Mac"
    }

    /// Returns stable hostname candidates Android can try when the current IP changes.
    func getNetworkHostCandidates() -> [String] {
        let rawCandidates = [
            Host.current().name,
            ProcessInfo.processInfo.hostName,
            Host.current().localizedName
        ]

        var candidates: [String] = []

        for rawValue in rawCandidates {
            guard let normalized = normalizeHostCandidate(rawValue) else { continue }
            appendUnique(normalized, to: &candidates)

            if normalized.contains(".") {
                let shortName = normalized.split(separator: ".").first.map(String.init) ?? normalized
                appendUnique(shortName, to: &candidates)
                appendUnique("\(shortName).local", to: &candidates)
            } else {
                appendUnique("\(normalized).local", to: &candidates)
            }
        }

        return candidates
    }


    /// Formats the host name into a "John's Mac" style string suitable for the paired device UI.
    func getFriendlyMacName() -> String {
        let fullName = getMacName()
        let components = fullName.split(separator: " ")
        if let firstWord = components.first {
            let name = String(firstWord)
            if name.hasSuffix("'s") || name.hasSuffix("’s") {
                return "\(name) Mac"
            }
            return "\(name)'s Mac"
        }
        return "My Mac"
    }

    private func normalizeHostCandidate(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        let mapped = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }

        let collapsed = String(mapped)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))

        return collapsed.isEmpty ? nil : collapsed
    }

    private func appendUnique(_ value: String, to array: inout [String]) {
        guard !value.isEmpty, !array.contains(value) else { return }
        array.append(value)
    }
}
