import Foundation
import UIKit
import MachO

/// نتيجة فحص واحد. السيرفر هو اللي يقرر الحظر أو التحذير، مو الجهاز.
struct DetectionResult: Equatable {
    var jailbroken = false
    var debuggerAttached = false
    var injectedLibrary = false
    var screenCaptured = false
    var timeTampered = false
    var leftApp = false
    var simulator = false
}

/// يكشف تغيير وقت الجهاز أثناء الجلسة: يقارن ساعة الجهاز بساعة التشغيل (uptime) اللي ما تتأثر بتغيير الوقت.
struct ClockGuard {
    private let startDate = Date()
    private let startUptime = ProcessInfo.processInfo.systemUptime

    func isTampered(tolerance: TimeInterval = 5) -> Bool {
        let dateDelta = Date().timeIntervalSince(startDate)
        let uptimeDelta = ProcessInfo.processInfo.systemUptime - startUptime
        return abs(dateDelta - uptimeDelta) > tolerance
    }
}

enum AntiCheatDetector {

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // 1) كسر الحماية (Jailbreak)
    static func isJailbroken() -> Bool {
        if isSimulator { return false }

        let fm = FileManager.default
        let suspiciousPaths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/usr/sbin/sshd",
            "/usr/bin/ssh",
            "/bin/bash",
            "/etc/apt",
            "/private/var/lib/apt/",
            "/var/jb",
            "/var/binpack"
        ]
        if suspiciousPaths.contains(where: { fm.fileExists(atPath: $0) }) {
            return true
        }

        // الصندوق المعزول يمنع الكتابة خارج مجلد التطبيق. لو نجحت الكتابة فالعزل مكسور.
        let testPath = "/private/ac_test_\(UUID().uuidString).txt"
        do {
            try "x".write(toFile: testPath, atomically: true, encoding: .utf8)
            try? fm.removeItem(atPath: testPath)
            return true
        } catch {
            return false
        }
    }

    // 2) Debugger مربوط بالتطبيق
    // في نسخة DEBUG (تشغيل من Xcode) نتجاهله، وإلا راح تنحظر نفسك أثناء التجربة.
    static func isDebuggerAttached() -> Bool {
        #if DEBUG
        return false
        #else
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
        #endif
    }

    // 3) مكتبات حقن مثل Frida وSubstrate محملة داخل التطبيق
    static func hasInjectedLibrary() -> Bool {
        let bad = ["frida", "substrate", "substitute", "libhooker",
                   "cycript", "sslkillswitch", "tweakinject"]
        for i in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let name = String(cString: cName).lowercased()
            if bad.contains(where: { name.contains($0) }) { return true }
        }
        return false
    }

    // 4) تسجيل الشاشة أو مشاركتها أو عكسها
    @MainActor
    static func isScreenCaptured() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
    }
}
