import Foundation
import Carbon
import AppKit

public struct HotKeyBinding: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    public var isEnabled: Bool

    public init(keyCode: UInt32, carbonModifiers: UInt32, isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.isEnabled = isEnabled
    }

    public var displayString: String {
        guard isEnabled else { return "已关闭" }
        var result = ""
        if (carbonModifiers & UInt32(controlKey)) != 0 { result += "⌃" }
        if (carbonModifiers & UInt32(optionKey)) != 0  { result += "⌥" }
        if (carbonModifiers & UInt32(shiftKey)) != 0   { result += "⇧" }
        if (carbonModifiers & UInt32(cmdKey)) != 0     { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    public var shortBadge: String {
        guard isEnabled else { return "" }
        return displayString
    }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }

    public static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key\(keyCode)"
        }
    }
}

public struct HotKeyConfiguration: Codable, Sendable, Equatable {
    public static let storageKey = "MemoPilot.HotKeyConfiguration.v1"

    public var toggleWindow: HotKeyBinding
    public var quickScreenshot: HotKeyBinding
    public var clipboardAnalyze: HotKeyBinding

    public init(
        toggleWindow: HotKeyBinding = HotKeyBinding(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(optionKey),
            isEnabled: true
        ),
        quickScreenshot: HotKeyBinding = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_S),
            carbonModifiers: UInt32(optionKey | shiftKey),
            isEnabled: true
        ),
        clipboardAnalyze: HotKeyBinding = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_C),
            carbonModifiers: UInt32(optionKey),
            isEnabled: true
        )
    ) {
        self.toggleWindow = toggleWindow
        self.quickScreenshot = quickScreenshot
        self.clipboardAnalyze = clipboardAnalyze
    }

    public static let `default` = HotKeyConfiguration()

    public static func load() -> HotKeyConfiguration {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(HotKeyConfiguration.self, from: data) else {
            return .default
        }
        return decoded
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

public final class GlobalHotKeyService: @unchecked Sendable {
    public static let shared = GlobalHotKeyService()
    private static let hotKeySignature = OSType(0x4D504C54)

    private var toggleWindowHotKeyRef: EventHotKeyRef?
    private var captureHotKeyRef: EventHotKeyRef?
    private var clipboardHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    public var onToggleWindowTriggered: (@Sendable () -> Void)?
    public var onQuickScreenshotTriggered: (@Sendable () -> Void)?
    public var onClipboardAnalyzeTriggered: (@Sendable () -> Void)?

    private init() {}

    public func unregisterHotKeys() {
        if let ref = toggleWindowHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleWindowHotKeyRef = nil
        }
        if let ref = captureHotKeyRef {
            UnregisterEventHotKey(ref)
            captureHotKeyRef = nil
        }
        if let ref = clipboardHotKeyRef {
            UnregisterEventHotKey(ref)
            clipboardHotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    public func registerDefaultHotKeys() {
        applyConfiguration(HotKeyConfiguration.load())
    }

    public func applyConfiguration(_ config: HotKeyConfiguration) {
        unregisterHotKeys()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == GlobalHotKeyService.hotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }
                let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
                switch hotKeyID.id {
                case 1:
                    service.onToggleWindowTriggered?()
                    return noErr
                case 2:
                    service.onQuickScreenshotTriggered?()
                    return noErr
                case 3:
                    service.onClipboardAnalyzeTriggered?()
                    return noErr
                default:
                    return OSStatus(eventNotHandledErr)
                }
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        // 1. Toggle / Bring Window to Front
        if config.toggleWindow.isEnabled {
            let toggleHotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
            RegisterEventHotKey(
                config.toggleWindow.keyCode,
                config.toggleWindow.carbonModifiers,
                toggleHotKeyID,
                GetApplicationEventTarget(),
                0,
                &toggleWindowHotKeyRef
            )
        }

        // 2. Interactive Screenshot + Analyze
        if config.quickScreenshot.isEnabled {
            let captureHotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 2)
            RegisterEventHotKey(
                config.quickScreenshot.keyCode,
                config.quickScreenshot.carbonModifiers,
                captureHotKeyID,
                GetApplicationEventTarget(),
                0,
                &captureHotKeyRef
            )
        }

        // 3. Parse Current Clipboard Text/Image Immediately
        if config.clipboardAnalyze.isEnabled {
            let clipboardHotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 3)
            RegisterEventHotKey(
                config.clipboardAnalyze.keyCode,
                config.clipboardAnalyze.carbonModifiers,
                clipboardHotKeyID,
                GetApplicationEventTarget(),
                0,
                &clipboardHotKeyRef
            )
        }
    }
}
