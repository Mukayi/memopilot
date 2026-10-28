import SwiftUI
import AppKit
import MemoPilotCore

struct MenuBarContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @FocusState private var isInputFocused: Bool

    private let slateBlue = Color(red: 0.27, green: 0.44, blue: 0.72)
    private let warmAmber = Color(red: 0.78, green: 0.47, blue: 0.20)
    private let sageTeal  = Color(red: 0.22, green: 0.54, blue: 0.48)
    private let crimson   = Color(red: 0.76, green: 0.29, blue: 0.27)
    private let emerald   = Color(red: 0.24, green: 0.58, blue: 0.40)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar
            composerCard

            if let banner = viewModel.statusBanner {
                statusBannerView(banner)
            }

            if let plan = viewModel.parsedPlan {
                planPreviewSection(plan: plan)
            }

            footerBar
        }
        .padding(14)
        .background(Color(red: 0.988, green: 0.982, blue: 0.968))
        .environment(\.colorScheme, .light)
        .onAppear {
            viewModel.refreshCodexStatus()
            isInputFocused = true
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.86))
                    .frame(width: 22, height: 22)
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("MemoPilot")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))

            Spacer()

            Button {
                if let keyWin = NSApp.keyWindow, keyWin !== AppDelegate.mainWindow {
                    keyWin.orderOut(nil)
                }
                AppDelegate.bringMainWindowToFront()
            } label: {
                Text("打开历史工作台")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        Capsule()
                            .fill(Color.white)
                            .overlay(Capsule().strokeBorder(Color.black.opacity(0.07), lineWidth: 1))
                    )
            }
            .buttonStyle(FullHitAreaButtonStyle())
        }
    }

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "输入备忘，或按 ⌥⇧S 截取微信聊天 / 邮件 / 机票…",
                text: $viewModel.inputText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(2...5)
            .focused($isInputFocused)

            Divider().opacity(0.45)

            HStack(alignment: .center, spacing: 6) {
                Button {
                    Task { await viewModel.analyzeClipboard() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 10.5))
                        Text("剪贴板 ⌥C")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.045)))
                }
                .buttonStyle(FullHitAreaButtonStyle())
                .disabled(viewModel.isAnalyzing)

                Button {
                    if let keyWin = NSApp.keyWindow, keyWin !== AppDelegate.mainWindow {
                        keyWin.orderOut(nil)
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        await viewModel.captureScreenAndAnalyze()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 10.5))
                        Text("截图识别 ⌥⇧S")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.045)))
                }
                .buttonStyle(FullHitAreaButtonStyle())
                .disabled(viewModel.isAnalyzing)

                Spacer()

                Button {
                    Task { await viewModel.runAnalysis() }
                } label: {
                    Text(viewModel.isAnalyzing ? "拆解中…" : "拆解 ⌘↩")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.86)))
                }
                .buttonStyle(FullHitAreaButtonStyle())
                .disabled(viewModel.isAnalyzing)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.07), lineWidth: 1))
        )
    }

    private func statusBannerView(_ text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.isErrorBanner ? crimson : emerald)
                .frame(width: 5.5, height: 5.5)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(viewModel.isErrorBanner ? crimson : .secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    private func colorForKind(_ kind: DraftTargetKind) -> Color {
        switch kind {
        case .calendar: return slateBlue
        case .reminder: return warmAmber
        case .alarm:    return crimson
        case .note:     return sageTeal
        }
    }

    private func subtitleForItem(_ item: DraftItem) -> String {
        switch item.targetKind {
        case .calendar:
            return PromptBuilder.formatReadableRange(startISO: item.startISO, endISO: item.endISO)
        case .reminder, .alarm:
            return PromptBuilder.formatReadableSingleTime(item.startISO.isEmpty ? item.alarmTimeISO : item.startISO)
        case .note:
            return item.notes
        }
    }

    private func planPreviewSection(plan: ParsedPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(plan.items) { item in
                compactItemRow(item: item)
            }

            Button {
                Task { await viewModel.commitCurrentPlan() }
            } label: {
                Text("一键写入系统 (\(viewModel.selectedTotalCount))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(viewModel.selectedTotalCount > 0 ? Color.black.opacity(0.86) : Color.secondary.opacity(0.3))
                    )
            }
            .buttonStyle(FullHitAreaButtonStyle())
            .disabled(viewModel.isExecuting || viewModel.selectedTotalCount == 0)
            .padding(.top, 2)
        }
    }

    private func compactItemRow(item: DraftItem) -> some View {
        let barColor = colorForKind(item.targetKind)
        let subtitle = subtitleForItem(item)
        return HStack(alignment: .center, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(barColor)
                .frame(width: 3, height: 28)

            Button {
                viewModel.toggleItemSelection(id: item.id)
            } label: {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13.5))
                    .foregroundStyle(item.isSelected ? barColor : Color.secondary.opacity(0.35))
            }
            .buttonStyle(FullHitAreaButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(DraftTargetKind.allCases) { kind in
                            Button {
                                viewModel.setItemTargetKind(id: item.id, kind: kind)
                            } label: {
                                Label(kind.rawValue, systemImage: kind.iconName)
                            }
                        }
                    } label: {
                        Text("\(item.targetKind.rawValue) ▾")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(barColor)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    TextField(
                        "标题",
                        text: Binding(
                            get: { viewModel.draftItem(id: item.id, fallback: item).title },
                            set: { viewModel.updateItemTitle(id: item.id, $0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .opacity(item.isSelected ? 1.0 : 0.45)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 1))
        )
    }

    private var footerBar: some View {
        HStack {
            Text("iCloud 自动同步至 iPhone")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .buttonStyle(FullHitAreaButtonStyle())
        }
    }
}
