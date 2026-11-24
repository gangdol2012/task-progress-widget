// Claude Code hook for the task progress widget (terminal sessions, macOS).
//
// The macOS counterpart of progress-hook.ps1, built into the `progress-hook`
// binary next to this file (mac/build.sh). Claude Code runs it on hook
// events with the event's JSON on stdin; the event name comes as the first
// argument. It keeps one progress file per session in ~/.claude/task-progress
// (cli-<session>.json), the same folder the widget reads. Desktop-app
// sessions are covered by the mod instead; for them this only keeps a
// <session>.waiting.json flag while a permission prompt is actually on
// screen, which the mod can't see by itself.
//
// Set CC_PROGRESS_DEBUG=1 to also log every raw event to
// ~/.claude/task-progress-hook-debug.jsonl.
//
// It must never break Claude: every failure drops the event and exits 0.

import Foundation

let environment = ProcessInfo.processInfo.environment
let debug = environment["CC_PROGRESS_DEBUG"] == "1"
let home: String = {
    if let h = environment["HOME"], !h.isEmpty { return h }
    return NSHomeDirectory()
}()
let claudeHome = home + "/.claude"
let stateDir = claudeHome + "/task-progress"
let debugLog = claudeHome + "/task-progress-hook-debug.jsonl"
let fm = FileManager.default

func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

// Loose readers for JSON values, so a field of an unexpected type reads as
// empty instead of stopping the hook.
func str(_ v: Any?) -> String {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    default: return ""
    }
}

func int64(_ v: Any?) -> Int64 {
    var d: Double = 0
    switch v {
    case let n as NSNumber: d = n.doubleValue
    case let s as String: d = Double(s) ?? 0
    default: d = 0
    }
    guard d.isFinite else { return 0 }
    return Int64(max(-9e15, min(9e15, d)))
}

func bool(_ v: Any?) -> Bool {
    switch v {
    case let n as NSNumber: return n.boolValue
    case let s as String: return s == "true" || s == "True"
    default: return false
    }
}

func append(_ path: String, _ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: path) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

func writeJSON(_ path: String, _ obj: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
    // Written to a temporary file and renamed over, so the widget never
    // reads half a file.
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func removeIfThere(_ path: String) {
    if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
}

struct Task {
    var id: String
    var subject: String
    var status: String
}

// Async hooks for one session can run at the same time; they take turns on
// one lock file (held for a millisecond or so each).
func withLock(_ body: () throws -> Void) rethrows {
    let fd = open(stateDir + "/.hook.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }  // closing releases the lock
    let deadline = Date().addingTimeInterval(5)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        if Date() > deadline { return }
        usleep(10_000)
    }
    try body()
}

func run(_ argEvent: String) throws {
    let input = (try? FileHandle.standardInput.readToEnd()) ?? Data()
    if input.isEmpty { return }
    guard let e = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
    let event = argEvent.isEmpty ? str(e["hook_event_name"]) : argEvent
    let sid = String(str(e["session_id"]).unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
            ? Character($0) : "_"
    })
    if sid.isEmpty { return }

    try fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    let file = stateDir + "/cli-\(sid).json"

    if debug {
        let note: [String: Any] = ["event": event, "at": ISO8601DateFormatter().string(from: Date()), "data": e]
        if let d = try? JSONSerialization.data(withJSONObject: note), let line = String(data: d, encoding: .utf8) {
            append(debugLog, line)
        }
    }

    if environment["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop" {
        // Desktop session: only the permission-prompt flag.
        let flag = stateDir + "/\(sid).waiting.json"
        let ntype = str(e["notification_type"])
        if event == "Notification" && ["permission_prompt", "elicitation_dialog"].contains(ntype) {
            try writeJSON(flag, ["waiting": "permission", "ts": nowMs()])
        } else if ["PostToolUse", "Stop", "UserPromptSubmit", "SessionEnd"].contains(event) {
            removeIfThere(flag)
        }
        return
    }

    if event == "SessionEnd" {
        removeIfThere(file)
        return
    }

    try withLock {
        let now = nowMs()

        // Load the session's state (tasks kept in the order they appeared).
        var title = "", prompt = "", waiting = ""
        var running = false
        var stepStartedAt: Int64 = 0, avgStepMs: Int64 = 20000
        var tasks: [Task] = []
        if let data = fm.contents(atPath: file),
           let old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            title = str(old["title"])
            prompt = str(old["prompt"])
            waiting = str(old["waiting"])
            running = bool(old["running"])
            stepStartedAt = int64(old["stepStartedAt"])
            if old["avgStepMs"] != nil { avgStepMs = int64(old["avgStepMs"]) }
            if let list = old["tasks"] as? [[String: Any]] {
                tasks = list.map { Task(id: str($0["id"]), subject: str($0["subject"]), status: str($0["status"])) }
                    .filter { !$0.id.isEmpty }
            } else if let map = old["tasks"] as? [String: Any] {
                // The Windows hook's layout (an id -> task map), just in case.
                for (k, v) in map.sorted(by: { $0.key < $1.key }) {
                    let t = v as? [String: Any] ?? [:]
                    tasks.append(Task(id: k, subject: str(t["subject"]), status: str(t["status"])))
                }
            }
        }
        var doneBefore = tasks.filter { $0.status == "completed" }.count

        func setTask(_ id: String, _ subject: String, _ status: String) {
            if id.isEmpty { return }
            var i = tasks.firstIndex { $0.id == id }
            if i == nil {
                tasks.append(Task(id: id, subject: "", status: "pending"))
                i = tasks.count - 1
            }
            guard let k = i else { return }
            if !subject.isEmpty { tasks[k].subject = subject }
            if !status.isEmpty { tasks[k].status = status }
        }

        switch event {
        case "UserPromptSubmit":
            let typed = str(e["prompt"]).split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .joined(separator: " ")
            // Short replies ("yes", "ok do it") keep the last longer name.
            let short = typed.count < 20 || typed.split(separator: " ").count <= 3
            if !(short && !prompt.isEmpty) { prompt = String(typed.prefix(60)) }
            let sessionTitle = str(e["session_title"])
            if !sessionTitle.isEmpty { title = sessionTitle }
            // Finished tasks belong to earlier turns; keep only open ones.
            tasks = tasks.filter { $0.status != "completed" }
            doneBefore = 0
            running = true; waiting = ""; stepStartedAt = now
        case "TaskCreated":
            setTask(str(e["task_id"]), str(e["task_subject"]), "")
            running = true
        case "TaskCompleted":
            setTask(str(e["task_id"]), str(e["task_subject"]), "completed")
        case "PreToolUse":
            // Tools that wait for the person while they run.
            if ["AskUserQuestion", "ExitPlanMode"].contains(str(e["tool_name"])) { waiting = "question" }
            running = true
        case "PostToolUse":
            running = true; waiting = ""
            let input = e["tool_input"] as? [String: Any] ?? [:]
            switch str(e["tool_name"]) {
            case "TodoWrite":
                if let todos = input["todos"] as? [Any], !todos.isEmpty {
                    tasks = todos.enumerated().map { i, item in
                        let t = item as? [String: Any] ?? [:]
                        let status = str(t["status"])
                        let active = str(t["activeForm"])
                        let name = !active.isEmpty && status == "in_progress" ? active : str(t["content"])
                        return Task(id: "todo\(i)", subject: name, status: status)
                    }
                    doneBefore = min(doneBefore, tasks.filter { $0.status == "completed" }.count)
                }
            case "TaskUpdate":
                // Field names aren't documented; accept the likely ones.
                let id = [input["taskId"], input["task_id"], input["id"]].map(str).first { !$0.isEmpty } ?? ""
                let status = str(input["status"])
                if !id.isEmpty {
                    if status == "deleted" { tasks.removeAll { $0.id == id } }
                    else { setTask(id, str(input["subject"]), status) }
                }
            default:
                break
            }
        case "Notification":
            switch str(e["notification_type"]) {
            case "permission_prompt": waiting = "permission"
            case "elicitation_dialog", "agent_needs_input": waiting = "question"
            default: break
            }
        case "Stop":
            running = false; waiting = ""
        default:
            break
        }

        // Progress numbers for the widget.
        let total = tasks.count
        let completed = tasks.filter { $0.status == "completed" }.count
        let active = tasks.first { $0.status == "in_progress" } ?? tasks.first { $0.status != "completed" }
        if completed > doneBefore && stepStartedAt > 0 {
            // Learn how long a step takes (rolling average, clamped).
            var per = Double(now - stepStartedAt) / Double(completed - doneBefore)
            per = max(1000, min(300_000, per))
            avgStepMs = Int64(0.7 * Double(avgStepMs) + 0.3 * per)
            stepStartedAt = now
        }

        let out: [String: Any] = [
            "source": "cli", "title": title, "prompt": prompt,
            "total": total, "completed": completed,
            "label": active?.subject ?? "",
            "running": running, "done": total > 0 && completed >= total,
            "waiting": waiting,
            "stepStartedAt": stepStartedAt, "avgStepMs": avgStepMs, "ts": now,
            "tasks": tasks.map { ["id": $0.id, "subject": $0.subject, "status": $0.status] },
        ]
        try writeJSON(file, out)
    }
}

let argEvent = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
do {
    try run(argEvent)
} catch {
    // A hook must never break Claude; drop the event (logged in debug mode).
    if debug { append(debugLog, "ERROR \(argEvent): \(error)") }
}
exit(0)
