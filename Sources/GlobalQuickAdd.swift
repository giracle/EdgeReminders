import Carbon
import Combine
import Foundation

@MainActor
final class PanelQuickAdd: ObservableObject {
    @Published private(set) var requestID = UUID()

    func open() { requestID = UUID() }
}

@MainActor
final class GlobalQuickAdd {
    static let keyEquivalent = "n"
    private static let hotKeyID = EventHotKeyID(signature: 0x45524647, id: 1)
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func register() -> Bool {
        if hotKey != nil { return true }
        let target = GetApplicationEventTarget()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(target, GlobalQuickAdd.receiveHotKey, 1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return false }
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | shiftKey), Self.hotKeyID, target, 0, &hotKey)
        if status != noErr { unregister() }
        return status == noErr
    }

    private static let receiveHotKey: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var received = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &received)
        let id = received.id
        let signature = received.signature
        guard status == noErr else { return OSStatus(eventNotHandledErr) }
        return MainActor.assumeIsolated {
            guard id == GlobalQuickAdd.hotKeyID.id, signature == GlobalQuickAdd.hotKeyID.signature else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<GlobalQuickAdd>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
