import Foundation
import CryptoKit

struct SessionInfo: Decodable {
    let sessionId: String
    let secret: String
    let serverTime: Double   // بالميلي ثانية
}

struct ServerDecision: Decodable {
    let status: String       // ok | warn | ban
    let reasons: [String]
}

enum ServiceError: Error {
    case banned
    case http(Int)
    case badResponse
}

enum ReportService {

    /// عنوان السيرفر على Render.
    static let baseURL = URL(string: "https://ipadtools.onrender.com")!

    // MARK: - الجلسة

    static func startSession(playerId: String) async throws -> SessionInfo {
        let body = try JSONSerialization.data(withJSONObject: ["playerId": playerId])
        let data = try await post("/session", body: body)
        guard let info = try? JSONDecoder().decode(SessionInfo.self, from: data) else {
            throw ServiceError.badResponse
        }
        return info
    }

    // MARK: - إرسال التقرير

    private struct ReportBody: Encodable {
        let sessionId: String
        let playerId: String
        let timestamp: Int64
        let flags: Flags
        let signature: String

        struct Flags: Encodable {
            let jailbroken: Bool
            let debuggerAttached: Bool
            let injectedLibrary: Bool
            let screenCaptured: Bool
            let timeTampered: Bool
            let leftApp: Bool
            let simulator: Bool
        }
    }

    static func send(session: SessionInfo, playerId: String, result: DetectionResult) async throws -> ServerDecision {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        func b(_ v: Bool) -> String { v ? "1" : "0" }

        // لازم نفس الترتيب بالضبط في السيرفر
        let canonical = [
            session.sessionId, playerId, String(ts),
            b(result.jailbroken), b(result.debuggerAttached), b(result.injectedLibrary),
            b(result.screenCaptured), b(result.timeTampered), b(result.leftApp), b(result.simulator)
        ].joined(separator: "|")

        let body = ReportBody(
            sessionId: session.sessionId,
            playerId: playerId,
            timestamp: ts,
            flags: .init(
                jailbroken: result.jailbroken,
                debuggerAttached: result.debuggerAttached,
                injectedLibrary: result.injectedLibrary,
                screenCaptured: result.screenCaptured,
                timeTampered: result.timeTampered,
                leftApp: result.leftApp,
                simulator: result.simulator
            ),
            signature: sign(canonical, secret: session.secret)
        )

        let data = try await post("/report", body: JSONEncoder().encode(body))
        guard let decision = try? JSONDecoder().decode(ServerDecision.self, from: data) else {
            throw ServiceError.badResponse
        }
        return decision
    }

    // MARK: - أدوات

    private static func sign(_ message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func post(_ path: String, body: Data) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 60   // السيرفر المجاني على Render يحتاج وقت يصحى أول مرة
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.badResponse }
        switch http.statusCode {
        case 200: return data
        case 403: throw ServiceError.banned
        default:  throw ServiceError.http(http.statusCode)
        }
    }
}
