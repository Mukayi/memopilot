import SwiftUI
import AppKit
import MemoPilotCore

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case pending = "待确认"
    case committed = "已写入"
    case screenshot = "含截图"

    var id: String { rawValue }
}

// MARK: - Dynamic Theme Palette (Seamless Paper Canvas + Muted Semantic Tones)
struct ThemePalette {
    let sidebarBg: Color
    let sidebarSelectedRow: Color
    let sidebarSegmentWell: Color
    let mainCanvasBg: Color
    let composerWellBg: Color
    let subtleButtonBg: Color
    let hairline: Color
    let primaryActionBg: Color
    let primaryActionFg: Color
    let swatchDot: Color

    let calendarTone: Color
    let reminderTone: Color
    let noteTone: Color
    let committedTone: Color
    let urgentTone: Color

    static func forTheme(_ theme: WorkspaceTheme) -> ThemePalette {
        switch theme {
        case .warmPaper:
            return ThemePalette(
                sidebarBg: Color(red: 0.945, green: 0.933, blue: 0.910),
                sidebarSelectedRow: Color(red: 0.988, green: 0.982, blue: 0.968),
                sidebarSegmentWell: Color.black.opacity(0.05),
                mainCanvasBg: Color(red: 0.988, green: 0.982, blue: 0.968),
                composerWellBg: Color(red: 0.955, green: 0.945, blue: 0.925),
                subtleButtonBg: Color.black.opacity(0.048),
                hairline: Color(red: 0.25, green: 0.20, blue: 0.14).opacity(0.085),
                primaryActionBg: Color(red: 0.16, green: 0.15, blue: 0.14),
                primaryActionFg: Color(red: 0.99, green: 0.98, blue: 0.96),
                swatchDot: Color(red: 0.88, green: 0.82, blue: 0.72),
                calendarTone: Color(red: 0.24, green: 0.43, blue: 0.68),
                reminderTone: Color(red: 0.76, green: 0.45, blue: 0.16),
                noteTone: Color(red: 0.21, green: 0.51, blue: 0.44),
                committedTone: Color(red: 0.22, green: 0.55, blue: 0.37),
                urgentTone: Color(red: 0.72, green: 0.27, blue: 0.25)
            )

        case .notesWhite:
            return ThemePalette(
                sidebarBg: Color(red: 0.948, green: 0.948, blue: 0.955),
                sidebarSelectedRow: Color.white,
                sidebarSegmentWell: Color.black.opacity(0.05),
                mainCanvasBg: Color.white,
                composerWellBg: Color(red: 0.965, green: 0.967, blue: 0.974),
                subtleButtonBg: Color.black.opacity(0.045),
                hairline: Color.black.opacity(0.07),
                primaryActionBg: Color.black.opacity(0.86),
                primaryActionFg: Color.white,
                swatchDot: Color(red: 0.92, green: 0.93, blue: 0.95),
                calendarTone: Color(red: 0.24, green: 0.44, blue: 0.72),
                reminderTone: Color(red: 0.78, green: 0.46, blue: 0.16),
                noteTone: Color(red: 0.20, green: 0.52, blue: 0.46),
                committedTone: Color(red: 0.21, green: 0.56, blue: 0.38),
                urgentTone: Color(red: 0.74, green: 0.27, blue: 0.25)
            )

        case .mistBlue:
            return ThemePalette(
                sidebarBg: Color(red: 0.922, green: 0.938, blue: 0.962),
                sidebarSelectedRow: Color(red: 0.984, green: 0.990, blue: 0.998),
                sidebarSegmentWell: Color(red: 0.15, green: 0.25, blue: 0.40).opacity(0.06),
                mainCanvasBg: Color(red: 0.980, green: 0.987, blue: 0.996),
                composerWellBg: Color(red: 0.942, green: 0.955, blue: 0.976),
                subtleButtonBg: Color(red: 0.15, green: 0.25, blue: 0.40).opacity(0.055),
                hairline: Color(red: 0.15, green: 0.25, blue: 0.40).opacity(0.085),
                primaryActionBg: Color(red: 0.15, green: 0.22, blue: 0.34),
                primaryActionFg: Color.white,
                swatchDot: Color(red: 0.68, green: 0.78, blue: 0.92),
                calendarTone: Color(red: 0.22, green: 0.45, blue: 0.75),
                reminderTone: Color(red: 0.76, green: 0.46, blue: 0.18),
                noteTone: Color(red: 0.20, green: 0.53, blue: 0.48),
                committedTone: Color(red: 0.21, green: 0.56, blue: 0.39),
                urgentTone: Color(red: 0.72, green: 0.28, blue: 0.27)
            )

        case .darkNight:
            return ThemePalette(
                sidebarBg: Color(red: 0.105, green: 0.110, blue: 0.125),
                sidebarSelectedRow: Color(red: 0.165, green: 0.172, blue: 0.195),
                sidebarSegmentWell: Color.white.opacity(0.06),
                mainCanvasBg: Color(red: 0.135, green: 0.140, blue: 0.160),
                composerWellBg: Color(red: 0.180, green: 0.188, blue: 0.212),
                subtleButtonBg: Color.white.opacity(0.07),
                hairline: Color.white.opacity(0.08),
                primaryActionBg: Color(red: 0.92, green: 0.93, blue: 0.95),
                primaryActionFg: Color(red: 0.12, green: 0.13, blue: 0.15),
                swatchDot: Color(red: 0.25, green: 0.27, blue: 0.32),
                calendarTone: Color(red: 0.46, green: 0.66, blue: 0.95),
                reminderTone: Color(red: 0.92, green: 0.64, blue: 0.34),
                noteTone: Color(red: 0.38, green: 0.76, blue: 0.68),
                committedTone: Color(red: 0.38, green: 0.78, blue: 0.54),
                urgentTone: Color(red: 0.92, green: 0.45, blue: 0.42)
            )
        }
    }
}

struct MainWorkspaceView: View {
    @ObservedObject var viewModel: AppViewModel
    @FocusState private var isComposerFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @State private var dragStartSidebarWidth: CGFloat?

    // Strict 3-Column Alignment Constant:
    // Col 1 (18pt checkbox) + 10pt gap + Col 2 (44pt target pill) + 12pt gap = 84pt
    private let col3LeadingIndent: CGFloat = 84

    private var palette: ThemePalette {
        ThemePalette.forTheme(viewModel.theme)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !viewModel.isSidebarCollapsed {
                sidebarColumn
                    .frame(width: viewModel.sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(palette.sidebarBg)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                resizableDivider
            }

            mainDetailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(palette.mainCanvasBg)
        }
        .ignoresSafeArea(.all, edges: .top)
        .frame(minWidth: 920, minHeight: 560, alignment: .topLeading)
        .environment(\.colorScheme, viewModel.theme.isDark ? .dark : .light)
        .onAppear {
            viewModel.refreshCodexStatus()
        }
    }

    private var resizableDivider: some View {
        Rectangle()
            .fill(palette.hairline)
            .frame(width: 1)
            .contentShape(Rectangle().inset(by: -3))
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    viewModel.isSidebarCollapsed.toggle()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragStartSidebarWidth ?? viewModel.sidebarWidth
                        if dragStartSidebarWidth == nil {
                            dragStartSidebarWidth = base
                        }
                        let proposed = base + value.translation.width
                        if proposed >= 180 {
                            viewModel.sidebarWidth = min(max(proposed, 235), 350)
                        }
                    }
                    .onEnded { value in
                        let base = dragStartSidebarWidth ?? viewModel.sidebarWidth
                        dragStartSidebarWidth = nil
                        if base + value.translation.width < 180 {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                                viewModel.isSidebarCollapsed = true
                            }
                        }
                    }
            )
    }

    // MARK: - Left Sidebar (All elements share exact 12pt horizontal margin)

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                Spacer().frame(width: 78)
                Spacer()
                sidebarToggleButton
                newMemoButton
            }
            .frame(height: 46)
            .padding(.trailing, 12)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            // Segmented Filter Bar
            HStack(spacing: 2) {
                ForEach(HistoryFilter.allCases) { filter in
                    let isSelected = viewModel.selectedFilter == filter
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.selectedFilter = filter
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .fill(isSelected ? palette.sidebarSelectedRow : Color.clear)
                                    .shadow(color: isSelected ? Color.black.opacity(0.04) : .clear, radius: 2, x: 0, y: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(palette.sidebarSegmentWell)
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if viewModel.filteredHistoryRecords.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text(viewModel.historyRecords.isEmpty ? "暂无历史请求" : "当前筛选无匹配记录")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    sidebarGroupedContent
                }
            }

            HStack(alignment: .center) {
                Text("共 \(viewModel.historyRecords.count) 条记录")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)

                Spacer()

                if !viewModel.historyRecords.isEmpty {
                    Button("清空") {
                        viewModel.clearAllHistory()
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                viewModel.isSidebarCollapsed.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(palette.subtleButtonBg)
                )
        }
        .buttonStyle(.plain)
        .help(viewModel.isSidebarCollapsed ? "展开历史侧边栏 (⌃⌘S)" : "隐藏历史侧边栏 (⌃⌘S)")
    }

    private var newMemoButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                viewModel.isInputCollapsed = false
                viewModel.inputText = ""
                isComposerFocused = true
            }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(palette.subtleButtonBg)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: [.command])
        .help("新建备忘输入 (⌘N)")
    }

    @ViewBuilder
    private var sidebarGroupedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.pinnedHistoryRecords.isEmpty {
                collapsibleSidebarSection(
                    title: "已置顶",
                    icon: "pin.fill",
                    isExpanded: $viewModel.isPinnedSectionExpanded,
                    records: viewModel.pinnedHistoryRecords
                )
            }

            if !viewModel.todayHistoryRecords.isEmpty {
                collapsibleSidebarSection(
                    title: "今天",
                    icon: nil,
                    isExpanded: $viewModel.isTodaySectionExpanded,
                    records: viewModel.todayHistoryRecords
                )
            }

            if !viewModel.earlierHistoryRecords.isEmpty {
                collapsibleSidebarSection(
                    title: "更早",
                    icon: nil,
                    isExpanded: $viewModel.isEarlierSectionExpanded,
                    records: viewModel.earlierHistoryRecords
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    private func collapsibleSidebarSection(
        title: String,
        icon: String?,
        isExpanded: Binding<Bool>,
        records: [HistoryRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 5) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(records.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                VStack(spacing: 4) {
                    ForEach(records) { record in
                        historyRowCard(record)
                    }
                }
            }
        }
    }

    private func historyRowCard(_ record: HistoryRecord) -> some View {
        let isSelected = viewModel.selectedRecordID == record.id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.selectHistoryRecord(record.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Circle()
                        .fill(record.isCommitted ? palette.committedTone : palette.reminderTone)
                        .frame(width: 5.5, height: 5.5)

                    Text(record.displayTitle)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if record.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(45))
                    }

                    Text(Self.shortTimeString(record.createdAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }

                if !record.rawInputText.isEmpty {
                    Text(record.rawInputText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(Self.summaryCountsLine(for: record.plan, isCommitted: record.isCommitted))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? palette.sidebarSelectedRow : Color.clear)
                    .shadow(color: isSelected ? Color.black.opacity(0.04) : .clear, radius: 2, x: 0, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? palette.hairline : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                viewModel.togglePinRecord(record.id)
            } label: {
                Label(record.isPinned ? "取消置顶" : "置顶此条记录", systemImage: record.isPinned ? "pin.slash" : "pin")
            }

            if !record.rawInputText.isEmpty {
                Button {
                    viewModel.isInputCollapsed = false
                    viewModel.inputText = record.rawInputText
                } label: {
                    Label("填入上方输入框", systemImage: "arrow.uturn.up")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.rawInputText, forType: .string)
                } label: {
                    Label("复制原始文本", systemImage: "doc.on.doc")
                }
            }

            Divider()

            Button(role: .destructive) {
                viewModel.deleteHistoryRecord(record.id)
            } label: {
                Label("删除记录", systemImage: "trash")
            }
        }
    }

    private static func summaryCountsLine(for plan: ParsedPlan, isCommitted: Bool) -> String {
        var parts: [String] = []
        if !plan.events.isEmpty { parts.append("日历 \(plan.events.count)") }
        if !plan.reminders.isEmpty { parts.append("提醒 \(plan.reminders.count)") }
        if !plan.alarms.isEmpty { parts.append("闹钟 \(plan.alarms.count)") }
        if !plan.notes.isEmpty { parts.append("备忘 \(plan.notes.count)") }
        parts.append(isCommitted ? "已写入" : "待确认")
        return parts.joined(separator: " · ")
    }

    // MARK: - Right Main Column (All sections share exact 24pt left/right margin)

    private var mainDetailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            rightPaneHeaderBar
                .frame(height: 46)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if !viewModel.isInputCollapsed {
                        sleekCommandComposerBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let banner = viewModel.statusBanner {
                        statusBannerLine(banner)
                    }

                    if let record = viewModel.currentInspectingRecord {
                        recordInspectorContent(record: record)
                    } else {
                        emptyWorkspacePlaceholder
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rightPaneHeaderBar: some View {
        HStack(alignment: .center, spacing: 10) {
            if viewModel.isSidebarCollapsed {
                Spacer().frame(width: 66)
                sidebarToggleButton
                newMemoButton
                Divider()
                    .frame(height: 14)
                    .opacity(0.5)
            }

            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("MemoPilot")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button("") {
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: [.command])
            .frame(width: 0, height: 0)
            .opacity(0)

            // Search Field
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                TextField("搜索历史记录 (⌘F)…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($isSearchFocused)
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 175, height: 24)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.composerWellBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(palette.hairline, lineWidth: 1)
                    )
            )

            // Unified Theme & Options Menu
            Menu {
                Section("界面底色") {
                    ForEach(WorkspaceTheme.allCases) { themeOption in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.theme = themeOption
                            }
                        } label: {
                            HStack {
                                Text(themeOption.rawValue)
                                if viewModel.theme == themeOption {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Divider()

                Button {
                    viewModel.autoCommit.toggle()
                } label: {
                    Label(
                        viewModel.autoCommit ? "已开启：识别后自动写入系统" : "当前模式：先预览后确认",
                        systemImage: viewModel.autoCommit ? "bolt.fill" : "eye"
                    )
                }

                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        viewModel.isInputCollapsed.toggle()
                    }
                } label: {
                    Label(
                        viewModel.isInputCollapsed ? "展开顶部输入栏" : "收起顶部输入栏",
                        systemImage: viewModel.isInputCollapsed ? "chevron.down" : "chevron.up"
                    )
                }

                Button {
                    viewModel.loadDemoPlan()
                } label: {
                    Label("加载示例数据", systemImage: "wand.and.stars")
                }
            } label: {
                HStack(alignment: .center, spacing: 5) {
                    Circle()
                        .fill(palette.swatchDot)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.6))
                    Text(viewModel.theme.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    Capsule()
                        .fill(palette.composerWellBg)
                        .overlay(Capsule().strokeBorder(palette.hairline, lineWidth: 1))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            connectionStatusBadge
        }
        .padding(.horizontal, 24)
    }

    private var connectionStatusBadge: some View {
        Menu {
            ForEach(AIProviderMode.allCases) { mode in
                Button {
                    viewModel.aiProviderMode = mode
                } label: {
                    HStack {
                        Text(mode.rawValue)
                        if viewModel.aiProviderMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button("刷新连接状态") {
                viewModel.refreshCodexStatus()
            }
            Button("终端登录 OpenAI Codex…") {
                CodexCLIBridge.openTerminalForInstallOrLogin()
            }
        } label: {
            HStack(alignment: .center, spacing: 4) {
                Circle()
                    .fill(viewModel.codexStatus.isReady ? palette.committedTone : palette.reminderTone)
                    .frame(width: 5.5, height: 5.5)
                Text(viewModel.codexStatus.activeProviderLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(palette.composerWellBg)
                    .overlay(Capsule().strokeBorder(palette.hairline, lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(viewModel.codexStatus.statusMessage)
    }

    // MARK: - Soft Recessed Command Composer Pill

    private var sleekCommandComposerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "plus.bubble")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            TextField(
                "输入备忘或粘贴微信聊天记录，按 ⌘↩ 智能拆解…",
                text: $viewModel.inputText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(1...3)
            .focused($isComposerFocused)

            if !viewModel.inputText.isEmpty {
                Button {
                    viewModel.inputText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Button {
                Task { await viewModel.captureScreenAndAnalyze() }
            } label: {
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 11, weight: .medium))
                    Text("截图识别 ⌥⇧S")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.subtleButtonBg)
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(viewModel.isAnalyzing)

            Button {
                Task { await viewModel.runAnalysis() }
            } label: {
                HStack(alignment: .center, spacing: 4) {
                    if viewModel.isAnalyzing {
                        ProgressView().controlSize(.mini)
                        Text("拆解中…")
                            .font(.system(size: 11, weight: .semibold))
                    } else {
                        Text("拆解")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("⌘↩")
                            .font(.system(size: 10))
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(palette.primaryActionFg)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.primaryActionBg)
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(viewModel.isAnalyzing)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.composerWellBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(palette.hairline, lineWidth: 1)
                )
        )
    }

    private func statusBannerLine(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(viewModel.isErrorBanner ? palette.urgentTone : palette.committedTone)
                .frame(width: 5.5, height: 5.5)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(viewModel.isErrorBanner ? palette.urgentTone : .secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    // MARK: - Zero-Drawer, Strictly Aligned 2-Line Document Body

    private func recordInspectorContent(record: HistoryRecord) -> some View {
        let activePlan = viewModel.parsedPlan ?? record.plan
        return VStack(alignment: .leading, spacing: 0) {
            // Document Header: Flush-left title & raw input; flush-right actions
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(record.displayTitle)
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(Self.fullTimeString(record.createdAt))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }

                    if !record.rawInputText.isEmpty {
                        Text("原始输入：\(record.rawInputText)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                HStack(alignment: .center, spacing: 6) {
                    // 1. Add Draft Menu
                    Menu {
                        ForEach(DraftTargetKind.allCases) { kind in
                            Button {
                                viewModel.addNewDraftItem(kind: kind)
                            } label: {
                                Label("新增\(kind.rawValue)", systemImage: kind.iconName)
                            }
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text("新增")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(palette.subtleButtonBg)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    // 2. More Actions Menu
                    Menu {
                        Button {
                            viewModel.togglePinRecord(record.id)
                        } label: {
                            Label(record.isPinned ? "取消置顶" : "置顶此条记录", systemImage: record.isPinned ? "pin.slash" : "pin")
                        }

                        if !record.rawInputText.isEmpty {
                            Button {
                                viewModel.isInputCollapsed = false
                                viewModel.inputText = record.rawInputText
                            } label: {
                                Label("填入上方输入框", systemImage: "arrow.uturn.up")
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            viewModel.deleteHistoryRecord(record.id)
                        } label: {
                            Label("删除此条历史记录", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(palette.subtleButtonBg)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    // 3. Primary Commit Action
                    Button {
                        Task { await viewModel.commitCurrentPlan() }
                    } label: {
                        HStack(alignment: .center, spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text(record.isCommitted ? "重新写入 (\(viewModel.selectedTotalCount))" : "一键写入系统 (\(viewModel.selectedTotalCount))")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(palette.primaryActionFg)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.selectedTotalCount > 0 ? palette.primaryActionBg : Color.secondary.opacity(0.3))
                        )
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .disabled(viewModel.isExecuting || viewModel.selectedTotalCount == 0)
                }
            }
            .padding(.bottom, 12)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            // Parsed Items List (Every row is strictly 2 lines, aligned to X = 0 / 28 / 92)
            sheetRowsBody(plan: activePlan)
        }
        .id(record.id)
    }

    private func sheetRowsBody(plan: ParsedPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(plan.items) { item in
                editableDraftRow(item: item)
                if item.id != plan.items.last?.id {
                    Rectangle()
                        .fill(palette.hairline)
                        .frame(height: 1)
                        .padding(.leading, col3LeadingIndent)
                }
            }
        }
    }

    private func tone(for kind: DraftTargetKind) -> Color {
        switch kind {
        case .calendar: return palette.calendarTone
        case .reminder: return palette.reminderTone
        case .alarm:    return palette.urgentTone
        case .note:     return palette.noteTone
        }
    }

    // Strict 3-Column, 2-Line Row Grid (Apple Reminders / Calendar Popover Style):
    // Col 1 (18pt): Checkbox
    // Gap   (10pt)
    // Col 2 (44pt): Clean Semantic Pill (`日历` / `提醒` / `闹钟` / `备忘`) — click to open editor popover
    // Gap   (12pt)
    // Col 3 (Starts at X = 84pt):
    //   Line 1: Bold Title Text + subtle `编辑` & `×` buttons on far right
    //   Line 2: Single clean metadata line (Time · Reminder · Location/Notes)
    private func editableDraftRow(item: DraftItem) -> some View {
        let current = viewModel.draftItem(id: item.id, fallback: item)
        let activeTone = tone(for: current.targetKind)
        let isPopoverOpen = Binding<Bool>(
            get: { viewModel.editingItemID == item.id },
            set: { newValue in
                viewModel.editingItemID = newValue ? item.id : nil
            }
        )

        return HStack(alignment: .top, spacing: 0) {
            // Col 1: 18pt Checkbox
            Button {
                viewModel.toggleItemSelection(id: item.id)
            } label: {
                Image(systemName: current.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14.5))
                    .foregroundStyle(current.isSelected ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.32))
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)

            // Col 2: 44pt Pure SwiftUI Semantic Pill (Zero NSPopUpButton truncation!)
            Button {
                isPopoverOpen.wrappedValue.toggle()
            } label: {
                Text(current.targetKind.rawValue)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(activeTone)
                    .frame(width: 44, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(activeTone.opacity(0.11))
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .help("点击修改类型（日历 / 提醒 / 闹钟 / 备忘）与详情")

            // Col 3: Starts at exact X = 84pt
            VStack(alignment: .leading, spacing: 3.5) {
                // Line 1: Clean Title + Subtle Edit / Delete Buttons
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        isPopoverOpen.wrappedValue.toggle()
                    } label: {
                        Text(current.title.isEmpty ? "未命名事项" : current.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    Button {
                        isPopoverOpen.wrappedValue.toggle()
                    } label: {
                        Text("修改")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .frame(height: 19)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(palette.subtleButtonBg)
                            )
                    }
                    .buttonStyle(.plain)
                    .fixedSize()

                    Button {
                        viewModel.deleteDraftItem(id: item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 19, height: 19)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("删除此项")
                }

                // Line 2: Pure SwiftUI Single-Line Summary (100% aligned baseline)
                Button {
                    isPopoverOpen.wrappedValue.toggle()
                } label: {
                    Text(summaryDetailLine(for: current))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10.5)
        .opacity(current.isSelected ? 1.0 : 0.45)
        .popover(isPresented: isPopoverOpen, arrowEdge: .trailing) {
            draftEditorPopover(item: current)
        }
        .contextMenu {
            Menu("切换类型（日历 / 提醒 / 闹钟 / 备忘）") {
                ForEach(DraftTargetKind.allCases) { kind in
                    Button {
                        viewModel.setItemTargetKind(id: item.id, kind: kind)
                    } label: {
                        Label("转为\(kind.rawValue)", systemImage: kind.iconName)
                    }
                }
            }

            Button {
                isPopoverOpen.wrappedValue = true
            } label: {
                Label("修改草稿详情…", systemImage: "slider.horizontal.3")
            }

            Divider()

            Button(role: .destructive) {
                viewModel.deleteDraftItem(id: item.id)
            } label: {
                Label("删除此项", systemImage: "trash")
            }
        }
    }

    private func summaryDetailLine(for item: DraftItem) -> String {
        switch item.targetKind {
        case .calendar:
            let timeStr = PromptBuilder.formatReadableRange(startISO: item.startISO, endISO: item.endISO)
            let leadStr = item.leadTimeMinutes.isEmpty ? "准点" : item.leadTimeMinutes.map { PromptBuilder.formatLeadTimeMinutes($0) }.joined(separator: "/")
            return [timeStr, item.location, "提醒：\(leadStr)", item.notes]
                .filter { !$0.isEmpty }
                .joined(separator: "  ·  ")

        case .reminder, .alarm:
            let iso = item.startISO.isEmpty ? item.alarmTimeISO : item.startISO
            let timeStr = PromptBuilder.formatReadableSingleTime(iso)
            let leadStr = item.leadTimeMinutes.isEmpty ? "准点" : item.leadTimeMinutes.map { PromptBuilder.formatLeadTimeMinutes($0) }.joined(separator: "/")
            return [timeStr, "提醒：\(leadStr)", item.location, item.notes]
                .filter { !$0.isEmpty }
                .joined(separator: "  ·  ")

        case .note:
            let cat = item.category.isEmpty ? "备忘" : item.category
            let body = item.notes.replacingOccurrences(of: "\n", with: " ")
            return "[\(cat)]  \(body)"
        }
    }

    // Native macOS Popover Inspector (Like Apple Calendar / Reminders — keeps main list 100% clean & aligned!)
    private func draftEditorPopover(item: DraftItem) -> some View {
        let startDateBinding = Binding<Date>(
            get: {
                PromptBuilder.parseISODate(item.startISO)
                    ?? PromptBuilder.parseISODate(item.alarmTimeISO)
                    ?? Date().addingTimeInterval(3600)
            },
            set: { newDate in
                viewModel.updateItemStartDate(id: item.id, newDate)
            }
        )

        let endDateBinding = Binding<Date>(
            get: {
                if let e = PromptBuilder.parseISODate(item.endISO) {
                    return e
                }
                let s = PromptBuilder.parseISODate(item.startISO) ?? Date().addingTimeInterval(3600)
                return s.addingTimeInterval(3600)
            },
            set: { newDate in
                viewModel.updateItemEndDate(id: item.id, newDate)
            }
        )

        return VStack(alignment: .leading, spacing: 12) {
            // 1. 4-Way Target Switcher: 日历 | 提醒 | 闹钟 | 备忘
            HStack(spacing: 3) {
                ForEach(DraftTargetKind.allCases) { kind in
                    let isSelected = (item.targetKind == kind)
                    let kindTone = tone(for: kind)
                    Button {
                        viewModel.setItemTargetKind(id: item.id, kind: kind)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: kind.iconName)
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(kind.rawValue)
                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        }
                        .foregroundStyle(isSelected ? kindTone : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? kindTone.opacity(0.14) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            // 2. Title Field
            VStack(alignment: .leading, spacing: 4) {
                Text("标题")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    "输入事项标题…",
                    text: Binding(
                        get: { viewModel.draftItem(id: item.id, fallback: item).title },
                        set: { viewModel.updateItemTitle(id: item.id, $0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
            }

            if item.targetKind != .note {
                // 3. Date & Time Picker
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.targetKind == .alarm ? "闹钟时间" : "日期与时间")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        DatePicker("", selection: startDateBinding, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.stepperField)

                        if item.targetKind == .calendar {
                            Text("至")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            DatePicker("", selection: endDateBinding, displayedComponents: [.hourAndMinute])
                                .labelsHidden()
                                .datePickerStyle(.stepperField)
                        }
                    }

                    HStack(spacing: 5) {
                        quickTimePresetButton(title: "今天18:00", dayOffset: 0, hour: 18, minute: 0, itemID: item.id)
                        quickTimePresetButton(title: "明早08:00", dayOffset: 1, hour: 8, minute: 0, itemID: item.id)
                        quickTimePresetButton(title: "明天10:00", dayOffset: 1, hour: 10, minute: 0, itemID: item.id)
                        quickTimePresetButton(title: "明天15:00", dayOffset: 1, hour: 15, minute: 0, itemID: item.id)
                    }
                }

                // 4. Advance Reminder Chips
                VStack(alignment: .leading, spacing: 5) {
                    Text("提前提醒")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    let presets: [(label: String, mins: [Int])] = [
                        ("准点", [0]),
                        ("5分钟", [5]),
                        ("15分钟", [15]),
                        ("30分钟", [30]),
                        ("1小时", [60]),
                        ("3小时", [180, 60])
                    ]

                    HStack(spacing: 4) {
                        ForEach(presets, id: \.label) { preset in
                            let isCurrent = (item.leadTimeMinutes == preset.mins)
                            Button {
                                viewModel.updateItemLeadTimes(id: item.id, preset.mins)
                            } label: {
                                Text(preset.label)
                                    .font(.system(size: 10.5, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? Color.white : .secondary)
                                    .padding(.horizontal, 7)
                                    .frame(height: 22)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(isCurrent ? Color.black.opacity(0.82) : Color.primary.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // 5. Location & Notes
            VStack(alignment: .leading, spacing: 6) {
                if item.targetKind != .note {
                    Text("地点与备注")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField(
                        "地点（可选，如：国贸三期 / 首都机场 T2）",
                        text: Binding(
                            get: { viewModel.draftItem(id: item.id, fallback: item).location },
                            set: { viewModel.updateItemLocation(id: item.id, $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                } else {
                    Text("备忘内容")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                TextField(
                    "备注详情…",
                    text: Binding(
                        get: { viewModel.draftItem(id: item.id, fallback: item).notes },
                        set: { viewModel.updateItemNotes(id: item.id, $0) }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .font(.system(size: 12))
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func quickTimePresetButton(title: String, dayOffset: Int, hour: Int, minute: Int, itemID: UUID) -> some View {
        Button {
            let cal = Calendar.current
            let baseDay = cal.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
            if let targetDate = cal.date(bySettingHour: hour, minute: minute, second: 0, of: baseDay) {
                viewModel.updateItemStartDate(id: itemID, targetDate)
            }
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    private var emptyWorkspacePlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("选择左侧历史记录，或在上方输入新备忘")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Cached Date Formatting Helpers

    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func shortTimeString(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return todayFormatter.string(from: date)
        } else {
            return shortDateFormatter.string(from: date)
        }
    }

    private static func fullTimeString(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }
}
