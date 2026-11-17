import SwiftUI
import AppKit
import MemoPilotCore

struct PaperDigestWorkspaceView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var paperVM: PaperDigestViewModel
    var isStandaloneWindow: Bool = false

    @FocusState private var isURLInputFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @State private var dragStartSidebarWidth: CGFloat?
    @State private var isHoveringDivider: Bool = false
    @State private var hoveredRecordID: UUID?

    private var palette: ThemePalette {
        ThemePalette.forTheme(appViewModel.theme)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !paperVM.isSidebarCollapsed {
                paperSidebarColumn
                    .frame(width: paperVM.sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(palette.sidebarBg)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                resizableDivider
            }

            paperMainDetailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(palette.mainCanvasBg)
        }
        .ignoresSafeArea(.all, edges: .top)
        .frame(minWidth: 920, minHeight: 560, alignment: .topLeading)
        .environment(\.colorScheme, appViewModel.theme.isDark ? .dark : .light)
        .onAppear {
            appViewModel.refreshCodexStatus()
        }
    }

    private var resizableDivider: some View {
        Rectangle()
            .fill(isHoveringDivider ? Color.accentColor.opacity(0.42) : palette.hairline)
            .frame(width: isHoveringDivider ? 2 : 1)
            .contentShape(Rectangle().inset(by: -3))
            .animation(.easeOut(duration: 0.12), value: isHoveringDivider)
            .onHover { isHoveringDivider = $0 }
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    paperVM.isSidebarCollapsed.toggle()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragStartSidebarWidth ?? paperVM.sidebarWidth
                        if dragStartSidebarWidth == nil {
                            dragStartSidebarWidth = base
                        }
                        let proposed = base + value.translation.width
                        if proposed >= 180 {
                            paperVM.sidebarWidth = min(max(proposed, 235), 360)
                        }
                    }
                    .onEnded { value in
                        let base = dragStartSidebarWidth ?? paperVM.sidebarWidth
                        dragStartSidebarWidth = nil
                        if base + value.translation.width < 180 {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                                paperVM.isSidebarCollapsed = true
                            }
                        }
                    }
            )
    }

    // MARK: - Left Sidebar (论文速递库)

    private var paperSidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                Spacer().frame(width: 78)
                Spacer()
                sidebarToggleButton
                newPaperButton
            }
            .frame(height: 46)
            .padding(.trailing, 12)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            // 4-Way Filter Bar
            HStack(spacing: 2) {
                ForEach(PaperDigestFilter.allCases) { filter in
                    let isSelected = (paperVM.selectedFilter == filter)
                    Text(filter.rawValue)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(isSelected ? palette.sidebarSelectedRow : Color.primary.opacity(0.001))
                                .shadow(color: isSelected ? Color.black.opacity(0.04) : .clear, radius: 2, x: 0, y: 1)
                        )
                        .hoverHighlight(cornerRadius: 5.5, hoverOpacity: 0.055, isSuppressed: isSelected)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                paperVM.selectedFilter = filter
                            }
                        }
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

            if paperVM.filteredRecords.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text(paperVM.records.isEmpty ? "暂无论文解析记录" : "当前筛选无匹配论文")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !paperVM.starredRecords.isEmpty {
                            collapsiblePaperSection(
                                title: "星标收藏",
                                icon: "star.fill",
                                isExpanded: $paperVM.isStarredSectionExpanded,
                                records: paperVM.starredRecords
                            )
                        }
                        if !paperVM.unstarredRecords.isEmpty {
                            collapsiblePaperSection(
                                title: "最近解析",
                                icon: nil,
                                isExpanded: $paperVM.isRecentSectionExpanded,
                                records: paperVM.unstarredRecords
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .center) {
                Text("共 \(paperVM.records.count) 篇论文/推送")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !paperVM.records.isEmpty {
                    Button("清空") {
                        paperVM.clearAllRecords()
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .buttonStyle(FullHitAreaButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                paperVM.isSidebarCollapsed.toggle()
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
        .buttonStyle(FullHitAreaButtonStyle())
        .help("显示/隐藏左侧论文列表")
    }

    private var newPaperButton: some View {
        Button {
            paperVM.urlOrTextInput = ""
            isURLInputFocused = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(palette.subtleButtonBg)
                )
        }
        .buttonStyle(FullHitAreaButtonStyle())
        .help("输入新公众号/论文链接")
    }

    private func collapsiblePaperSection(
        title: String,
        icon: String?,
        isExpanded: Binding<Bool>,
        records: [PaperDigestRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.reminderTone)
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
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.001))
            .hoverHighlight(cornerRadius: 5.5, hoverOpacity: 0.055)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.wrappedValue.toggle()
                }
            }

            if isExpanded.wrappedValue {
                VStack(spacing: 4) {
                    ForEach(records) { record in
                        paperSidebarRow(record)
                    }
                }
            }
        }
    }

    private func paperSidebarRow(_ record: PaperDigestRecord) -> some View {
        let isSelected = (paperVM.selectedRecordID == record.id)
        let isHovered = (hoveredRecordID == record.id)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(record.isArchivedToNotes ? palette.committedTone : palette.calendarTone)
                    .frame(width: 5.5, height: 5.5)

                Text(record.sidebarTitle)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if record.isPinned {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(palette.reminderTone)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !record.digest.authorsAndAffiliations.isEmpty {
                Text(record.digest.authorsAndAffiliations)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 5) {
                if !record.digest.sourceAccountOrSite.isEmpty {
                    Text(record.digest.sourceAccountOrSite)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if record.digest.hasOpenSourceCode {
                    Text("· 含代码")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(palette.committedTone)
                }
                Spacer(minLength: 0)
                Text(Self.shortDateString(record.createdAt))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? palette.sidebarSelectedRow
                        : (isHovered ? palette.sidebarSelectedRow.opacity(0.62) : Color.primary.opacity(0.001))
                )
                .shadow(color: isSelected ? Color.black.opacity(0.04) : .clear, radius: 2, x: 0, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? palette.hairline : (isHovered ? palette.hairline.opacity(0.75) : Color.clear),
                            lineWidth: 1
                        )
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                paperVM.selectRecord(record.id)
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredRecordID = record.id
            } else if hoveredRecordID == record.id {
                hoveredRecordID = nil
            }
        }
        .contextMenu {
            Button {
                paperVM.toggleStar(record.id)
            } label: {
                Label(record.isPinned ? "取消星标" : "设为星标收藏", systemImage: record.isPinned ? "star.slash" : "star")
            }

            Button {
                paperVM.copyMarkdownToClipboard(record)
            } label: {
                Label("复制完整 Markdown 笔记", systemImage: "doc.on.doc")
            }

            Button {
                Task { await paperVM.archiveToAppleNotes(record) }
            } label: {
                Label("归档至苹果备忘录", systemImage: "note.text")
            }

            if !record.digest.sourceURL.isEmpty, let url = URL(string: record.digest.sourceURL) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("在浏览器打开原链接", systemImage: "safari")
                }
            }

            Divider()

            Button(role: .destructive) {
                paperVM.deleteRecord(record.id)
            } label: {
                Label("删除此篇记录", systemImage: "trash")
            }
        }
    }

    // MARK: - Right Main Detail Column

    private var paperMainDetailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            paperHeaderBar
                .frame(height: 46)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    paperURLComposerBar

                    if let banner = paperVM.statusBanner {
                        paperStatusBannerLine(banner)
                    }

                    if let record = paperVM.currentRecord {
                        paperInspectorCard(record: record)
                    } else {
                        emptyPaperPlaceholder
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var paperHeaderBar: some View {
        HStack(alignment: .center, spacing: 10) {
            if paperVM.isSidebarCollapsed {
                Spacer().frame(width: 66)
                sidebarToggleButton
                newPaperButton
                Divider()
                    .frame(height: 14)
                    .opacity(0.5)
            }

            if isStandaloneWindow {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.calendarTone)
                    Text("MemoPilot · 论文与推送解析")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .fixedSize()

                Button {
                    AppDelegate.bringMainWindowToFront()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10, weight: .semibold))
                        Text("备忘主窗口")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 23)
                    .background(
                        Capsule()
                            .fill(palette.composerWellBg)
                            .overlay(Capsule().strokeBorder(palette.hairline, lineWidth: 1))
                    )
                }
                .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 11))
                .fixedSize()
            } else {
                WorkspaceModeSwitcherBar(appViewModel: appViewModel, palette: palette)
            }

            Spacer(minLength: 6)

            // Search Field
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                TextField("搜索标题、机构或标签…", text: $paperVM.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($isSearchFocused)
                if !paperVM.searchQuery.isEmpty {
                    Button {
                        paperVM.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(FullHitAreaButtonStyle())
                }
            }
            .frame(width: 168, height: 24)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.composerWellBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(palette.hairline, lineWidth: 1)
                    )
            )

            // Theme Pill
            Menu {
                Section("界面底色") {
                    ForEach(WorkspaceTheme.allCases) { themeOption in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                appViewModel.theme = themeOption
                            }
                        } label: {
                            HStack {
                                Text(themeOption.rawValue)
                                if appViewModel.theme == themeOption {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 5) {
                    Circle()
                        .fill(palette.swatchDot)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.6))
                    Text(appViewModel.theme.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            .hoverHighlight(cornerRadius: 12, hoverOpacity: 0.065)

            // AI Provider Status Pill
            Menu {
                Section("AI 通道选择") {
                    ForEach(AIProviderMode.allCases) { mode in
                        Button {
                            appViewModel.aiProviderMode = mode
                        } label: {
                            HStack {
                                Text(mode.rawValue)
                                if appViewModel.aiProviderMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Divider()
                Section("解析深度与速度") {
                    ForEach(AISpeedProfile.allCases) { profile in
                        Button {
                            appViewModel.aiSpeedProfile = profile
                        } label: {
                            HStack {
                                Text(profile.rawValue)
                                if appViewModel.aiSpeedProfile == profile {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 4) {
                    Circle()
                        .fill(appViewModel.codexStatus.isReady ? palette.committedTone : palette.reminderTone)
                        .frame(width: 5.5, height: 5.5)
                    Text(appViewModel.codexStatus.activeProviderLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            .hoverHighlight(cornerRadius: 12, hoverOpacity: 0.065)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - URL / Article Composer Bar

    private var paperURLComposerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(palette.calendarTone)
                .padding(.leading, 2)

            TextField(
                "粘贴微信公众号推送链接、arXiv / HuggingFace / GitHub 链接（或直接粘贴正文），按 ⌘↩ 深度拆解…",
                text: $paperVM.urlOrTextInput,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(1...3)
            .focused($isURLInputFocused)

            if !paperVM.urlOrTextInput.isEmpty {
                Button {
                    paperVM.urlOrTextInput = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(FullHitAreaButtonStyle())
            }

            Button {
                Task {
                    await paperVM.pasteClipboardAndAnalyze(
                        preferredMode: appViewModel.aiProviderMode,
                        speedProfile: appViewModel.aiSpeedProfile
                    )
                }
            } label: {
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .medium))
                    Text("剪贴板链接")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.subtleButtonBg)
                )
            }
            .buttonStyle(FullHitAreaButtonStyle())
            .fixedSize()
            .disabled(paperVM.isAnalyzing)

            Button {
                Task {
                    await paperVM.runAnalysis(
                        preferredMode: appViewModel.aiProviderMode,
                        speedProfile: appViewModel.aiSpeedProfile
                    )
                }
            } label: {
                HStack(alignment: .center, spacing: 5) {
                    if paperVM.isAnalyzing {
                        ProgressView().controlSize(.mini)
                        Text("解析中…")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    } else {
                        Text("解析论文")
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        Text("⌘↩")
                            .font(.system(size: 10))
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(palette.primaryActionFg)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.primaryActionBg)
                )
            }
            .buttonStyle(FullHitAreaButtonStyle())
            .fixedSize()
            .disabled(paperVM.isAnalyzing)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7.5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.composerWellBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(palette.hairline, lineWidth: 1)
                )
        )
    }

    private func paperStatusBannerLine(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if paperVM.isAnalyzing || paperVM.isArchivingNotes {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(paperVM.isErrorBanner ? palette.urgentTone : palette.committedTone)
                    .frame(width: 5.5, height: 5.5)
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(paperVM.isErrorBanner ? palette.urgentTone : .secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Spacer()

            if let record = paperVM.currentRecord {
                if text.contains("备忘录") && record.isArchivedToNotes {
                    Button {
                        AppleExecutors.openAppleNote(externalID: record.appleNoteExternalID)
                    } label: {
                        HStack(spacing: 3) {
                            Text("打开备忘录")
                                .font(.system(size: 10.5, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(palette.subtleButtonBg))
                    }
                    .buttonStyle(FullHitAreaButtonStyle())
                    .fixedSize()
                } else if text.contains("Markdown 文件"), let mdPath = record.exportedMarkdownPath {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mdPath)])
                    } label: {
                        HStack(spacing: 3) {
                            Text("在 Finder 显示")
                                .font(.system(size: 10.5, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(palette.subtleButtonBg))
                    }
                    .buttonStyle(FullHitAreaButtonStyle())
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - 6-Module Paper Digest Holographic Card

    private func paperInspectorCard(record: PaperDigestRecord) -> some View {
        let d = record.digest

        return VStack(alignment: .leading, spacing: 16) {
            // Module 1: Paper Identity Header + Direct Links + Export Toolbar
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    // Left: Alias & Venue Badge (Single-line, never squeezes action buttons)
                    HStack(spacing: 6) {
                        if !d.shortAlias.isEmpty {
                            Text(d.shortAlias)
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(palette.calendarTone)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(palette.calendarTone.opacity(0.12))
                                )
                        }

                        if !d.venueAndDate.isEmpty {
                            Text(d.venueAndDate)
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(palette.subtleButtonBg)
                                )
                        }
                    }

                    Spacer(minLength: 8)

                    // Right: Star + Copy MD + Save .md + Archive to Apple Notes
                    HStack(alignment: .center, spacing: 6) {
                        Button {
                            paperVM.toggleStar(record.id)
                        } label: {
                            Image(systemName: record.isPinned ? "star.fill" : "star")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(record.isPinned ? palette.reminderTone : .secondary)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.subtleButtonBg))
                        }
                        .buttonStyle(FullHitAreaButtonStyle())
                        .help(record.isPinned ? "取消星标收藏" : "加入星标收藏")

                        Button {
                            paperVM.copyMarkdownToClipboard(record)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("复制 MD")
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.subtleButtonBg))
                        }
                        .buttonStyle(FullHitAreaButtonStyle())
                        .fixedSize()
                        .help("一键复制带 YAML Frontmatter 的结构化 Markdown")

                        Menu {
                            Button {
                                paperVM.exportMarkdownToLocalFolder(record, forceChooseFolder: false)
                            } label: {
                                if let savedDir = paperVM.savedExportDirectoryPath {
                                    Label("快速导出至：\((savedDir as NSString).lastPathComponent)", systemImage: "arrow.down.doc")
                                } else {
                                    Label("导出 .md 文件到本地目录 / Obsidian…", systemImage: "arrow.down.doc")
                                }
                            }

                            if paperVM.savedExportDirectoryPath != nil {
                                Button {
                                    paperVM.exportMarkdownToLocalFolder(record, forceChooseFolder: true)
                                } label: {
                                    Label("更改默认导出文件夹…", systemImage: "folder.badge.gearshape")
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("存为 .md")
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.subtleButtonBg))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .hoverHighlight(cornerRadius: 6, hoverOpacity: 0.07)

                        Button {
                            Task { await paperVM.archiveToAppleNotes(record) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: record.isArchivedToNotes ? "checkmark.circle.fill" : "note.text.badge.plus")
                                    .font(.system(size: 10.5, weight: .bold))
                                Text(record.isArchivedToNotes ? "已存备忘录" : "归档备忘录")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(palette.primaryActionFg)
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(record.isArchivedToNotes ? palette.committedTone : palette.primaryActionBg)
                            )
                        }
                        .buttonStyle(FullHitAreaButtonStyle())
                        .fixedSize()
                        .disabled(paperVM.isArchivingNotes)
                    }
                    .fixedSize()
                }

                // Primary & Chinese Titles
                Text(d.primaryDisplayTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .textSelection(.enabled)

                if !d.paperTitleZH.isEmpty && d.paperTitleZH != d.primaryDisplayTitle {
                    Text(d.paperTitleZH)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !d.domainTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(d.domainTags.prefix(5), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(palette.noteTone)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(palette.noteTone.opacity(0.10))
                                )
                        }
                    }
                }

                if !d.authorsAndAffiliations.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "building.columns")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                        Text(d.authorsAndAffiliations)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }

                // Direct External Links Strip
                HStack(spacing: 8) {
                    if !d.sourceURL.isEmpty {
                        externalLinkPill(
                            label: d.sourceAccountOrSite.isEmpty ? "打开原推送" : d.sourceAccountOrSite,
                            icon: "link",
                            urlString: d.sourceURL,
                            tone: palette.noteTone
                        )
                    }
                    if !d.paperURL.isEmpty {
                        externalLinkPill(label: "论文主页 / arXiv", icon: "doc.text", urlString: d.paperURL, tone: palette.calendarTone)
                    }
                    if !d.pdfURL.isEmpty {
                        externalLinkPill(label: "PDF 直达", icon: "arrow.up.right.square", urlString: d.pdfURL, tone: palette.calendarTone)
                    }
                    if !d.codeURL.isEmpty {
                        externalLinkPill(label: "开源代码 / 模型", icon: "chevron.left.forwardslash.chevron.right", urlString: d.codeURL, tone: palette.committedTone)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.slash")
                                .font(.system(size: 9.5))
                            Text("代码暂未开源")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .frame(height: 23)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.subtleButtonBg))
                    }
                    if !d.projectURL.isEmpty {
                        externalLinkPill(label: "Project Page", icon: "globe", urlString: d.projectURL, tone: palette.reminderTone)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.bottom, 4)

            Rectangle().fill(palette.hairline).frame(height: 1)

            // Module 2: One-Line Conclusion & Why It Matters
            VStack(alignment: .leading, spacing: 12) {
                if !d.oneLineConclusion.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("一句话核心结论 (TL;DR)", systemImage: "bolt.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(palette.calendarTone)
                        Text(d.oneLineConclusion)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineSpacing(4.5)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(palette.calendarTone.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(palette.calendarTone.opacity(0.20), lineWidth: 1)
                            )
                    )
                }

                if !d.whyItMatters.isEmpty {
                    paperSectionCard(title: "为什么值得读 · 核心洞察", icon: "lightbulb.fill", accent: palette.reminderTone) {
                        Text(d.whyItMatters)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.9))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
            }

            // Module 3: Problem, Bottlenecks & Scope Boundary
            if !d.problemAndBottlenecks.isEmpty || !d.scopeBoundary.isEmpty {
                paperSectionCard(title: "面向的问题与结论边界", icon: "scope", accent: palette.urgentTone) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(d.problemAndBottlenecks.enumerated()), id: \.offset) { _, item in
                            bulletPointRow(text: item, dotColor: palette.urgentTone)
                        }

                        if !d.scopeBoundary.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Text("边界界定")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(palette.reminderTone)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(palette.reminderTone.opacity(0.14)))
                                    .fixedSize()
                                    .padding(.top, 1)

                                Text(d.scopeBoundary)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3.5)
                                    .textSelection(.enabled)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }

            // Module 4: Core Method Breakdown
            if !d.methodSteps.isEmpty {
                paperSectionCard(title: "核心方法与机制拆解", icon: "cpu", accent: palette.noteTone) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(d.methodSteps.enumerated()), id: \.offset) { idx, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text(String(format: "%02d", idx + 1))
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(palette.noteTone)
                                    .frame(width: 24, height: 20)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(palette.noteTone.opacity(0.12))
                                    )
                                    .padding(.top, 1)

                                Text(step)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary.opacity(0.92))
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            // Module 5: Key Quantitative Results & Compute Trade-offs
            if !d.keyResults.isEmpty || !d.computeAndTradeoffs.isEmpty {
                paperSectionCard(title: "关键实验结果与算力权衡", icon: "chart.bar.xaxis", accent: palette.committedTone) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(d.keyResults.enumerated()), id: \.offset) { _, res in
                            bulletPointRow(text: res, dotColor: palette.committedTone)
                        }

                        if !d.computeAndTradeoffs.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Text("代价与权衡")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(palette.urgentTone)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(palette.urgentTone.opacity(0.12)))
                                    .fixedSize()
                                    .padding(.top, 1)

                                Text(d.computeAndTradeoffs)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3.5)
                                    .textSelection(.enabled)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }

            // Module 6: Reviewer Limitations & Editable Personal Notes
            if !d.limitations.isEmpty {
                paperSectionCard(title: "局限性、盲区与未来方向", icon: "exclamationmark.triangle", accent: palette.reminderTone) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(d.limitations.enumerated()), id: \.offset) { _, lim in
                            bulletPointRow(text: lim, dotColor: palette.reminderTone)
                        }
                    }
                }
            }

            // Personal Notes Editor
            paperSectionCard(title: "我的个人批注与灵感", icon: "square.and.pencil", accent: palette.calendarTone) {
                ZStack(alignment: .topLeading) {
                    if record.userNotes.isEmpty {
                        Text("在此记录你对这篇工作的想法、可借鉴到自己实验里的 Trick 或待验证问题（会自动保存并随 Markdown / 备忘录一并导出）…")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                    TextEditor(
                        text: Binding(
                            get: { record.userNotes },
                            set: { paperVM.updateUserNotes(id: record.id, $0) }
                        )
                    )
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 68, maxHeight: 130)
                }
            }
        }
        .id(record.id)
    }

    // MARK: - Reusable Subviews

    private func paperSectionCard<Content: View>(
        title: String,
        icon: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.composerWellBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(palette.hairline, lineWidth: 1)
                )
        )
    }

    private func bulletPointRow(text: String, dotColor: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(dotColor.opacity(0.85))
                .frame(width: 5.5, height: 5.5)
                .padding(.top, 6.5)

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.92))
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }

    private func externalLinkPill(label: String, icon: String, urlString: String, tone: Color) -> some View {
        Button {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(tone)
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tone.opacity(0.11))
            )
        }
        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 5))
        .fixedSize()
        .help(urlString)
    }

    private var emptyPaperPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("在上方粘贴微信公众号推送或 arXiv 链接，一键提炼论文核心方法与量化证据")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func shortDateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

// MARK: - Shared Top-Bar Mode Switcher Pill ([备忘日程 | 论文解析] + ⧉ 弹出独立窗口)

struct WorkspaceModeSwitcherBar: View {
    @ObservedObject var appViewModel: AppViewModel
    let palette: ThemePalette

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(WorkspaceMode.allCases) { mode in
                    let isSelected = (appViewModel.workspaceMode == mode)
                    HStack(spacing: 4) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(mode.rawValue)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(isSelected ? palette.sidebarSelectedRow : Color.primary.opacity(0.001))
                            .shadow(color: isSelected ? Color.black.opacity(0.05) : .clear, radius: 2, x: 0, y: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            appViewModel.workspaceMode = mode
                        }
                    }
                }
            }
            .padding(2.5)
            .background(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(palette.sidebarSegmentWell)
            )
            .fixedSize()

            Button {
                AppDelegate.openPaperDigestWindow()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "uiwindow.split.2x1")
                        .font(.system(size: 10, weight: .semibold))
                    Text("独立窗口")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.composerWellBg)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.hairline, lineWidth: 1))
                )
            }
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
            .fixedSize()
            .help("在独立副窗口中打开「论文与推送解析」，方便与备忘窗口双开对照 (⇧⌘P)")
        }
    }
}
