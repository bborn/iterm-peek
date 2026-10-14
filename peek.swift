// iterm-peek: show a small card for a GitHub PR/issue or Linear issue near the mouse.
//
// Invoked by an iTerm2 Smart Selection "Run Command" action on Cmd-click.
// Esc or a click elsewhere closes it, Return opens the link, Cmd-C copies it.
// Cmd-clicking the same link again while its card is up opens it in the browser.
//
//   iterm-peek <url-or-id>          show the card
//   iterm-peek --dump <url-or-id>   print what the card would show, no UI

import AppKit
import Combine
import SwiftUI

// MARK: - Targets

enum Target {
    case github(kind: String, repo: String, number: Int)  // kind: "pull" or "issues"
    case linear(identifier: String)

    var key: String {
        switch self {
        case let .github(kind, repo, n): return "github:\(repo)/\(kind)/\(n)"
        case let .linear(id): return "linear:\(id)"
        }
    }

    static func parse(_ raw: String) -> Target? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n<>()[]'\".,;"))
        if let m = capture(s, #"github\.com/([\w.-]+/[\w.-]+)/(pull|issues)/(\d+)"#) {
            return .github(kind: m[1], repo: m[0], number: Int(m[2])!)
        }
        if let m = capture(s, #"linear\.app/[\w-]+/issue/([A-Za-z][A-Za-z0-9]*-\d+)"#) {
            return .linear(identifier: m[0].uppercased())
        }
        if let m = capture(s, #"^([A-Za-z][A-Za-z0-9]{0,6}-\d+)$"#) {
            return .linear(identifier: m[0].uppercased())
        }
        return nil
    }
}

func capture(_ s: String, _ pattern: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (1..<m.numberOfRanges).map { String(s[Range(m.range(at: $0), in: s)!]) }
}

// MARK: - Card model

struct Pill: Hashable { let text: String; let color: Color }
struct Meta: Hashable { let icon: String; let text: String }

struct Card {
    var kicker: String
    var title: String
    var pills: [Pill] = []
    var meta: [Meta] = []
    var snippet: String?
    var url: URL?
}

@MainActor
final class PeekModel: ObservableObject {
    @Published var card: Card
    @Published var loading = true
    @Published var error: String?

    init(card: Card) { self.card = card }
}

// MARK: - Fetching

struct PeekError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func run(_ exe: String, _ args: [String]) throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw PeekError(message: msg?.isEmpty == false ? msg! : "\(exe) exited \(p.terminationStatus)")
    }
    return data
}

func ghPath() -> String {
    ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/gh"
}

func json(_ data: Data) throws -> [String: Any] {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw PeekError(message: "Unexpected response")
    }
    return obj
}

func ago(_ iso: Any?) -> String? {
    guard let s = iso as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) else { return nil }
    return RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
}

func snippet(_ body: Any?) -> String? {
    guard var s = body as? String else { return nil }
    s = s.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: #"(?m)^\s*(\|.*|>\s*\[!\w+\]\s*)$"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"(?m)^\s*(#+|>)\s*"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    s = s.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

func login(_ v: Any?) -> String? { (v as? [String: Any])?["login"] as? String }

let green = Color(red: 0.16, green: 0.65, blue: 0.27)
let red = Color(red: 0.85, green: 0.24, blue: 0.24)
let purple = Color(red: 0.51, green: 0.31, blue: 0.87)
let amber = Color(red: 0.85, green: 0.6, blue: 0.1)
let gray = Color.gray

func checksPill(_ rollup: Any?) -> Pill? {
    guard let checks = rollup as? [[String: Any]], !checks.isEmpty else { return nil }
    var failing = 0, pending = 0
    for c in checks {
        let conclusion = (c["conclusion"] as? String) ?? ""
        let state = (c["state"] as? String) ?? ""
        let status = (c["status"] as? String) ?? ""
        if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"].contains(conclusion)
            || ["FAILURE", "ERROR"].contains(state) {
            failing += 1
        } else if (c["__typename"] as? String == "CheckRun" && status != "COMPLETED")
            || ["PENDING", "EXPECTED"].contains(state) {
            pending += 1
        }
    }
    if failing > 0 { return Pill(text: "✗ \(failing) failing", color: red) }
    if pending > 0 { return Pill(text: "● \(pending) pending", color: amber) }
    return Pill(text: "✓ \(checks.count) checks", color: green)
}

func fetchGitHub(kind: String, repo: String, number: Int) throws -> Card {
    let gh = ghPath()
    if kind == "pull" {
        let fields = "title,state,isDraft,author,reviewDecision,statusCheckRollup,headRefName,baseRefName,"
            + "additions,deletions,changedFiles,updatedAt,url,body,assignees,labels"
        let pr = try json(run(gh, ["pr", "view", String(number), "-R", repo, "--json", fields]))
        var card = Card(kicker: "\(repo) #\(number)", title: pr["title"] as? String ?? "")
        switch (pr["state"] as? String, pr["isDraft"] as? Bool) {
        case ("MERGED", _): card.pills.append(Pill(text: "Merged", color: purple))
        case ("CLOSED", _): card.pills.append(Pill(text: "Closed", color: red))
        case (_, true?): card.pills.append(Pill(text: "Draft", color: gray))
        default: card.pills.append(Pill(text: "Open", color: green))
        }
        if pr["state"] as? String == "OPEN" {
            switch pr["reviewDecision"] as? String {
            case "APPROVED": card.pills.append(Pill(text: "Approved", color: green))
            case "CHANGES_REQUESTED": card.pills.append(Pill(text: "Changes requested", color: red))
            case "REVIEW_REQUIRED": card.pills.append(Pill(text: "Review required", color: amber))
            default: break
            }
        }
        if let checks = checksPill(pr["statusCheckRollup"]) { card.pills.append(checks) }
        if let author = login(pr["author"]) { card.meta.append(Meta(icon: "person", text: author)) }
        if let head = pr["headRefName"] as? String, let base = pr["baseRefName"] as? String {
            card.meta.append(Meta(icon: "arrow.triangle.branch", text: "\(head) → \(base)"))
        }
        if let a = pr["additions"] as? Int, let d = pr["deletions"] as? Int, let f = pr["changedFiles"] as? Int {
            card.meta.append(Meta(icon: "plusminus", text: "+\(a) −\(d) · \(f) file\(f == 1 ? "" : "s")"))
        }
        if let when = ago(pr["updatedAt"]) { card.meta.append(Meta(icon: "clock", text: "updated \(when)")) }
        card.snippet = snippet(pr["body"])
        card.url = URL(string: pr["url"] as? String ?? "")
        return card
    }

    let fields = "title,state,stateReason,author,assignees,labels,comments,updatedAt,body,url"
    let issue = try json(run(gh, ["issue", "view", String(number), "-R", repo, "--json", fields]))
    var card = Card(kicker: "\(repo) #\(number)", title: issue["title"] as? String ?? "")
    if issue["state"] as? String == "OPEN" {
        card.pills.append(Pill(text: "Open", color: green))
    } else if issue["stateReason"] as? String == "NOT_PLANNED" {
        card.pills.append(Pill(text: "Not planned", color: gray))
    } else {
        card.pills.append(Pill(text: "Closed", color: purple))
    }
    for label in (issue["labels"] as? [[String: Any]] ?? []).prefix(3) {
        if let name = label["name"] as? String { card.pills.append(Pill(text: name, color: gray)) }
    }
    if let author = login(issue["author"]) { card.meta.append(Meta(icon: "person", text: author)) }
    let assignees = (issue["assignees"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }
    if !assignees.isEmpty { card.meta.append(Meta(icon: "person.crop.circle.badge.checkmark", text: assignees.joined(separator: ", "))) }
    if let comments = issue["comments"] as? [Any], !comments.isEmpty {
        card.meta.append(Meta(icon: "bubble.left", text: "\(comments.count) comment\(comments.count == 1 ? "" : "s")"))
    }
    if let when = ago(issue["updatedAt"]) { card.meta.append(Meta(icon: "clock", text: "updated \(when)")) }
    card.snippet = snippet(issue["body"])
    card.url = URL(string: issue["url"] as? String ?? "")
    return card
}

// LINEAR_API_KEY usually comes from the shell profile, which iTerm2 does not load
// for Smart Selection commands, so fall back to asking a login shell for it.
func linearKey() -> String? {
    if let k = ProcessInfo.processInfo.environment["LINEAR_API_KEY"], !k.isEmpty { return k }
    let marker = "__ITERM_PEEK__"
    guard let data = try? run("/bin/zsh", ["-lic", "printf '\\n\(marker)%s\\n' \"$LINEAR_API_KEY\""]),
          let out = String(data: data, encoding: .utf8),
          let line = out.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else { return nil }
    let key = String(line.dropFirst(marker.count))
    return key.isEmpty ? nil : key
}

func hexColor(_ hex: Any?) -> Color {
    guard let s = (hex as? String)?.dropFirst(), let v = UInt32(s, radix: 16) else { return gray }
    return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
}

func fetchLinear(identifier: String) async throws -> Card {
    guard let key = linearKey() else { throw PeekError(message: "LINEAR_API_KEY is not set") }
    let query = """
    query($id: String!) { issue(id: $id) {
      identifier title url description priorityLabel updatedAt
      state { name color } assignee { name } project { name } cycle { number }
      labels(first: 3) { nodes { name color } }
      attachments(first: 10) { nodes { url } }
    } }
    """
    var req = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
    req.httpMethod = "POST"
    req.setValue(key, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": ["id": identifier]])
    let (data, _) = try await URLSession.shared.data(for: req)
    let body = try json(data)
    guard let issue = (body["data"] as? [String: Any])?["issue"] as? [String: Any] else {
        let msg = ((body["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? "Not found"
        throw PeekError(message: "\(identifier): \(msg)")
    }

    var card = Card(kicker: identifier, title: issue["title"] as? String ?? "")
    if let project = (issue["project"] as? [String: Any])?["name"] as? String { card.kicker += " · \(project)" }
    if let state = issue["state"] as? [String: Any], let name = state["name"] as? String {
        card.pills.append(Pill(text: name, color: hexColor(state["color"])))
    }
    if let priority = issue["priorityLabel"] as? String, priority != "No priority" {
        card.pills.append(Pill(text: priority, color: gray))
    }
    for label in ((issue["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []) {
        if let name = label["name"] as? String { card.pills.append(Pill(text: name, color: hexColor(label["color"]))) }
    }
    let assignee = (issue["assignee"] as? [String: Any])?["name"] as? String
    card.meta.append(Meta(icon: "person", text: assignee ?? "Unassigned"))
    if let cycle = (issue["cycle"] as? [String: Any])?["number"] as? Int {
        card.meta.append(Meta(icon: "arrow.triangle.2.circlepath", text: "Cycle \(cycle)"))
    }
    let prs = ((issue["attachments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
        .compactMap { $0["url"] as? String }
        .compactMap { capture($0, #"github\.com/[\w.-]+/([\w.-]+)/pull/(\d+)"#) }
        .map { "\($0[0])#\($0[1])" }
    if !prs.isEmpty { card.meta.append(Meta(icon: "arrow.triangle.pull", text: prs.joined(separator: ", "))) }
    if let when = ago(issue["updatedAt"]) { card.meta.append(Meta(icon: "clock", text: "updated \(when)")) }
    card.snippet = snippet(issue["description"])
    card.url = URL(string: issue["url"] as? String ?? "")
    return card
}

func fetch(_ target: Target) async throws -> Card {
    switch target {
    case let .github(kind, repo, number):
        return try await Task.detached { try fetchGitHub(kind: kind, repo: repo, number: number) }.value
    case let .linear(id):
        return try await fetchLinear(identifier: id)
    }
}

// MARK: - State shared between invocations

struct PeekState: Codable {
    var pid: Int32
    var target: String
    var url: String?
    var closedAt: Double?
}

let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/iterm-peek/state.json")

func readState() -> PeekState? {
    guard let data = try? Data(contentsOf: stateURL) else { return nil }
    return try? JSONDecoder().decode(PeekState.self, from: data)
}

func writeState(_ state: PeekState) {
    try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
}

// MARK: - UI

struct CardView: View {
    @ObservedObject var model: PeekModel
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.card.kicker)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(model.card.title.isEmpty ? "Loading…" : model.card.title)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture(perform: open)
            if !model.card.pills.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.card.pills, id: \.self) { pill in
                        Text(pill.text)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(pill.color)
                            .background(pill.color.opacity(0.15), in: Capsule())
                    }
                }
            }
            if !model.card.meta.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.card.meta, id: \.self) { meta in
                        HStack(spacing: 6) {
                            Image(systemName: meta.icon).frame(width: 14)
                            Text(meta.text).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if let snippet = model.card.snippet {
                Text(snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.loading {
                ProgressView().controlSize(.small)
            }
            if let error = model.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("↩ open   esc close   ⌘C copy link")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class Peek: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let target: Target
    let model: PeekModel
    let anchor = NSEvent.mouseLocation
    var panel: KeyPanel!
    var hosting: NSHostingView<CardView>!
    var monitors: [Any] = []
    var cancellable: AnyCancellable?
    var closing = false

    init(target: Target, fallbackURL: URL?) {
        self.target = target
        let kicker: String
        switch target {
        case let .github(_, repo, n): kicker = "\(repo) #\(n)"
        case let .linear(id): kicker = id
        }
        model = PeekModel(card: Card(kicker: kicker, title: "", url: fallbackURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hosting = NSHostingView(rootView: CardView(model: model, open: { [weak self] in self?.open() }))

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        layout()
        panel.makeKeyAndOrderFront(nil)
        saveState()

        cancellable = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.layout() }
        }

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let cmd = event.modifierFlags.contains(.command)
            switch (event.keyCode, cmd, event.charactersIgnoringModifiers) {
            case (53, _, _): self.close()
            case (36, _, _), (76, _, _), (_, true, "o"): self.open()
            case (_, true, "c"): self.copyLink()
            case (_, true, "w"): self.close()
            default: return event
            }
            return nil
        }!)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }!)

        Task {
            do {
                let card = try await fetch(target)
                model.card = card
                saveState()
            } catch {
                model.error = error.localizedDescription
            }
            model.loading = false
        }
    }

    // Keep the card's top-left corner just below and right of the click,
    // flipping above the cursor or to the left when it would run off screen.
    func layout() {
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        var x = anchor.x + 8
        var top = anchor.y - 14
        if x + size.width > visible.maxX - 8 { x = max(visible.minX + 8, anchor.x - size.width - 8) }
        if top - size.height < visible.minY + 8 { top = min(visible.maxY - 8, anchor.y + size.height + 14) }
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        if ProcessInfo.processInfo.environment["ITERM_PEEK_DEBUG"] != nil {
            let screenTop = NSScreen.screens[0].frame.maxY
            print("frame \(Int(panel.frame.minX)),\(Int(screenTop - panel.frame.maxY)),\(Int(size.width)),\(Int(size.height)) key=\(panel.isKeyWindow)")
            fflush(stdout)
        }
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func saveState() {
        writeState(PeekState(pid: getpid(), target: target.key, url: model.card.url?.absoluteString))
    }

    func open() {
        if let url = model.card.url { NSWorkspace.shared.open(url) }
        close()
    }

    func copyLink() {
        guard let url = model.card.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        close()
    }

    func close() {
        guard !closing else { return }
        closing = true
        if var state = readState(), state.pid == getpid() {
            state.closedAt = Date().timeIntervalSince1970
            writeState(state)
        }
        monitors.forEach(NSEvent.removeMonitor)
        panel.orderOut(nil)
        NSApp.terminate(nil)
    }
}

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())
let dump = args.first == "--dump"
if dump { args.removeFirst() }
guard let input = args.first else {
    FileHandle.standardError.write("usage: iterm-peek [--dump] <github-or-linear-url-or-id>\n".data(using: .utf8)!)
    exit(64)
}
let inputURL = input.contains("://") ? URL(string: input) : nil

guard let target = Target.parse(input) else {
    // Not something we know how to peek at: behave like a normal Cmd-click.
    if let url = inputURL { NSWorkspace.shared.open(url) }
    exit(0)
}

if dump {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let card = try await fetch(target)
            print(card.kicker)
            print(card.title)
            print(card.pills.map(\.text).joined(separator: " | "))
            card.meta.forEach { print("\($0.icon): \($0.text)") }
            if let s = card.snippet { print("---\n\(s.prefix(300))") }
            print(card.url?.absoluteString ?? "(no url)")
        } catch {
            print("error: \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// A second Cmd-click on the link whose card is showing (or was closed by that
// same click a moment ago) opens it instead of peeking again.
if let state = readState() {
    let alive = kill(state.pid, 0) == 0
    if alive { kill(state.pid, SIGTERM) }
    let recent = alive || (state.closedAt.map { Date().timeIntervalSince1970 - $0 < 1.5 } ?? false)
    if recent, state.target == target.key, let url = URL(string: state.url ?? "") ?? inputURL {
        NSWorkspace.shared.open(url)
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { Peek(target: target, fallbackURL: inputURL) }
app.delegate = delegate
app.run()
