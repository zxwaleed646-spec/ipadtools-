import SwiftUI
import UIKit

@MainActor
final class AntiCheatViewModel: ObservableObject {

    enum Status { case idle, ok, warn, banned, error }

    @Published var status: Status = .idle
    @Published var message: String = ""

    let playerId: String

    private var session: SessionInfo?
    private var clock: ClockGuard?
    private var loopTask: Task<Void, Never>?
    private var leftApp = false

    private static let reasonLabels: [String: String] = [
        "jailbroken": "الجهاز مكسور الحماية",
        "debugger": "أداة تصحيح (Debugger) مربوطة بالتطبيق",
        "injected_library": "مكتبة حقن (مثل Frida) محملة",
        "screen_captured": "تسجيل الشاشة أو مشاركتها شغال",
        "time_tampered": "وقت الجهاز غير صحيح",
        "simulator": "التطبيق يشتغل على محاكي"
    ]

    init() {
        let key = "playerId"
        if let saved = UserDefaults.standard.string(forKey: key) {
            playerId = saved
        } else {
            let new = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            UserDefaults.standard.set(new, forKey: key)
            playerId = new
        }
    }

    // MARK: - التحكم

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await loop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        session = nil
        clock = nil
        status = .idle
        message = ""
    }

    func markLeftApp() { leftApp = true }

    /// فحص فوري (مثلاً عند بدء تسجيل الشاشة)
    func checkNow() {
        Task { await runCheck() }
    }

    // MARK: - الحلقة

    private func loop() async {
        clock = ClockGuard()

        // نكرر المحاولة لين السيرفر يرد (النسخة المجانية على Render تنام وتحتاج وقت تصحى)
        while session == nil && !Task.isCancelled {
            do {
                session = try await ReportService.startSession(playerId: playerId)
            } catch ServiceError.banned {
                setBanned("هذا الحساب محظور من اللعب.")
                return
            } catch {
                status = .error
                message = "جاري الاتصال بالسيرفر... تأكد من الإنترنت."
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        while !Task.isCancelled {
            await runCheck()
            if status == .banned { break }
            try? await Task.sleep(nanoseconds: 10_000_000_000) // كل 10 ثواني
        }
    }

    private func runCheck() async {
        guard let session, let clock else { return }

        var r = DetectionResult()
        r.simulator = AntiCheatDetector.isSimulator
        r.jailbroken = AntiCheatDetector.isJailbroken()
        r.debuggerAttached = AntiCheatDetector.isDebuggerAttached()
        r.injectedLibrary = AntiCheatDetector.hasInjectedLibrary()
        r.screenCaptured = AntiCheatDetector.isScreenCaptured()
        r.timeTampered = clock.isTampered()
        r.leftApp = leftApp

        do {
            let decision = try await ReportService.send(session: session, playerId: playerId, result: r)
            leftApp = false
            apply(decision)
        } catch ServiceError.banned {
            setBanned("تم حظرك بسبب مخالفة قواعد اللعب العادل.")
        } catch ServiceError.http(let code) where code == 401 {
            // السيرفر أعاد التشغيل وضاعت الجلسة: نبدأ جلسة جديدة
            await renewSession()
        } catch {
            status = .error
            message = "تعذر إرسال نتيجة الفحص."
        }
    }

    private func renewSession() async {
        do {
            session = try await ReportService.startSession(playerId: playerId)
        } catch ServiceError.banned {
            setBanned("هذا الحساب محظور من اللعب.")
        } catch {
            status = .error
            message = "تعذر تجديد الجلسة مع السيرفر."
        }
    }

    private func apply(_ d: ServerDecision) {
        let labels = d.reasons.compactMap { Self.reasonLabels[$0] }
        switch d.status {
        case "ban":
            setBanned("تم حظرك: " + labels.joined(separator: "، "))
        case "warn":
            status = .warn
            message = "تنبيه: " + labels.joined(separator: "، ")
        default:
            status = .ok
            message = "كل شي سليم"
        }
    }

    private func setBanned(_ text: String) {
        status = .banned
        message = text
        loopTask?.cancel()
        loopTask = nil
    }
}
