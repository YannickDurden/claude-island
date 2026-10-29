import Foundation
import Testing
@testable import ClaudeIsland

/// A permission answered in Claude itself must leave the island, with no decision sent back.
@MainActor
struct PermissionSettlingTests {
    private func event(_ name: String, tool: String = "Bash", toolUseId: String? = nil, session: String = "s1") -> HookEvent {
        var json: [String: Any] = ["hook_event_name": name, "session_id": session, "tool_name": tool]
        json["tool_use_id"] = toolUseId
        return HookEvent(json: try! JSONSerialization.data(withJSONObject: json), headers: [:])!
    }

    @Test func toolRunningSettlesItsOwnRequestOnly() {
        let store = SessionStore()
        var replies: [Decision] = []
        _ = store.requestPermission(event("PermissionRequest", toolUseId: "t1")) { replies.append($0) }
        _ = store.requestPermission(event("PermissionRequest", toolUseId: "t2")) { replies.append($0) }

        store.handle(event("PostToolUse", toolUseId: "t1"))

        #expect(store.permissions.map(\.toolUseId) == ["t2"])
        #expect(replies == [.terminal])
    }

    @Test func endOfTurnSettlesTheSessionRequests() {
        let store = SessionStore()
        _ = store.requestPermission(event("PermissionRequest", tool: "ExitPlanMode", toolUseId: "t1")) { _ in }
        _ = store.requestPermission(event("PermissionRequest", toolUseId: "t9", session: "other")) { _ in }

        store.handle(event("Stop"))

        #expect(store.permissions.map(\.sessionId) == ["other"])
    }

    @Test func finishIsAnnouncedAndNotTurnedIntoAttention() {
        let store = SessionStore()
        store.handle(event("Stop"))
        #expect(store.sessions.first?.status == .done)
        #expect(store.justFinished == "s1")

        let idle = #"{"hook_event_name":"Notification","session_id":"s1","notification_type":"idle_prompt"}"#
        store.handle(HookEvent(json: Data(idle.utf8), headers: [:])!)
        #expect(store.sessions.first?.status == .done)
    }

    @Test func fallsBackToToolNameWithoutToolUseId() {
        let store = SessionStore()
        _ = store.requestPermission(event("PermissionRequest", tool: "WebFetch")) { _ in }

        store.handle(event("PostToolUse", tool: "Read", toolUseId: "x"))
        #expect(store.permissions.count == 1)

        store.handle(event("PostToolUse", tool: "WebFetch", toolUseId: "y"))
        #expect(store.permissions.isEmpty)
    }
}
