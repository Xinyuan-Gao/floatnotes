import AppKit
import Carbon.HIToolbox

/// 全局热键（Carbon RegisterEventHotKey）。
/// 直接用 Carbon 是为了避免引入 SPM 依赖；生产版可换成 soffes/HotKey 或 sindresorhus/KeyboardShortcuts。
final class GlobalHotKey {

    private static var registry: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private static let signature: OSType = 0x464C4E54   // 'FLNT'

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()

        let id = Self.nextID
        Self.nextID += 1
        self.id = id

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, ref != nil else {
            NSLog("[HotKey] 注册失败 keyCode=\(keyCode) status=\(status)")
            return nil
        }
        Self.registry[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.registry.removeValue(forKey: id)
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard err == noErr else { return err }
            if let fn = GlobalHotKey.registry[hkID.id] {
                DispatchQueue.main.async { fn() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// 常用键码 / 修饰键，避免到处 import Carbon
enum Key {
    static let n: UInt32 = UInt32(kVK_ANSI_N)
    static let h: UInt32 = UInt32(kVK_ANSI_H)
    static let l: UInt32 = UInt32(kVK_ANSI_L)
    static let d: UInt32 = UInt32(kVK_ANSI_D)
    static let r: UInt32 = UInt32(kVK_ANSI_R)
    static let e: UInt32 = UInt32(kVK_ANSI_E)
    static let k: UInt32 = UInt32(kVK_ANSI_K)
    static let t: UInt32 = UInt32(kVK_ANSI_T)
    static let g: UInt32 = UInt32(kVK_ANSI_G)
    static let b: UInt32 = UInt32(kVK_ANSI_B)

    static let cmdOption: UInt32 = UInt32(cmdKey | optionKey)
    static let cmdOptionShift: UInt32 = UInt32(cmdKey | optionKey | shiftKey)
    static let cmdShift: UInt32 = UInt32(cmdKey | shiftKey)
}
