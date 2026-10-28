import SwiftUI
import AppKit
import Carbon
import MemoPilotCore

enum ShortcutTargetSlot: String, Identifiable {
    case toggleWindow
    case clipboardAnalyze
    case quickScreenshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleWindow: return "呼出 / 隐藏主窗口"
        case .clipboardAnalyze: return "读取剪贴板并拆解"
        case .quickScreenshot: return "框选截图并识别"
        }
    }

    var subtitle: String {
        switch self {
        case .toggleWindow: return "在任意应用下快速唤出或隐藏 MemoPilot"
        case .clipboardAnalyze: return "复制微信文字或图片后一键唤醒拆解"
        case .quickScreenshot: return "框选屏幕区域后 OCR + AI 自动提取"
        }
    }
}

struct ShortcutSettingsPopoverView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var recordingSlot: ShortcutTargetSlot?
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Label("全局快捷键设置", systemImage: "keyboard")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("恢复默认") {
                    stopRecording()
                    viewModel.resetHotKeysToDefault()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }

            Text("点击右侧快捷键胶囊后，直接按下键盘组合键（需含 ⌘ / ⌥ / ⌃ / ⇧）即可修改；按 Delete 可关闭该快捷键。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)

            Divider()

            VStack(spacing: 10) {
                shortcutRow(
                    slot: .toggleWindow,
                    binding: viewModel.hotKeyConfig.toggleWindow,
                    onToggleEnabled: { enabled in
                        var cfg = viewModel.hotKeyConfig
                        cfg.toggleWindow.isEnabled = enabled
                        viewModel.updateHotKeyConfig(cfg)
                    }
                )

                shortcutRow(
                    slot: .clipboardAnalyze,
                    binding: viewModel.hotKeyConfig.clipboardAnalyze,
                    onToggleEnabled: { enabled in
                        var cfg = viewModel.hotKeyConfig
                        cfg.clipboardAnalyze.isEnabled = enabled
                        viewModel.updateHotKeyConfig(cfg)
                    }
                )

                shortcutRow(
                    slot: .quickScreenshot,
                    binding: viewModel.hotKeyConfig.quickScreenshot,
                    onToggleEnabled: { enabled in
                        var cfg = viewModel.hotKeyConfig
                        cfg.quickScreenshot.isEnabled = enabled
                        viewModel.updateHotKeyConfig(cfg)
                    }
                )
            }

            Divider()

            HStack(spacing: 12) {
                Text("窗口内快捷键：⌘↩ 智能拆解  ·  ⌘N 新建输入  ·  ⌘F 搜索历史  ·  ⌃⌘S 收起侧栏")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 390)
        .onDisappear {
            stopRecording()
        }
    }

    private func shortcutRow(
        slot: ShortcutTargetSlot,
        binding: HotKeyBinding,
        onToggleEnabled: @escaping (Bool) -> Void
    ) -> some View {
        let isRecording = (recordingSlot == slot)

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(slot.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording(for: slot)
                }
            } label: {
                Text(isRecording ? "请按键… (ESC)" : binding.displayString)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isRecording ? Color.white : (binding.isEnabled ? Color.primary : Color.secondary.opacity(0.5)))
                    .frame(minWidth: 102)
                    .frame(height: 26)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isRecording ? Color.accentColor : Color.primary.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        isRecording ? Color.accentColor : Color.primary.opacity(0.12),
                                        lineWidth: 1
                                    )
                            )
                    )
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { binding.isEnabled },
                set: { newVal in
                    stopRecording()
                    onToggleEnabled(newVal)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(binding.isEnabled ? "已启用此全局快捷键" : "已禁用此全局快捷键")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
    }

    private func startRecording(for slot: ShortcutTargetSlot) {
        stopRecording()
        recordingSlot = slot
        // Pause global hotkeys while recording so pressing the current hotkey doesn't fire the global action
        GlobalHotKeyService.shared.unregisterHotKeys()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // ESC cancels recording
            if Int(keyCode) == kVK_Escape && flags.isEmpty {
                stopRecording()
                return nil
            }

            // Delete / Backspace without modifiers disables the shortcut
            if (Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete) && flags.isEmpty {
                applyRecordedBinding(for: slot, keyCode: keyCode, carbonMods: 0, isEnabled: false)
                stopRecording()
                return nil
            }

            let isFunctionKey = [
                kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
            ].contains(Int(keyCode))

            let carbonMods = HotKeyBinding.carbonModifiers(from: flags)
            guard carbonMods != 0 || isFunctionKey else {
                NSSound.beep()
                return nil
            }

            applyRecordedBinding(for: slot, keyCode: keyCode, carbonMods: carbonMods, isEnabled: true)
            stopRecording()
            return nil
        }
    }

    private func applyRecordedBinding(for slot: ShortcutTargetSlot, keyCode: UInt32, carbonMods: UInt32, isEnabled: Bool) {
        var cfg = viewModel.hotKeyConfig
        switch slot {
        case .toggleWindow:
            if isEnabled {
                cfg.toggleWindow = HotKeyBinding(keyCode: keyCode, carbonModifiers: carbonMods, isEnabled: true)
            } else {
                cfg.toggleWindow.isEnabled = false
            }
        case .clipboardAnalyze:
            if isEnabled {
                cfg.clipboardAnalyze = HotKeyBinding(keyCode: keyCode, carbonModifiers: carbonMods, isEnabled: true)
            } else {
                cfg.clipboardAnalyze.isEnabled = false
            }
        case .quickScreenshot:
            if isEnabled {
                cfg.quickScreenshot = HotKeyBinding(keyCode: keyCode, carbonModifiers: carbonMods, isEnabled: true)
            } else {
                cfg.quickScreenshot.isEnabled = false
            }
        }
        viewModel.updateHotKeyConfig(cfg)
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if recordingSlot != nil {
            recordingSlot = nil
            GlobalHotKeyService.shared.applyConfiguration(viewModel.hotKeyConfig)
        }
    }
}
