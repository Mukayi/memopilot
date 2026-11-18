import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MemoPilotCore

@MainActor
final class PaperDigestViewModel: ObservableObject {
    @Published var isAnalyzing: Bool = false
    @Published var isArchivingNotes: Bool = false
    @Published private(set) var discussingRecordIDs: Set<UUID> = []
    @Published private(set) var loadingPDFRecordIDs: Set<UUID> = []
    @Published var statusBanner: String?
    @Published var isErrorBanner: Bool = false

    @Published var records: [PaperDigestRecord] = []
    @Published var latestCreatedRecordID: UUID?
    @Published private var discussionDraftsByRecord: [UUID: String] = [:]

    private let store = PaperDigestStore.shared
    private var notesSaveDebounceTask: Task<Void, Never>?
    private var discussionTasks: [UUID: Task<Bool, Never>] = [:]
    private var pendingUserMessageIDs: [UUID: UUID] = [:]
    private var pdfPrefetchTasks: [UUID: Task<Void, Never>] = [:]
    private var activeAnalysisTask: Task<UUID?, Never>?

    var savedExportDirectoryPath: String? {
        store.savedExportDirectoryPath
    }

    init() {
        let hadFile = store.hasExistingStoreFile
        var loaded = store.loadAll()

        // Reconcile crash-leftover unanswered user turns & stale cached PDF metadata
        var didMutateOnStartup = false
        for i in loaded.indices {
            if loaded[i].discussionMessages.last?.role == .user {
                loaded[i].discussionMessages.removeLast()
                didMutateOnStartup = true
            }
            let expectedPagesURL = store.cachedPDFPagesFileURL(for: loaded[i].id)
            let expectedPDFURL = store.cachedPDFFileURL(for: loaded[i].id)
            if FileManager.default.fileExists(atPath: expectedPDFURL.path),
               let cachedDoc = PaperPDFService.loadCachedDocumentIfPresent(for: loaded[i].id, store: store) {
                if loaded[i].cachedPDFPath != expectedPDFURL.path || loaded[i].cachedPDFPageCount != cachedDoc.pageCount {
                    loaded[i].cachedPDFPath = expectedPDFURL.path
                    loaded[i].cachedPDFPageCount = cachedDoc.pageCount
                    didMutateOnStartup = true
                }
            } else if !FileManager.default.fileExists(atPath: expectedPagesURL.path),
                      (loaded[i].cachedPDFPageCount != nil || loaded[i].cachedPDFPath != nil) {
                loaded[i].cachedPDFPath = nil
                loaded[i].cachedPDFPageCount = nil
                didMutateOnStartup = true
            }
        }

        if loaded.isEmpty && !hadFile && !UserDefaults.standard.bool(forKey: "MemoPilot.didSeedPaperSampleV1") {
            let sample = Self.makeInitialSampleRecord()
            UserDefaults.standard.set(true, forKey: "MemoPilot.didSeedPaperSampleV1")
            self.records = [sample]
            self.store.saveAll([sample])
        } else {
            self.records = loaded
            if didMutateOnStartup {
                self.store.saveAll(loaded)
            }
        }

        store.pruneOrphanedPDFAssets(keepingRecordIDs: Set(self.records.map(\.id)))
        self.latestCreatedRecordID = self.records.first?.id

        if let firstID = self.records.first?.id {
            prefetchPDFIfNeeded(for: firstID, silent: true)
        }
    }

    // MARK: - Per-Record Discussion Drafts

    func discussionDraft(for recordID: UUID?) -> String {
        guard let recordID else { return "" }
        return discussionDraftsByRecord[recordID] ?? ""
    }

    func setDiscussionDraft(_ text: String, for recordID: UUID?) {
        guard let recordID else { return }
        if text.isEmpty {
            discussionDraftsByRecord.removeValue(forKey: recordID)
        } else {
            discussionDraftsByRecord[recordID] = text
        }
    }

    // MARK: - Filtering & Selection

    func filteredRecords(query: String, filter: PaperDigestFilter) -> [PaperDigestRecord] {
        records.filter { rec in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .starred: matchesFilter = rec.isPinned
            case .hasCode: matchesFilter = rec.digest.hasOpenSourceCode
            case .syncedNotes: matchesFilter = rec.isArchivedToNotes
            }
            return matchesFilter && rec.matches(query: query)
        }
    }

    func record(id: UUID?) -> PaperDigestRecord? {
        guard let id else { return records.first }
        return records.first(where: { $0.id == id })
    }

    private func saveRecordsImmediately() {
        notesSaveDebounceTask?.cancel()
        notesSaveDebounceTask = nil
        store.saveAll(records)
    }

    func toggleStar(_ id: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].isPinned.toggle()
        records[idx].updatedAt = Date()
        saveRecordsImmediately()
    }

    func updateUserNotes(id: UUID, _ newNotes: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }),
              records[idx].userNotes != newNotes else { return }
        records[idx].userNotes = newNotes
        records[idx].updatedAt = Date()

        notesSaveDebounceTask?.cancel()
        notesSaveDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            self.store.saveAll(self.records)
        }
    }

    func deleteRecord(_ id: UUID) {
        discussionTasks[id]?.cancel()
        discussionTasks.removeValue(forKey: id)
        pendingUserMessageIDs.removeValue(forKey: id)
        discussingRecordIDs.remove(id)
        pdfPrefetchTasks[id]?.cancel()
        pdfPrefetchTasks.removeValue(forKey: id)
        loadingPDFRecordIDs.remove(id)
        discussionDraftsByRecord.removeValue(forKey: id)

        records.removeAll { $0.id == id }
        store.removeCachedAssets(for: id)
        saveRecordsImmediately()
    }

    func clearAllRecords() {
        for (_, task) in discussionTasks { task.cancel() }
        discussionTasks.removeAll()
        pendingUserMessageIDs.removeAll()
        discussingRecordIDs.removeAll()
        for (_, task) in pdfPrefetchTasks { task.cancel() }
        pdfPrefetchTasks.removeAll()
        loadingPDFRecordIDs.removeAll()
        discussionDraftsByRecord.removeAll()

        records.removeAll()
        latestCreatedRecordID = nil
        statusBanner = nil
        isErrorBanner = false
        store.removeAllCachedAssets()
        saveRecordsImmediately()
    }

    // MARK: - Original PDF Caching, Prefetching & Local PDF Attachment

    func isLoadingPDF(_ recordID: UUID) -> Bool {
        loadingPDFRecordIDs.contains(recordID)
    }

    func hasReadyPDF(_ record: PaperDigestRecord) -> Bool {
        if let count = record.cachedPDFPageCount, count > 0,
           let path = record.cachedPDFPath,
           FileManager.default.fileExists(atPath: path) {
            return true
        }
        return PaperPDFService.loadCachedDocumentIfPresent(for: record.id, store: store) != nil
    }

    func canAutoFetchRemotePDF(_ record: PaperDigestRecord) -> Bool {
        if !record.digest.pdfURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return !WebArticleFetcher.extractArxivIDs(from: record.digest.paperURL + "\n" + record.digest.sourceURL).isEmpty
    }

    func prefetchPDFIfNeeded(for recordID: UUID, silent: Bool = true) {
        guard let rec = records.first(where: { $0.id == recordID }) else { return }
        if hasReadyPDF(rec) {
            if rec.cachedPDFPageCount == nil,
               let doc = PaperPDFService.loadCachedDocumentIfPresent(for: recordID, store: store),
               let idx = records.firstIndex(where: { $0.id == recordID }) {
                records[idx].cachedPDFPath = store.cachedPDFFileURL(for: recordID).path
                records[idx].cachedPDFPageCount = doc.pageCount
                saveRecordsImmediately()
            }
            return
        }
        guard canAutoFetchRemotePDF(rec) || rec.cachedPDFPath != nil else { return }
        guard pdfPrefetchTasks[recordID] == nil else { return }

        loadingPDFRecordIDs.insert(recordID)
        let snapshot = rec
        let storeRef = self.store
        let task = Task { @MainActor [weak self] in
            defer {
                self?.loadingPDFRecordIDs.remove(recordID)
                self?.pdfPrefetchTasks.removeValue(forKey: recordID)
            }
            do {
                let (pdfPath, doc) = try await Task.detached(priority: .utility) {
                    try await PaperPDFService.ensureCachedPDF(for: snapshot, store: storeRef)
                }.value
                guard let self, !Task.isCancelled,
                      let idx = self.records.firstIndex(where: { $0.id == recordID }) else { return }
                self.records[idx].cachedPDFPath = pdfPath
                self.records[idx].cachedPDFPageCount = doc.pageCount
                self.saveRecordsImmediately()
                if !silent {
                    self.isErrorBanner = false
                    self.statusBanner = "📄 已加载原始论文 PDF（共 \(doc.pageCount) 页），后续提问将自动结合全文作答"
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                if !silent {
                    self.isErrorBanner = true
                    self.statusBanner = error.localizedDescription
                }
            }
        }
        pdfPrefetchTasks[recordID] = task
    }

    func chooseAndAttachLocalPDF(for recordID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "选择该论文对应的原始 PDF 文档"
        panel.prompt = "关联此 PDF"
        panel.allowedContentTypes = [.pdf]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            attachLocalPDF(url: url, for: recordID)
        }
    }

    func attachLocalPDF(url: URL, for recordID: UUID) {
        guard records.contains(where: { $0.id == recordID }) else { return }
        pdfPrefetchTasks[recordID]?.cancel()
        pdfPrefetchTasks.removeValue(forKey: recordID)
        loadingPDFRecordIDs.insert(recordID)

        let storeRef = self.store
        Task { @MainActor [weak self] in
            defer { self?.loadingPDFRecordIDs.remove(recordID) }
            do {
                let (savedPath, doc) = try await Task.detached(priority: .userInitiated) {
                    try PaperPDFService.importLocalPDF(sourceURL: url, for: recordID, store: storeRef)
                }.value
                guard let self, let idx = self.records.firstIndex(where: { $0.id == recordID }) else { return }
                self.records[idx].cachedPDFPath = savedPath
                self.records[idx].cachedPDFPageCount = doc.pageCount
                self.records[idx].updatedAt = Date()
                self.saveRecordsImmediately()
                self.isErrorBanner = false
                self.statusBanner = "📄 已关联本地原始 PDF（共 \(doc.pageCount) 页），提问将结合全文检索作答"
            } catch {
                self?.isErrorBanner = true
                self?.statusBanner = "关联 PDF 失败：\(error.localizedDescription)"
            }
        }
    }

    func openPDFForReading(_ record: PaperDigestRecord) {
        if let localPath = record.cachedPDFPath,
           FileManager.default.fileExists(atPath: localPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: localPath))
            return
        }
        let cachedURL = store.cachedPDFFileURL(for: record.id)
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            NSWorkspace.shared.open(cachedURL)
            return
        }
        if !record.digest.pdfURL.isEmpty, let remoteURL = URL(string: record.digest.pdfURL) {
            NSWorkspace.shared.open(remoteURL)
        }
    }

    // MARK: - Multi-Turn Discussion (Grounded in Card + Original PDF)

    func isDiscussing(_ recordID: UUID) -> Bool {
        discussingRecordIDs.contains(recordID)
    }

    func cancelDiscussion(recordID: UUID) {
        guard let running = discussionTasks[recordID] else { return }
        running.cancel()
        discussionTasks.removeValue(forKey: recordID)
        discussingRecordIDs.remove(recordID)

        if let pendingMsgID = pendingUserMessageIDs.removeValue(forKey: recordID),
           let idx = records.firstIndex(where: { $0.id == recordID }),
           let msgIdx = records[idx].discussionMessages.firstIndex(where: { $0.id == pendingMsgID }) {
            let restoredQuestion = records[idx].discussionMessages[msgIdx].content
            records[idx].discussionMessages.remove(at: msgIdx)
            saveRecordsImmediately()
            if (discussionDraftsByRecord[recordID] ?? "").isEmpty {
                discussionDraftsByRecord[recordID] = restoredQuestion
            }
        }
    }

    func clearDiscussion(recordID: UUID) {
        discussionTasks[recordID]?.cancel()
        discussionTasks.removeValue(forKey: recordID)
        pendingUserMessageIDs.removeValue(forKey: recordID)
        discussingRecordIDs.remove(recordID)

        guard let idx = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[idx].discussionMessages.removeAll()
        records[idx].updatedAt = Date()
        saveRecordsImmediately()
    }

    @discardableResult
    func askFollowUpQuestion(
        recordID: UUID,
        question: String,
        preferredMode: AIProviderMode,
        speedProfile: AISpeedProfile
    ) async -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !discussingRecordIDs.contains(recordID),
              let initialIdx = records.firstIndex(where: { $0.id == recordID }) else {
            return false
        }

        let snapshotRecord = records[initialIdx]
        let priorHistory = snapshotRecord.discussionMessages
        let userMsg = PaperDiscussionMessage(role: .user, content: trimmed)
        pendingUserMessageIDs[recordID] = userMsg.id
        discussionDraftsByRecord.removeValue(forKey: recordID)

        withAnimation(.easeInOut(duration: 0.16)) {
            records[initialIdx].discussionMessages.append(userMsg)
            records[initialIdx].updatedAt = Date()
            discussingRecordIDs.insert(recordID)
            isErrorBanner = false
        }
        saveRecordsImmediately()

        let storeRef = self.store
        let task = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                self.discussingRecordIDs.remove(recordID)
                self.discussionTasks.removeValue(forKey: recordID)
                self.pendingUserMessageIDs.removeValue(forKey: recordID)
            }

            // Ensure original PDF pages are loaded (either from cache or fetched on-the-fly)
            var pdfDoc = PaperPDFService.loadCachedDocumentIfPresent(for: recordID, store: storeRef)
            if pdfDoc == nil {
                if let runningPrefetch = self.pdfPrefetchTasks[recordID] {
                    await runningPrefetch.value
                    pdfDoc = PaperPDFService.loadCachedDocumentIfPresent(for: recordID, store: storeRef)
                } else if self.canAutoFetchRemotePDF(snapshotRecord) || snapshotRecord.cachedPDFPath != nil {
                    self.loadingPDFRecordIDs.insert(recordID)
                    if let fetched = try? await Task.detached(priority: .userInitiated, operation: {
                        try await PaperPDFService.ensureCachedPDF(for: snapshotRecord, store: storeRef)
                    }).value {
                        pdfDoc = fetched.document
                        if let rIdx = self.records.firstIndex(where: { $0.id == recordID }) {
                            self.records[rIdx].cachedPDFPath = fetched.pdfPath
                            self.records[rIdx].cachedPDFPageCount = fetched.document.pageCount
                            self.saveRecordsImmediately()
                        }
                    }
                    self.loadingPDFRecordIDs.remove(recordID)
                }
            }

            if Task.isCancelled { return false }

            do {
                let latestRecordSnapshot = self.records.first(where: { $0.id == recordID }) ?? snapshotRecord
                let answer = try await PaperDigestAnalyzer.askFollowUp(
                    record: latestRecordSnapshot,
                    priorHistory: priorHistory,
                    question: trimmed,
                    pdfDocument: pdfDoc,
                    preferredMode: preferredMode,
                    speedProfile: speedProfile
                )
                guard !Task.isCancelled else { return false }

                let assistantMsg = PaperDiscussionMessage(role: .assistant, content: answer)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    self.discussingRecordIDs.remove(recordID)
                    // Only append if the record AND `userMsg` were NOT cleared/deleted while waiting!
                    if let targetIdx = self.records.firstIndex(where: { $0.id == recordID }),
                       self.records[targetIdx].discussionMessages.contains(where: { $0.id == userMsg.id }) {
                        self.records[targetIdx].discussionMessages.append(assistantMsg)
                        self.records[targetIdx].updatedAt = Date()
                        self.saveRecordsImmediately()
                    }
                }
                return true
            } catch is CancellationError {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if let targetIdx = self.records.firstIndex(where: { $0.id == recordID }) {
                        self.records[targetIdx].discussionMessages.removeAll { $0.id == userMsg.id }
                        self.saveRecordsImmediately()
                    }
                }
                return false
            } catch {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if let targetIdx = self.records.firstIndex(where: { $0.id == recordID }) {
                        self.records[targetIdx].discussionMessages.removeAll { $0.id == userMsg.id }
                        self.saveRecordsImmediately()
                    }
                    if (self.discussionDraftsByRecord[recordID] ?? "").isEmpty {
                        self.discussionDraftsByRecord[recordID] = trimmed
                    }
                    self.isErrorBanner = true
                    self.statusBanner = "讨论提问失败：\(error.localizedDescription)"
                }
                return false
            }
        }

        discussionTasks[recordID] = task
        return await task.value
    }

    // MARK: - Analyze Link / Article / Local PDF

    func cancelAnalysis() {
        activeAnalysisTask?.cancel()
        activeAnalysisTask = nil
        isAnalyzing = false
        statusBanner = nil
    }

    @discardableResult
    func pasteClipboardAndAnalyze(preferredMode: AIProviderMode, speedProfile: AISpeedProfile) async -> UUID? {
        guard !isAnalyzing else { return nil }

        // 1. Check if user copied a `.pdf` file directly in Finder (`⌘C`)
        if let copiedURLs = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let firstPDF = copiedURLs.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            return await runAnalysis(rawInput: firstPDF.path, preferredMode: preferredMode, speedProfile: speedProfile)
        }

        // 2. Otherwise read clipboard text / URL
        let rawClipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawClipboard.isEmpty else {
            isErrorBanner = true
            statusBanner = "剪贴板为空，请先复制公众号链接、arXiv 链接、本地 PDF 文件或文章正文"
            return nil
        }
        return await runAnalysis(rawInput: rawClipboard, preferredMode: preferredMode, speedProfile: speedProfile)
    }

    @discardableResult
    func runAnalysis(
        rawInput: String,
        preferredMode: AIProviderMode,
        speedProfile: AISpeedProfile
    ) async -> UUID? {
        guard !isAnalyzing else { return nil }
        let submitted = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else {
            isErrorBanner = true
            statusBanner = "请粘贴微信公众号文章链接、arXiv / HuggingFace / GitHub 链接，或拖入本地 PDF"
            return nil
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            isAnalyzing = true
            isErrorBanner = false
            statusBanner = "🌐 正在解析内容…"
        }

        let storeRef = self.store
        let task = Task<UUID?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            do {
                let digest = try await PaperDigestAnalyzer.analyze(
                    rawInput: submitted,
                    preferredMode: preferredMode,
                    speedProfile: speedProfile,
                    onStageChange: { [weak self] msg in
                        Task { @MainActor in
                            self?.statusBanner = msg
                        }
                    }
                )
                guard !Task.isCancelled else { return nil }

                var newRecord = PaperDigestRecord(
                    createdAt: Date(),
                    updatedAt: Date(),
                    isPinned: false,
                    digest: digest
                )

                // If the analyzed input was a local PDF file, cache & attach it immediately!
                if let localPDF = WebArticleFetcher.extractLocalPDFFileURL(from: submitted),
                   let imported = try? PaperPDFService.importLocalPDF(sourceURL: localPDF, for: newRecord.id, store: storeRef) {
                    newRecord.cachedPDFPath = imported.pdfPath
                    newRecord.cachedPDFPageCount = imported.document.pageCount
                }

                withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                    self.records.insert(newRecord, at: 0)
                    self.latestCreatedRecordID = newRecord.id
                    self.isAnalyzing = false
                    self.isErrorBanner = false
                    self.statusBanner = "✨ 解析完成：\(digest.primaryDisplayTitle)"
                    self.saveRecordsImmediately()
                }

                // Proactively pre-cache remote PDF in background so follow-up Q&A is instant!
                self.prefetchPDFIfNeeded(for: newRecord.id, silent: true)
                return newRecord.id
            } catch is CancellationError {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.isAnalyzing = false
                    self.statusBanner = nil
                }
                return nil
            } catch {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.isAnalyzing = false
                    self.isErrorBanner = true
                    self.statusBanner = error.localizedDescription
                }
                return nil
            }
        }
        activeAnalysisTask = task
        let result = await task.value
        activeAnalysisTask = nil
        return result
    }

    // MARK: - Export & Archive Actions

    func copyMarkdownToClipboard(_ record: PaperDigestRecord) {
        let md = record.toMarkdown(includeFrontmatter: true)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        isErrorBanner = false
        statusBanner = "📋 已复制完整 Markdown 论文笔记（含 YAML 头与讨论记录，可直接粘贴至 Obsidian / Notion / 飞书）"
    }

    func archiveToAppleNotes(_ record: PaperDigestRecord) async {
        guard !isArchivingNotes else { return }
        let wasAlreadyArchived = record.isArchivedToNotes
        isArchivingNotes = true
        isErrorBanner = false
        statusBanner = wasAlreadyArchived
            ? "📒 正在同步更新苹果「备忘录 > MemoPilot 论文速递」中的笔记…"
            : "📒 正在归档至苹果「备忘录 > MemoPilot 论文速递」文件夹…"
        defer { isArchivingNotes = false }

        do {
            let extID = try await AppleExecutors.shared.archivePaperDigestToAppleNotes(record: record)
            if let idx = records.firstIndex(where: { $0.id == record.id }) {
                records[idx].isArchivedToNotes = true
                if let extID, !extID.isEmpty {
                    records[idx].appleNoteExternalID = extID
                }
                records[idx].updatedAt = Date()
                saveRecordsImmediately()
            }
            isErrorBanner = false
            statusBanner = wasAlreadyArchived
                ? "✅ 已同步更新苹果「备忘录 > MemoPilot 论文速递」：\(record.digest.primaryDisplayTitle)"
                : "✅ 已归档至苹果「备忘录 > MemoPilot 论文速递」：\(record.digest.primaryDisplayTitle)"
        } catch {
            isErrorBanner = true
            statusBanner = "归档备忘录失败：\(error.localizedDescription)"
        }
    }

    func exportMarkdownToLocalFolder(_ record: PaperDigestRecord, forceChooseFolder: Bool = false) {
        var targetDirURL: URL?
        if !forceChooseFolder,
           let savedPath = store.savedExportDirectoryPath,
           FileManager.default.fileExists(atPath: savedPath) {
            targetDirURL = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            let panel = NSOpenPanel()
            panel.title = "选择论文 Markdown 导出目录（如 Obsidian 知识库文件夹）"
            panel.prompt = "导出至此文件夹"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let picked = panel.url {
                store.savedExportDirectoryPath = picked.path
                targetDirURL = picked
            }
        }

        guard let dirURL = targetDirURL else { return }
        do {
            let savedFilePath = try store.writeMarkdownFile(for: record, directoryURL: dirURL)
            if let idx = records.firstIndex(where: { $0.id == record.id }) {
                records[idx].exportedMarkdownPath = savedFilePath
                records[idx].updatedAt = Date()
                saveRecordsImmediately()
            }
            isErrorBanner = false
            statusBanner = "💾 已保存 Markdown 文件：\((savedFilePath as NSString).lastPathComponent)"
        } catch {
            isErrorBanner = true
            statusBanner = "导出 Markdown 失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Curated Sample Record

    private static func makeInitialSampleRecord() -> PaperDigestRecord {
        PaperDigestRecord(
            createdAt: Date().addingTimeInterval(-600),
            updatedAt: Date().addingTimeInterval(-600),
            isPinned: true,
            digest: PaperDigest(
                paperTitleEN: "DeepSeek-R1: Incentivizing Reasoning Capability in LLMs via Reinforcement Learning",
                paperTitleZH: "用纯强化学习激发大模型涌现推理能力",
                shortAlias: "DeepSeek-R1",
                authorsAndAffiliations: "DeepSeek-AI",
                venueAndDate: "arXiv:2501.12948 · 2025-01",
                sourceAccountOrSite: "示例文献卡片",
                sourceArticleTitle: "粘贴任意微信公众号推送或 arXiv 链接，即可生成此结构化全息卡片",
                sourceURL: "https://arxiv.org/abs/2501.12948",
                paperURL: "https://arxiv.org/abs/2501.12948",
                pdfURL: "https://arxiv.org/pdf/2501.12948",
                codeURL: "https://github.com/deepseek-ai/DeepSeek-R1",
                projectURL: "",
                domainTags: ["LLM Reasoning", "GRPO", "Reinforcement Learning", "Distillation"],
                oneLineConclusion: "证明无需人类标注推理轨迹（SFT），仅靠基于规则奖励的纯强化学习（GRPO）即可让基座模型自发涌现反思、长思维链与自我验证能力；配合少量冷启动数据与多阶段对齐，在数学与代码基准上追平 OpenAI-o1-1217。",
                whyItMatters: "打破了「复杂推理必须先靠大规模过程监督（PRM）或蒙特卡洛树搜索（MCTS）热启动」的主流共识，并首次系统展示了大模型推理模式可通过直接蒸馏赋予小模型远超其自发 RL 的上限。",
                problemAndBottlenecks: [
                    "传统后训练高度依赖昂贵的长链思维人工标注或脆弱的过程奖励模型（PRM，易触发 Reward Hacking）。",
                    "MCTS 类搜索方法在超长 Token 生成空间中分支爆炸，训练与推理算力开销极高。",
                    "小参数模型从零跑大规模 RL 难以自主探索出高质量长推理模式。"
                ],
                scopeBoundary: "证明了具有可客观验证答案的任务（数学、代码、逻辑）可通过规则奖励驱动推理涌现；对于开放式创意写作或主观偏好任务仍需结合通用奖励模型与 SFT。",
                methodSteps: [
                    "R1-Zero 纯 RL 验证：在 DeepSeek-V3-Base 上直接运行 GRPO（组相对策略优化，省去独立 Critic 模型），仅使用准确性规则奖励 + 格式奖励。",
                    "冷启动对齐（Cold Start）：收集数千条高可读性长 CoT 样本微调基座，解决 R1-Zero 中英文混杂与可读性差的问题。",
                    "推理导向 RL + 拒绝采样 SFT：第二轮收敛后采集 60 万推理轨迹与 20 万通用数据联合微调，再经全场景第二阶段 RL 对齐。",
                    "推理能力蒸馏：直接用 DeepSeek-R1 生成的 80 万样本微调 Qwen/Llama（1.5B~70B）小模型。"
                ],
                keyResults: [
                    "AIME 2024 Pass@1 从 R1-Zero 初期的 15.6% 飙升至 71.0%（R1 正式版达 79.8%，略超 o1-1217 的 79.2%）。",
                    "Codeforces 达到 96.3% 百分位（2029 Elo），MATH-500 达到 97.3%。",
                    "蒸馏版 DeepSeek-R1-Distill-Qwen-32B 在 AIME 2024 取得 72.6%，显著击败在 Qwen-32B-Base 上直接做大规模 RL 的 47.0%。"
                ],
                computeAndTradeoffs: "省去了与 Policy 同等规模的 Critic 显存开销（GRPO 组内均值基线），但长 CoT 生成导致采样阶段序列长度大幅拉长（数千至上万 Token），推理时延与 KV Cache 成本随思考长度线性增加。",
                limitations: [
                    "对结构化输出、复杂函数调用与多轮角色扮演表现仍弱于通用指令模型。",
                    "对提示词（Few-shot）敏感：添加 Few-shot 示例反而会显著降低 R1 的推理表现，需采用 Zero-shot 直接描述问题。",
                    "软件工程类长上下文评测（如 SWE-bench Verified 49.2%）因 RL 验证环境评测慢，训练规模尚不充分。"
                ]
            )
        )
    }
}
