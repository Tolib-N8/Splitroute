import SplitrouteCore
import SwiftUI

struct AppIcon: View {
    @Environment(AppModel.self) private var model
    var key: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: model.icon(forKey: key))
            .resizable()
            .interpolation(.high)
            .frame(width: size * 0.8, height: size * 0.8)
            .frame(width: size, height: size)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

/// Пилюля-фильтр как в дизайне («Все», «VPN»…).
struct FilterPill: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(13, .semibold))
                .foregroundStyle(selected ? Theme.bg : Theme.text)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(selected ? Theme.text : .clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? .clear : Theme.line))
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Иконка отвечает на клик: «обновить»-подобные и шестерёнка крутятся, остальные подпрыгивают.
    @ViewBuilder func liveSymbol(_ name: String?, value: Int) -> some View {
        if let name, name.contains("clockwise") || name.contains("circlepath") || name.hasPrefix("gearshape") {
            symbolEffect(.rotate, value: value)
        } else {
            symbolEffect(.bounce, value: value)
        }
    }
}

struct PrimaryButton: View {
    var title: String
    var systemImage: String = "plus"
    var action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .liveSymbol(systemImage, value: taps)
                .font(Theme.font(13, .bold))
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 20)
                .frame(height: 38)
                .background(Theme.lime, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct OutlineButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).liveSymbol(systemImage, value: taps) }
                Text(title)
            }
            .font(Theme.font(13, .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 20)
            .frame(height: 38)
            .overlay(Capsule().stroke(Theme.text.opacity(0.85), lineWidth: 1.2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SearchField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.text3))
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

struct LimeToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Theme.lime : Theme.surface2)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? Theme.bg : Theme.text3).frame(width: 16, height: 16).padding(3)
                }
                .overlay(Capsule().stroke(isOn ? .clear : Theme.line))
                .animation(.snappy(duration: 0.18), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

/// Столбики трафика за 24 часа.
struct SparkBars: View {
    var values: [Int64]
    var color: Color

    var body: some View {
        let maxV = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(values.indices, id: \.self) { i in
                let v = values[i]
                RoundedRectangle(cornerRadius: 1)
                    .fill(v == 0 ? Theme.line : color)
                    .frame(width: 4, height: v == 0 ? 2 : max(4, 22 * CGFloat(v) / CGFloat(maxV)))
            }
        }
        .frame(height: 22, alignment: .bottom)
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }
}

/// Заголовок экрана: крупный title слева, сводка справа.
struct ScreenHeader<Subtitle: View>: View {
    var title: String
    var summary: String
    var footnote: String
    @ViewBuilder var subtitle: Subtitle

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(Theme.font(30, .semibold)).foregroundStyle(Theme.text)
                subtitle
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Text(summary).font(Theme.font(13)).foregroundStyle(Theme.text)
                Text(footnote).font(Theme.font(11)).foregroundStyle(Theme.text2)
            }
            .padding(.top, 8)
        }
    }
}

extension AppModel {
    var updatedText: String {
        guard let lastUpdate else { return state.isRunning ? L("Ожидание данных") : L("Ядро остановлено") }
        let s = max(0, Int(Date().timeIntervalSince(lastUpdate)))
        return L("Обновлено \(s) сек. назад")
    }
}
