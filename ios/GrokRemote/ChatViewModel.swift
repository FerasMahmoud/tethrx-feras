import Foundation
import SwiftUI

/// Drives a single session: keeps a live SSE connection, folds streaming events
/// into `items`, and sends / cancels turns.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var busy = false
    @Published var live = false
    @Published var mode: String?          // "plan" while Grok is planning
    @Published var errorMessage: String?
    @Published var usage: SessionUsage?   // live token/context/cost meter
    @Published var commands: [SlashCommand] = []   // grok's slash commands (/compact, skills…)
    @Published var queued: [String] = []           // follow-ups to send when the turn ends

    // Live per-session settings (mirror the bridge; changed from the chat controls).
    @Published var planMode: Bool
    @Published var effort: String         // "", "high", "medium", "low"
    @Published var autoApprove: Bool

    let client: BridgeClient
    let session: SessionInfo

    private let liveActivity = LiveActivityManager()
    var sessionName: String { session.displayName }

    private var streamTask: Task<Void, Never>?
    /// Highest SSE event id folded in. Sent on reconnect so the bridge resumes from
    /// there instead of replaying the whole session and duplicating the transcript.
    private var lastEventId = 0
    private var assistantIndex: Int?   // current assistant bubble being appended to
    private var thoughtIndex: Int?     // current thought bubble being appended to

    init(client: BridgeClient, session: SessionInfo) {
        self.client = client
        self.session = session
        self.planMode = session.planMode ?? false
        self.effort = session.effort ?? ""
        self.autoApprove = session.autoApprove ?? false
        self.usage = session.usage
        liveActivity.onPushToken = { [weak self] token in
            guard let self else { return }
            Task { try? await self.client.registerActivityToken(sessionId: self.session.id, token: token) }
        }
    }

    /// Change plan mode / reasoning effort / auto-approve for this session, live.
    func setConfig(planMode: Bool? = nil, effort: String? = nil, autoApprove: Bool? = nil) async {
        if let planMode { self.planMode = planMode }
        if let effort { self.effort = effort }
        if let autoApprove { self.autoApprove = autoApprove }
        do {
            let updated = try await client.setConfig(sessionId: session.id, planMode: planMode, effort: effort, autoApprove: autoApprove)
            self.planMode = updated.planMode ?? self.planMode
            self.effort = updated.effort ?? self.effort
            self.autoApprove = updated.autoApprove ?? self.autoApprove
        } catch {
            errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Open (and auto-reconnect) the event stream for this session.
    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { @MainActor in
            while !Task.isCancelled {
                live = true
                do {
                    for try await event in client.events(sessionId: session.id, lastEventId: lastEventId) {
                        if let id = event["_eventId"] as? Int { lastEventId = max(lastEventId, id) }
                        apply(event)
                    }
                } catch {
                    // transient — fall through to reconnect
                }
                live = false
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Image attachment for multimodal send (base64-encoded on the wire).
    struct AttachedImage {
        var name: String
        var mime: String
        var data: Data
    }

    /// Called when the open chat should bump the session read cursor (parent AppState).
    var onActivity: ((Int) -> Void)?

    func send(_ text: String, images: [AttachedImage] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        busy = true
        errorMessage = nil
        // Optimistic user bubble with images (server turn_start is text-only).
        if !images.isEmpty {
            var item = ChatItem(role: .user, text: trimmed.isEmpty ? "" : trimmed)
            item.images = images.map { ChatImage(name: $0.name, mime: $0.mime, data: $0.data) }
            items.append(item)
        }
        do {
            let payload: [[String: Any]]? = images.isEmpty ? nil : images.map {
                [
                    "name": $0.name,
                    "mime": $0.mime,
                    "data": $0.data.base64EncodedString()
                ]
            }
            try await client.send(sessionId: session.id, text: trimmed, images: payload)
        } catch {
            busy = false
            errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancel() async {
        queued.removeAll()                       // stopping drops any queued follow-ups
        await client.cancel(sessionId: session.id)
    }

    /// Queue a follow-up to send automatically once the current turn finishes.
    func enqueue(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queued.append(t)
    }

    /// Send the next queued follow-up (after a beat, so the bridge is idle again).
    /// The message stays in the queue until the bridge has actually accepted it —
    /// popping first meant a failed send silently destroyed what the user typed.
    private func drainQueue() {
        guard let next = queued.first else { return }
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard queued.first == next else { return }   // something else already handled it
            do {
                try await client.send(sessionId: session.id, text: next)
                if queued.first == next { queued.removeFirst() }
            } catch {
                // 409 just means a turn is still running — e.g. the bridge auto-continuing
                // after an approved plan. Leave it queued; the next turn_complete retries.
                if !Self.isConflict(error) {
                    errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private static func isConflict(_ error: Error) -> Bool {
        if case .badStatus(409) = (error as? BridgeError) ?? .badURL { return true }
        return false
    }

    /// Answer a permission request (Approve/Reject). optionId nil cancels the turn.
    func decide(_ item: ChatItem, optionId: String?, always: Bool = false) async {
        guard let requestId = item.requestId else { return }
        let idx = items.firstIndex(where: { $0.id == item.id })
        if let idx { items[idx].decided = optionId ?? "cancelled" }   // optimistic — hide the buttons
        do {
            try await client.resolvePermission(sessionId: session.id, requestId: requestId, optionId: optionId, always: always)
            if always { autoApprove = true }
        } catch {
            if Self.isConflict(error) {
                // 409: nothing is waiting on this anymore (answered elsewhere, or the
                // session restarted). Re-showing the buttons would just fail again.
                if let idx, items.indices.contains(idx) { items[idx].decided = "cancelled" }
                errorMessage = "That approval was no longer pending — grok isn't waiting on it."
            } else {
                // The bridge never heard the decision, so Grok is still blocked. Put the
                // buttons back rather than leaving a card that claims it was answered.
                if let idx, items.indices.contains(idx) { items[idx].decided = nil }
                errorMessage = "Couldn't send that decision. Check the connection and try again."
            }
        }
    }

    /// Approve or revise a plan (plan mode). Approving proceeds to execution.
    func decidePlan(_ item: ChatItem, approved: Bool) async {
        guard let requestId = item.requestId else { return }
        let idx = items.firstIndex(where: { $0.id == item.id })
        if let idx { items[idx].decided = approved ? "approved" : "rejected" }
        do {
            try await client.resolvePlan(sessionId: session.id, requestId: requestId, approved: approved)
        } catch {
            if Self.isConflict(error) {
                if let idx, items.indices.contains(idx) { items[idx].decided = "rejected" }
                errorMessage = "That plan review was no longer pending."
            } else {
                if let idx, items.indices.contains(idx) { items[idx].decided = nil }
                errorMessage = "Couldn't send that decision. Check the connection and try again."
            }
        }
    }

    // MARK: Event folding

    private func apply(_ event: [String: Any]) {
        live = true
        switch event["kind"] as? String {
        case "turn_start":
            assistantIndex = nil
            thoughtIndex = nil
            busy = true
            liveActivity.start(sessionName: sessionName, phase: "working", detail: "Grok is working…")
            let t = event["text"] as? String ?? ""
            // Skip duplicate user bubble if we already optimistically added one with images.
            let last = items.last
            if last?.role == .user, !last!.images.isEmpty {
                // Keep optimistic bubble; optionally merge text.
                if !t.isEmpty, last?.text.isEmpty == true, let i = items.indices.last {
                    items[i].text = t
                }
            } else if !t.isEmpty {
                append(.user, t)
            }
            if let eid = event["_eventId"] as? Int { onActivity?(eid) }

        case "text":
            let t = event["text"] as? String ?? ""
            if let i = assistantIndex, items.indices.contains(i) {
                items[i].text += t
            } else {
                append(.assistant, t)
                assistantIndex = items.count - 1
            }
            if let eid = event["_eventId"] as? Int { onActivity?(eid) }

        case "image":
            // Agent (or tool) image block — attach to current assistant bubble or new one.
            let mime = event["mimeType"] as? String ?? event["mime"] as? String ?? "image/png"
            let b64 = event["data"] as? String
            let uri = event["uri"] as? String
            var path: String? = nil
            if let uri, uri.hasPrefix("file://") {
                path = String(uri.dropFirst("file://".count))
            } else if let uri, uri.hasPrefix("/") {
                path = uri
            }
            var data: Data? = nil
            if let b64 { data = Data(base64Encoded: b64) }
            let img = ChatImage(
                name: path.map { ($0 as NSString).lastPathComponent } ?? "image",
                mime: mime,
                data: data,
                path: path
            )
            if let i = assistantIndex, items.indices.contains(i) {
                items[i].images.append(img)
            } else {
                var item = ChatItem(role: .assistant, text: "")
                item.images = [img]
                items.append(item)
                assistantIndex = items.count - 1
            }
            // Lazy-load path-only images
            if img.data == nil, let path = img.path {
                Task { await self.loadImage(path: path, into: img.id) }
            }
            if let eid = event["_eventId"] as? Int { onActivity?(eid) }

        case "thought":
            let t = event["text"] as? String ?? ""
            if let i = thoughtIndex, items.indices.contains(i) {
                items[i].text += t
            } else {
                append(.thought, t)
                thoughtIndex = items.count - 1
            }

        case "tool_call":
            assistantIndex = nil
            thoughtIndex = nil
            let tool = event["tool"] as? String ?? "tool"
            liveActivity.update(phase: "working", detail: tool)
            let label = (event["command"] as? String) ?? (event["title"] as? String) ?? tool
            var item = ChatItem(role: .tool, text: label)
            item.toolCallId = event["id"] as? String
            item.toolStatus = "running"
            items.append(item)

        case "tool_update":
            if let id = event["id"] as? String,
               let idx = items.lastIndex(where: { $0.toolCallId == id }) {
                if let st = event["status"] as? String, !st.isEmpty { items[idx].toolStatus = st }
                if let code = event["exitCode"] as? Int, code != 0 { items[idx].toolStatus = "failed" }
                if let out = event["output"] as? String, !out.isEmpty { items[idx].toolOutput = out }
                if let d = event["diff"] as? [String: Any], let path = d["path"] as? String {
                    items[idx].diff = FileDiff(path: path,
                                               oldText: d["oldText"] as? String ?? "",
                                               newText: d["newText"] as? String ?? "")
                }
            }

        case "plan":
            assistantIndex = nil
            let entries = event["entries"] as? [[String: Any]] ?? []
            let lines = entries.compactMap { $0["content"] as? String }
            if !lines.isEmpty { append(.tool, "plan\n" + lines.map { "• \($0)" }.joined(separator: "\n")) }

        case "permission_request":
            assistantIndex = nil
            thoughtIndex = nil
            liveActivity.update(phase: "waiting", detail: "Waiting for your approval")
            var item = ChatItem(role: .permission,
                                text: (event["command"] as? String) ?? (event["title"] as? String)
                                      ?? (event["tool"] as? String) ?? "Grok wants to run a tool")
            item.requestId = event["requestId"] as? String
            item.toolCallId = event["toolCallId"] as? String
            if let opts = event["options"] as? [[String: Any]] {
                item.options = opts.compactMap { o in
                    guard let oid = o["optionId"] as? String, let name = o["name"] as? String else { return nil }
                    return PermissionOption(optionId: oid, name: name, kind: o["kind"] as? String ?? "")
                }
            }
            items.append(item)

        case "end":
            let reason = event["stopReason"] as? String ?? "done"
            append(.status, "· \(reason) ·")
            assistantIndex = nil
            thoughtIndex = nil

        case "permission_resolved":
            if let rid = event["requestId"] as? String,
               let idx = items.firstIndex(where: { $0.role == .permission && $0.requestId == rid && $0.decided == nil }) {
                items[idx].decided = (event["optionId"] as? String) ?? "cancelled"
            }

        case "plan_review":
            assistantIndex = nil
            thoughtIndex = nil
            liveActivity.update(phase: "waiting", detail: "Plan ready to review")
            var item = ChatItem(role: .plan, text: event["planContent"] as? String ?? "Grok drafted a plan.")
            item.requestId = event["requestId"] as? String
            items.append(item)

        case "plan_resolved":
            if let rid = event["requestId"] as? String,
               let idx = items.firstIndex(where: { $0.role == .plan && $0.requestId == rid && $0.decided == nil }) {
                items[idx].decided = (event["approved"] as? Bool == true) ? "approved" : "rejected"
            }

        case "mode":
            mode = event["mode"] as? String

        case "usage":
            if let dict = event["usage"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: dict),
               let u = try? JSONDecoder().decode(SessionUsage.self, from: data) {
                usage = u
            }

        case "commands":
            if let arr = event["commands"] as? [[String: Any]],
               let data = try? JSONSerialization.data(withJSONObject: arr),
               let cmds = try? JSONDecoder().decode([SlashCommand].self, from: data) {
                commands = cmds
            }

        case "turn_complete":
            busy = false
            assistantIndex = nil
            thoughtIndex = nil
            liveActivity.end(phase: "done", detail: "Finished")
            if let eid = event["_eventId"] as? Int { onActivity?(eid) }
            // Scan assistant text for markdown images ![alt](/path)
            hydrateMarkdownImages()
            drainQueue()

        case "error":
            busy = false
            liveActivity.end(phase: "error", detail: "Something went wrong")
            append(.error, event["message"] as? String ?? "Something went wrong.")

        default:
            break   // "log", "raw", heartbeats — ignored in the UI
        }
    }

    private func append(_ role: ChatRole, _ text: String) {
        items.append(ChatItem(role: role, text: text))
    }

    private func loadImage(path: String, into imageId: UUID) async {
        do {
            let (mime, data) = try await client.fetchFile(path: path)
            if let idx = items.firstIndex(where: { $0.images.contains(where: { $0.id == imageId }) }),
               let j = items[idx].images.firstIndex(where: { $0.id == imageId }) {
                items[idx].images[j].data = data
                items[idx].images[j].mime = mime
            }
        } catch {
            // leave placeholder
        }
    }

    /// Pull `![alt](/abs/path)` and bare image paths from assistant text into image chips.
    private func hydrateMarkdownImages() {
        let pattern = #"!\[[^\]]*\]\(([^)]+)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        for i in items.indices where items[i].role == .assistant {
            let text = items[i].text
            let range = NSRange(text.startIndex..., in: text)
            re.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: text) else { return }
                var path = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if path.hasPrefix("file://") { path = String(path.dropFirst(7)) }
                guard path.hasPrefix("/"),
                      ["png","jpg","jpeg","gif","webp","heic"].contains((path as NSString).pathExtension.lowercased())
                else { return }
                if items[i].images.contains(where: { $0.path == path }) { return }
                let img = ChatImage(name: (path as NSString).lastPathComponent, mime: "image/jpeg", path: path)
                items[i].images.append(img)
                Task { await self.loadImage(path: path, into: img.id) }
            }
        }
    }

    /// Compact JSON preview of a tool's arguments for display.
    private static func compact(_ any: Any?) -> String {
        guard let any,
              JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any),
              let s = String(data: data, encoding: .utf8)
        else { return "" }
        return s.count > 140 ? String(s.prefix(140)) + "…" : s
    }
}
