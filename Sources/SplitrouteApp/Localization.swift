import Foundation

/// Перевод строки интерфейса. Ключ — русский текст (язык разработки); компилятор с
/// `-emit-localized-strings` извлекает литералы, переданные сюда, как и в `Text("…")`.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value)
}

enum Lang {
    /// Интерфейс по-русски (иначе — английский): для правил множественного числа.
    static var isRussian: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("ru") ?? true }
}
