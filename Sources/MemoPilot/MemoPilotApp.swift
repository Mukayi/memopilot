import SwiftUI
import AppKit
import MemoPilotCore

public enum WorkspaceTheme: String, CaseIterable, Identifiable, Sendable {
    case warmPaper = "暖米护眼"
    case notesWhite = "纯净纸白"
    case mistBlue = "冰川雾蓝"
    case darkNight = "深邃暗夜"

    public var id: String { rawValue }

    public var isDark: Bool {
        self == .darkNight
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isSnapshotPreview: Bool = false
    @Published var isSidebarCollapsed: Bool = false
    @Published var sidebarWidth: CGFloat = 264
    @Published var isPinnedSectionExpanded: Bool = true
    @Published var isTodaySectionExpanded: Bool = true
    @Published var isEarlierSectionExpanded: Bool = true
    @Published var isInputCollapsed: Bool = false
    @Published var theme: WorkspaceTheme = WorkspaceTheme(
        rawValue: UserDefaults.standard.string(forKey: "MemoPilot.theme") ?? ""
    ) ?? .warmPaper {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "MemoPilot.theme")
        }
    }

    @Published var inputText: String = ""
    @Published var attachedImagePath: String?
    @Published var isAnalyzing: Bool = false
    @Published var isExecuting: Bool = false
    @Published var autoCommit: Bool = UserDefaults.standard.bool(forKey: "MemoPilot.autoCommit") {
        didSet {
            UserDefaults.standard.set(autoCommit, forKey: "MemoPilot.autoCommit")
        }
    }
    @Published var isNotesAutoWatchEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "MemoPilot.isNotesAutoWatchEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "MemoPilot.isNotesAutoWatchEnabled")
    }() {
        didSet {
            UserDefaults.standard.set(isNotesAutoWatchEnabled, forKey: "MemoPilot.isNotesAutoWatchEnabled")
        }
    }
    @Published var isSyncingNotes: Bool = false
    @Published var aiProviderMode: AIProviderMode = AIProviderMode(
        rawValue: UserDefaults.standard.string(forKey: "MemoPilot.aiProviderMode") ?? ""
    ) ?? .auto {
        didSet {
            UserDefaults.standard.set(aiProviderMode.rawValue, forKey: "MemoPilot.aiProviderMode")
            refreshCodexStatus()
        }
    }
    @Published var aiSpeedProfile: AISpeedProfile = AISpeedProfile(
        rawValue: UserDefaults.standard.string(forKey: "MemoPilot.aiSpeedProfile") ?? ""
    ) ?? .flash {
        didSet {
            UserDefaults.standard.set(aiSpeedProfile.rawValue, forKey: "MemoPilot.aiSpeedProfile")
        }
    }
    @Published var codexStatus: CodexEnvironmentStatus = CodexEnvironmentStatus(
        isLoggedIn: true,
        activeProviderLabel: "Cursor 已连接",
        statusMessage: "正在检测本地 AI 连接状态…"
    )
    @Published var parsedPlan: ParsedPlan? {
        didSet {
            refreshCalendarConflicts()
        }
    }
    @Published var calendarConflicts: [UUID: String] = [:]
    @Published var isLaunchAtLoginEnabled: Bool = LaunchAtLoginService.isEnabled
    @Published var editingItemID: UUID?
    @Published var isShowingShortcutSettings: Bool = false
    @Published var hotKeyConfig: HotKeyConfiguration = HotKeyConfiguration.load()
    @Published var statusBanner: String?
    @Published var isErrorBanner: Bool = false

    // History state
    @Published var historyRecords: [HistoryRecord] = []
    @Published var selectedRecordID: UUID?
    @Published var searchQuery: String = "" {
        didSet {
            reconcileSelectionWithFilter()
        }
    }
    @Published var selectedFilter: HistoryFilter = .all {
        didSet {
            reconcileSelectionWithFilter()
        }
    }

    private let historyStore = HistoryStore.shared
    private var saveDebounceTask: Task<Void, Never>?
    private var conflictCheckTask: Task<Void, Never>?
    private var notificationObserver: NSObjectProtocol?
    private var remotePollingTimer: Timer?
    private var notesWatchTimer: Timer?
    private var pasteMonitor: Any?
    private var hasStartedListeners = false
    private var isHandlingRemote = false

    var selectedTotalCount: Int {
        guard let plan = parsedPlan else { return 0 }
        return plan.pendingItems.filter(\.isSelected).count
    }

    var totalEventsInHistory: Int {
        historyRecords.reduce(0) { $0 + $1.plan.events.count }
    }

    var totalRemindersAndNotesInHistory: Int {
        historyRecords.reduce(0) { $0 + $1.plan.reminders.count + $1.plan.notes.count }
    }

    var filteredHistoryRecords: [HistoryRecord] {
        historyRecords.filter { record in
            let matchesFilter: Bool
            switch selectedFilter {
            case .all:
                matchesFilter = true
            case .pending:
                matchesFilter = !record.isCommitted
            case .committed:
                matchesFilter = record.isCommitted
            case .screenshot:
                matchesFilter = record.savedImagePath != nil
            }
            return matchesFilter && record.matches(query: searchQuery)
        }
    }

    var pinnedHistoryRecords: [HistoryRecord] {
        filteredHistoryRecords.filter(\.isPinned)
    }

    var todayHistoryRecords: [HistoryRecord] {
        filteredHistoryRecords.filter { !$0.isPinned && Calendar.current.isDateInToday($0.createdAt) }
    }

    var earlierHistoryRecords: [HistoryRecord] {
        filteredHistoryRecords.filter { !$0.isPinned && !Calendar.current.isDateInToday($0.createdAt) }
    }

    var currentInspectingRecord: HistoryRecord? {
        guard let id = selectedRecordID else { return nil }
        return historyRecords.first(where: { $0.id == id })
    }

    init() {
        let hadExistingFile = historyStore.hasExistingHistoryFile
        var loaded = historyStore.loadAll()

        if loaded.isEmpty && !hadExistingFile && !UserDefaults.standard.bool(forKey: "MemoPilot.didSeedInitialHistoryV1") {
            let seeded = Self.makeInitialSampleHistory()
            UserDefaults.standard.set(true, forKey: "MemoPilot.didSeedInitialHistoryV1")
            self.historyRecords = seeded
            self.historyStore.saveAll(seeded)
        } else {
            if !UserDefaults.standard.bool(forKey: "MemoPilot.didSeedPinV2"), !loaded.isEmpty {
                loaded[0].isPinned = true
                UserDefaults.standard.set(true, forKey: "MemoPilot.didSeedPinV2")
                self.historyStore.saveAll(loaded)
            }
            self.historyRecords = loaded
        }

        if let first = self.historyRecords.first {
            self.selectedRecordID = first.id
            self.parsedPlan = first.plan
            self.statusBanner = first.commitSummary
        }
    }

    func registerHotKeysAndRemoteListener() {
        guard !hasStartedListeners else { return }
        hasStartedListeners = true

        GlobalHotKeyService.shared.onToggleWindowTriggered = {
            Task { @MainActor in
                AppDelegate.toggleMainWindow()
            }
        }
        GlobalHotKeyService.shared.onQuickScreenshotTriggered = { [weak self] in
            Task { @MainActor in
                await self?.captureScreenAndAnalyze()
                AppDelegate.bringMainWindowToFront()
            }
        }
        GlobalHotKeyService.shared.onClipboardAnalyzeTriggered = { [weak self] in
            Task { @MainActor in
                AppDelegate.bringMainWindowToFront()
                await self?.analyzeClipboard()
            }
        }
        GlobalHotKeyService.shared.applyConfiguration(hotKeyConfig)

        // Clean up any stale command left from a previous session
        if FileManager.default.fileExists(atPath: CursorRemoteControl.commandFilePath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: CursorRemoteControl.commandFilePath)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let oldCmd = try? decoder.decode(RemoteControlCommand.self, from: data),
               Date().timeIntervalSince(oldCmd.createdAt) > 15.0 {
                try? FileManager.default.removeItem(atPath: CursorRemoteControl.commandFilePath)
            }
        }

        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: CursorRemoteControl.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleIncomingRemoteCommand()
            }
        }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isHandlingRemote,
                      FileManager.default.fileExists(atPath: CursorRemoteControl.commandFilePath) else { return }
                await self.handleIncomingRemoteCommand()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        remotePollingTimer = timer

        let notesTimer = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.isNotesAutoWatchEnabled,
                      !self.isAnalyzing,
                      !self.isSyncingNotes else { return }
                await self.syncAppleNotesFolder(manualTrigger: false)
            }
        }
        RunLoop.main.add(notesTimer, forMode: .common)
        notesWatchTimer = notesTimer

        // Intercept Cmd+V when an image (or Finder image file) is on the pasteboard
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isShowingShortcutSettings else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags == .command && event.charactersIgnoringModifiers?.lowercased() == "v" {
                if let payload = ClipboardService.readPayload(),
                   let imgPath = payload.imagePath,
                   payload.text.isEmpty {
                    Task { @MainActor in
                        self.attachImageAndNotify(path: imgPath)
                    }
                    return nil
                }
            }
            return event
        }

        refreshCodexStatus()
        refreshCalendarConflicts()
    }

    func toggleLaunchAtLogin() {
        let next = !isLaunchAtLoginEnabled
        LaunchAtLoginService.setEnabled(next)
        isLaunchAtLoginEnabled = LaunchAtLoginService.isEnabled
        isErrorBanner = false
        statusBanner = isLaunchAtLoginEnabled ? "✅ 已开启开机自动启动" : "已关闭开机自动启动"
    }

    func refreshCalendarConflicts() {
        conflictCheckTask?.cancel()
        guard let items = parsedPlan?.items, !items.isEmpty else {
            if !calendarConflicts.isEmpty {
                calendarConflicts = [:]
            }
            return
        }
        conflictCheckTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let detected = await Task.detached(priority: .utility) {
                AppleExecutors.shared.detectCalendarConflicts(for: items)
            }.value
            guard !Task.isCancelled else { return }
            if self.calendarConflicts != detected {
                self.calendarConflicts = detected
            }
        }
    }

    func attachImageAndNotify(path: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            isInputCollapsed = false
            attachedImagePath = path
            isErrorBanner = false
            statusBanner = "🖼️ 已粘贴/拖入图片，按 ⌘↩ 即可拆解"
        }
    }

    func refreshCodexStatus() {
        let mode = aiProviderMode
        Task {
            let status = await CodexCLIBridge.checkStatusAsync(preferredMode: mode)
            if self.codexStatus != status {
                self.codexStatus = status
            }
        }
    }

    func updateHotKeyConfig(_ newConfig: HotKeyConfiguration) {
        hotKeyConfig = newConfig
        newConfig.save()
        GlobalHotKeyService.shared.applyConfiguration(newConfig)
    }

    func resetHotKeysToDefault() {
        updateHotKeyConfig(.default)
        statusBanner = "⌨️ 已恢复默认全局快捷键（⌥Space / ⌥C / ⌥⇧S）"
        isErrorBanner = false
    }

    private func reconcileSelectionWithFilter() {
        let visible = filteredHistoryRecords
        if let currentID = selectedRecordID, visible.contains(where: { $0.id == currentID }) {
            return
        }
        AppDelegate.clearAnyWindowFirstResponder()
        if let firstVisible = visible.first {
            selectedRecordID = firstVisible.id
            parsedPlan = firstVisible.plan
            statusBanner = firstVisible.commitSummary
            isErrorBanner = false
        } else {
            selectedRecordID = nil
            parsedPlan = nil
            statusBanner = nil
            isErrorBanner = false
        }
    }

    func handleIncomingRemoteCommand() async {
        guard !isHandlingRemote,
              FileManager.default.fileExists(atPath: CursorRemoteControl.commandFilePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: CursorRemoteControl.commandFilePath)) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cmd: RemoteControlCommand
        if let decoded = try? decoder.decode(RemoteControlCommand.self, from: data) {
            cmd = decoded
        } else if let fallback = try? JSONDecoder().decode(RemoteControlCommand.self, from: data) {
            cmd = fallback
        } else {
            try? FileManager.default.removeItem(atPath: CursorRemoteControl.commandFilePath)
            return
        }

        // Ignore stale commands older than 15 seconds
        if Date().timeIntervalSince(cmd.createdAt) > 15.0 {
            try? FileManager.default.removeItem(atPath: CursorRemoteControl.commandFilePath)
            return
        }

        isHandlingRemote = true
        try? FileManager.default.removeItem(atPath: CursorRemoteControl.commandFilePath)
        defer { isHandlingRemote = false }

        AppDelegate.bringMainWindowToFront()

        switch cmd.action {
        case "status":
            let currentTitle = currentInspectingRecord?.displayTitle ?? "无"
            CursorRemoteControl.writeResponse(
                "MemoPilot 运行中 | 主题: \(theme.rawValue) | 侧栏收起: \(isSidebarCollapsed) | AI: \(codexStatus.activeProviderLabel) | 历史记录: \(historyRecords.count) 条 | 当前选中: \(currentTitle)"
            )

        case "theme":
            if let t = cmd.theme {
                withAnimation(.easeInOut(duration: 0.2)) {
                    switch t {
                    case "warm": theme = .warmPaper
                    case "white": theme = .notesWhite
                    case "blue": theme = .mistBlue
                    case "dark": theme = .darkNight
                    default: break
                    }
                }
            }
            CursorRemoteControl.writeResponse("✅ 已将 MemoPilot 底色切换为：\(theme.rawValue)")

        case "sidebar":
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                if cmd.text == "hide" {
                    isSidebarCollapsed = true
                } else if cmd.text == "show" {
                    isSidebarCollapsed = false
                } else {
                    isSidebarCollapsed.toggle()
                }
            }
            CursorRemoteControl.writeResponse("✅ 左侧历史栏状态：\(isSidebarCollapsed ? "已收起" : "已展开")")

        case "input":
            withAnimation(.easeInOut(duration: 0.18)) {
                isInputCollapsed = false
                inputText = cmd.text ?? ""
                statusBanner = "🔗 Cursor 已填入备忘内容"
                isErrorBanner = false
            }
            CursorRemoteControl.writeResponse("✅ 已在 MemoPilot 输入框填入文本")

        case "push-plan":
            guard let rawJSON = cmd.planJSON,
                  let plan = try? ParsedPlan.decode(from: rawJSON) else {
                CursorRemoteControl.writeResponse("❌ 解析传入的 Plan JSON 失败")
                return
            }
            let rawText = cmd.text ?? ""
            let newRecord = HistoryRecord(
                createdAt: Date(),
                rawInputText: rawText,
                savedImagePath: nil,
                plan: plan,
                isCommitted: false,
                isPinned: false
            )
            AppDelegate.clearAnyWindowFirstResponder()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                selectedFilter = .all
                searchQuery = ""
                historyRecords.insert(newRecord, at: 0)
                selectedRecordID = newRecord.id
                parsedPlan = plan
                isErrorBanner = false
                statusBanner = "🔗 Cursor 已直接创建并同步拆解结果：\(plan.summary)"
                historyStore.saveAll(historyRecords)
            }
            if cmd.autoCommit == true {
                await commitCurrentPlan()
                CursorRemoteControl.writeResponse("✅ Cursor 已推送拆解结果并自动写入系统：\(statusBanner ?? "")")
            } else {
                CursorRemoteControl.writeResponse("✅ Cursor 已将「\(plan.summary)」实时推送至 MemoPilot 界面（共 \(plan.events.count) 日程, \(plan.reminders.count) 待办, \(plan.notes.count) 备忘）")
            }

        case "analyze":
            if let text = cmd.text, !text.isEmpty {
                inputText = text
            }
            await runAnalysis()
            CursorRemoteControl.writeResponse("✅ MemoPilot AI 拆解完成：\(statusBanner ?? "")")

        case "commit":
            await commitCurrentPlan()
            CursorRemoteControl.writeResponse("✅ MemoPilot 写入结果：\(statusBanner ?? "")")

        case "pin":
            if let id = selectedRecordID {
                togglePinRecord(id)
                CursorRemoteControl.writeResponse("✅ 已切换当前记录置顶状态")
            } else {
                CursorRemoteControl.writeResponse("⚠️ 当前无选中记录")
            }

        case "delete-current":
            if let id = selectedRecordID {
                deleteHistoryRecord(id)
                CursorRemoteControl.writeResponse("✅ 已安全删除当前记录，剩余 \(historyRecords.count) 条")
            } else {
                CursorRemoteControl.writeResponse("⚠️ 当前无选中记录")
            }

        case "expand-first":
            if let firstItem = parsedPlan?.items.first {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                    editingItemID = firstItem.id
                }
                CursorRemoteControl.writeResponse("✅ 已展开首条草稿编辑面板：\(firstItem.title)")
            } else {
                CursorRemoteControl.writeResponse("⚠️ 当前无草稿项")
            }

        case "switch-second-to-alarm":
            if let plan = parsedPlan, plan.items.count > 1 {
                let secondID = plan.items[1].id
                setItemTargetKind(id: secondID, kind: .alarm)
                CursorRemoteControl.writeResponse("✅ 已将第 2 条草稿切换为「闹钟」")
            } else {
                CursorRemoteControl.writeResponse("⚠️ 草稿项不足 2 条")
            }

        case "load-demo":
            loadDemoPlan()
            CursorRemoteControl.writeResponse("✅ 已加载示例记录")

        case "clipboard":
            await analyzeClipboard()
            CursorRemoteControl.writeResponse("✅ 已执行剪贴板拆解：\(statusBanner ?? "")")

        case "sync-notes":
            await syncAppleNotesFolder(manualTrigger: true)
            CursorRemoteControl.writeResponse("✅ 已执行苹果备忘录同步：\(statusBanner ?? "")")

        case "open-shortcuts":
            isShowingShortcutSettings = true
            CursorRemoteControl.writeResponse("✅ 已打开快捷键自定义面板")

        case "close-shortcuts":
            isShowingShortcutSettings = false
            CursorRemoteControl.writeResponse("✅ 已关闭快捷键自定义面板")

        case "demo-partial-commit":
            if var plan = parsedPlan, plan.items.count >= 4 {
                let idsToMark: Set<UUID> = [plan.items[0].id, plan.items[3].id]
                plan.markItemsCommitted(idsToMark)
                parsedPlan = plan
                syncCurrentPlanIntoSelectedRecord(plan, immediateSave: true)
                CursorRemoteControl.writeResponse("✅ 已将 2 条草稿标记为已写入系统")
            } else {
                CursorRemoteControl.writeResponse("⚠️ 草稿项不足")
            }

        case "screenshot":
            let outPath = cmd.text ?? "/Users/xiatianze/Desktop/MemoPilot/docs/live-cursor-operated.png"
            try? await Task.sleep(nanoseconds: 180_000_000)
            AppDelegate.captureOwnWindow(to: outPath)
            CursorRemoteControl.writeResponse("✅ 已保存当前实时窗口画面至：\(outPath)")

        default:
            CursorRemoteControl.writeResponse("⚠️ 未知指令：\(cmd.action)")
        }
    }

    func selectHistoryRecord(_ id: UUID) {
        guard selectedRecordID != id else { return }
        AppDelegate.clearAnyWindowFirstResponder()
        editingItemID = nil
        selectedRecordID = id
        if let record = historyRecords.first(where: { $0.id == id }) {
            parsedPlan = record.plan
            statusBanner = record.commitSummary
            isErrorBanner = false
        }
    }

    func togglePinRecord(_ id: UUID) {
        guard let idx = historyRecords.firstIndex(where: { $0.id == id }) else { return }
        historyRecords[idx].isPinned.toggle()
        historyStore.saveAll(historyRecords)
    }

    // MARK: - Unified DraftItem Editing & Target Switching

    func draftItem(id: UUID, fallback: DraftItem) -> DraftItem {
        parsedPlan?.item(id: id) ?? fallback
    }

    func toggleItemSelection(id: UUID) {
        guard var plan = parsedPlan else { return }
        plan.toggleItemSelection(id: id)
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: true)
    }

    func setItemTargetKind(id: UUID, kind: DraftTargetKind) {
        AppDelegate.clearAnyWindowFirstResponder()
        guard var plan = parsedPlan,
              plan.setItemTargetKind(id: id, kind: kind) else { return }
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: true)
    }

    func updateItemTitle(id: UUID, _ newTitle: String) {
        guard var plan = parsedPlan,
              plan.updateItemTitle(id: id, newTitle: newTitle) else { return }
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: false)
    }

    func updateItemLocation(id: UUID, _ newLocation: String) {
        guard var plan = parsedPlan,
              plan.updateItemLocation(id: id, newLocation: newLocation) else { return }
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: false)
    }

    func updateItemNotes(id: UUID, _ newNotes: String) {
        guard var plan = parsedPlan,
              plan.updateItemNotes(id: id, newNotes: newNotes) else { return }
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: false)
    }

    func updateItemCategory(id: UUID, _ newCategory: String) {
        guard var plan = parsedPlan,
              plan.updateItemCategory(id: id, newCategory: newCategory) else { return }
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: false)
    }

    func updateItemStartDate(id: UUID, _ newDate: Date) {
        guard var plan = parsedPlan,
              plan.updateItemStartDate(id: id, newDate: newDate) else { return }
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: true)
    }

    func updateItemEndDate(id: UUID, _ newDate: Date) {
        guard var plan = parsedPlan,
              plan.updateItemEndDate(id: id, newDate: newDate) else { return }
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: true)
    }

    func updateItemLeadTimes(id: UUID, _ minutes: [Int]) {
        guard var plan = parsedPlan,
              plan.updateItemLeadTimes(id: id, minutes: minutes) else { return }
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: true)
    }

    func toggleItemPriority(id: UUID) {
        guard var plan = parsedPlan,
              plan.toggleItemPriority(id: id) else { return }
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: true)
    }

    func deleteDraftItem(id: UUID) {
        AppDelegate.clearAnyWindowFirstResponder()
        if editingItemID == id {
            editingItemID = nil
        }
        guard var plan = parsedPlan,
              let targetItem = plan.item(id: id) else { return }

        plan.deleteItem(id: id)
        parsedPlan = plan
        syncCurrentPlanIntoSelectedRecord(plan, immediateSave: true)

        if targetItem.isCommitted {
            Task {
                let msg = await AppleExecutors.shared.deleteFromSystem(item: targetItem)
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.isErrorBanner = false
                    self.statusBanner = msg
                }
            }
        }
    }

    func addNewDraftItem(kind: DraftTargetKind = .reminder) {
        AppDelegate.clearAnyWindowFirstResponder()
        guard var plan = parsedPlan else { return }
        let added = plan.addNewDraftItem(kind: kind)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            parsedPlan = plan
            editingItemID = added.id
            syncCurrentPlanIntoSelectedRecord(plan, immediateSave: true)
        }
    }

    // Legacy compatibility helpers
    func isEventSelected(id: UUID, fallback: Bool) -> Bool {
        parsedPlan?.isEventSelected(id: id, fallback: fallback) ?? fallback
    }

    func isReminderSelected(id: UUID, fallback: Bool) -> Bool {
        parsedPlan?.isReminderSelected(id: id, fallback: fallback) ?? fallback
    }

    func isNoteSelected(id: UUID, fallback: Bool) -> Bool {
        parsedPlan?.isNoteSelected(id: id, fallback: fallback) ?? fallback
    }

    func eventTitle(id: UUID, fallback: String) -> String {
        parsedPlan?.eventTitle(id: id, fallback: fallback) ?? fallback
    }

    func reminderTitle(id: UUID, fallback: String) -> String {
        parsedPlan?.reminderTitle(id: id, fallback: fallback) ?? fallback
    }

    func noteTitle(id: UUID, fallback: String) -> String {
        parsedPlan?.noteTitle(id: id, fallback: fallback) ?? fallback
    }

    func toggleEventSelection(id: UUID) { toggleItemSelection(id: id) }
    func toggleReminderSelection(id: UUID) { toggleItemSelection(id: id) }
    func toggleNoteSelection(id: UUID) { toggleItemSelection(id: id) }
    func updateEventTitle(id: UUID, _ newTitle: String) { updateItemTitle(id: id, newTitle) }
    func updateEventLeadTimes(id: UUID, _ minutes: [Int]) { updateItemLeadTimes(id: id, minutes) }
    func updateReminderTitle(id: UUID, _ newTitle: String) { updateItemTitle(id: id, newTitle) }
    func updateNoteTitle(id: UUID, _ newTitle: String) { updateItemTitle(id: id, newTitle) }
    func deleteEventItem(id: UUID) { deleteDraftItem(id: id) }
    func deleteReminderItem(id: UUID) { deleteDraftItem(id: id) }
    func deleteNoteItem(id: UUID) { deleteDraftItem(id: id) }

    private func syncCurrentPlanIntoSelectedRecord(_ plan: ParsedPlan, immediateSave: Bool) {
        guard let id = selectedRecordID,
              let idx = historyRecords.firstIndex(where: { $0.id == id }) else { return }
        historyRecords[idx].plan = plan
        historyRecords[idx].isCommitted = !plan.items.isEmpty && plan.pendingItems.isEmpty
        if immediateSave {
            saveDebounceTask?.cancel()
            historyStore.saveAll(historyRecords)
        } else {
            saveDebounceTask?.cancel()
            let snapshot = historyRecords
            saveDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                historyStore.saveAll(snapshot)
            }
        }
    }

    func deleteHistoryRecord(_ id: UUID) {
        AppDelegate.clearAnyWindowFirstResponder()
        if let target = historyRecords.first(where: { $0.id == id }) {
            historyStore.removeSavedImageIfOwned(target.savedImagePath)
        }
        historyRecords.removeAll { $0.id == id }
        historyStore.saveAll(historyRecords)

        if selectedRecordID == id {
            let nextRecord = filteredHistoryRecords.first ?? historyRecords.first
            selectedRecordID = nextRecord?.id
            parsedPlan = nextRecord?.plan
            statusBanner = nextRecord?.commitSummary
            isErrorBanner = false
        }
    }

    func clearAllHistory() {
        AppDelegate.clearAnyWindowFirstResponder()
        for record in historyRecords {
            historyStore.removeSavedImageIfOwned(record.savedImagePath)
        }
        historyRecords.removeAll()
        selectedRecordID = nil
        parsedPlan = nil
        statusBanner = nil
        isErrorBanner = false
        historyStore.saveAll([])
    }

    func loadDemoPlan() {
        AppDelegate.clearAnyWindowFirstResponder()
        let demoPlan = Self.sampleContractAndFlightPlan()
        let rawInput = "明天下午3点去国贸三期见老张聊年度合同，出门前记得带公章；后天早上7点半飞上海虹桥 MU5102，顺便记一下西门丰巢取件码 4-2-1028"
        let newRecord = HistoryRecord(
            createdAt: Date(),
            rawInputText: rawInput,
            savedImagePath: nil,
            plan: demoPlan,
            isCommitted: false
        )
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
            selectedFilter = .all
            searchQuery = ""
            isErrorBanner = false
            statusBanner = "已生成示例请求并记入左侧历史记录"
            historyRecords.insert(newRecord, at: 0)
            selectedRecordID = newRecord.id
            parsedPlan = demoPlan
            historyStore.saveAll(historyRecords)
        }
    }

    func captureScreenAndAnalyze() async {
        guard !isAnalyzing else { return }
        statusBanner = nil
        do {
            guard let path = try await ScreenCaptureService.captureInteractiveRegion() else {
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                attachedImagePath = path
            }
            await runAnalysis()
        } catch {
            isErrorBanner = true
            statusBanner = "截图失败：\(error.localizedDescription)"
        }
    }

    func analyzeClipboard() async {
        guard !isAnalyzing else { return }
        guard let payload = ClipboardService.readPayload() else {
            withAnimation(.easeInOut(duration: 0.2)) {
                isErrorBanner = true
                statusBanner = "剪贴板为空（请先复制一段微信/网页文字或图片，再按 ⌥C）"
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            isInputCollapsed = false
            inputText = payload.text
            attachedImagePath = payload.imagePath
            isErrorBanner = false
            statusBanner = "📋 已读取剪贴板内容，正在智能拆解…"
        }
        await runAnalysis()
    }

    func syncAppleNotesFolder(manualTrigger: Bool = false) async {
        guard !isSyncingNotes, !isAnalyzing else { return }
        isSyncingNotes = true
        defer { isSyncingNotes = false }

        if manualTrigger {
            withAnimation(.easeInOut(duration: 0.18)) {
                isErrorBanner = false
                statusBanner = "📒 正在扫描苹果「备忘录 > MemoPilot」文件夹中的新笔记…"
            }
        }

        do {
            let newNotes = try await AppleNotesWatcherService.shared.fetchUnprocessedNotes(
                allowLaunchingNotesApp: manualTrigger
            )
            guard !newNotes.isEmpty else {
                if manualTrigger {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isErrorBanner = false
                        statusBanner = "📒 「备忘录 > MemoPilot」文件夹暂无新笔记（在 iPhone/Mac 备忘录该文件夹新建笔记即可自动同步）"
                    }
                }
                return
            }

            var syncedCount = 0
            for note in newNotes {
                let cleanText = AppleNotesWatcherService.normalizeNoteText(note.plaintext)
                guard !cleanText.isEmpty else { continue }

                withAnimation(.easeInOut(duration: 0.18)) {
                    isAnalyzing = true
                    isErrorBanner = false
                    statusBanner = "📒 检测到备忘录「\(note.title)」，正在自动拆解…"
                }

                do {
                    let plan = try await CodexCLIBridge.analyze(
                        userText: cleanText,
                        imagePath: nil,
                        preferredMode: aiProviderMode,
                        speedProfile: aiSpeedProfile
                    )
                    let record = HistoryRecord(
                        createdAt: Date(),
                        rawInputText: "【备忘录同步】\(cleanText)",
                        savedImagePath: nil,
                        plan: plan,
                        isCommitted: false
                    )

                    await AppleNotesWatcherService.shared.markNoteAsProcessed(note: note, summary: plan.summary)

                    AppDelegate.clearAnyWindowFirstResponder()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        selectedFilter = .all
                        searchQuery = ""
                        historyRecords.insert(record, at: 0)
                        selectedRecordID = record.id
                        parsedPlan = plan
                        isAnalyzing = false
                        historyStore.saveAll(historyRecords)
                    }
                    syncedCount += 1

                    if autoCommit {
                        await commitCurrentPlan()
                    } else {
                        statusBanner = "📒 已从苹果备忘录自动同步 \(syncedCount) 篇笔记：\(plan.summary)"
                    }
                } catch {
                    isAnalyzing = false
                    if manualTrigger {
                        isErrorBanner = true
                        statusBanner = "备忘录「\(note.title)」拆解失败：\(error.localizedDescription)"
                    }
                }
            }
        } catch {
            if manualTrigger {
                isErrorBanner = true
                statusBanner = "访问苹果备忘录失败：\(error.localizedDescription)"
            }
        }
    }

    func runAnalysis() async {
        guard !isAnalyzing else { return }
        let submittedInput = inputText
        let submittedImage = attachedImagePath
        let trimmed = submittedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || submittedImage != nil else {
            withAnimation(.easeInOut(duration: 0.2)) {
                isErrorBanner = true
                statusBanner = "请输入备忘内容，或点击右侧「截图识别」"
            }
            return
        }

        refreshCodexStatus()
        withAnimation(.easeInOut(duration: 0.2)) {
            isAnalyzing = true
            isErrorBanner = false
            statusBanner = "正在智能拆解日程、提前提醒与关键信息…"
        }

        do {
            let plan = try await CodexCLIBridge.analyze(
                userText: trimmed,
                imagePath: submittedImage,
                preferredMode: aiProviderMode,
                speedProfile: aiSpeedProfile
            )
            let persistedImg = historyStore.persistScreenshotIfNeeded(tempPath: submittedImage)
            let record = HistoryRecord(
                createdAt: Date(),
                rawInputText: trimmed,
                savedImagePath: persistedImg,
                plan: plan,
                isCommitted: false
            )

            AppDelegate.clearAnyWindowFirstResponder()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                selectedFilter = .all
                searchQuery = ""
                historyRecords.insert(record, at: 0)
                selectedRecordID = record.id
                parsedPlan = plan
                isAnalyzing = false
                if inputText == submittedInput {
                    inputText = ""
                }
                if attachedImagePath == submittedImage {
                    attachedImagePath = nil
                }
                historyStore.saveAll(historyRecords)
            }

            if autoCommit {
                await commitCurrentPlan()
            } else {
                statusBanner = plan.summary.isEmpty ? nil : "✨ \(plan.summary)"
            }
        } catch {
            withAnimation(.easeInOut(duration: 0.2)) {
                isAnalyzing = false
                isErrorBanner = true
                statusBanner = error.localizedDescription
            }
        }
    }

    func commitCurrentPlan() async {
        guard !isExecuting, var planToCommit = parsedPlan, selectedTotalCount > 0 else { return }
        let targetRecordID = selectedRecordID
        isExecuting = true
        let report = await AppleExecutors.shared.execute(plan: planToCommit)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isExecuting = false
            isErrorBanner = !report.errors.isEmpty
            statusBanner = report.summaryText

            if !report.committedItemIDs.isEmpty {
                planToCommit.markItemsCommitted(
                    report.committedItemIDs,
                    externalIDs: report.committedExternalIDs
                )
            }
            if selectedRecordID == targetRecordID {
                parsedPlan = planToCommit
            }

            if let id = targetRecordID,
               let idx = historyRecords.firstIndex(where: { $0.id == id }) {
                historyRecords[idx].plan = planToCommit
                let allCommitted = !planToCommit.items.isEmpty && planToCommit.pendingItems.isEmpty
                if allCommitted || (report.errors.isEmpty && !report.committedItemIDs.isEmpty) {
                    historyRecords[idx].isCommitted = allCommitted
                    historyRecords[idx].committedAt = Date()
                }
                historyRecords[idx].commitSummary = report.summaryText
                historyStore.saveAll(historyRecords)
            }
        }
    }

    // MARK: - Initial Sample History

    private static func sampleContractAndFlightPlan() -> ParsedPlan {
        ParsedPlan(
            summary: "国贸合同洽谈 + 早班飞上海 + 备齐公章与取件码",
            events: [
                CalendarEventDraft(
                    title: "老张丨国贸三期丨年度合同洽谈",
                    startISO: "2026-10-28T15:00:00+08:00",
                    endISO: "2026-10-28T16:30:00+08:00",
                    location: "北京国贸三期 B 座 12F",
                    notes: "带上法务审过的合同修订版",
                    leadTimeMinutes: [60, 15],
                    needsAlarm: false,
                    alarmTimeISO: "",
                    reasonForLeadTime: "线下外出赴约，预留 1 小时通勤与 15 分钟到场"
                ),
                CalendarEventDraft(
                    title: "✈️ 飞往上海虹桥 MU5102",
                    startISO: "2026-10-29T07:30:00+08:00",
                    endISO: "2026-10-29T09:45:00+08:00",
                    location: "首都机场 T2 航站楼",
                    notes: "值机柜台 F 区",
                    leadTimeMinutes: [180, 60],
                    needsAlarm: true,
                    alarmTimeISO: "2026-10-29T05:00:00+08:00",
                    reasonForLeadTime: "早班航班，提前 3 小时出发并设 05:00 强提醒"
                )
            ],
            reminders: [
                ReminderDraft(
                    title: "出门前装好公司公章与合同原件",
                    dueISO: "2026-10-28T13:45:00+08:00",
                    notes: "放在黑色公文包夹层",
                    priority: 1,
                    leadTimeMinutes: 15
                ),
                ReminderDraft(
                    title: "丰巢取件码 4-2-1028（顺丰文件）",
                    dueISO: "2026-10-28T19:00:00+08:00",
                    notes: "小区西门快递柜",
                    priority: 0,
                    leadTimeMinutes: 0
                )
            ],
            notes: [
                KeyNoteDraft(
                    title: "国贸合同核心条款底线",
                    bodyMarkdown: "• 付款周期：坚持按季度结算，首付不低于 30%\n• 违约金上限：控制在合同总额 10% 以内",
                    category: "工作备忘"
                )
            ]
        )
    }

    private static func makeInitialSampleHistory() -> [HistoryRecord] {
        let first = HistoryRecord(
            createdAt: Date().addingTimeInterval(-300),
            rawInputText: "明天下午3点去国贸三期见老张聊年度合同，出门前记得带公章；后天早上7点半飞上海虹桥 MU5102，顺便记一下西门丰巢取件码 4-2-1028",
            savedImagePath: nil,
            plan: sampleContractAndFlightPlan(),
            isCommitted: false,
            isPinned: true
        )

        let second = HistoryRecord(
            createdAt: Date().addingTimeInterval(-7200),
            rawInputText: "【微信群通知】周五上午10点半 Q4 产品路线图评审，腾讯会议 882-910-442，会前把数据看板更新完；另外停车场车位在 B2 层 C08",
            savedImagePath: nil,
            plan: ParsedPlan(
                summary: "周五产品评审线上会 + 更新数据看板 + 停车位记录",
                events: [
                    CalendarEventDraft(
                        title: "Q4 产品路线图评审（腾讯会议 882-910-442）",
                        startISO: "2026-10-30T10:30:00+08:00",
                        endISO: "2026-10-30T11:30:00+08:00",
                        location: "腾讯会议 882-910-442",
                        notes: "提前投屏准备好转化率漏斗图表",
                        leadTimeMinutes: [15, 5],
                        needsAlarm: false,
                        alarmTimeISO: "",
                        reasonForLeadTime: "线上会议，提前 15 分钟调试设备、5 分钟入会"
                    )
                ],
                reminders: [
                    ReminderDraft(
                        title: "更新 Q4 产品评审数据看板",
                        dueISO: "2026-10-30T09:30:00+08:00",
                        notes: "重点补齐留存率周环比",
                        priority: 1,
                        leadTimeMinutes: 30
                    )
                ],
                notes: [
                    KeyNoteDraft(
                        title: "今日停车位置：B2 层 C08",
                        bodyMarkdown: "• 商场地下车库 B2 层 C 区 08 号车位（近 3 号电梯厅）",
                        category: "生活速记"
                    )
                ]
            ),
            isCommitted: true,
            isPinned: false,
            commitSummary: "已写入：📅 日历 1 项 · ☑️ 提醒事项 1 项 · 📝 备忘录 1 篇",
            committedAt: Date().addingTimeInterval(-7100)
        )

        let third = HistoryRecord(
            createdAt: Date().addingTimeInterval(-86400),
            rawInputText: "周六下午2点带猫去瑞鹏宠物医院打年度疫苗，提前1小时提醒我拿免疫证",
            savedImagePath: nil,
            plan: ParsedPlan(
                summary: "周六下午宠物医院打疫苗 + 带免疫证提醒",
                events: [
                    CalendarEventDraft(
                        title: "带猫去瑞鹏宠物医院打年度疫苗",
                        startISO: "2026-10-31T14:00:00+08:00",
                        endISO: "2026-10-31T15:00:00+08:00",
                        location: "瑞鹏宠物医院",
                        notes: "年度妙三多 + 狂犬疫苗",
                        leadTimeMinutes: [60, 15],
                        needsAlarm: false,
                        alarmTimeISO: "",
                        reasonForLeadTime: "线下预约就诊，提前 1 小时准备航空箱与免疫证"
                    )
                ],
                reminders: [
                    ReminderDraft(
                        title: "出门拿猫咪免疫证与航空箱",
                        dueISO: "2026-10-31T13:00:00+08:00",
                        notes: "免疫证在书房抽屉第二格",
                        priority: 1,
                        leadTimeMinutes: 0
                    )
                ],
                notes: []
            ),
            isCommitted: true,
            isPinned: false,
            commitSummary: "已写入：📅 日历 1 项 · ☑️ 提醒事项 1 项",
            committedAt: Date().addingTimeInterval(-86000)
        )

        return [first, second, third]
    }
}
