import Foundation
import os.log
import NeutrinoCore
import NeutrinoAuth

// MARK: - DeviceSessionError

enum DeviceSessionError: LocalizedError {
    case notAuthenticated
    case networkError(underlying: Error)
    case serverError(statusCode: Int)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:       return "You are not signed in."
        case .networkError:           return "A network error occurred. Please check your connection."
        case .serverError(let code):  return "Server error (\(code))."
        case .decodingError(let err): return "Failed to read server response: \(err.localizedDescription)"
        }
    }
}

// MARK: - DeviceSessionService

/// The visible half of device registration: lists the devices registered against this account and
/// revokes them.
///
/// Registration itself happens at login (`AuthService` sends `X-Device-Name`); this service reads
/// the result back from `GET /api/v1/auth/sessions` and can revoke a device with
/// `DELETE /api/v1/auth/sessions/{id}`.
@MainActor
final class DeviceSessionService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var sessions: [DeviceSession] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    // MARK: - Dependencies

    /// Set once at app launch so the service can refresh tokens before requests.
    weak var authService: AuthService?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoSheets",
                                category: "DeviceSessionService")

    private let session: URLSession

    private var baseURL: String { AuthService.baseURL }

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Load

    /// Loads the registered devices, current device first and then most recently used.
    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let data = try await request(method: "GET", path: "/api/v1/auth/sessions")
            let response = try DeviceSession.decoder.decode(APISessionListResponse.self, from: data)
            sessions = response.sessions.sorted(by: Self.byRecency)
            logger.debug("loaded \(self.sessions.count) registered device(s)")
        } catch {
            logger.error("load failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Revoke

    /// Revokes one registered device. Optimistic: the row goes immediately and comes back if the
    /// server refuses.
    func revoke(sessionID: String) async {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let removed = sessions.remove(at: index)
        do {
            _ = try await request(method: "DELETE", path: "/api/v1/auth/sessions/\(sessionID)")
            logger.debug("revoked device session")
        } catch {
            logger.error("revoke failed: \(error, privacy: .public)")
            sessions.insert(removed, at: index)
            sessions.sort(by: Self.byRecency)
            self.error = error.localizedDescription
        }
    }

    // MARK: - Ordering

    /// This device first, then most recently used. Somebody checking their registered devices is
    /// looking for the ones they do not recognise, so the one they are holding gets out of the way
    /// at the top rather than hiding in the middle of the list.
    private static func byRecency(_ lhs: DeviceSession, _ rhs: DeviceSession) -> Bool {
        if lhs.isCurrentDevice != rhs.isCurrentDevice { return lhs.isCurrentDevice }
        return (lhs.lastUsedAt ?? lhs.createdAt) > (rhs.lastUsedAt ?? rhs.createdAt)
    }

    // MARK: - HTTP

    private func request(method: String, path: String) async throws -> Data {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw DeviceSessionError.notAuthenticated
        }
        guard let url = URL(string: baseURL + path) else {
            throw DeviceSessionError.serverError(statusCode: 0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req, retry: .default)
        } catch {
            throw DeviceSessionError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DeviceSessionError.serverError(statusCode: 0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw DeviceSessionError.serverError(statusCode: http.statusCode)
        }
        return data
    }
}

// MARK: - API Response Models

private struct APISessionListResponse: Decodable {
    let sessions: [DeviceSession]
}
