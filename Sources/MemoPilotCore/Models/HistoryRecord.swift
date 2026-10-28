import Foundation

public struct HistoryRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var rawInputText: String
    public var savedImagePath: String?
    public var plan: ParsedPlan
    public var isCommitted: Bool
    public var isPinned: Bool
    public var commitSummary: String?
    public var committedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, createdAt, rawInputText, savedImagePath, plan, isCommitted, isPinned, commitSummary, committedAt
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawInputText: String,
        savedImagePath: String? = nil,
        plan: ParsedPlan,
        isCommitted: Bool = false,
        isPinned: Bool = false,
        commitSummary: String? = nil,
        committedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawInputText = rawInputText
        self.savedImagePath = savedImagePath
        self.plan = plan
        self.isCommitted = isCommitted
        self.isPinned = isPinned
        self.commitSummary = commitSummary
        self.committedAt = committedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        self.rawInputText = (try? c.decodeIfPresent(String.self, forKey: .rawInputText)) ?? ""
        self.savedImagePath = try? c.decodeIfPresent(String.self, forKey: .savedImagePath)
        self.plan = (try? c.decodeIfPresent(ParsedPlan.self, forKey: .plan)) ?? ParsedPlan()
        self.isCommitted = (try? c.decodeIfPresent(Bool.self, forKey: .isCommitted)) ?? false
        self.isPinned = (try? c.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        self.commitSummary = try? c.decodeIfPresent(String.self, forKey: .commitSummary)
        self.committedAt = try? c.decodeIfPresent(Date.self, forKey: .committedAt)
    }

    public var displayTitle: String {
        let summaryTrimmed = plan.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryTrimmed.isEmpty {
            return summaryTrimmed
        }
        if let firstItem = plan.items.first(where: { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return firstItem.title
        }
        let trimmed = rawInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "屏幕截图识别" : String(trimmed.prefix(36))
    }

    public var totalItemsCount: Int {
        plan.items.count
    }

    public func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if rawInputText.lowercased().contains(q) { return true }
        if plan.summary.lowercased().contains(q) { return true }
        if plan.items.contains(where: {
            $0.title.lowercased().contains(q) || $0.location.lowercased().contains(q) || $0.notes.lowercased().contains(q)
        }) {
            return true
        }
        return false
    }
}
