import SplitrouteCore
import SwiftUI

extension Licensing {
    var buyTitle: String { config.price.map { L("Купить за \($0)") } ?? L("Купить") }
}

/// Пробный период и его конец — над содержимым экрана.
struct LicenseBanner: View {
    @Environment(Licensing.self) private var licensing
    @State private var showKey = false

    var body: some View {
        Group {
            switch licensing.status {
            case .trial(let days):
                banner(icon: "clock", color: Theme.amber,
                       title: L("Пробный период: \(days) \(Format.plural(days, "день", "дня", "дней"))"),
                       detail: L("Потом маршрутизация выключится, пока не будет ключа"))
            case .expired:
                banner(icon: "lock.fill", color: Theme.coral,
                       title: L("Пробный период закончился — маршрутизация выключена"),
                       detail: L("Splitroute покупается один раз — для всех ваших Mac и будущих версий"))
            default:
                EmptyView()
            }
        }
        .sheet(isPresented: $showKey) { LicenseKeySheet() }
    }

    private func banner(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(13, .semibold))
                Text(detail).font(Theme.font(12)).foregroundStyle(Theme.text2).lineLimit(2)
            }
            Spacer()
            Button(L("Ввести ключ")) { showKey = true }
                .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.text2)
            if licensing.config.buyURL != nil {
                PrimaryButton(title: licensing.buyTitle, systemImage: "cart") { licensing.openStore() }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.35)))
        .padding(.top, 14)
    }
}

/// Ввод ключа из письма Lemon Squeezy.
struct LicenseKeySheet: View {
    @Environment(Licensing.self) private var licensing
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Ключ лицензии")).font(Theme.font(20, .semibold))
            Text(L("Ключ приходит на почту после покупки. Он работает на всех ваших Mac."))
                .font(Theme.font(12)).foregroundStyle(Theme.text2)
            TextField("", text: $key, prompt: Text(verbatim: "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX").foregroundStyle(Theme.text3))
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12).frame(height: 38)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                .onSubmit(activate)
            if let error {
                Text(error).font(Theme.font(12)).foregroundStyle(Theme.coral).textSelection(.enabled)
            }
            HStack {
                if licensing.config.buyURL != nil {
                    Button(licensing.buyTitle) { licensing.openStore() }
                        .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                }
                Spacer()
                Button(L("Отмена")) { dismiss() }.buttonStyle(.plain).font(Theme.font(13)).foregroundStyle(Theme.text2)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    PrimaryButton(title: L("Активировать"), systemImage: "key") { activate() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private func activate() {
        guard !busy, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        busy = true
        error = nil
        Task {
            do {
                try await licensing.activate(key: key)
                model.scheduleApply(immediately: true)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// «Настройки → Лицензия».
struct LicenseSection: View {
    @Environment(Licensing.self) private var licensing
    @State private var showKey = false
    @State private var error: String?

    private var subtitle: String {
        switch licensing.status {
        case .notForSale: return L("Сейчас Splitroute бесплатный")
        case .earlyAdopter: return L("Вы пользовались Splitroute до начала продаж — бесплатно навсегда. Спасибо!")
        case .licensed(let l): return L("Ключ \(l.maskedKey)") + (l.customerEmail.map { " · \($0)" } ?? "")
        case .trial(let days): return L("Пробный период: \(days) \(Format.plural(days, "день", "дня", "дней"))")
        case .expired: return L("Пробный период закончился")
        }
    }

    private var title: String {
        switch licensing.status {
        case .notForSale: return L("Бесплатно")
        case .earlyAdopter: return L("Ранний пользователь")
        case .licensed: return L("Куплено")
        case .trial: return L("Пробный период")
        case .expired: return L("Нужна лицензия")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(L("Лицензия"))
            SettingRow(title, subtitle) {
                HStack(spacing: 14) {
                    if case .licensed = licensing.status {
                        Button(L("Отвязать этот Mac")) {
                            Task {
                                do { try await licensing.deactivate() } catch { self.error = error.localizedDescription }
                            }
                        }
                        .buttonStyle(.plain).font(Theme.font(12)).foregroundStyle(Theme.text2)
                        .help(L("Освободить ключ, чтобы активировать его на другом Mac"))
                    } else if licensing.config.sales {
                        Button(L("Ввести ключ")) { showKey = true }
                            .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.text2)
                        if licensing.config.buyURL != nil {
                            Button(licensing.buyTitle) { licensing.openStore() }
                                .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                        }
                    }
                }
            }
            if let error {
                Text(error).font(Theme.font(11)).foregroundStyle(Theme.coral).padding(.vertical, 6)
            }
        }
        .sheet(isPresented: $showKey) { LicenseKeySheet() }
    }
}
