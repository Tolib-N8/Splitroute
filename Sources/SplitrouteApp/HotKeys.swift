import Carbon.HIToolbox
import Foundation

/// Глобальные горячие клавиши через Carbon — не требуют разрешения «Универсальный доступ».
@MainActor
final class HotKeys {
    struct Binding {
        var keyCode: Int
        var title: String
        var keys: [String]
        var action: @MainActor () -> Void
    }

    static let shared = HotKeys()
    private(set) var bindings: [Binding] = []
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    /// ⌥⌘ + клавиша.
    func register(_ bindings: [Binding]) {
        unregister()
        self.bindings = bindings
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            MainActor.assumeIsolated {
                if HotKeys.shared.bindings.indices.contains(index) { HotKeys.shared.bindings[index].action() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        for (i, b) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5350_5254), id: UInt32(i))  // 'SPRT'
            RegisterEventHotKey(UInt32(b.keyCode), UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    func unregister() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
