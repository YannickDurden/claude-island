import Foundation
import Network
import OSLog

let log = Logger(subsystem: "local.ClaudeIsland", category: "hooks")

/// The hook events registered in `hooks.json`.
enum HookEventName: String, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case notification = "Notification"
    case permissionRequest = "PermissionRequest"
    case stop = "Stop"
}

/// The subset of a Claude Code hook payload the island displays.
struct HookEvent: Sendable {
    struct Question: Sendable {
        let text: String
        let options: [String]
        let multiSelect: Bool
    }

    let name: HookEventName
    let sessionId, cwd: String
    let tool, toolUseId, detail, message, notificationType, agentId, agentType: String?
    /// First question of an `AskUserQuestion` call, with a "(+n)" suffix when there are more.
    let question: String?
    /// Claude's own "don't ask again" rules for a `PermissionRequest`, rescoped to the session (JSON array).
    let sessionRules: Data?
    /// `AskUserQuestion` only: its questions, and its raw input to send back with the answers.
    let questions: [Question]
    let toolInput: Data?
    /// From the hook's `headers` (env interpolation), empty when the variable is unset.
    let termProgram: String?
    let focusURL: URL?

    init?(json: Data, headers: [String: String]) {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let name = (o["hook_event_name"] as? String).flatMap(HookEventName.init(rawValue:)),
              let sessionId = o["session_id"] as? String else { return nil }
        self.name = name
        self.sessionId = sessionId
        cwd = o["cwd"] as? String ?? ""
        tool = o["tool_name"] as? String
        toolUseId = o["tool_use_id"] as? String
        message = o["message"] as? String
        notificationType = o["notification_type"] as? String
        agentId = o["agent_id"] as? String
        agentType = o["agent_type"] as? String
        let input = o["tool_input"] as? [String: Any]
        detail = ["command", "file_path", "url", "pattern", "description", "prompt"]
            .lazy.compactMap { input?[$0] as? String }.first
        questions = (input?["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return Question(text: text, options: options, multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        toolInput = questions.isEmpty ? nil : input.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        if let questions = input?["questions"] as? [[String: Any]], let first = questions.first?["question"] as? String {
            question = questions.count > 1 ? "\(first) (+\(questions.count - 1))" : first
        } else {
            question = nil
        }
        sessionRules = (o["permission_suggestions"] as? [[String: Any]]).flatMap { suggestions in
            suggestions.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: suggestions.map {
                $0.merging(["destination": "session"]) { _, new in new }
            })
        }
        termProgram = headers["x-term-program"].flatMap { $0.isEmpty ? nil : $0 }
        focusURL = .warp(headers["x-focus-url"]) ?? .claudeDesktop(headers["x-desktop-session"])
    }
}

extension URL {
    /// Warp exports a per-pane `WARP_FOCUS_URL`.
    static func warp(_ value: String?) -> URL? {
        value.flatMap(URL.init(string:)).flatMap { $0.scheme == "warp" ? $0 : nil }
    }

    /// Claude Desktop sessions export `CLAUDE_CODE_HOST_SESSION_ID=local_…`.
    // ponytail: undocumented Desktop deep link, falls back to nothing if it changes.
    static func claudeDesktop(_ hostSessionId: String?) -> URL? {
        guard let hostSessionId, hostSessionId.wholeMatch(of: /local_[A-Za-z0-9-]{1,64}/) != nil else { return nil }
        return URL(string: "claude://code/continue?session=\(hostSessionId)")
    }
}

enum Decision: Equatable {
    /// `allowForSession` carries the permission updates (JSON array) Claude adds for the rest of the session.
    case allow, allowForSession(Data), deny, terminal
    /// `AskUserQuestion` answered from the island: its input plus `answers` (question → option label).
    // ponytail: the Agent SDK's answer format; undocumented for hooks, Claude falls back to its own prompt if ignored.
    case answer(input: Data, answers: [String: String])

    /// Empty body = no decision: Claude Code falls back to its usual terminal prompt.
    var output: Data {
        var decision: [String: Any]
        switch self {
        case .allow: decision = ["behavior": "allow"]
        case .allowForSession(let rules):
            decision = ["behavior": "allow"]
            decision["updatedPermissions"] = try? JSONSerialization.jsonObject(with: rules)
        case .answer(let input, let answers):
            var updated = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
            updated["answers"] = answers
            decision = ["behavior": "allow", "updatedInput": updated]
        case .deny: decision = ["behavior": "deny", "message": "Refusé depuis Claude Island"]
        case .terminal: return Data()
        }
        let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
    }
}

/// Minimal HTTP endpoint for Claude Code `"type": "http"` hooks, bound to 127.0.0.1 only.
@MainActor
final class HookServer {
    static let port: UInt16 = 47821
    /// Hook payloads are a few KB; anything bigger is not Claude Code.
    private static let maxRequestSize = 1 << 20
    /// A request must be fully received within this delay (the permission wait comes after).
    private static let readTimeout: TimeInterval = 10

    private let listener: NWListener
    private let store: SessionStore
    /// Connections still receiving their request.
    private var reading: Set<ObjectIdentifier> = []

    init(store: SessionStore) {
        self.store = store
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        listener = try! NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.accept(conn) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { print("HookServer: \(error)") }
        }
        listener.start(queue: .main)
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        reading.insert(id)
        conn.start(queue: .main)
        read(conn, Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readTimeout) { [weak self] in
            if self?.reading.remove(id) != nil { conn.cancel() }
        }
    }

    private func read(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return conn.cancel() }
                let buffer = buffer + (data ?? Data())
                if let request = Self.request(of: buffer) {
                    self.reading.remove(ObjectIdentifier(conn))
                    self.handle(request.body, request.headers, conn)
                } else if done || error != nil || buffer.count > Self.maxRequestSize {
                    self.reading.remove(ObjectIdentifier(conn))
                    conn.cancel()
                } else {
                    self.read(conn, buffer)
                }
            }
        }
    }

    private func handle(_ body: Data, _ headers: [String: String], _ conn: NWConnection) {
        guard let event = HookEvent(json: body, headers: headers) else { return Self.reply(conn) }
        guard event.name == .permissionRequest else {
            store.handle(event)
            return Self.reply(conn)
        }
        // Keep the request open until the user decides in the island.
        let id = store.requestPermission(event) { decision in
            log.notice("Decision \(String(describing: decision), privacy: .public) for \(event.tool ?? "?", privacy: .public), connection \(String(describing: conn.state), privacy: .public)")
            Self.reply(conn, decision.output)
        }
        // Claude Code closes the connection on hook timeout: drop the stale card.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, done, error in
            guard done || error != nil else { return }
            log.notice("Claude closed a pending permission request")
            MainActor.assumeIsolated { self?.store.dropPermission(id) }
        }
    }

    // ponytail: assumes a Content-Length body (what Claude Code sends), no chunked encoding.
    nonisolated static func request(of buffer: Data) -> (headers: [String: String], body: Data)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        var headers: [String: String] = [:]
        for line in String(decoding: buffer[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = buffer[end.upperBound...]
        return body.count >= length ? (headers, Data(body.prefix(length))) : nil
    }

    private static func reply(_ conn: NWConnection, _ json: Data = Data()) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + json, completion: .contentProcessed { error in
            if let error { log.error("Reply failed: \(error, privacy: .public)") }
            conn.cancel()
        })
    }
}
