import Foundation
import Testing
@testable import ClaudeIsland

/// The two parsers sitting on the trust boundary: raw HTTP from Claude Code, then its hook JSON.
struct HookParsingTests {
    private func http(_ body: String, headers: String = "") -> Data {
        Data("POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\(headers)\r\n\(body)".utf8)
    }

    @Test func parsesHeadersCaseInsensitivelyAndBody() throws {
        let request = try #require(HookServer.request(of: http(#"{"a":1}"#, headers: "X-Focus-Url: warp://session/abc\r\n")))
        #expect(request.headers["x-focus-url"] == "warp://session/abc")
        #expect(String(decoding: request.body, as: UTF8.self) == #"{"a":1}"#)
    }

    @Test func waitsForTheWholeBody() {
        let full = http(#"{"hook_event_name":"Stop"}"#)
        #expect(HookServer.request(of: full.dropLast(3)) == nil)
        #expect(HookServer.request(of: Data("POST /hook HTTP/1.1\r\nContent-Length: 5".utf8)) == nil)
    }

    @Test func readsAskUserQuestion() throws {
        let json = #"""
        {"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp/api","tool_name":"AskUserQuestion",
         "tool_input":{"questions":[{"question":"Redis ou APCu ?"},{"question":"TTL ?"}]}}
        """#
        let event = try #require(HookEvent(json: Data(json.utf8), headers: [:]))
        #expect(event.name == .preToolUse)
        #expect(event.question == "Redis ou APCu ? (+1)")
    }

    @Test func picksTheFocusURL() throws {
        let json = Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8)
        let warp = try #require(HookEvent(json: json, headers: ["x-focus-url": "warp://session/abc", "x-desktop-session": "local_x"]))
        #expect(warp.focusURL?.absoluteString == "warp://session/abc")

        let desktop = try #require(HookEvent(json: json, headers: ["x-focus-url": "", "x-desktop-session": "local_ab-12"]))
        #expect(desktop.focusURL?.absoluteString == "claude://code/continue?session=local_ab-12")

        // Unset variables arrive empty; anything else is refused rather than opened.
        let none = try #require(HookEvent(json: json, headers: ["x-focus-url": "https://evil.test", "x-desktop-session": "local_x&y=1"]))
        #expect(none.focusURL == nil)
    }

    @Test func ignoresUnknownEventsAndBadJSON() {
        #expect(HookEvent(json: Data(#"{"hook_event_name":"PostCompact","session_id":"s1"}"#.utf8), headers: [:]) == nil)
        #expect(HookEvent(json: Data("pas du json".utf8), headers: [:]) == nil)
    }
}
