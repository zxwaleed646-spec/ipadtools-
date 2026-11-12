import SwiftUI
import UIKit

@main
struct AntiCheatApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @AppStorage("consentGiven_v1") private var consentGiven = false
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = AntiCheatViewModel()

    var body: some View {
        Group {
            if consentGiven {
                GameView(vm: vm, onRevoke: {
                    vm.stop()
                    consentGiven = false
                })
                .onAppear { vm.start() }
            } else {
                ConsentView(onAccept: { consentGiven = true })
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        // مغادرة التطبيق
        .onChange(of: scenePhase) { phase in
            if phase == .background && consentGiven { vm.markLeftApp() }
        }
        // بدء أو إيقاف تسجيل الشاشة: فحص فوري
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            if consentGiven { vm.checkNow() }
        }
    }
}
