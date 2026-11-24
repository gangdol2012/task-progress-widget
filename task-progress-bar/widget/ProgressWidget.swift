// Claude Progress: the floating Claude progress widget for macOS.
//
// The macOS counterpart of progress_widget.py, drawn natively with AppKit
// and built into "Claude Progress.app" by mac/build.sh. Same files, same
// rules, same look.
//
// Reads one JSON file per session in STATE_DIR: <session>.json from the
// task-progress-bar mod (Claude desktop app) and cli-<session>.json from the
// terminal hook (Claude Code in a terminal). One row per session that is
// working or waiting for the person, kept green for a moment after it
// finishes. Click a desktop-app row to open that session; right-click (or
// Control-click) for settings. Borderless, draggable, resizable, one copy at
// a time, on every Space.
//
// Extra modes, used by the build and for testing:
//   ClaudeProgress [state dir]                 the widget
//   ClaudeProgress --snapshot out.png [--theme dark|light] [--scale 1.5] [state dir]
//   ClaudeProgress --render-icon out.iconset

import AppKit

// MARK: - Paths, timings, look

let environment = ProcessInfo.processInfo.environment
let HOME: String = {
    if let h = environment["HOME"], !h.isEmpty { return h }
    return NSHomeDirectory()
}()
let CLAUDE_HOME = HOME + "/.claude"
var STATE_DIR = CLAUDE_HOME + "/task-progress"

let FRESH_MS = 5000.0                     // desktop sessions heartbeat every second
let CLI_FRESH_MS = 15 * 60 * 1000.0       // terminal sessions only report on events
let SHOW_DONE_MS = 15000.0
let SHOW_WAITING_MS = 3 * 3600 * 1000.0
let CLEANUP_MS = 2 * 24 * 3600 * 1000.0
let DEFAULT_STEP_MS = 20000.0

struct RGB {
    var r, g, b: Double
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init(_ hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        r = Double((v >> 16) & 0xff) / 255
        g = Double((v >> 8) & 0xff) / 255
        b = Double(v & 0xff) / 255
    }
    var color: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }
}

/// Blend two colors; t=0 gives a, t=1 gives b.
func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
    RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
}

struct Palette {
    let card, border, edge, track, ink, soft, coral, coralHi, success, amber: RGB
}

// Claude design template. Dark: surface-dark family; light: cream canvas.
let THEMES: [String: Palette] = [
    "dark": Palette(card: RGB("#1f1e1b"), border: RGB("#5c574e"), edge: RGB("#33302b"),
                    track: RGB("#2e2b27"), ink: RGB("#faf9f5"), soft: RGB("#a09d96"),
                    coral: RGB("#cc785c"), coralHi: RGB("#e8a58c"), success: RGB("#5db872"),
                    amber: RGB("#e8a55a")),
    "light": Palette(card: RGB("#faf9f5"), border: RGB("#d6cdbf"), edge: RGB("#e6dfd8"),
                     track: RGB("#ebe6df"), ink: RGB("#141413"), soft: RGB("#6c6a64"),
                     coral: RGB("#cc785c"), coralHi: RGB("#e9b09b"), success: RGB("#3f9a55"),
                     amber: RGB("#c7822e")),
]

// Layout in points at scale 1 (the Windows widget's pixels at 100%).
let W: CGFloat = 320
let PAD: CGFloat = 16
let RADIUS: CGFloat = 14
let BAR_H: CGFloat = 6
let HEADER_H: CGFloat = 40
let ROW_H: CGFloat = 62
let EMPTY_H: CGFloat = 34
let MAX_ROWS = 8
let CLICK_SLOP: CGFloat = 4    // points the pointer may move and still count as a click
let GRIP: CGFloat = 18         // corner area that resizes, at scale 1
let MIN_SCALE = 0.75, MAX_SCALE = 2.0
// After Claude's computer control last hid us, stay out of screen captures
// and let clicks through this long.
let CONTROL_QUIET_S = 60.0
// Tk sizes fonts in points at 96 dpi; these are those sizes in Mac points.
let PT: CGFloat = 96.0 / 72.0

let ERROR_LOG = CLAUDE_HOME + "/task-progress-widget.log"
let SETTINGS_FILE = CLAUDE_HOME + "/task-progress-widget.json"
let LOCK_FILE = CLAUDE_HOME + "/task-progress-widget.lock"
// Where the Claude desktop app keeps its session files (titles live there):
// ~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json
let APP_SUPPORT = HOME + "/Library/Application Support"
let SESSION_LINK = "claude://claude.ai/epitaxy/"
let TITLE_REFRESH_S = 10.0
let SHOW_NOTE = Notification.Name("io.github.ohmygoditisme.claude-progress.show")
// For the menu's About line, as on Windows. The version comes from the
// app's Info.plist, which mac/build.sh fills in from .claude-plugin/plugin.json,
// so it can't fall out of step; a bare binary outside the app has none.
let VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
let AUTHOR = "OhMyGodItIsMe"
let PROJECT_URL = "https://github.com/OhMyGodItIsMe/task-progress-widget"

let WAITING_TEXT = [
    "permission": "Waiting for your permission",
    "question": "Claude asked you something",
    "answer": "Your turn: Claude asked a question",
]

// MARK: - Small helpers

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

/// Double to Int without ever trapping on NaN, infinity or overflow.
func toInt(_ d: Double) -> Int {
    guard d.isFinite else { return 0 }
    return Int(max(-1e15, min(1e15, d)))
}

func num(_ v: Any?) -> Double {
    switch v {
    case let n as NSNumber: return n.doubleValue.isFinite ? n.doubleValue : 0
    case let s as String: return Double(s) ?? 0
    default: return 0
    }
}

func str(_ v: Any?) -> String {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    default: return ""
    }
}

/// Python's bool(): empty and zero are false.
func truthy(_ v: Any?) -> Bool {
    switch v {
    case nil, is NSNull: return false
    case let n as NSNumber: return n.doubleValue != 0
    case let s as String: return !s.isEmpty
    case let a as [Any]: return !a.isEmpty
    case let d as [String: Any]: return !d.isEmpty
    default: return true
    }
}

func fmtEta(_ ms: Double) -> String {
    let s = max(0, toInt(ms / 1000))
    if s < 2 { return "almost done" }
    if s < 60 { return "~\(s)s left" }
    return String(format: "~%dm %02ds left", s / 60, s % 60)
}

func clip(_ text: String, _ n: Int) -> String {
    text.count <= n ? text : String(text.prefix(n - 1)) + "…"
}

func logError(_ place: String, _ what: String) {
    let line = "\(Date()) \(place): \(what)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: ERROR_LOG) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    } else {
        try? data.write(to: URL(fileURLWithPath: ERROR_LOG))
    }
}

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// MARK: - Settings

struct Settings {
    var scale = 1.0
    var x: Int? = nil      // left edge, screen points
    var y: Int? = nil      // top edge, screen points (macOS counts up from the bottom)
    var sound = true
    var theme = "auto"
}

func loadSettings() -> Settings {
    var cfg = Settings()
    if let saved = readJSON(SETTINGS_FILE) {
        if let n = saved["scale"] as? NSNumber { cfg.scale = n.doubleValue }
        if let n = saved["x"] as? NSNumber, n.doubleValue.isFinite { cfg.x = toInt(n.doubleValue) }
        if let n = saved["y"] as? NSNumber, n.doubleValue.isFinite { cfg.y = toInt(n.doubleValue) }
        if let n = saved["sound"] as? NSNumber { cfg.sound = n.boolValue }
        if let t = saved["theme"] as? String { cfg.theme = t }
    }
    cfg.scale = cfg.scale.isFinite ? max(MIN_SCALE, min(MAX_SCALE, cfg.scale)) : 1.0
    if !["auto", "dark", "light"].contains(cfg.theme) { cfg.theme = "auto" }
    return cfg
}

func saveSettings(_ cfg: Settings) {
    let obj: [String: Any] = [
        "scale": cfg.scale,
        "x": cfg.x.map { $0 as Any } ?? NSNull(),
        "y": cfg.y.map { $0 as Any } ?? NSNull(),
        "sound": cfg.sound,
        "theme": cfg.theme,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
    try? data.write(to: URL(fileURLWithPath: SETTINGS_FILE), options: .atomic)
}

// MARK: - Sessions

struct Row {
    var status: String      // "working", "waiting" or "finished"
    var waiting: String
    var cli: Bool
    var total: Int
    var completed: Int
    var label: String
    var prompt: String
    var title: String
    var link: String
    var started: Double
    var avg: Double
    var id: String
}

/// Session id -> (title, app session id), from the Claude app's files.
///
/// The app keeps one JSON file per session (local_*.json) with its title,
/// its own id (for the claude:// link) and the id the mod writes under
/// (cliSessionId). This is the app's private format, so anything missing
/// just means falling back to the request text and no link. Scanned off the
/// main thread at most every TITLE_REFRESH_S seconds, re-reading only the
/// files that changed.
final class TitleIndex {
    private let queue = DispatchQueue(label: "claude-progress.titles", qos: .utility)
    private var cache: [String: (stamp: Date, size: Int, entries: [(String, String, String)])] = [:]
    private var scanning = false
    private var lastScan = Date.distantPast
    private(set) var map: [String: (title: String, appId: String)] = [:]

    func refreshIfDue() {
        guard !scanning, Date().timeIntervalSince(lastScan) >= TITLE_REFRESH_S else { return }
        scanning = true
        lastScan = Date()
        queue.async {
            let found = self.scan()
            DispatchQueue.main.async {
                self.map = found
                self.scanning = false
            }
        }
    }

    /// Scan now, on this thread (for --snapshot).
    func scanNow() { map = queue.sync { scan() } }

    private func scan() -> [String: (title: String, appId: String)] {
        let fm = FileManager.default
        var found: [String: (title: String, appId: String)] = [:]
        var seen = Set<String>()
        let tops = ((try? fm.contentsOfDirectory(atPath: APP_SUPPORT)) ?? [])
            .filter { $0.hasPrefix("Claude") }.sorted()
            .map { APP_SUPPORT + "/" + $0 + "/claude-code-sessions" }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        for top in tops where fm.fileExists(atPath: top) {
            guard let walk = fm.enumerator(at: URL(fileURLWithPath: top), includingPropertiesForKeys: keys,
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                           errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walk {
                let name = url.lastPathComponent
                guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
                let vals = try? url.resourceValues(forKeys: Set(keys))
                guard vals?.isRegularFile == true else { continue }
                let path = url.path
                let stamp = vals?.contentModificationDate ?? .distantPast
                let size = vals?.fileSize ?? 0
                seen.insert(path)
                var entries: [(String, String, String)]
                if let hit = cache[path], hit.stamp == stamp, hit.size == size {
                    entries = hit.entries
                } else {
                    entries = []
                    if let d = readJSON(path) {
                        let title = str(d["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
                        var appId = str(d["sessionId"])
                        if appId.isEmpty { appId = String(name.dropLast(5)) }
                        for key in ["cliSessionId", "lastAssistantCliSessionId"] {
                            let sid = str(d[key])
                            if !sid.isEmpty { entries.append((sid, title, appId)) }
                        }
                    }
                    cache[path] = (stamp, size, entries)
                }
                for (sid, title, appId) in entries { found[sid] = (title, appId) }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return found
    }
}

func loadSessions(_ now: Double, _ known: [String: (title: String, appId: String)]) -> [Row] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: STATE_DIR) else { return [] }
    var desktopFresh = Set<String>()
    var parsed: [(name: String, sid: String, cli: Bool, age: Double, d: [String: Any])] = []
    var flags: [String: String] = [:]  // desktop session id -> waiting reason, from <sid>.waiting.json
    for name in names where name.hasSuffix(".json") {
        let path = STATE_DIR + "/" + name
        if name.hasSuffix(".waiting.json") {
            // Written by the hook while a permission prompt is on screen.
            guard let flag = readJSON(path) else { continue }
            if now - num(flag["ts"]) < SHOW_WAITING_MS {
                let why = str(flag["waiting"])
                flags[String(name.dropLast(".waiting.json".count))] = why.isEmpty ? "permission" : why
            } else {
                try? fm.removeItem(atPath: path)
            }
            continue
        }
        // Missing, or caught mid-write: the next tick will get it.
        guard let d = readJSON(path) else { continue }
        let age = now - num(d["ts"])
        if age > CLEANUP_MS {
            try? fm.removeItem(atPath: path)
            continue
        }
        let cli = name.hasPrefix("cli-")
        let base = String(name.dropLast(5))
        let sid = cli ? String(base.dropFirst(4)) : base
        if !cli && age < CLI_FRESH_MS { desktopFresh.insert(sid) }
        parsed.append((name, sid, cli, age, d))
    }

    var rows: [Row] = []
    for p in parsed {
        if p.cli && desktopFresh.contains(p.sid) { continue }  // the desktop mod already reports it
        let d = p.d
        let running = truthy(d["running"])
        var waiting = truthy(d["waiting"]) ? str(d["waiting"]) : ""
        if waiting.isEmpty && !p.cli { waiting = flags[p.sid] ?? "" }
        let started = num(d["stepStartedAt"])
        let working = running && p.age < (p.cli ? CLI_FRESH_MS : FRESH_MS)
        let status: String
        if !waiting.isEmpty && p.age < SHOW_WAITING_MS && (working || !running) {
            status = "waiting"
        } else if working {
            status = "working"
        } else if started > 0 && p.age < SHOW_DONE_MS {
            status = "finished"
        } else {
            continue
        }
        var (title, appId) = known[p.sid] ?? ("", "")
        if p.cli { title = str(d["title"]) }
        let avg = num(d["avgStepMs"])
        rows.append(Row(
            status: status, waiting: waiting, cli: p.cli,
            total: toInt(num(d["total"])), completed: toInt(num(d["completed"])),
            label: str(d["label"]), prompt: str(d["prompt"]), title: title,
            link: appId.isEmpty ? "" : SESSION_LINK + appId,
            started: started, avg: avg > 0 ? avg : DEFAULT_STEP_MS, id: p.name))
    }
    rows.sort { $0.id < $1.id }
    return Array(rows.prefix(MAX_ROWS))
}

// MARK: - Drawing

func sansFont(_ size: CGFloat, _ scale: CGFloat, bold: Bool = false) -> NSFont {
    NSFont.systemFont(ofSize: max(7, size * PT * scale), weight: bold ? .semibold : .regular)
}

func serifFont(_ size: CGFloat, _ scale: CGFloat) -> NSFont {
    let pt = max(8, size * PT * scale)
    if let f = NSFont(name: "Georgia", size: pt) { return f }
    let sys = NSFont.systemFont(ofSize: pt)
    if let d = sys.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: pt) { return f }
    return sys
}

enum Align { case left, right, center }

/// Draws one line of text vertically centered on cy (Tk's anchor "w"/"e"),
/// cut with an ellipsis past maxWidth. Returns the width used.
@discardableResult
func drawText(_ s: String, _ x: CGFloat, _ cy: CGFloat, _ font: NSFont, _ color: RGB,
              align: Align = .left, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byTruncatingTail
    let text = NSAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: color.color, .paragraphStyle: para,
    ])
    let size = text.size()
    let room = max(0, maxWidth)
    let w = size.width + 1 <= room ? ceil(size.width) + 1 : room
    var x0 = x
    switch align {
    case .left: break
    case .right: x0 = x - w
    case .center: x0 = x - w / 2
    }
    text.draw(with: NSRect(x: x0, y: cy - size.height / 2, width: w, height: ceil(size.height)),
              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    return w
}

func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
    NSAttributedString(string: s, attributes: [.font: font]).size().width
}

/// A bar with round ends from x1 to x2, centered on y.
func pill(_ x1: CGFloat, _ y: CGFloat, _ x2: CGFloat, _ h: CGFloat, _ color: RGB) {
    let right = max(x2, x1 + h)
    color.color.setFill()
    NSBezierPath(roundedRect: NSRect(x: x1, y: y - h / 2, width: right - x1, height: h),
                 xRadius: h / 2, yRadius: h / 2).fill()
}

func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ color: RGB,
          width: CGFloat = 1, round: Bool = false) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x1, y: y1))
    p.line(to: NSPoint(x: x2, y: y2))
    p.lineWidth = width
    if round { p.lineCapStyle = .round }
    color.color.setStroke()
    p.stroke()
}

func oval(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ color: RGB) {
    color.color.setFill()
    NSBezierPath(ovalIn: NSRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)).fill()
}

struct Hit {
    let y0: CGFloat
    let y1: CGFloat
    let link: String
}

/// Everything the card shows, laid out at scale 1 and multiplied by `scale`,
/// so text, bars and spacing grow and shrink together. Draws into the current
/// graphics context, which must be flipped (y grows downward, like Tk).
struct Painter {
    let scale: CGFloat
    let c: Palette

    func s(_ v: CGFloat) -> CGFloat { v * scale }
    var width: CGFloat { (W * scale).rounded() }

    func height(_ rows: Int) -> CGFloat {
        s(HEADER_H + (rows > 0 ? CGFloat(rows) * ROW_H : EMPTY_H) + 6).rounded()
    }

    func paint(_ rows: [Row], _ now: Double) -> [Hit] {
        let w = width, h = height(rows.count), pad = s(PAD)

        // Card with a 1pt soft border.
        c.border.color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h),
                     xRadius: s(RADIUS), yRadius: s(RADIUS)).fill()
        c.card.color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: w - 2, height: h - 2),
                     xRadius: s(RADIUS) - 1, yRadius: s(RADIUS) - 1).fill()

        let working = rows.filter { $0.status == "working" }.count
        let waiting = rows.filter { $0.status == "waiting" }.count
        drawText("Claude", pad, s(21), serifFont(11, scale), c.ink)
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) needs you") }
        let sub = parts.isEmpty ? (rows.isEmpty ? "idle" : "") : parts.joined(separator: "  ·  ")
        if !sub.isEmpty {
            drawText(sub, pad + s(60), s(22), sansFont(8, scale), c.soft,
                     maxWidth: w - pad - s(16) - (pad + s(60)))
        }
        // Close button: an x drawn as two lines.
        let xc = w - pad - s(2), yc = s(21), xr = s(4)
        line(xc - xr, yc - xr, xc + xr, yc + xr, c.soft, width: max(1, s(1.2)), round: true)
        line(xc - xr, yc + xr, xc + xr, yc - xr, c.soft, width: max(1, s(1.2)), round: true)
        line(pad, s(HEADER_H - 2), w - pad, s(HEADER_H - 2), c.edge)

        var hits: [Hit] = []
        if rows.isEmpty {
            drawText("Nothing running", pad, s(HEADER_H + 14), sansFont(8, scale), c.soft)
        }
        for (i, r) in rows.enumerated() {
            let y = s(HEADER_H + 4 + CGFloat(i) * ROW_H)
            if i > 0 { line(pad, y - s(4), w - pad, y - s(4), c.track) }
            paintRow(y, r, now)
            if !r.link.isEmpty { hits.append(Hit(y0: y - s(4), y1: y + s(ROW_H - 4), link: r.link)) }
        }

        // Resize grip: three short diagonal strokes in the bottom-right corner.
        let gx = w - s(6), gy = h - s(6)
        for n: CGFloat in [4, 8, 12] {
            line(gx - s(n), gy, gx, gy - s(n), c.edge, width: max(1, s(1.2)))
        }
        return hits
    }

    func paintRow(_ y: CGFloat, _ r: Row, _ now: Double) {
        let total = r.total, completed = r.completed
        let elapsed = r.started > 0 ? now - r.started : 0
        let pad = s(PAD), barW = s(W - 2 * PAD), barH = s(BAR_H)
        let w = width

        // Status dot: breathing coral while working, slow amber pulse while
        // waiting on the person, green when done.
        let cy = y + s(11)
        if r.status == "finished" {
            oval(pad, cy - s(3.5), pad + s(7), cy + s(3.5), c.success)
        } else {
            let amber = r.status == "waiting"
            let t = (sin(now / (amber ? 520.0 : 260.0)) + 1) / 2
            let rad = s(3 + 1.2 * CGFloat(t)), cx = pad + s(3)
            oval(cx - rad, cy - rad, cx + rad, cy + rad,
                 mix(c.card, amber ? c.amber : c.coral, 0.55 + 0.45 * t))
        }

        let by = y + s(30)
        pill(pad, by, pad + barW, barH, c.track)
        var frac = 0.0
        if total > 0 {
            var within = 0.0
            if r.status == "working" && r.avg > 0 { within = max(0, min(0.95, elapsed / r.avg)) }
            frac = min(1, (Double(completed) + within) / Double(total))
        }

        let right: String, rightC: RGB, info: String, infoC: RGB
        if r.status == "finished" {
            pill(pad, by, pad + barW, barH, c.success)
            (right, rightC, info, infoC) = ("done", c.success, "Finished", c.success)
        } else if r.status == "waiting" {
            if total > 0 { pill(pad, by, pad + max(barH, barW * CGFloat(frac)), barH, c.amber) }
            (right, rightC) = ("needs you", c.amber)
            (info, infoC) = (WAITING_TEXT[r.waiting] ?? "Waiting for you", c.amber)
        } else if total == 0 {
            let seg = barW / 4
            let phase = now.truncatingRemainder(dividingBy: 2400) / 1200
            var pos = phase <= 1 ? phase : 2 - phase
            pos = 0.5 - 0.5 * cos(pos * .pi)  // ease in/out so it glides instead of bouncing
            let left = pad + (barW - seg) * CGFloat(pos)
            pill(left, by, left + seg, barH, c.coral)
            (right, rightC) = ("\(max(0, toInt(elapsed / 1000)))s", c.soft)
            (info, infoC) = ("Working, no task list", c.soft)
        } else {
            let fillX = pad + max(barH, barW * CGFloat(frac))
            pill(pad, by, fillX, barH, c.coral)
            // Soft highlight drifting across the filled part.
            let span = fillX - pad - barH
            if span > s(24) {
                let gx = pad + barH / 2 + CGFloat(now.truncatingRemainder(dividingBy: 1600) / 1600) * span
                for (k, gw) in [18.0, 10.0, 4.0].enumerated() {
                    let col = mix(c.coral, c.coralHi, Double(k + 1) / 3)
                    let a = max(pad + barH / 2, gx - s(CGFloat(gw)) / 2)
                    let b = min(fillX - barH / 2, gx + s(CGFloat(gw)) / 2)
                    if b > a { line(a, by, b, by, col, width: max(1, barH - s(2)), round: true) }
                }
            }
            (right, rightC) = ("\(toInt(frac * 100))%", c.coral)
            let eta = fmtEta(r.avg * Double(total - completed) - elapsed)
            let step = r.label.isEmpty ? "" : "  ·  \(r.label)"
            (info, infoC) = (clip("\(completed) of \(total)  ·  \(eta)\(step)", 50), c.soft)
        }

        let rightFont = sansFont(9, scale, bold: true)
        let rightW = textWidth(right, rightFont)
        drawText(right, w - pad, cy, rightFont, rightC, align: .right)

        // The session's title as the app shows it; the request text if the
        // app's files don't have one.
        var name = r.title.isEmpty ? (r.prompt.isEmpty ? "(untitled session)" : r.prompt) : r.title
        if r.cli { name = "› " + name }  // terminal session
        let nameX = pad + s(14)
        drawText(clip(name, 34), nameX, cy, sansFont(9, scale), c.ink,
                 maxWidth: w - pad - rightW - s(8) - nameX)
        drawText(info, pad, by + s(15), sansFont(8, scale), infoC, maxWidth: w - 2 * pad)
    }
}

/// Runs `body` with the current graphics context drawing into a new bitmap
/// of `points` at `density` pixels per point, flipped like the widget's view.
func renderBitmap(_ points: NSSize, density: CGFloat, _ body: () -> Void) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(points.width * density), pixelsHigh: Int(points.height * density),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = points
    let cg = base.cgContext
    cg.scaleBy(x: density, y: density)
    cg.translateBy(x: 0, y: points.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - The window

final class Panel: NSPanel {
    // Never take the keyboard from the app the person is working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CardView: NSView {
    weak var widget: Widget?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) { widget?.paint() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                      .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    func local(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }
    override func mouseDown(with e: NSEvent) { widget?.press(e, local(e)) }
    override func mouseDragged(with e: NSEvent) { widget?.drag() }
    override func mouseUp(with e: NSEvent) { widget?.release(local(e)) }
    override func rightMouseDown(with e: NSEvent) { widget?.showMenu(e) }
    override func scrollWheel(with e: NSEvent) { widget?.wheel(e) }
    override func magnify(with e: NSEvent) { widget?.pinch(e) }
    override func mouseMoved(with e: NSEvent) { widget?.hover(local(e)) }
    override func cursorUpdate(with e: NSEvent) { widget?.hover(local(e)) }
    override func mouseExited(with e: NSEvent) { NSCursor.arrow.set() }
}

func resizeCursor() -> NSCursor {
    if #available(macOS 15.0, *) {
        return NSCursor.frameResize(position: .bottomRight, directions: .all)
    }
    let sel = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
    if NSCursor.responds(to: sel), let c = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
        return c
    }
    return NSCursor.crosshair
}

func onAScreen(_ p: NSPoint) -> Bool {
    NSScreen.screens.contains { NSMouseInRect(p, $0.frame, false) }
}

final class Widget: NSObject, NSApplicationDelegate {
    var cfg = loadSettings()
    let panel: Panel
    let view = CardView()
    let titles = TitleIndex()
    var rows: [Row] = []
    var hits: [Hit] = []
    var seen: [String: String]? = nil   // nil: the first load only records, never beeps
    var mode = ""                        // "", "move" or "resize"
    var startMouse = NSPoint.zero
    var startOrigin = NSPoint.zero
    var lastLoad = 0.0
    var busy = 0
    var timer: Timer?
    var saveTimer: Timer?
    var scrollSum: CGFloat = 0
    var dark = (at: 0.0, value: true)
    // Claude's computer control state (see guardTick).
    var quiet = false
    var quietUntil = 0.0
    var signalSource: DispatchSourceSignal?

    override init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: W, height: HEADER_H + EMPTY_H),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
    }

    var painter: Painter { Painter(scale: CGFloat(cfg.scale), c: colors()) }
    func s(_ v: CGFloat) -> CGFloat { v * CGFloat(cfg.scale) }

    func colors() -> Palette {
        if cfg.theme != "auto" { return THEMES[cfg.theme] ?? THEMES["dark"]! }
        let now = Date().timeIntervalSince1970
        if now - dark.at > 1 {  // follow macOS, checked lazily
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            dark = (now, match == .darkAqua)
        }
        return THEMES[dark.value ? "dark" : "light"]!
    }

    // MARK: Start

    func applicationDidFinishLaunching(_ n: Notification) {
        panel.title = "Claude progress"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false            // moved by hand, so a click can still open a row
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        view.widget = self
        view.wantsLayer = true
        panel.contentView = view

        let p = painter
        let w = p.width, h0 = p.height(0)
        var origin = defaultTopLeft(w)
        if let x = cfg.x, let y = cfg.y {
            let fx = CGFloat(x), fy = CGFloat(y)
            if onAScreen(NSPoint(x: fx + 10, y: fy - 10)) && onAScreen(NSPoint(x: fx + w - 10, y: fy - 10)) {
                origin = NSPoint(x: fx, y: fy)  // else unset, or that screen is gone
            }
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y - h0, width: w, height: h0), display: false)
        panel.orderFrontRegardless()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appHidden), name: NSApplication.didHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(bringBack),
                                                            name: SHOW_NOTE, object: nil)

        // `kill` (and the installer) ends it like the close button does, so
        // launchd only starts it again after a real crash.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        signalSource = src

        tick()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringBack()
        return false
    }

    /// Top-left corner for the default spot: top-right of the main screen.
    func defaultTopLeft(_ w: CGFloat) -> NSPoint {
        guard let scr = NSScreen.screens.first ?? NSScreen.main else { return NSPoint(x: 100, y: 800) }
        let vf = scr.visibleFrame
        return NSPoint(x: max(vf.minX, vf.maxX - w - 24), y: vf.maxY - 24)
    }

    @objc func bringBack() {
        NSApp.unhideWithoutActivation()
        panel.orderFrontRegardless()
        screensChanged()
    }

    /// A screen went away or changed: if the widget is now off every screen,
    /// put it back in its default spot.
    @objc func screensChanged() {
        let f = panel.frame
        if !onAScreen(NSPoint(x: f.minX + 10, y: f.maxY - 10)) && !onAScreen(NSPoint(x: f.maxX - 10, y: f.maxY - 10)) {
            let o = defaultTopLeft(f.width)
            panel.setFrameOrigin(NSPoint(x: o.x, y: o.y - f.height))
        }
    }

    // MARK: Refresh

    func tick() {
        let now = nowMs()
        guardTick(now)
        titles.refreshIfDue()
        if busy == 0 || now - lastLoad >= 200 {
            lastLoad = now
            rows = loadSessions(now, titles.map)
            notify(rows)
        }
        busy = rows.filter { $0.status == "working" || $0.status == "waiting" }.count
        fitFrame()
        view.needsDisplay = true
        schedule(busy > 0 || !mode.isEmpty ? 1.0 / 30 : 0.5)
    }

    func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)  // keeps running while a menu is open or during a drag
        timer = t
    }

    /// Size the window to its rows, keeping the top-left corner in place.
    func fitFrame() {
        let p = painter
        let w = p.width, h = p.height(rows.count)
        let f = panel.frame
        if abs(f.width - w) > 0.5 || abs(f.height - h) > 0.5 {
            panel.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: w, height: h), display: true)
            panel.invalidateShadow()
        }
    }

    func paint() {
        hits = painter.paint(rows, nowMs())
    }

    /// Sound when a session finishes or starts waiting on the person.
    func notify(_ rows: [Row]) {
        var now: [String: String] = [:]
        for r in rows { now[r.id] = r.status }
        if cfg.sound, let seen = seen {
            for (id, st) in now {
                let before = seen[id]
                if st == "waiting" && before != "waiting" { beep("waiting"); break }
                if st == "finished" && (before == "working" || before == "waiting") { beep("finished"); break }
            }
        }
        seen = now
    }

    func beep(_ kind: String) {
        // Glass for "finished", Ping for "needs you".
        if let snd = NSSound(named: kind == "waiting" ? "Ping" : "Glass") {
            snd.stop()
            snd.play()
        } else {
            NSSound.beep()
        }
    }

    // MARK: Claude's computer control
    //
    // While it works, Claude's computer control may hide the apps it wasn't
    // given, this one included. Nothing else hides this widget (it has no
    // Dock icon or menu bar of its own), so being hidden means Claude is
    // controlling the screen: come straight back, but out of screen captures
    // and letting clicks pass through, so Claude never sees or clicks it.
    // Back to normal once nothing has hidden it for a while.

    @objc func appHidden() { controlled() }

    func controlled() {
        quietUntil = Date().timeIntervalSince1970 + CONTROL_QUIET_S
        if !quiet {
            quiet = true
            mode = ""
            panel.sharingType = .none
            panel.ignoresMouseEvents = true
        }
        NSApp.unhideWithoutActivation()  // back, without taking focus
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFrontRegardless()
    }

    func guardTick(_ now: Double) {
        if NSApp.isHidden || panel.isMiniaturized {
            controlled()
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        if quiet && now / 1000 > quietUntil {
            quiet = false
            panel.sharingType = .readOnly
            panel.ignoresMouseEvents = false
        }
    }

    // MARK: Mouse

    var width: CGFloat { painter.width }

    func onGrip(_ p: NSPoint) -> Bool {
        p.x >= width - s(GRIP) && p.y >= panel.frame.height - s(GRIP)
    }

    func rowLink(_ p: NSPoint) -> String {
        hits.first { $0.y0 <= p.y && p.y < $0.y1 }?.link ?? ""
    }

    func setScale(_ v: Double) {
        let v = max(MIN_SCALE, min(MAX_SCALE, v.isFinite ? v : 1))
        if abs(v - cfg.scale) > 0.001 {
            cfg.scale = v
            fitFrame()
            view.needsDisplay = true
        }
    }

    func saveSoon() {
        saveTimer?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            if let self = self { saveSettings(self.cfg) }
        }
        RunLoop.main.add(t, forMode: .common)
        saveTimer = t
    }

    func press(_ e: NSEvent, _ p: NSPoint) {
        if e.modifierFlags.contains(.control) {  // Control-click: the right-click menu
            showMenu(e)
            return
        }
        if p.x >= width - s(34) && p.y <= s(HEADER_H) {
            NSApp.terminate(nil)
            return
        }
        mode = onGrip(p) ? "resize" : "move"
        startMouse = NSEvent.mouseLocation
        startOrigin = panel.frame.origin
        schedule(1.0 / 30)
    }

    func drag() {
        let m = NSEvent.mouseLocation
        if mode == "resize" {
            setScale(Double((m.x - panel.frame.minX) / W))
        } else if mode == "move" {
            panel.setFrameOrigin(NSPoint(x: startOrigin.x + m.x - startMouse.x,
                                         y: startOrigin.y + m.y - startMouse.y))
        }
    }

    func release(_ p: NSPoint) {
        let m = NSEvent.mouseLocation
        let moved = abs(m.x - startMouse.x) + abs(m.y - startMouse.y)
        let was = mode
        mode = ""
        if was == "resize" {
            saveSettings(cfg)
        } else if was == "move" && moved <= CLICK_SLOP {
            // A click, not a drag: open that session.
            let link = rowLink(p)
            if !link.isEmpty, let url = URL(string: link), !NSWorkspace.shared.open(url) {
                logError("open session", link)
            }
        } else if was == "move" {
            cfg.x = toInt(Double(panel.frame.minX))
            cfg.y = toInt(Double(panel.frame.maxY))
            saveSettings(cfg)
        }
    }

    func hover(_ p: NSPoint) {
        if !mode.isEmpty { return }
        if onGrip(p) {
            resizeCursor().set()
        } else if !rowLink(p).isEmpty {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Command- or Control-scroll resizes, like Ctrl-scroll on Windows.
    func wheel(_ e: NSEvent) {
        guard !e.modifierFlags.intersection([.command, .control]).isEmpty else { return }
        // Up (fingers or wheel, whatever the scroll direction setting) grows it.
        let dy = e.scrollingDeltaY * (e.isDirectionInvertedFromDevice ? -1 : 1)
        if e.hasPreciseScrollingDeltas {
            scrollSum += dy
            while abs(scrollSum) >= 12 {
                let step: CGFloat = scrollSum > 0 ? 1 : -1
                setScale(cfg.scale + 0.1 * Double(step))
                scrollSum -= 12 * step
            }
        } else if dy != 0 {
            setScale(cfg.scale + (dy > 0 ? 0.1 : -0.1))
        }
        saveSoon()
    }

    func pinch(_ e: NSEvent) {
        setScale(cfg.scale * Double(1 + e.magnification))
        saveSoon()
    }

    // MARK: Right-click menu: settings

    func showMenu(_ e: NSEvent) {
        mode = ""
        let menu = NSMenu()
        menu.autoenablesItems = false
        let sound = NSMenuItem(title: "Sound when a session finishes or needs you",
                               action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self
        sound.state = cfg.sound ? .on : .off
        menu.addItem(sound)

        let themes = NSMenu()
        for (label, value) in [("Match macOS", "auto"), ("Dark", "dark"), ("Light", "light")] {
            let item = NSMenuItem(title: label, action: #selector(pickTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = cfg.theme == value ? .on : .off
            themes.addItem(item)
        }
        let theme = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        menu.addItem(theme)
        menu.setSubmenu(themes, for: theme)

        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset size and position", action: #selector(resetPlace), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let close = NSMenuItem(title: "Close widget", action: #selector(closeWidget), keyEquivalent: "")
        close.target = self
        menu.addItem(close)

        menu.addItem(.separator())
        let version = VERSION.isEmpty ? "" : " v\(VERSION)"
        let about = NSMenuItem(title: "About: Task progress widget\(version) by \(AUTHOR)",
                               action: #selector(openProject), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        NSMenu.popUpContextMenu(menu, with: e, for: view)
    }

    @objc func openProject() {
        if let url = URL(string: PROJECT_URL), !NSWorkspace.shared.open(url) {
            logError("open project page", PROJECT_URL)
        }
    }

    @objc func toggleSound() {
        cfg.sound.toggle()
        saveSettings(cfg)
    }

    @objc func pickTheme(_ item: NSMenuItem) {
        cfg.theme = item.representedObject as? String ?? "auto"
        dark.at = 0
        saveSettings(cfg)
        view.needsDisplay = true
    }

    @objc func resetPlace() {
        cfg.scale = 1.0
        cfg.x = nil
        cfg.y = nil
        saveSettings(cfg)
        let p = painter
        let w = p.width, h = p.height(rows.count)
        let o = defaultTopLeft(w)
        panel.setFrame(NSRect(x: o.x, y: o.y - h, width: w, height: h), display: true)
        panel.invalidateShadow()
    }

    @objc func closeWidget() { NSApp.terminate(nil) }
}

// MARK: - Build and test modes

/// One frame of the widget as a PNG (for tests and screenshots).
func snapshot(to out: String, theme: String, scale: Double) -> Int32 {
    let titles = TitleIndex()
    titles.scanNow()
    let now = nowMs()
    let rows = loadSessions(now, titles.map)
    let p = Painter(scale: CGFloat(scale), c: THEMES[theme] ?? THEMES["dark"]!)
    guard let rep = renderBitmap(NSSize(width: p.width, height: p.height(rows.count)), density: 2, {
        _ = p.paint(rows, now)
    }), let png = rep.representation(using: .png, properties: [:]) else { return 1 }
    do { try png.write(to: URL(fileURLWithPath: out)) } catch { return 1 }
    print("\(rows.count) rows -> \(out)")
    return 0
}

/// The app icon: a small card with three progress rows, in every size an
/// .iconset needs (mac/build.sh turns it into AppIcon.icns).
func renderIcon(to dir: String) -> Int32 {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let c = THEMES["dark"]!
    for base in [16, 32, 128, 256, 512] {
        for density in [1, 2] {
            let px = CGFloat(base * density)
            guard let rep = renderBitmap(NSSize(width: px, height: px), density: 1, {
                let u = px / 1024  // drawn on Apple's 1024-point icon grid
                let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
                let r = 185 * u
                c.border.color.setFill()
                NSBezierPath(roundedRect: body, xRadius: r, yRadius: r).fill()
                c.card.color.setFill()
                NSBezierPath(roundedRect: body.insetBy(dx: 12 * u, dy: 12 * u),
                             xRadius: r - 12 * u, yRadius: r - 12 * u).fill()
                let rowsSpec: [(RGB, CGFloat)] = [(c.coral, 0.68), (c.amber, 0.4), (c.success, 1.0)]
                for (i, spec) in rowsSpec.enumerated() {
                    let cy = (300 + CGFloat(i) * 212) * u
                    let dot: CGFloat = 34 * u
                    oval(210 * u - dot, cy - dot, 210 * u + dot, cy + dot, spec.0)
                    let x1 = 290 * u, x2 = 814 * u, bh = 54 * u
                    pill(x1, cy, x2, bh, c.track)
                    pill(x1, cy, x1 + (x2 - x1) * spec.1, bh, spec.0)
                }
            }), let png = rep.representation(using: .png, properties: [:]) else { return 1 }
            let name = density == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            do { try png.write(to: URL(fileURLWithPath: dir + "/" + name)) } catch { return 1 }
        }
    }
    return 0
}

func uncaught(_ ex: NSException) {
    logError("uncaught", "\(ex.name.rawValue): \(ex.reason ?? "")")
}

// MARK: - Main

var snapshotOut: String? = nil
var iconOut: String? = nil
var snapTheme = "dark"
var snapScale = 1.0
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--snapshot": snapshotOut = args.isEmpty ? nil : args.removeFirst()
    case "--render-icon": iconOut = args.isEmpty ? nil : args.removeFirst()
    case "--theme": snapTheme = args.isEmpty ? snapTheme : args.removeFirst()
    case "--scale": snapScale = Double(args.isEmpty ? "" : args.removeFirst()) ?? snapScale
    default:
        var isDir: ObjCBool = false
        if !a.hasPrefix("-"), FileManager.default.fileExists(atPath: a, isDirectory: &isDir), isDir.boolValue {
            STATE_DIR = a
        }
    }
}

if let out = iconOut { exit(renderIcon(to: out)) }
if let out = snapshotOut { exit(snapshot(to: out, theme: snapTheme, scale: snapScale)) }

// One copy at a time: the first holds a lock for as long as it runs; a
// second asks it to come forward and quits.
try? FileManager.default.createDirectory(atPath: CLAUDE_HOME, withIntermediateDirectories: true)
let lockFD = open(LOCK_FILE, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    DistributedNotificationCenter.default().postNotificationName(SHOW_NOTE, object: nil, userInfo: nil,
                                                                 deliverImmediately: true)
    exit(0)
}

NSSetUncaughtExceptionHandler(uncaught)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon or menu bar, like Windows' no taskbar button
let widget = Widget()
app.delegate = widget
app.run()
