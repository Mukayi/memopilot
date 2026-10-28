import Foundation
import Carbon

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

        // 1. Option + Space (keycode 49 = Space) -> Toggle / Bring Window to Front
        let toggleHotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            toggleHotKeyID,
            GetApplicationEventTarget(),
            0,
            &toggleWindowHotKeyRef
        )

        // 2. Option + Shift + S (keycode 1 = 's') -> Interactive Screenshot + Analyze
        let captureHotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 2)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(optionKey | shiftKey),
            captureHotKeyID,
            GetApplicationEventTarget(),
            0,
            &captureHotKeyRef
        )

        // 3. Option + C (keycode 8 = 'c') -> Parse Current Clipboard Text/Image Immediately
        let clipboardHotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 3)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            UInt32(optionKey),
            clipboardHotKeyID,
            GetApplicationEventTarget(),
            0,
            &clipboardHotKeyRef
        )
    }
}
