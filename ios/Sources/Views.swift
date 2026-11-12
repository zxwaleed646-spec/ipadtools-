import SwiftUI

// MARK: - شاشة الموافقة

struct ConsentView: View {
    let onAccept: () -> Void
    @State private var declined = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)

                Text("نظام اللعب العادل")
                    .font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 12) {
                    Text("قبل ما تبدأ، نبي موافقتك الصريحة على الفحوصات التالية:")
                        .font(.headline)

                    Label("هل الجهاز مكسور الحماية (Jailbreak)", systemImage: "lock.open")
                    Label("وجود أدوات تصحيح أو حقن مربوطة باللعبة", systemImage: "ladybug")
                    Label("تسجيل الشاشة أو مشاركتها أثناء اللعب", systemImage: "record.circle")
                    Label("تغيير وقت الجهاز أثناء اللعب", systemImage: "clock")
                    Label("مغادرة اللعبة أثناء الجلسة", systemImage: "arrow.uturn.left")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("اللي ما نسويه:")
                        .font(.headline)
                    Text("ما نقرأ ملفاتك أو صورك أو رسائلك، وما نشوف تطبيقاتك الثانية، وما نراقب شي خارج اللعبة. الفحص يشتغل فقط وأنت داخل اللعبة.")
                    Text("اللي نرسله للسيرفر: معرّف لاعب عشوائي ونتيجة كل فحص (صح أو خطأ) مع الوقت. تقدر تسحب موافقتك في أي وقت من داخل اللعبة.")
                }
                .font(.callout)

                if declined {
                    Text("بدون الموافقة ما نقدر نشغّل اللعب التنافسي.")
                        .foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Button("لا أوافق") { declined = true }
                        .buttonStyle(.bordered)
                    Button("أوافق وابدأ") { onAccept() }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - شاشة اللعبة (بدّلها بلعبتك)

struct GameView: View {
    @ObservedObject var vm: AntiCheatViewModel
    let onRevoke: () -> Void
    @State private var score = 0

    var body: some View {
        VStack(spacing: 24) {
            StatusBadge(status: vm.status, message: vm.message)

            Spacer()

            Text("النقاط: \(score)")
                .font(.system(size: 48, weight: .bold, design: .rounded))

            Button("اضغط!") { score += 1 }
                .font(.title)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(vm.status == .banned)

            Spacer()

            Button("سحب الموافقة", role: .destructive, action: onRevoke)
                .font(.footnote)
        }
        .padding()
    }
}

struct StatusBadge: View {
    let status: AntiCheatViewModel.Status
    let message: String

    private var color: Color {
        switch status {
        case .ok: return .green
        case .warn: return .orange
        case .banned: return .red
        case .error: return .gray
        case .idle: return .blue
        }
    }

    var body: some View {
        Text(message.isEmpty ? "جاري التحقق..." : message)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
    }
}
