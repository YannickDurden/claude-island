import Foundation

/// Claude Code's registry of running sessions: one `~/.claude/sessions/<pid>.json` per process.
// ponytail: undocumented internal format; hooks stay the source of truth for live status.
enum SessionRegistry {
    struct Entry: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let status: String?
        let name: String?
        let hostSessionId: String?
        /// Milliseconds since 1970.
        let updatedAt: Double?
    }

    /// Entries whose process is still alive.
    static func load() -> [Entry] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
            .filter { kill($0.pid, 0) == 0 }
    }

    /// Terminal markers from the process environment (same user, so `ps -E` may read it).
    static func terminal(of pid: Int32) -> (program: String?, focusURL: URL?) {
        let ps = Process()
        ps.executableURL = URL(filePath: "/bin/ps")
        ps.arguments = ["-E", "-ww", "-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return (nil, nil) }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        func env(_ name: String) -> String? {
            (output.firstMatch(of: try! Regex(" \(name)=(\\S+)"))?.output[1].substring).map(String.init)
        }
        return (env("TERM_PROGRAM"), .warp(env("WARP_FOCUS_URL")))
    }
}
