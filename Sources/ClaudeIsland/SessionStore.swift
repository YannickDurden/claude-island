import AppKit
import Observation

@MainActor
@Observable
final class SessionStore {
    enum Status { case working, idle, attention, done }

    struct Subagent: Identifiable {
        let id: String
        let type: String
        var running = true
        var activity = ""
    }

    struct Session: Identifiable {
        let id: String
        let cwd: String
        var status = Status.idle
        var activity = ""
        var subagents: [Subagent] = []
        /// Pending `AskUserQuestion`, answered in Claude itself.
        var question: String?
        /// Last hook received (or registry update): the session the user is most likely in.
        var lastActivity = Date.distantPast
        var termProgram: String?
        var focusURL: URL?
        /// Known once seen in the registry; lets dead processes be dropped.
        var pid: Int32?

        var name: String { (cwd as NSString).lastPathComponent }

        /// Warp panes and Claude Desktop sessions have a URL; other terminals only get their app activated.
        @MainActor
        func focusTerminal() {
            // A click in the non-activating panel leaves us inactive, and since macOS 14
            // only the active app may hand the foreground over to another one.
            NSApp.activate()
            if let focusURL {
                NSWorkspace.shared.open(focusURL)
            } else if let id = appBundleId, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }

        /// The app hosting the session: Claude Desktop or the terminal.
        var appBundleId: String? {
            focusURL?.scheme == "claude" ? "com.anthropic.claudefordesktop" : Self.terminalBundleIds[termProgram ?? ""]
        }

        private static let terminalBundleIds = [
            "WarpTerminal": "dev.warp.Warp-Stable",
            "ghostty": "com.mitchellh.ghostty",
            "Apple_Terminal": "com.apple.Terminal",
        ]
    }

    struct Permission: Identifiable {
        let id = UUID()
        let sessionId, tool, detail: String
        let toolUseId: String?
        /// Present when Claude offers a "don't ask again" rule.
        let sessionRules: Data?
        let questions: [HookEvent.Question]
        let toolInput: Data?
        let reply: (Decision) -> Void

        /// Whether a later event of the session shows this request was already answered in Claude.
        func isSettled(by e: HookEvent) -> Bool {
            guard e.sessionId == sessionId else { return false }
            switch e.name {
            case .postToolUse, .postToolUseFailure:
                // Without a tool_use_id, fall back to the tool name.
                return toolUseId.map { $0 == e.toolUseId } ?? (tool == e.tool)
            case .stop, .userPromptSubmit, .sessionEnd:
                return true
            default:
                return false
            }
        }
    }

    private(set) var sessions: [Session] = []
    private(set) var permissions: [Permission] = []

    var hasQuestions: Bool { sessions.contains { $0.question != nil } }

    /// Session that just finished its turn: the island unfolds on it for a few seconds.
    private(set) var justFinished: String?
    private var finishedToken = UUID()

    private func announceFinished(_ sessionId: String) {
        justFinished = sessionId
        let token = UUID()
        finishedToken = token
        Task {
            try? await Task.sleep(for: .seconds(4))
            // A later finish restarts the delay.
            if finishedToken == token { justFinished = nil }
        }
    }

    /// The session waiting on the user, if any: the only case where the collapsed pill
    /// grows wings past the notch (menus flow around it). Blocked requests come first.
    var alerting: Session? {
        let blocked = Set(permissions.map(\.sessionId))
        let byRecency = sessions.sorted { $0.lastActivity > $1.lastActivity }
        return byRecency.first { blocked.contains($0.id) || $0.question != nil }
            ?? byRecency.first { $0.status == .attention }
    }

    func handle(_ e: HookEvent) {
        // The user may answer in Claude itself while the island waits: close those requests.
        for permission in permissions where permission.isSettled(by: e) {
            dropPermission(permission.id)
            permission.reply(.terminal)
        }
        if e.name == .sessionEnd {
            sessions.removeAll { $0.id == e.sessionId }
            return
        }
        let i = index(of: e)
        switch e.name {
        case .userPromptSubmit:
            sessions[i].status = .working
            sessions[i].activity = ""
            sessions[i].question = nil
            sessions[i].subagents.removeAll { !$0.running }
        case .preToolUse where e.question != nil:
            sessions[i].status = .attention
            sessions[i].question = e.question
            NSSound(named: "Glass")?.play()
        case .preToolUse:
            // The main agent moving on means the question was answered; subagents may run meanwhile.
            if e.agentId == nil { sessions[i].question = nil }
            if sessions[i].question == nil { sessions[i].status = .working }
            let activity = [e.tool, e.detail].compactMap { $0 }.joined(separator: " · ")
            // Subagent tool calls carry the subagent's agent_id.
            if let j = sessions[i].subagents.firstIndex(where: { $0.id == e.agentId }) {
                sessions[i].subagents[j].activity = activity
            } else {
                sessions[i].activity = activity
            }
        case .subagentStart:
            sessions[i].subagents.append(Subagent(id: e.agentId ?? UUID().uuidString, type: e.agentType ?? "agent"))
        case .subagentStop:
            if let j = sessions[i].subagents.firstIndex(where: { $0.id == e.agentId }) {
                sessions[i].subagents[j].running = false
            }
        case .notification where e.notificationType == "idle_prompt" && sessions[i].status == .done:
            // "Waiting for your input" right after a finish: already shown as done.
            break
        case .notification:
            sessions[i].status = .attention
            sessions[i].activity = e.message ?? ""
            NSSound(named: "Glass")?.play()
        case .postToolUse, .postToolUseFailure:
            if sessions[i].question == nil, !permissions.contains(where: { $0.sessionId == e.sessionId }) {
                sessions[i].status = .working
            }
        case .stop:
            sessions[i].status = .done
            sessions[i].question = nil
            announceFinished(e.sessionId)
        case .sessionStart, .sessionEnd, .permissionRequest:
            // Creating the session in `index(of:)` is all they need here.
            break
        }
    }

    /// Adds sessions that sent no hook yet (idle, or started before the app) and drops dead processes.
    func sync(with entries: [SessionRegistry.Entry]) {
        for entry in entries {
            if let i = sessions.firstIndex(where: { $0.id == entry.sessionId }) {
                sessions[i].pid = entry.pid
                continue
            }
            var session = Session(id: entry.sessionId, cwd: entry.cwd)
            session.pid = entry.pid
            session.status = entry.status == "busy" ? .working : .idle
            session.activity = entry.name ?? ""
            session.lastActivity = entry.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            if let url = URL.claudeDesktop(entry.hostSessionId) {
                session.focusURL = url
            } else {
                (session.termProgram, session.focusURL) = SessionRegistry.terminal(of: entry.pid)
            }
            sessions.append(session)
        }
        let alive = Set(entries.map(\.pid))
        sessions.removeAll { $0.pid.map { !alive.contains($0) } ?? false }
    }

    func requestPermission(_ e: HookEvent, reply: @escaping (Decision) -> Void) -> UUID {
        sessions[index(of: e)].status = .attention
        let permission = Permission(sessionId: e.sessionId, tool: e.tool ?? "?", detail: e.detail ?? "",
                                    toolUseId: e.toolUseId, sessionRules: e.sessionRules,
                                    questions: e.questions, toolInput: e.toolInput, reply: reply)
        permissions.append(permission)
        // Questions already rang on PreToolUse.
        if e.questions.isEmpty { NSSound(named: "Glass")?.play() }
        return permission.id
    }

    func decide(_ permission: Permission, _ decision: Decision) {
        dropPermission(permission.id)
        if decision != .terminal, let i = sessions.firstIndex(where: { $0.id == permission.sessionId }) {
            sessions[i].status = .working
        }
        permission.reply(decision)
    }

    /// The session stays in `.attention` until Claude moves on; only the card goes.
    func dismissQuestion(of sessionId: String) {
        if let i = sessions.firstIndex(where: { $0.id == sessionId }) { sessions[i].question = nil }
    }

    func dropPermission(_ id: UUID) {
        permissions.removeAll { $0.id == id }
    }

    func name(of sessionId: String) -> String {
        sessions.first { $0.id == sessionId }?.name ?? "Claude"
    }

    /// Sessions started before the app launched have no SessionStart: create them lazily.
    private func index(of e: HookEvent) -> Int {
        let i = sessions.firstIndex { $0.id == e.sessionId } ?? {
            sessions.append(Session(id: e.sessionId, cwd: e.cwd))
            return sessions.count - 1
        }()
        sessions[i].lastActivity = .now
        if let t = e.termProgram { sessions[i].termProgram = t }
        if let u = e.focusURL { sessions[i].focusURL = u }
        return i
    }
}
