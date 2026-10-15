import SplitrouteCore
import SwiftUI

/// «Настройки → Поддержать Splitroute»: видно, когда есть хотя бы одна ссылка.
struct SupportSection: View {
    private var support: Support { Support.shared }

    var body: some View {
        if !support.links.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(L("Поддержать Splitroute"))
                SettingRow(L("Splitroute бесплатный и с открытым кодом"), L("Если он вам помогает — можно поддержать разработку")) {
                    HStack(spacing: 14) {
                        ForEach(support.links.all, id: \.url) { link in
                            Button(link.title) { support.open(link.url) }
                                .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Theme.lime)
                        }
                    }
                }
            }
        }
    }
}

/// Одна просьба через две недели пользования; после «Не сейчас» или доната больше не появляется.
struct SupportBanner: View {
    private var support: Support { Support.shared }

    var body: some View {
        if support.shouldAsk, let first = support.links.all.first {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill").foregroundStyle(Theme.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Нравится Splitroute?")).font(Theme.font(13, .semibold))
                    Text(L("Он бесплатный. Если он экономит вам время — поддержите разработку"))
                        .font(Theme.font(12)).foregroundStyle(Theme.text2).lineLimit(2)
                }
                Spacer()
                Button(L("Не сейчас")) { support.dismissAsk() }
                    .buttonStyle(.plain).font(Theme.font(12)).foregroundStyle(Theme.text2)
                PrimaryButton(title: L("Поддержать"), systemImage: "heart") { support.open(first.url) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .padding(.top, 14)
        }
    }
}
