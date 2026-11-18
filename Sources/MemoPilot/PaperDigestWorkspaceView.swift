import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MemoPilotCore

// MARK: - Responsive Flush-Left Wrapping FlowLayout (Prevents Tag / Link Pill Overflow)

struct WrappingFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 7
    var verticalSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let childProposal = ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxUsedWidth: CGFloat = 0

        for subview in subviews {
            let rawSize = subview.sizeThatFits(childProposal)
            let clampedWidth = maxWidth.isFinite ? min(rawSize.width, maxWidth) : rawSize.width
            let size = CGSize(width: clampedWidth, height: rawSize.height)
            if currentX > 0 && currentX + size.width > maxWidth {
                maxUsedWidth = max(maxUsedWidth, currentX - horizontalSpacing)
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        if currentX > 0 {
            maxUsedWidth = max(maxUsedWidth, currentX - horizontalSpacing)
        }
        let totalHeight = subviews.isEmpty ? 0 : (currentY + rowHeight)
        return CGSize(width: proposal.width ?? maxUsedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let availWidth = max(bounds.width, 1)
        let childProposal = ProposedViewSize(width: availWidth, height: nil)
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let rawSize = subview.sizeThatFits(childProposal)
            let size = CGSize(width: min(rawSize.width, availWidth), height: rawSize.height)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX + 0.5 {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Paper Digest Workspace View (Per-Window Local UI State + Shared Repository)

struct PaperDigestWorkspaceView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var paperVM: PaperDigestViewModel
    var isStandaloneWindow: Bool = false

    // Per-window independent UI state (allows Main Window & Standalone Window to inspect different papers or resize sidebars independently)
    @State private var urlOrTextInput: String = ""
    @State private var selectedRecordID: UUID?
    @State private var searchQuery: String = ""
    @State private var selectedFilter: PaperDigestFilter = .all
    @State private var isSidebarCollapsed: Bool = false
    @State private var sidebarWidth: CGFloat = 268
    @State private var isStarredSectionExpanded: Bool = true
    @State private var isRecentSectionExpanded: Bool = true
    @State private var isShowingClearConfirmation: Bool = false
    @State private var isAuthorsExpanded: Bool = false
    @State private var isURLBarCollapsed: Bool = false
    @State private var isDiscussionExpanded: Bool = false
    @State private var discussionThreadHeight: CGFloat = 185
    @State private var dragStartDiscussionHeight: CGFloat?
    @State private var isHoveringDiscussionDivider: Bool = false
    @State private var isDropTargetingURLBar: Bool = false
    @State private var isDropTargetingDiscussion: Bool = false

    @FocusState private var isURLInputFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isNotesEditorFocused: Bool
    @FocusState private var isDiscussionInputFocused: Bool
    @State private var dragStartSidebarWidth: CGFloat?
    @State private var isHoveringDivider: Bool = false
    @State private var hoveredRecordID: UUID?

    private var palette: ThemePalette {
        ThemePalette.forTheme(appViewModel.theme)
    }

    private var visibleRecords: [PaperDigestRecord] {
        paperVM.filteredRecords(query: searchQuery, filter: selectedFilter)
    }

    private var starredRecords: [PaperDigestRecord] {
        visibleRecords.filter(\.isPinned)
    }

    private var unstarredRecords: [PaperDigestRecord] {
        visibleRecords.filter { !$0.isPinned }
    }

    private var activeRecord: PaperDigestRecord? {
        if let id = selectedRecordID,
           let matched = visibleRecords.first(where: { $0.id == id }) {
            return matched
        }
        return visibleRecords.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !isSidebarCollapsed {
                paperSidebarColumn
                    .frame(width: sidebarWidth)
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
            if selectedRecordID == nil {
                selectedRecordID = paperVM.records.first?.id
                if let first = paperVM.records.first {
                    isDiscussionExpanded = !first.discussionMessages.isEmpty
                    paperVM.prefetchPDFIfNeeded(for: first.id, silent: true)
                }
            }
            if !isStandaloneWindow {
                sidebarWidth = min(max(appViewModel.sidebarWidth, 235), 315)
            }
            appViewModel.refreshCodexStatus()
        }
        .onChange(of: paperVM.latestCreatedRecordID) { _, newID in
            if let newID {
                selectedFilter = .all
                searchQuery = ""
                isAuthorsExpanded = false
                isDiscussionExpanded = false
                selectedRecordID = newID
                paperVM.prefetchPDFIfNeeded(for: newID, silent: true)
            }
        }
        .onChange(of: activeRecord?.id) { _, newActiveID in
            isAuthorsExpanded = false
            if let newActiveID, let rec = paperVM.record(id: newActiveID) {
                isDiscussionExpanded = !rec.discussionMessages.isEmpty
                paperVM.prefetchPDFIfNeeded(for: newActiveID, silent: true)
            } else {
                isDiscussionExpanded = false
            }
        }
        .onChange(of: isDiscussionInputFocused) { _, focused in
            if focused && !isDiscussionExpanded {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                    isDiscussionExpanded = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleSidebarNotification)) { note in
            let targetWin = note.object as? NSWindow
            let expectedWin = isStandaloneWindow ? AppDelegate.paperDigestWindow : AppDelegate.mainWindow
            if targetWin == nil || targetWin === expectedWin {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    isSidebarCollapsed.toggle()
                }
            }
        }
        .confirmationDialog(
            "确定要清空全部论文解析记录吗？",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空全部记录", role: .destructive) {
                paperVM.clearAllRecords()
                selectedRecordID = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将移除本地保存的所有论文解析卡片、缓存 PDF 与个人批注（已归档至苹果备忘录或本地 .md 的文件不受影响）。")
        }
    }

    private var resizableDivider: some View {
        ZStack {
            Rectangle()
                .fill(isHoveringDivider ? Color.accentColor.opacity(0.45) : palette.hairline)
                .frame(width: isHoveringDivider ? 2 : 1)
        }
        .frame(width: 1)
        .overlay {
            NativeSplitResizeHandle(
                orientation: .verticalDivider,
                onHoverChanged: { hovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHoveringDivider = hovering
                    }
                },
                onDragChanged: { translation in
                    let base = dragStartSidebarWidth ?? sidebarWidth
                    if dragStartSidebarWidth == nil {
                        dragStartSidebarWidth = base
                    }
                    let proposed = base + translation.width
                    if proposed >= 180 {
                        let clamped = min(max(proposed, 235), 315)
                        sidebarWidth = clamped
                        if !isStandaloneWindow {
                            appViewModel.sidebarWidth = clamped
                        }
                    }
                },
                onDragEnded: { translation in
                    let base = dragStartSidebarWidth ?? sidebarWidth
                    dragStartSidebarWidth = nil
                    if base + translation.width < 180 {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                            isSidebarCollapsed = true
                        }
                    }
                },
                onDoubleClick: {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        isSidebarCollapsed.toggle()
                    }
                }
            )
            .frame(width: 8)
        }
        .zIndex(10)
    }

    // MARK: - Left Sidebar (论文速递库 — Exact 12pt Horizontal Margins)

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
            .windowTitlebarDragBackground()

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            // 4-Way Filter Segmented Bar
            HStack(spacing: 2) {
                ForEach(PaperDigestFilter.allCases) { filter in
                    let isSelected = (selectedFilter == filter)
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
                                selectedFilter = filter
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

            if visibleRecords.isEmpty {
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
                        if !starredRecords.isEmpty {
                            collapsiblePaperSection(
                                title: "星标收藏",
                                icon: "star.fill",
                                isExpanded: $isStarredSectionExpanded,
                                records: starredRecords
                            )
                        }
                        if !unstarredRecords.isEmpty {
                            collapsiblePaperSection(
                                title: "最近解析",
                                icon: nil,
                                isExpanded: $isRecentSectionExpanded,
                                records: unstarredRecords
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
                        isShowingClearConfirmation = true
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
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
                isSidebarCollapsed.toggle()
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
        .help(isSidebarCollapsed ? "展开论文侧边栏 (⌃⌘S)" : "隐藏论文侧边栏 (⌃⌘S)")
    }

    private var newPaperButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isURLBarCollapsed = false
            }
            urlOrTextInput = ""
            isURLInputFocused = true
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
        .buttonStyle(FullHitAreaButtonStyle())
        .keyboardShortcut("n", modifiers: [.command])
        .help("新建论文链接解析 (⌘N)")
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
                VStack(spacing: 5) {
                    ForEach(records) { record in
                        paperSidebarRow(record)
                    }
                }
            }
        }
    }

    // Consistent 3-Line Card Structure (Matches MainWorkspaceView's historyRowCard alignment)
    private func paperSidebarRow(_ record: PaperDigestRecord) -> some View {
        let isSelected = (activeRecord?.id == record.id)
        let isHovered = (hoveredRecordID == record.id)

        return VStack(alignment: .leading, spacing: 4.5) {
            // Line 1: Status Dot + Title + Star + Right-Aligned Timestamp
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
                        .font(.system(size: 9))
                        .foregroundStyle(palette.reminderTone)
                }

                Text(Self.shortTimeString(record.createdAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Line 2: Authors / Affiliations (Indented 11.5pt to align directly under Title!)
            if !record.digest.authorsAndAffiliations.isEmpty {
                Text(record.digest.authorsAndAffiliations)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 11.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Line 3: Source + Code / Notes Status (Indented 11.5pt to align directly under Title!)
            HStack(spacing: 5) {
                Text(record.digest.sourceAccountOrSite.isEmpty ? "文献解析" : record.digest.sourceAccountOrSite)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if record.digest.hasOpenSourceCode {
                    Text("· 含代码")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.committedTone)
                        .fixedSize()
                }
                if record.isArchivedToNotes {
                    Text("· 已存备忘")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.calendarTone)
                        .fixedSize()
                }
                if !record.discussionMessages.isEmpty {
                    let turns = max(1, record.discussionMessages.filter { $0.role == .user }.count)
                    Text("· 讨论 \(turns)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.noteTone)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 11.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? palette.sidebarSelectedRow
                        : (isHovered ? palette.sidebarSelectedRow.opacity(0.62) : palette.sidebarSelectedRow.opacity(0.28))
                )
                .shadow(color: isSelected ? Color.black.opacity(0.04) : .clear, radius: 2, x: 0, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? palette.hairline : (isHovered ? palette.hairline.opacity(0.75) : palette.hairline.opacity(0.35)),
                            lineWidth: 1
                        )
                )
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            isNotesEditorFocused = false
            isDiscussionInputFocused = false
            isAuthorsExpanded = false
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedRecordID = record.id
                isDiscussionExpanded = !(record.discussionMessages.isEmpty)
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
                Label(record.isArchivedToNotes ? "同步更新至苹果备忘录" : "归档至苹果备忘录", systemImage: "note.text")
            }

            if record.isArchivedToNotes {
                Button {
                    AppleExecutors.openAppleNote(externalID: record.appleNoteExternalID)
                } label: {
                    Label("在「备忘录」中打开查看 ↗", systemImage: "arrow.up.forward.app")
                }
            }

            if paperVM.hasReadyPDF(record) || !record.digest.pdfURL.isEmpty {
                Button {
                    paperVM.openPDFForReading(record)
                } label: {
                    Label("打开原始论文 PDF", systemImage: "doc.richtext")
                }
            }

            Button {
                paperVM.chooseAndAttachLocalPDF(for: record.id)
            } label: {
                Label("关联本地原始 PDF…", systemImage: "paperclip")
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
                if selectedRecordID == record.id {
                    selectedRecordID = visibleRecords.first?.id
                }
            } label: {
                Label("删除此篇记录", systemImage: "trash")
            }
        }
    }

    // MARK: - Right Main Detail Column (Exact 24pt Left/Right Margin + Viewport-Safe Dock Clamp)

    private var paperMainDetailColumn: some View {
        GeometryReader { colGeo in
            let maxAllowedThreadHeight = max(120, min(colGeo.size.height - 210, 480))

            VStack(alignment: .leading, spacing: 0) {
                paperHeaderBar
                    .frame(height: 46)
                    .windowTitlebarDragBackground()

                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: 1)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if !isURLBarCollapsed || activeRecord == nil || paperVM.isAnalyzing {
                            paperURLComposerBar
                        } else {
                            collapsedURLBarPill
                        }

                        if let banner = paperVM.statusBanner {
                            paperStatusBannerLine(banner)
                        }

                        if let record = activeRecord {
                            paperInspectorCard(record: record)
                        } else {
                            emptyPaperPlaceholder
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }

                if let record = activeRecord {
                    paperDiscussionDock(record: record, maxThreadHeightBudget: maxAllowedThreadHeight)
                }
            }
            .frame(width: colGeo.size.width, height: colGeo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Every single header item has exact height = 26pt, centered at Y = 10..36pt inside 46pt bar!
    private var paperHeaderBar: some View {
        HStack(alignment: .center, spacing: 10) {
            if isSidebarCollapsed {
                Spacer().frame(width: 52)
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
                    Text("论文与推送解析")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .fixedSize()

                Button {
                    AppDelegate.bringMainWindowToFront()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                        Text("备忘主窗口")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(
                        Capsule()
                            .fill(palette.composerWellBg)
                            .overlay(Capsule().strokeBorder(palette.hairline, lineWidth: 1))
                    )
                }
                .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 13))
                .fixedSize()
            } else {
                WorkspaceModeSwitcherBar(appViewModel: appViewModel, palette: palette)
            }

            Spacer(minLength: 6)

            // Search Field (26pt uniform height, flexible down to 120pt)
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                TextField("搜索标题、机构或标签 (⌘F)…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($isSearchFocused)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(FullHitAreaButtonStyle())
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 120, idealWidth: 170, maxWidth: 176)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(palette.composerWellBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .strokeBorder(palette.hairline, lineWidth: 1)
                    )
            )
            .background {
                Button("") { isSearchFocused = true }
                    .keyboardShortcut("f", modifiers: [.command])
                    .opacity(0)
            }

            // Theme Pill (26pt exact height, zero NSPopUpButton shift)
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
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    Capsule()
                        .fill(palette.composerWellBg)
                        .overlay(Capsule().strokeBorder(palette.hairline, lineWidth: 1))
                )
            }
            .menuStyle(.button)
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 13))
            .menuIndicator(.hidden)
            .fixedSize()

            // AI Provider Status Pill (26pt exact height, includes refresh & login actions!)
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
                Divider()
                Button("刷新连接状态") {
                    appViewModel.refreshCodexStatus()
                }
                Button("终端登录 OpenAI Codex…") {
                    CodexCLIBridge.openTerminalForInstallOrLogin()
                }
            } label: {
                HStack(alignment: .center, spacing: 5) {
                    Circle()
                        .fill(appViewModel.codexStatus.isReady ? palette.committedTone : palette.reminderTone)
                        .frame(width: 5.5, height: 5.5)
                    Text(appViewModel.codexStatus.activeProviderLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    Capsule()
                        .fill(palette.composerWellBg)
                        .overlay(Capsule().strokeBorder(palette.hairline, lineWidth: 1))
                )
            }
            .menuStyle(.button)
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 13))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(appViewModel.codexStatus.statusMessage)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - URL / Article / Local PDF Composer Bar (Collapsible + Drag & Drop PDF Support)

    private var collapsedURLBarPill: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isURLBarCollapsed = false
                }
                isURLInputFocused = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.calendarTone)
                    Text("解析新论文 / 公众号链接 / 拖入 PDF (⌘N)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.composerWellBg)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.hairline, lineWidth: 1))
                )
            }
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 7))

            Button {
                Task {
                    if let createdID = await paperVM.pasteClipboardAndAnalyze(
                        preferredMode: appViewModel.aiProviderMode,
                        speedProfile: appViewModel.aiSpeedProfile
                    ) {
                        selectedRecordID = createdID
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10.5, weight: .medium))
                    Text("剪贴板一键解析")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.subtleButtonBg))
            }
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 7))
            .disabled(paperVM.isAnalyzing)

            Spacer()
        }
    }

    private var paperURLComposerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isDropTargetingURLBar ? "arrow.down.doc.fill" : "link.badge.plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.calendarTone)
                .padding(.leading, 2)

            TextField(
                "粘贴公众号推送、arXiv / HF / GitHub 链接（或直接拖入本地 PDF），按 ⌘↩ 深度拆解…",
                text: $urlOrTextInput,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(1...3)
            .focused($isURLInputFocused)

            if !urlOrTextInput.isEmpty {
                Button {
                    urlOrTextInput = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(FullHitAreaButtonStyle())
            }

            Button {
                Task {
                    let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !clip.isEmpty {
                        urlOrTextInput = clip
                    }
                    if let createdID = await paperVM.pasteClipboardAndAnalyze(
                        preferredMode: appViewModel.aiProviderMode,
                        speedProfile: appViewModel.aiSpeedProfile
                    ) {
                        selectedRecordID = createdID
                        urlOrTextInput = ""
                    }
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

            if paperVM.isAnalyzing {
                Button {
                    paperVM.cancelAnalysis()
                } label: {
                    HStack(alignment: .center, spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("取消解析")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(palette.primaryActionFg)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.primaryActionBg))
                }
                .buttonStyle(FullHitAreaButtonStyle())
                .fixedSize()
            } else {
                Button {
                    let submitted = urlOrTextInput
                    Task {
                        if let createdID = await paperVM.runAnalysis(
                            rawInput: submitted,
                            preferredMode: appViewModel.aiProviderMode,
                            speedProfile: appViewModel.aiSpeedProfile
                        ) {
                            selectedRecordID = createdID
                            if urlOrTextInput == submitted {
                                urlOrTextInput = ""
                            }
                        }
                    }
                } label: {
                    HStack(alignment: .center, spacing: 4) {
                        Text("解析论文")
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        Text("⌘↩")
                            .font(.system(size: 10))
                            .opacity(0.75)
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
                .keyboardShortcut(.return, modifiers: (isNotesEditorFocused || isDiscussionInputFocused) ? [.command, .option, .shift] : [.command])
            }

            if activeRecord != nil && urlOrTextInput.isEmpty && !paperVM.isAnalyzing {
                Button {
                    isURLInputFocused = false
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isURLBarCollapsed = true
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 26)
                }
                .buttonStyle(FullHitAreaButtonStyle())
                .help("收起顶部输入栏以获得更大阅读视野")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.composerWellBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isDropTargetingURLBar ? palette.calendarTone : palette.hairline, lineWidth: isDropTargetingURLBar ? 1.5 : 1)
                )
        )
        .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargetingURLBar) { providers in
            handleDroppedPDFProviders(providers) { pdfURL in
                Task { @MainActor in
                    urlOrTextInput = pdfURL.path
                    if let createdID = await paperVM.runAnalysis(
                        rawInput: pdfURL.path,
                        preferredMode: appViewModel.aiProviderMode,
                        speedProfile: appViewModel.aiSpeedProfile
                    ) {
                        selectedRecordID = createdID
                        urlOrTextInput = ""
                    }
                }
            }
        }
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

            if let record = activeRecord {
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

    // MARK: - 6-Module Paper Digest Holographic Card (Precision Pixel Grid)

    private func paperInspectorCard(record: PaperDigestRecord) -> some View {
        let d = record.digest

        return VStack(alignment: .leading, spacing: 16) {
            // Module 1: Paper Identity Header + Direct Links + Export Toolbar
            VStack(alignment: .leading, spacing: 11) {
                // Row 1: Left = Alias & Venue (26pt height) | Right = Uniform 26pt Action Buttons (Zero baseline shift & narrow-window safe!)
                HStack(alignment: .center, spacing: 8) {
                    HStack(alignment: .center, spacing: 6) {
                        if !d.shortAlias.isEmpty {
                            Text(d.shortAlias)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(palette.calendarTone)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 140)
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(palette.calendarTone.opacity(0.12))
                                )
                        }

                        if !d.compactVenueBadgeText.isEmpty {
                            Text(d.compactVenueBadgeText)
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(palette.subtleButtonBg)
                                )
                                .help(d.venueAndDate)
                        }
                    }

                    Spacer(minLength: 8)

                    // Right Action Toolbar: Every button/menu is strictly 26pt tall with identical corner radius!
                    HStack(alignment: .center, spacing: 5) {
                        Button {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                                isDiscussionExpanded = true
                            }
                            isDiscussionInputFocused = true
                        } label: {
                            let userTurnCount = record.discussionMessages.filter { $0.role == .user }.count
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(userTurnCount > 0 ? "讨论 (\(userTurnCount))" : "继续讨论")
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(palette.calendarTone)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(palette.calendarTone.opacity(0.11))
                            )
                        }
                        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
                        .fixedSize()
                        .help("展开下方讨论面板，结合结构化卡片与原始 PDF 全文深入问答")

                        Button {
                            paperVM.toggleStar(record.id)
                        } label: {
                            Image(systemName: record.isPinned ? "star.fill" : "star")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(record.isPinned ? palette.reminderTone : .secondary)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.subtleButtonBg))
                        }
                        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
                        .help(record.isPinned ? "取消星标收藏" : "加入星标收藏")

                        Button {
                            paperVM.copyMarkdownToClipboard(record)
                        } label: {
                            HStack(spacing: 3.5) {
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
                        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
                        .fixedSize()
                        .help("一键复制带 YAML Frontmatter 与讨论记录的结构化 Markdown")

                        Menu {
                            Button {
                                paperVM.exportMarkdownToLocalFolder(record, forceChooseFolder: false)
                            } label: {
                                if let savedDir = paperVM.savedExportDirectoryPath {
                                    Label("快速保存 .md 至：\((savedDir as NSString).lastPathComponent)", systemImage: "arrow.down.doc")
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
                            HStack(spacing: 2.5) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                                    .opacity(0.65)
                            }
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.subtleButtonBg))
                        }
                        .menuStyle(.button)
                        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("导出为本地 .md 文件（支持绑定 Obsidian 目录）")

                        Button {
                            Task { await paperVM.archiveToAppleNotes(record) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: record.isArchivedToNotes ? "checkmark.circle.fill" : "note.text.badge.plus")
                                    .font(.system(size: 10.5, weight: .bold))
                                Text(record.isArchivedToNotes ? "更新备忘录" : "归档备忘录")
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
                        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
                        .fixedSize()
                        .disabled(paperVM.isArchivingNotes)
                        .help(record.isArchivedToNotes ? "已归档至备忘录；再次点击可将最新个人批注同步更新至同一篇备忘录" : "一键归档至苹果「备忘录 > MemoPilot 论文速递」")
                    }
                    .fixedSize()
                }

                // Row 2: Primary & Chinese Titles
                VStack(alignment: .leading, spacing: 5) {
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
                }
                .padding(.top, 2)

                // Row 3: Wrapping Domain Tags (Uses WrappingFlowLayout so long tags wrap cleanly to X = 0!)
                if !d.domainTags.isEmpty {
                    WrappingFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(Array(d.domainTags.prefix(6).enumerated()), id: \.offset) { _, tag in
                            Text(tag)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(palette.noteTone)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(palette.noteTone.opacity(0.10))
                                )
                        }
                    }
                }

                // Row 4: Authors & Affiliations with Clean Hanging Indent & Expand Toggle for Long Consortium Lists
                if !d.authorsAndAffiliations.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "building.columns")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, alignment: .center)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(d.authorsAndAffiliations)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(isAuthorsExpanded ? nil : 2)
                                .lineSpacing(2.5)
                                .textSelection(.enabled)

                            if d.authorsAndAffiliations.count > 95 {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        isAuthorsExpanded.toggle()
                                    }
                                } label: {
                                    Text(isAuthorsExpanded ? "收起作者列表 ▴" : "展开全部作者 ▾")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(palette.calendarTone)
                                }
                                .buttonStyle(FullHitAreaButtonStyle())
                            }
                        }
                    }
                }

                // Row 5: Wrapping Direct External Links Strip (Uniform 24pt height, wraps cleanly on narrow windows!)
                WrappingFlowLayout(horizontalSpacing: 7, verticalSpacing: 7) {
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
                    if paperVM.hasReadyPDF(record) || !d.pdfURL.isEmpty {
                        Button {
                            paperVM.openPDFForReading(record)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: paperVM.hasReadyPDF(record) ? "doc.richtext.fill" : "arrow.up.right.square")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(paperVM.hasReadyPDF(record) ? "原始 PDF (已缓存)" : "PDF 直达")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(palette.calendarTone)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(palette.calendarTone.opacity(0.11)))
                        }
                        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 5.5))
                        .help(record.cachedPDFPath ?? d.pdfURL)
                    }
                    if !d.codeURL.isEmpty {
                        externalLinkPill(label: "开源代码 / 模型", icon: "chevron.left.forwardslash.chevron.right", urlString: d.codeURL, tone: palette.committedTone)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.slash")
                                .font(.system(size: 9.5))
                            Text("代码暂未开源")
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(palette.subtleButtonBg))
                    }
                    if !d.projectURL.isEmpty {
                        externalLinkPill(label: "Project Page", icon: "globe", urlString: d.projectURL, tone: palette.reminderTone)
                    }
                    if record.isArchivedToNotes {
                        Button {
                            AppleExecutors.openAppleNote(externalID: record.appleNoteExternalID)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "note.text")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("打开备忘录")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(palette.committedTone)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(palette.committedTone.opacity(0.11)))
                        }
                        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 5.5))
                    }
                }
                .padding(.top, 2)
            }
            .padding(.bottom, 2)

            Rectangle().fill(palette.hairline).frame(height: 1)

            // Module 2: One-Line Conclusion (Uses identical 16pt icon column + 16pt padding as all other cards!)
            if !d.oneLineConclusion.isEmpty {
                paperSectionCard(
                    title: "一句话核心结论 (TL;DR)",
                    icon: "bolt.fill",
                    accent: palette.calendarTone,
                    tintedBackground: palette.calendarTone.opacity(0.065),
                    tintedBorder: palette.calendarTone.opacity(0.20)
                ) {
                    Text(d.oneLineConclusion)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineSpacing(4.5)
                        .padding(.leading, 24)
                        .textSelection(.enabled)
                }
            }

            if !d.whyItMatters.isEmpty {
                paperSectionCard(title: "为什么值得读 · 核心洞察", icon: "lightbulb.fill", accent: palette.reminderTone) {
                    Text(d.whyItMatters)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineSpacing(4.5)
                        .padding(.leading, 24)
                        .textSelection(.enabled)
                }
            }

            // Module 3: Problem, Bottlenecks & Scope Boundary
            if !d.problemAndBottlenecks.isEmpty || !d.scopeBoundary.isEmpty {
                paperSectionCard(title: "面向的问题与结论边界", icon: "scope", accent: palette.urgentTone) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(d.problemAndBottlenecks.enumerated()), id: \.offset) { _, item in
                            bulletPointRow(text: item, dotColor: palette.urgentTone)
                        }

                        if !d.scopeBoundary.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("结论边界与前提")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(palette.reminderTone)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(palette.reminderTone.opacity(0.13)))

                                Text(d.scopeBoundary)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                            }
                            .padding(.leading, 24)
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
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(palette.noteTone)
                                    .frame(width: 16, height: 18, alignment: .center)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                            .fill(palette.noteTone.opacity(0.12))
                                    )
                                    .padding(.top, 1.5)

                                Text(step)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary.opacity(0.92))
                                    .lineSpacing(4.5)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            // Module 5: Key Quantitative Results & Compute Trade-offs
            if !d.keyResults.isEmpty || !d.computeAndTradeoffs.isEmpty {
                paperSectionCard(title: "关键实验结果与算力权衡", icon: "chart.bar.xaxis", accent: palette.committedTone) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(d.keyResults.enumerated()), id: \.offset) { _, res in
                            bulletPointRow(text: res, dotColor: palette.committedTone)
                        }

                        if !d.computeAndTradeoffs.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("算力、显存与工程代价")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(palette.urgentTone)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(palette.urgentTone.opacity(0.12)))

                                Text(d.computeAndTradeoffs)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                            }
                            .padding(.leading, 24)
                            .padding(.top, 4)
                        }
                    }
                }
            }

            // Module 6: Reviewer Limitations & Editable Personal Notes
            if !d.limitations.isEmpty {
                paperSectionCard(title: "局限性、盲区与未来方向", icon: "exclamationmark.triangle", accent: palette.reminderTone) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(d.limitations.enumerated()), id: \.offset) { _, lim in
                            bulletPointRow(text: lim, dotColor: palette.reminderTone)
                        }
                    }
                }
            }

            // Personal Notes Editor (Exact caret alignment with placeholder + guarded against ⌘↩ hijack)
            paperSectionCard(title: "我的个人批注与灵感", icon: "square.and.pencil", accent: palette.calendarTone) {
                ZStack(alignment: .topLeading) {
                    if record.userNotes.isEmpty {
                        Text("在此记录你对这篇工作的想法、可借鉴到自己实验里的 Trick 或待验证问题（自动保存，并随 Markdown / 备忘录同步导出）…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 0)
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
                    .focused($isNotesEditorFocused)
                    .frame(minHeight: 68, maxHeight: 140)
                }
                .padding(.leading, 19)
            }
        }
        .id(record.id)
    }

    // MARK: - Bottom-Docked Paper Discussion Panel (Grounded in Card + Original PDF, Independent Scroll & Draggable Height!)

    private static let quickDiscussionPrompts: [String] = [
        "结合原论文展开讲讲核心模块的具体结构与训练目标",
        "原论文的消融实验与超参数设置（学习率/数据/算力）是什么？",
        "这项工作的实验设计有哪些潜在漏洞或评测盲区？",
        "相比现有主流基线，它最核心的收益与代价取舍是什么？"
    ]

    private func discussionDraftBinding(for recordID: UUID) -> Binding<String> {
        Binding(
            get: { paperVM.discussionDraft(for: recordID) },
            set: { paperVM.setDiscussionDraft($0, for: recordID) }
        )
    }

    private func submitDiscussionQuestion(for record: PaperDigestRecord, presetQuestion: String? = nil) {
        let currentDraft = paperVM.discussionDraft(for: record.id)
        let questionToSend = (presetQuestion ?? currentDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !questionToSend.isEmpty, !paperVM.isDiscussing(record.id) else { return }

        if presetQuestion == nil {
            paperVM.setDiscussionDraft("", for: record.id)
        }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            isDiscussionExpanded = true
        }

        let targetID = record.id
        Task {
            await paperVM.askFollowUpQuestion(
                recordID: targetID,
                question: questionToSend,
                preferredMode: appViewModel.aiProviderMode,
                speedProfile: appViewModel.aiSpeedProfile
            )
        }
    }

    private func paperDiscussionDock(record: PaperDigestRecord, maxThreadHeightBudget: CGFloat) -> some View {
        let isBusy = paperVM.isDiscussing(record.id)
        let isPDFLoading = paperVM.isLoadingPDF(record.id)
        let isPDFReady = paperVM.hasReadyPDF(record)
        let hasMessages = !record.discussionMessages.isEmpty
        let showThreadArea = isDiscussionExpanded || isBusy
        let effectiveThreadHeight = min(max(discussionThreadHeight, 105), maxThreadHeightBudget)
        let draftBinding = discussionDraftBinding(for: record.id)
        let currentDraftText = draftBinding.wrappedValue

        let makeResizeHandle = { () -> NativeSplitResizeHandle in
            NativeSplitResizeHandle(
                orientation: .horizontalDivider,
                onHoverChanged: { hovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHoveringDiscussionDivider = hovering
                    }
                },
                onDragChanged: { translation in
                    if !isDiscussionExpanded {
                        isDiscussionExpanded = true
                    }
                    let base = dragStartDiscussionHeight ?? (showThreadArea ? effectiveThreadHeight : 105)
                    if dragStartDiscussionHeight == nil {
                        dragStartDiscussionHeight = base
                    }
                    // Dragging UP gives negative top-down translation.height -> increases dock height
                    let proposed = base - translation.height
                    if proposed >= 75 {
                        discussionThreadHeight = min(max(proposed, 105), maxThreadHeightBudget)
                    }
                },
                onDragEnded: { translation in
                    let base = dragStartDiscussionHeight ?? effectiveThreadHeight
                    dragStartDiscussionHeight = nil
                    if base - translation.height < 75 && !isBusy {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                            isDiscussionExpanded = false
                        }
                    }
                },
                onDoubleClick: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                        isDiscussionExpanded.toggle()
                    }
                }
            )
        }

        return VStack(alignment: .leading, spacing: 0) {
            // Draggable Horizontal Resize Handle (Outside .onDrop so AppKit DropView never intercepts splitter drags!)
            ZStack {
                Rectangle()
                    .fill(isHoveringDiscussionDivider ? Color.accentColor.opacity(0.55) : palette.hairline)
                    .frame(height: isHoveringDiscussionDivider ? 2 : 1)

                Capsule()
                    .fill(isHoveringDiscussionDivider ? Color.accentColor.opacity(0.85) : palette.hairline.opacity(0.95))
                    .frame(width: 36, height: 3.5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .overlay {
                makeResizeHandle()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .zIndex(30)

            VStack(alignment: .leading, spacing: 9) {
                // Header Strip (Visible when expanded, loading PDF, or when prior messages exist)
                if showThreadArea || hasMessages || isPDFLoading {
                    HStack(alignment: .center, spacing: 8) {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.calendarTone)
                                .frame(width: 16, alignment: .center)

                            Text("继续讨论")
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(.primary)
                                .fixedSize()
                        }
                        .overlay {
                            makeResizeHandle()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        // Live Original PDF Grounding Status Badge / Action Pill
                        pdfGroundingStatusBadge(for: record, isPDFLoading: isPDFLoading, isPDFReady: isPDFReady)

                        makeResizeHandle()
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)

                        if hasMessages {
                            Button {
                                paperVM.clearDiscussion(recordID: record.id)
                            } label: {
                                Text("清空对话")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .frame(height: 22)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.subtleButtonBg))
                            }
                            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 5))
                        }

                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                                isDiscussionExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 3) {
                                let turnCount = record.discussionMessages.filter { $0.role == .user }.count
                                Text(showThreadArea ? "收起" : (turnCount > 0 ? "展开 (\(turnCount))" : "展开"))
                                    .font(.system(size: 10.5, weight: .medium))
                                Image(systemName: showThreadArea ? "chevron.down" : "chevron.up")
                                    .font(.system(size: 8.5, weight: .bold))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.subtleButtonBg))
                        }
                        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 5))
                    }
                }

                // Expandable Thread / Quick Starter Area
                if showThreadArea {
                    if !hasMessages && !isBusy {
                        WrappingFlowLayout(horizontalSpacing: 7, verticalSpacing: 7) {
                            ForEach(Self.quickDiscussionPrompts, id: \.self) { preset in
                                Button {
                                    submitDiscussionQuestion(for: record, presetQuestion: preset)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 9.5, weight: .semibold))
                                        Text(preset)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    .foregroundStyle(palette.calendarTone)
                                    .padding(.horizontal, 10)
                                    .frame(height: 25)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(palette.calendarTone.opacity(0.09))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .strokeBorder(palette.calendarTone.opacity(0.18), lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
                            }
                        }
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(record.discussionMessages) { msg in
                                        discussionMessageRow(msg)
                                            .id(msg.id)
                                    }

                                    if isBusy {
                                        HStack(alignment: .center, spacing: 8) {
                                            ProgressView().controlSize(.mini)
                                                .frame(width: 16)
                                            Text(
                                                isPDFLoading
                                                    ? "正在下载并提取原始论文 PDF 全文，随后作答…"
                                                    : (isPDFReady ? "正在检索结构化卡片与原始 PDF 全文思考作答…" : "正在结合结构化卡片思考作答…")
                                            )
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 4)
                                        .id("discussion-thinking-anchor")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, 4)
                            }
                            .frame(height: effectiveThreadHeight)
                            .onAppear {
                                if isBusy {
                                    proxy.scrollTo("discussion-thinking-anchor", anchor: .bottom)
                                } else if let lastID = record.discussionMessages.last?.id {
                                    proxy.scrollTo(lastID, anchor: .bottom)
                                }
                            }
                            .onChange(of: record.discussionMessages.count) { _, _ in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    if isBusy {
                                        proxy.scrollTo("discussion-thinking-anchor", anchor: .bottom)
                                    } else if let lastID = record.discussionMessages.last?.id {
                                        proxy.scrollTo(lastID, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }

                // Always-Ready Docked Input Bar (Exact 24pt Horizontal Alignment with Upper Workspace + Native First-Click Caret!)
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isDropTargetingDiscussion ? "arrow.down.doc.fill" : "sparkles")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.calendarTone)
                        .padding(.leading, 2)

                    TextField(
                        isPDFReady
                            ? "围绕「\(record.digest.shortAlias.isEmpty ? "当前论文" : record.digest.shortAlias)」追问公式、实验表或实现细节（已结合原 PDF，按 ↩ 发送）…"
                            : "围绕「\(record.digest.shortAlias.isEmpty ? "当前论文" : record.digest.shortAlias)」继续追问方法细节或局限性（按 ↩ 发送，支持拖入 PDF）…",
                        text: draftBinding
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isDiscussionInputFocused)
                    .onSubmit {
                        submitDiscussionQuestion(for: record)
                    }

                    if !currentDraftText.isEmpty {
                        Button {
                            paperVM.setDiscussionDraft("", for: record.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(FullHitAreaButtonStyle())
                    }

                    if !showThreadArea && !hasMessages {
                        pdfCompactInputBadge(for: record, isPDFLoading: isPDFLoading, isPDFReady: isPDFReady)
                    }

                    Menu {
                        Section("一键追问灵感") {
                            ForEach(Self.quickDiscussionPrompts, id: \.self) { preset in
                                Button(preset) {
                                    submitDiscussionQuestion(for: record, presetQuestion: preset)
                                }
                            }
                        }
                        Divider()
                        Button {
                            paperVM.chooseAndAttachLocalPDF(for: record.id)
                        } label: {
                            Label(isPDFReady ? "更换关联的本地 PDF…" : "关联本地原始 PDF…", systemImage: "paperclip")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("灵感")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.up")
                                .font(.system(size: 7.5, weight: .bold))
                                .opacity(0.65)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.subtleButtonBg))
                    }
                    .menuStyle(.button)
                    .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(isBusy)

                    if isBusy {
                        Button {
                            paperVM.cancelDiscussion(recordID: record.id)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 9, weight: .bold))
                                Text("停止")
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 11)
                            .frame(height: 25)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.urgentTone.opacity(0.88)))
                        }
                        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
                        .fixedSize()
                        .help("立即停止本次回答并恢复提问草稿")
                    } else {
                        let canSend = !currentDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button {
                            submitDiscussionQuestion(for: record)
                        } label: {
                            HStack(spacing: 4) {
                                Text("提问")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 11.5))
                            }
                            .foregroundStyle(canSend ? Color.white : Color.secondary)
                            .padding(.horizontal, 11)
                            .frame(height: 25)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(canSend ? palette.calendarTone : palette.subtleButtonBg)
                            )
                        }
                        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
                        .fixedSize()
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: isDiscussionInputFocused ? [.command] : [.command, .control, .option])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6.5)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.composerWellBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    isDropTargetingDiscussion
                                        ? palette.committedTone
                                        : (isDiscussionInputFocused ? palette.calendarTone.opacity(0.55) : palette.hairline),
                                    lineWidth: isDropTargetingDiscussion ? 1.5 : 1
                                )
                        )
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 2)
            .padding(.bottom, 12)
            .background(palette.mainCanvasBg)
            .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargetingDiscussion) { providers in
                handleDroppedPDFProviders(providers) { pdfURL in
                    Task { @MainActor in
                        paperVM.attachLocalPDF(url: pdfURL, for: record.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pdfGroundingStatusBadge(for record: PaperDigestRecord, isPDFLoading: Bool, isPDFReady: Bool) -> some View {
        if isPDFLoading {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("正在加载原始 PDF…")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 21)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.subtleButtonBg))
        } else if isPDFReady {
            Menu {
                Button {
                    paperVM.openPDFForReading(record)
                } label: {
                    Label("在预览中打开缓存的原始 PDF", systemImage: "doc.richtext")
                }
                Button {
                    paperVM.chooseAndAttachLocalPDF(for: record.id)
                } label: {
                    Label("更换关联的本地 PDF…", systemImage: "paperclip")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    let pagesLabel = record.cachedPDFPageCount.map { " (\($0)页)" } ?? ""
                    Text("已结合原始 PDF\(pagesLabel)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(palette.committedTone)
                .padding(.horizontal, 8)
                .frame(height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(palette.committedTone.opacity(0.11))
                )
            }
            .menuStyle(.button)
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 5))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("后续追问将自动检索整份原始 PDF 全文并标注页码出处；点击可打开 PDF")
        } else if paperVM.canAutoFetchRemotePDF(record) {
            Button {
                paperVM.prefetchPDFIfNeeded(for: record.id, silent: false)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("加载原始 PDF 全文")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(palette.calendarTone)
                .padding(.horizontal, 8)
                .frame(height: 21)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.calendarTone.opacity(0.10)))
            }
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 5))
            .fixedSize()
        } else {
            Button {
                paperVM.chooseAndAttachLocalPDF(for: record.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("关联本地 PDF…")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 21)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.subtleButtonBg))
            }
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 5))
            .fixedSize()
            .help("当前链接不含公开 PDF，可手动关联或拖入本地 PDF 文件以结合全文讨论")
        }
    }

    @ViewBuilder
    private func pdfCompactInputBadge(for record: PaperDigestRecord, isPDFLoading: Bool, isPDFReady: Bool) -> some View {
        if isPDFReady {
            Button {
                paperVM.openPDFForReading(record)
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("PDF\(record.cachedPDFPageCount.map { " \($0)p" } ?? "")")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(palette.committedTone)
                .padding(.horizontal, 7)
                .frame(height: 25)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.committedTone.opacity(0.11)))
            }
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
            .fixedSize()
            .help("已挂载原始 PDF 全文（点击打开 PDF）")
        } else if !isPDFLoading && !paperVM.canAutoFetchRemotePDF(record) {
            Button {
                paperVM.chooseAndAttachLocalPDF(for: record.id)
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 25, height: 25)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.subtleButtonBg))
            }
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6))
            .help("关联本地原始 PDF 以结合全文作答")
        }
    }

    private func discussionMessageRow(_ msg: PaperDiscussionMessage) -> some View {
        let isUser = (msg.role == .user)

        return HStack(alignment: .top, spacing: 9) {
            Text(isUser ? "提问" : "解答")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(isUser ? palette.calendarTone : palette.committedTone)
                .padding(.horizontal, 6.5)
                .frame(height: 19)
                .background(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill((isUser ? palette.calendarTone : palette.committedTone).opacity(0.12))
                )
                .fixedSize()
                .padding(.top, 1.5)

            discussionMessageContentView(msg.content, isUser: isUser)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isUser {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(msg.content, forType: .string)
                    paperVM.isErrorBanner = false
                    paperVM.statusBanner = "📋 已复制该条讨论解答"
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.subtleButtonBg))
                }
                .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 5))
                .help("复制此条解答")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isUser ? palette.calendarTone.opacity(0.055) : palette.composerWellBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isUser ? palette.calendarTone.opacity(0.16) : palette.hairline, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func discussionMessageContentView(_ rawContent: String, isUser: Bool) -> some View {
        if isUser {
            Text(rawContent)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineSpacing(3.5)
                .textSelection(.enabled)
        } else {
            let normalized = rawContent
                .replacingOccurrences(of: "\\times", with: "×")
                .replacingOccurrences(of: "\\rightarrow", with: "→")
                .replacingOccurrences(of: "\\to", with: "→")
                .replacingOccurrences(of: "\\approx", with: "≈")
                .replacingOccurrences(of: "\\le", with: "≤")
                .replacingOccurrences(of: "\\ge", with: "≥")
            let blocks = ChatMarkdownFormatter.parseBlocks(normalized)

            VStack(alignment: .leading, spacing: 6.5) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let h):
                        Text(ChatMarkdownFormatter.makeSafeAttributedString(h))
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(.top, 2)
                            .textSelection(.enabled)

                    case .paragraph(let p):
                        Text(ChatMarkdownFormatter.makeSafeAttributedString(p))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.primary.opacity(0.92))
                            .lineSpacing(4)
                            .textSelection(.enabled)

                    case .bulletItem(let marker, let body):
                        HStack(alignment: .top, spacing: 6) {
                            Text(marker)
                                .font(.system(size: marker == "•" ? 12.5 : 11.5, weight: .bold, design: marker == "•" ? .default : .monospaced))
                                .foregroundStyle(palette.calendarTone)
                                .frame(minWidth: marker == "•" ? 10 : 18, alignment: .leading)
                                .padding(.top, marker == "•" ? 0 : 1)

                            Text(ChatMarkdownFormatter.makeSafeAttributedString(body))
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.primary.opacity(0.92))
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }

                    case .codeBlock(_, let code):
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.90))
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(palette.subtleButtonBg)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.hairline, lineWidth: 1))
                        )

                    case .table(let headers, let rows):
                        markdownTableBlockView(headers: headers, rows: rows)
                    }
                }
            }
        }
    }

    private func markdownTableBlockView(headers: [String], rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Row
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { colIdx, header in
                    Text(ChatMarkdownFormatter.makeSafeAttributedString(header))
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .overlay(alignment: .trailing) {
                            if colIdx < headers.count - 1 {
                                Rectangle().fill(palette.hairline).frame(width: 1)
                            }
                        }
                }
            }
            .background(palette.subtleButtonBg)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Rectangle().fill(palette.hairline).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                        Text(ChatMarkdownFormatter.makeSafeAttributedString(cell))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.primary.opacity(0.90))
                            .lineSpacing(2.5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5.5)
                            .overlay(alignment: .trailing) {
                                if colIdx < row.count - 1 {
                                    Rectangle().fill(palette.hairline).frame(width: 1)
                                }
                            }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1)
        )
        .padding(.vertical, 2)
    }

    private func handleDroppedPDFProviders(_ providers: [NSItemProvider], onResolved: @escaping @Sendable (URL) -> Void) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                if let url = item as? URL {
                    resolvedURL = url
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    resolvedURL = url
                } else {
                    resolvedURL = nil
                }
                if let resolvedURL, resolvedURL.pathExtension.lowercased() == "pdf" {
                    onResolved(resolvedURL)
                }
            }
            return true
        }

        provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { tempURL, _ in
            guard let tempURL else { return }
            let stableCopy = FileManager.default.temporaryDirectory
                .appendingPathComponent("MemoPilot-Drop-\(UUID().uuidString).pdf")
            if (try? FileManager.default.copyItem(at: tempURL, to: stableCopy)) != nil {
                onResolved(stableCopy)
            }
        }
        return true
    }

    // MARK: - Precision Aligned Reusable Subviews (16pt Icon Column + 8pt Gap = 24pt Text Indent!)

    private func paperSectionCard<Content: View>(
        title: String,
        icon: String,
        accent: Color,
        tintedBackground: Color? = nil,
        tintedBorder: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 16, height: 16, alignment: .center)

                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tintedBackground != nil ? accent : .primary)

                Spacer()
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tintedBackground ?? palette.composerWellBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tintedBorder ?? palette.hairline, lineWidth: 1)
                )
        )
    }

    // Bullet dot sits inside a 16pt leading column + 8pt spacing -> bullet text starts at exact 24pt indent (matching card title!)
    private func bulletPointRow(text: String, dotColor: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(dotColor.opacity(0.85))
                .frame(width: 5.5, height: 5.5)
                .frame(width: 16, alignment: .center)
                .padding(.top, 5.5)

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.92))
                .lineSpacing(4.5)
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
                    .truncationMode(.tail)
                    .frame(maxWidth: 190)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(tone)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(tone.opacity(0.11))
            )
        }
        .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 5.5))
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

    private static func shortTimeString(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return todayFormatter.string(from: date)
        } else {
            return shortDateFormatter.string(from: date)
        }
    }
}

// MARK: - Shared Top-Bar Mode Switcher Pill (Exact 26pt Height Matching Every Other Header Control!)

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
                    .frame(height: 21)
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
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.sidebarSegmentWell)
            )
            .fixedSize()

            Button {
                AppDelegate.openPaperDigestWindow()
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "uiwindow.split.2x1")
                        .font(.system(size: 10, weight: .semibold))
                    Text("独立窗口")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(palette.composerWellBg)
                        .overlay(RoundedRectangle(cornerRadius: 6.5, style: .continuous).strokeBorder(palette.hairline, lineWidth: 1))
                )
            }
            .buttonStyle(FullHitAreaButtonStyle(cornerRadius: 6.5))
            .fixedSize()
            .help("在独立副窗口中打开「论文与推送解析」，方便与备忘窗口双开对照 (⇧⌘P)")
        }
    }
}
