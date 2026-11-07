import ApeironKit
import Foundation
import Observation

/// Streaming assistant prose. A class so token deltas only re-render this block.
@Observable
final class AssistantTextModel: Identifiable {
    let id = UUID()
    var text: String
    var isStreaming: Bool

    init(text: String = "", isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }
}

@Observable
final class ThinkingModel: Identifiable {
    let id = UUID()
    var text: String
    var isStreaming: Bool
    var startedAt: Date
    var duration: TimeInterval?

    init(text: String = "", isStreaming: Bool = false, startedAt: Date = Date(), duration: TimeInterval? = nil) {
        self.text = text
        self.isStreaming = isStreaming
        self.startedAt = startedAt
        self.duration = duration
    }
}

@Observable
final class ToolCardModel: Identifiable {
    enum Status: Equatable {
        case preparing
        case awaitingApproval
        case running
        case succeeded
        case failed
        case denied
    }

    let id = UUID()
    let callID: String
    var name: String
    var title: String
    var category: ToolCategory
    var input: JSONValue
    var status: Status
    var output: String?
    var metadata: ToolMetadata?
    var startedAt: Date
    var duration: TimeInterval?

    init(callID: String, name: String, title: String, category: ToolCategory = .meta, input: JSONValue = [:], status: Status) {
        self.callID = callID
        self.name = name
        self.title = title
        self.category = category
        self.input = input
        self.status = status
        self.startedAt = Date()
    }

    var symbol: String {
        switch name {
        case "read_file": return "doc.text"
        case "write_file": return "doc.badge.plus"
        case "edit_file": return "pencil.line"
        case "list_directory": return "folder"
        case "glob": return "doc.text.magnifyingglass"
        case "grep": return "magnifyingglass"
        case "bash": return "terminal"
        case "web_fetch": return "globe"
        case "todo_write": return "checklist"
        case "use_skill": return "sparkles"
        case "task": return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }

    /// The most useful single-line detail for the header.
    var detail: String? {
        switch name {
        case "bash": return input["command"]?.stringValue
        case "grep": return input["path"]?.stringValue
        case "web_fetch": return input["url"]?.stringValue
        default: return nil
        }
    }
}

struct UserItem: Identifiable {
    let id = UUID()
    var text: String
    var imageCount: Int
    var attachmentNames: [String]
}

struct NoticeItem: Identifiable {
    enum Style { case info, warning, error, compaction, help }
    let id = UUID()
    var text: String
    var style: Style
}

enum TranscriptItem: Identifiable {
    case user(UserItem)
    case assistant(AssistantTextModel)
    case thinking(ThinkingModel)
    case tool(ToolCardModel)
    case notice(NoticeItem)

    var id: UUID {
        switch self {
        case .user(let item): return item.id
        case .assistant(let model): return model.id
        case .thinking(let model): return model.id
        case .tool(let model): return model.id
        case .notice(let item): return item.id
        }
    }
}

struct PendingApproval: Identifiable {
    var id: String { request.id }
    let request: PermissionRequest
    let continuation: CheckedContinuation<PermissionReply, Never>
}

struct ChangedFile: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var original: String
    var latest: String
    var stats: (added: Int, removed: Int) { LineDiff.stats(before: original, after: latest) }

    static func == (lhs: ChangedFile, rhs: ChangedFile) -> Bool {
        lhs.path == rhs.path && lhs.latest == rhs.latest && lhs.original == rhs.original
    }
}

/// Bridges the harness's permission prompts to the UI.
final class UIPermissionPrompter: PermissionPrompter, @unchecked Sendable {
    weak var controller: SessionController?

    func requestPermission(_ request: PermissionRequest) async -> PermissionReply {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard let controller = self.controller else {
                    continuation.resume(returning: .deny(feedback: nil))
                    return
                }
                controller.enqueueApproval(request, continuation: continuation)
            }
        }
    }
}
