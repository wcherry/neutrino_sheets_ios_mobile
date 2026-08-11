import Foundation
import UIKit

// MARK: - DeviceIdentity

/// This installation's identity, as the Neutrino auth service records it.
///
/// Phase 1 lists "Device registration" under Authentication. There is no separate registration
/// endpoint on the server: a device is registered by naming itself in the `X-Device-Name` header
/// when it logs in, which is what populates `device_name` on the session row that
/// `GET /api/v1/auth/sessions` later lists and `DELETE /api/v1/auth/sessions/{id}` revokes.
/// Registration is therefore a property of login, not a call of its own — and this type is what
/// login sends.
enum DeviceIdentity {

    // MARK: - Keys

    static let deviceNameKey = "ndoc.device_name"

    // MARK: - Device name

    /// The name this device registers under, e.g. "Will's iPhone — Neutrino Sheets".
    ///
    /// A user-set override wins; otherwise the device's own name is used. The app name is appended
    /// so the sessions list distinguishes this app from Drive and Notes on the same hardware, which
    /// otherwise all report the identical `UIDevice.name`.
    static var deviceName: String {
        if let custom = UserDefaults.standard.string(forKey: deviceNameKey),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return "\(UIDevice.current.name) — Neutrino Sheets"
    }

    /// Overrides the registered device name. Passing nil (or blank) restores the default.
    static func setDeviceName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: deviceNameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: deviceNameKey)
        }
    }

    /// Header value pair sent on login. Kept here so `AuthService` and its tests agree on it.
    static let deviceNameHeader = "X-Device-Name"
}

// MARK: - DeviceSession

/// One registered device (an active refresh-token session) from `GET /api/v1/auth/sessions`.
struct DeviceSession: Identifiable, Hashable, Decodable {

    // MARK: - Properties

    let id: String
    /// What the device called itself via `X-Device-Name` at login. Nil for clients that sent none.
    let deviceName: String?
    let userAgent: String?
    let ipAddress: String?
    let createdAt: Date
    let lastUsedAt: Date?

    // MARK: - Init

    init(id: String, deviceName: String?, userAgent: String? = nil, ipAddress: String? = nil,
         createdAt: Date, lastUsedAt: Date? = nil) {
        self.id = id
        self.deviceName = deviceName
        self.userAgent = userAgent
        self.ipAddress = ipAddress
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    // MARK: - Display

    /// Name to show in the devices list, falling back through the user agent to a generic label
    /// rather than leaving the row blank.
    var displayName: String {
        if let deviceName, !deviceName.trimmingCharacters(in: .whitespaces).isEmpty {
            return deviceName
        }
        if let userAgent, !userAgent.trimmingCharacters(in: .whitespaces).isEmpty {
            return userAgent
        }
        return "Unknown device"
    }

    /// True when this row is the device the app is running on, matched by the name it registered
    /// under. The server does not mark the caller's own session, and the session id is not
    /// something the token exchange hands back, so the registered name is the only join available.
    var isCurrentDevice: Bool {
        deviceName == DeviceIdentity.deviceName
    }

    /// "Last used 2 Aug 2026 at 09:20", or the creation date when it has never been used since.
    var lastUsedText: String {
        let date = lastUsedAt ?? createdAt
        let prefix = lastUsedAt == nil ? "Registered" : "Last used"
        return "\(prefix) \(Self.formatter.string(from: date))"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Decoding

    /// Session timestamps are `NaiveDateTime` — Drive's zone-less shape.
    static let decoder: JSONDecoder = DriveDate.makeDecoder()
}
