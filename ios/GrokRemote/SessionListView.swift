import SwiftUI
import UIKit

/// Lists the bridge's Grok sessions and starts new ones. Tapping opens live chat.
struct SessionListView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var lock: AppLock
    @EnvironmentObject var snippets: SnippetStore
    @State private var path: [SessionInfo] = []
    @State private var creating = false
    @State private var renaming: SessionInfo?
    @State private var renameText = ""
    @State private var foldering: SessionInfo?   // session being moved into a new folder
    @State private var folderText = ""
    @State private var collapsed: Set<String> = []
    @State private var query = ""
    @State private var contentHits: [SearchResult] = []
    /// main | running | subagents — subagents never mix into the default list.
    @State private var sessionFilter: SessionFilter = .main
    @State private var showSettings = false
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var showFsBrowser = false

    private enum SessionFilter: String, CaseIterable {
        case main, running, subagents
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if app.bridgeNeedsUpdate { updateBanner }
                    workingDir
                    runningNow
                    sessions
                    grokCliSection
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .refreshable {
                await app.reloadSessions()
                await app.reloadCwdRecents()
            }
            .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let s = renaming { Task { await app.renameSession(s.id, title: renameText) } }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("New folder", isPresented: Binding(get: { foldering != nil }, set: { if !$0 { foldering = nil } })) {
                TextField("Folder name", text: $folderText)
                Button("Move") {
                    if let s = foldering, !folderText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Task { await app.setFolder(s.id, folder: folderText) }
                    }
                    foldering = nil
                }
                Button("Cancel", role: .cancel) { foldering = nil }
            }
            .alert("New folder", isPresented: $creatingFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") { app.createFolder(newFolderName); newFolderName = "" }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            } message: {
                Text("Then use the ••• button on any session to move it in.")
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(app).environmentObject(lock).environmentObject(snippets)
            }
            .sheet(isPresented: $showFsBrowser) {
                if let client = app.client {
                    FsBrowserSheet(client: client, startPath: app.defaultCwd) { chosen in
                        app.defaultCwd = chosen
                        Task { await app.rememberCwd(chosen) }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SessionInfo.self) { session in
                if let client = app.client {
                    ChatView(vm: ChatViewModel(client: client, session: session))
                        .environmentObject(app)
                } else {
                    ZStack { Grok.bg.ignoresSafeArea(); Eyebrow("DISCONNECTED") }
                }
            }
        }
        .task {
            await app.reloadSessions()
            await app.reloadCwdRecents()
            openPending()
        }
        .onChange(of: app.pendingOpenSessionId) { _, _ in openPending() }
        // The whole array, not just its count: switching to another computer can
        // land on the same number of sessions, which would swallow the deep-open.
        .onChange(of: app.sessions) { _, _ in openPending() }
        // Share deep link with no sessions yet → open a new one so draft can prefill.
        .onChange(of: app.pendingShareText) { _, text in
            guard text != nil, path.isEmpty, app.sessions.isEmpty else { return }
            Task {
                if let s = await app.newSession() { path.append(s) }
            }
        }
        // Debounced full-text search over conversation history (bridge-side).
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 3, let client = app.client else { contentHits = []; return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            contentHits = (try? await client.search(q)) ?? []
        }
    }

    // MARK: Running now

    @ViewBuilder private var runningNow: some View {
        let running = app.sessions.filter { $0.isRunning && !$0.isSubagentSession }
        if !running.isEmpty, sessionFilter != .subagents {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("RUNNING NOW")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(running) { session in
                            Button {
                                if !path.contains(session) { path.append(session) }
                            } label: {
                                HStack(spacing: 7) {
                                    Circle().fill(Grok.accent).frame(width: 6, height: 6)
                                    Text(session.displayName).font(Grok.mono(12, .medium)).lineLimit(1)
                                }
                                .foregroundStyle(Grok.text)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .overlay(Capsule().stroke(Grok.hairlineStrong, lineWidth: 1))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: Bridge update banner

    private var updateBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Grok.text)
                Text("Your bridge needs an update").font(Grok.sans(15, .semibold)).foregroundStyle(Grok.text)
            }
            Text("This app needs bridge \(AppState.wantedBridgeVersion) or newer (you have \(app.health?.version ?? "unknown")). On the computer, run:")
                .font(Grok.mono(11)).foregroundStyle(Grok.textDim).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("cd ~/tethrx-feras/bridge && npm i -g .")
                    .font(Grok.mono(11)).foregroundStyle(Grok.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = "cd ~/tethrx-feras/bridge && npm i -g . && systemctl --user restart tethrx-bridge"
                    Haptics.tap()
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .medium)).foregroundStyle(Grok.textDim)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Grok.bg)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Grok.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            Text("Then reconnect. Chat still works; newest features need the update.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
        }
        .padding(14)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Open the session a notification (or debug launch argument) pointed at.
    private func openPending() {
        guard let id = app.pendingOpenSessionId else { return }
        guard let session = app.sessions.first(where: { $0.id == id }) else {
            // Not on this computer — it may live on another paired one.
            Task { await app.locateAndOpen(id) }
            return
        }
        app.pendingOpenSessionId = nil
        if !path.contains(session) { path.append(session) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                TethrXMark(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TETHRX").font(Grok.mono(13, .semibold)).tracking(1.2).foregroundStyle(Grok.text)
                    if let grok = app.health?.grok {
                        Text(grok.replacingOccurrences(of: "grok ", with: "v"))
                            .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineLimit(1)
                    }
                }
            }
            Spacer()
            CircleIconButton(system: "gearshape") { showSettings = true }
            CircleIconButton(system: "plus", filled: true, enabled: !creating) {
                Task { await startNew() }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: Working directory

    private var workingDir: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Eyebrow("WORKING DIRECTORY")
                Spacer(minLength: 0)
                if app.client != nil {
                    Button {
                        Haptics.tap()
                        showFsBrowser = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder").font(.system(size: 11, weight: .medium))
                            Text("Browse…").font(Grok.mono(11))
                        }
                        .foregroundStyle(Grok.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            FieldBox {
                TextField("", text: $app.defaultCwd,
                          prompt: Text("/Users/you/project — blank = daemon default").foregroundColor(Grok.textFaint))
                    .font(Grok.mono(13))
                    .foregroundStyle(Grok.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !app.cwdRecents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(app.cwdRecents, id: \.self) { path in
                            Button {
                                Haptics.tap()
                                app.defaultCwd = path
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(cwdChipLabel(path))
                                        .lineLimit(1)
                                }
                                .font(Grok.mono(11, .medium))
                                .foregroundStyle(app.defaultCwd == path ? Color.black : Grok.textDim)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(app.defaultCwd == path ? Color.white : Color.clear)
                                .overlay(Capsule().stroke(
                                    app.defaultCwd == path ? Color.clear : Grok.hairlineStrong, lineWidth: 1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Text("New sessions run Grok in this folder. Plan mode, effort, and approvals are set inside each session.")
                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
        }
    }

    private func cwdChipLabel(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? path : base
    }

    // MARK: Sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Eyebrow("SESSIONS")
                Spacer()
                Button { Haptics.tap(); newFolderName = ""; creatingFolder = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 12, weight: .medium))
                        Text("New folder").font(Grok.mono(11))
                    }
                    .foregroundStyle(Grok.textDim)
                }
                .buttonStyle(.plain)
                Text("\(filteredSessions.count)")
                    .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
            }
            .padding(.bottom, 10)

            // Filter chips — subagents live in their own tab (not mixed into main).
            HStack(spacing: 8) {
                filterChip("Main", active: sessionFilter == .main) { sessionFilter = .main }
                filterChip("Running", active: sessionFilter == .running) { sessionFilter = .running }
                filterChip("Subagents", active: sessionFilter == .subagents) { sessionFilter = .subagents }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)

            if app.sessions.count > 6 { searchField.padding(.bottom, 14) }

            if app.sessions.isEmpty {
                Text("// no sessions yet — tap + to start")
                    .font(Grok.mono(12)).foregroundStyle(Grok.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else if filteredSessions.isEmpty {
                Text(emptyFilterMessage)
                    .font(Grok.mono(12)).foregroundStyle(Grok.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                let groups = groupedSessions
                let hasFolders = groups.contains { !$0.folder.isEmpty }
                ForEach(groups, id: \.folder) { group in
                    if !group.folder.isEmpty || hasFolders {
                        folderHeader(group.folder.isEmpty ? "Ungrouped" : group.folder,
                                     key: group.folder, count: group.items.count)
                    }
                    if !collapsed.contains(group.folder) {
                        if group.items.isEmpty {
                            Text("// empty — use ••• on a session to move it here")
                                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                                .padding(.vertical, 10)
                        }
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, session in
                            if index > 0 { Rectangle().fill(Grok.hairline).frame(height: 1) }
                            sessionLink(session)
                        }
                    }
                    if hasFolders { Color.clear.frame(height: 8) }
                }
                contentSearchResults
            }
        }
    }

    /// Sessions whose CONVERSATION matched the query (beyond title/folder/path).
    @ViewBuilder private var contentSearchResults: some View {
        let titleMatches = Set(filteredSessions.map { $0.id })
        let extras = contentHits.filter { !titleMatches.contains($0.sessionId) }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty, !extras.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("FOUND IN CONVERSATIONS")
                    .padding(.top, 18).padding(.bottom, 10)
                ForEach(extras) { hit in
                    if let session = app.sessions.first(where: { $0.id == hit.sessionId }) {
                        Button {
                            if !path.contains(session) { path.append(session) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.displayName)
                                    .font(Grok.sans(15, .semibold)).foregroundStyle(Grok.text).lineLimit(1)
                                if let snippet = hit.hits.first?.snippet {
                                    Text("…\(snippet)…")
                                        .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(Grok.hairline).frame(height: 1)
                    }
                }
            }
        }
    }

    private var emptyFilterMessage: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return "// nothing matches \u{201C}\(q)\u{201D}" }
        switch sessionFilter {
        case .main: return "// no main sessions"
        case .running: return "// no running sessions"
        case .subagents: return "// no subagent sessions"
        }
    }

    // Session list: main excludes subagents; Subagents tab is only workers.
    // Unread + recent already sorted in AppState.
    private var filteredSessions: [SessionInfo] {
        var list = app.sessions
        switch sessionFilter {
        case .main:
            list = list.filter { !$0.isSubagentSession }
        case .running:
            list = list.filter { $0.isRunning && !$0.isSubagentSession }
        case .subagents:
            list = list.filter { $0.isSubagentSession }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.title.lowercased().contains(q)
            || ($0.folder?.lowercased().contains(q) ?? false)
            || ($0.cwd?.lowercased().contains(q) ?? false)
            || ($0.lastPreview?.lowercased().contains(q) ?? false)
            || ($0.agentName?.lowercased().contains(q) ?? false)
            || $0.id.lowercased().hasPrefix(q)
        }
    }

    private func filterChip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(label)
                .font(Grok.mono(11, active ? .semibold : .regular))
                .foregroundStyle(active ? Grok.bg : Grok.textDim)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(active ? Grok.accent : Grok.raised)
                .overlay(Capsule().stroke(active ? Color.clear : Grok.hairline, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // Ungrouped sessions first, then folders alphabetically; order within a group preserved.
    // Freshly-created (still empty) folders are shown too, so they're somewhere to drop
    // sessions into — but they're hidden while searching, where they'd just be noise.
    private var groupedSessions: [(folder: String, items: [SessionInfo])] {
        let groups = Dictionary(grouping: filteredSessions) { ($0.folder?.isEmpty == false) ? $0.folder! : "" }
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let matched = Set(groups.keys.filter { !$0.isEmpty })
        var out: [(String, [SessionInfo])] = []
        // Folders first, in the user's chosen order. While searching, only ones with hits.
        for name in app.orderedFolders where !searching || matched.contains(name) {
            out.append((name, groups[name] ?? []))
        }
        // Ungrouped last, so the folders you made are what you see first.
        if let ungrouped = groups[""], !ungrouped.isEmpty { out.append(("", ungrouped)) }
        return out
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Grok.textFaint)
            TextField("", text: $query, prompt: Text("search sessions").foregroundColor(Grok.textFaint))
                .font(Grok.mono(13)).foregroundStyle(Grok.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Grok.textFaint)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func folderHeader(_ name: String, key: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed.contains(key) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Grok.textFaint).frame(width: 10)
                    Image(systemName: key.isEmpty ? "tray" : "folder.fill")
                        .font(.system(size: 11)).foregroundStyle(Grok.textDim)
                    Text(name).font(Grok.mono(12, .semibold)).tracking(0.5).foregroundStyle(Grok.textDim)
                    Text("\(count)").font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Visible, like the row menus — reordering shouldn't be a hidden gesture.
            if !key.isEmpty {
                Menu {
                    Button { app.moveFolder(key, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                    Button { app.moveFolder(key, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                    Button(role: .destructive) { Task { await app.deleteFolder(key) } } label: {
                        Label("Delete folder", systemImage: "folder.badge.minus")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Grok.textFaint)
                        .frame(width: 32, height: 34)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func sessionLink(_ session: SessionInfo) -> some View {
        HStack(spacing: 2) {
            NavigationLink(value: session) {
                SessionRow(session: session, unread: app.isUnread(session))
            }
                .buttonStyle(.plain)
            // Visible affordance — the same actions used to be long-press only.
            Menu {
                menuItems(session)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Grok.textDim)
                    .frame(width: 36, height: 48)
                    .contentShape(Rectangle())
            }
        }
        .contextMenu { menuItems(session) }
    }

    @ViewBuilder private func menuItems(_ session: SessionInfo) -> some View {
        Button { renameText = session.title; renaming = session } label: { Label("Rename", systemImage: "pencil") }
        moveMenu(session)
        Button(role: .destructive) { Task { await app.deleteSession(session.id) } } label: { Label("Delete", systemImage: "trash") }
    }

    private func moveMenu(_ session: SessionInfo) -> some View {
        Menu {
            ForEach(app.folders, id: \.self) { f in
                if f != session.folder {
                    Button { Task { await app.setFolder(session.id, folder: f) } } label: { Label(f, systemImage: "folder") }
                }
            }
            Button { folderText = ""; foldering = session } label: { Label("New folder…", systemImage: "folder.badge.plus") }
            if let cur = session.folder, !cur.isEmpty {
                Button(role: .destructive) { Task { await app.setFolder(session.id, folder: "") } } label: {
                    Label("Remove from folder", systemImage: "folder.badge.minus")
                }
            }
        } label: {
            Label("Move to folder", systemImage: "folder")
        }
    }

    private func startNew() async {
        creating = true
        defer { creating = false }
        if let session = await app.newSession() { path.append(session) }
    }

    // MARK: Grok CLI resume

    /// CLI resume list follows the same Main / Subagents filter as bridge sessions.
    private var filteredGrokCli: [GrokCliSession] {
        switch sessionFilter {
        case .main, .running:
            return app.grokCliSessions.filter { !$0.isSubagentSession }
        case .subagents:
            return app.grokCliSessions.filter { $0.isSubagentSession }
        }
    }

    @ViewBuilder
    private var grokCliSection: some View {
        let list = filteredGrokCli
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Eyebrow(sessionFilter == .subagents ? "GROK CLI · SUBAGENTS" : "GROK CLI (RESUME)")
                    Spacer()
                    Text("\(list.count)")
                        .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                }
                .padding(.bottom, 12)

                Text(sessionFilter == .subagents
                     ? "Subagent workers from the host Grok CLI. Resume opens them as bridge sessions under Subagents."
                     : "Resume a main session from the host Grok CLI store. Subagents live under the Subagents filter.")
                    .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                    .padding(.bottom, 10)

                ForEach(Array(list.prefix(12).enumerated()), id: \.element.id) { index, g in
                    if index > 0 { Rectangle().fill(Grok.hairline).frame(height: 1) }
                    Button {
                        Haptics.tap()
                        Task {
                            if let s = await app.resumeGrokSession(g) {
                                if s.isSubagentSession { sessionFilter = .subagents }
                                path.append(s)
                            }
                        }
                    } label: {
                        GrokCliRow(session: g)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Host filesystem browser (dirs only for cwd pick)

/// Simple sheet: list directories via `listFs`, navigate, Use as working directory.
struct FsBrowserSheet: View {
    let client: BridgeClient
    var startPath: String
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: String = ""
    @State private var entries: [FsEntry] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(path.isEmpty ? "…" : path)
                    .font(Grok.mono(11))
                    .foregroundStyle(Grok.textDim)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                Rectangle().fill(Grok.hairline).frame(height: 1)

                if loading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText {
                    Text(errorText)
                        .font(Grok.mono(12)).foregroundStyle(Grok.danger)
                        .padding(20)
                    Spacer()
                } else {
                    List {
                        if canGoUp {
                            Button {
                                Task { await load(parentPath) }
                            } label: {
                                Label("..", systemImage: "arrow.up.left")
                                    .font(Grok.mono(13)).foregroundStyle(Grok.textDim)
                            }
                            .listRowBackground(Grok.bg)
                        }
                        ForEach(dirEntries) { entry in
                            Button {
                                let next = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
                                Task { await load(next) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 13)).foregroundStyle(Grok.textDim)
                                    Text(entry.name)
                                        .font(Grok.mono(13)).foregroundStyle(Grok.text)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Grok.textFaint)
                                }
                            }
                            .listRowBackground(Grok.bg)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Grok.bg)
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Grok.textDim)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if !path.isEmpty {
                            onPick(path)
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(path.isEmpty ? Grok.textFaint : Grok.text)
                    .disabled(path.isEmpty)
                }
            }
            .task { await load(startPath) }
        }
        .preferredColorScheme(.dark)
    }

    private var dirEntries: [FsEntry] {
        entries.filter(\.isDir).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var canGoUp: Bool {
        !path.isEmpty && path != "/" && path != parentPath
    }

    private var parentPath: String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    private func load(_ target: String) async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let listing = try await client.listFs(path: target)
            path = listing.path
            entries = listing.entries
        } catch {
            errorText = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Compact row for a host Grok CLI session (resume into bridge).
struct GrokCliRow: View {
    let session: GrokCliSession

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(session.id.prefix(8))
                        .font(Grok.mono(11, .medium)).foregroundStyle(Grok.textFaint)
                    if session.isSubagentSession {
                        Text((session.agentName?.isEmpty == false ? session.agentName! : "subagent").uppercased())
                            .font(Grok.mono(8, .bold)).tracking(0.6)
                            .foregroundStyle(Grok.textFaint)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Grok.hairline, lineWidth: 1))
                    }
                    if session.active == true {
                        HStack(spacing: 5) {
                            Circle().fill(Grok.accent).frame(width: 6, height: 6)
                            Text("ACTIVE").font(Grok.mono(9, .semibold)).tracking(0.8).foregroundStyle(Grok.accent)
                        }
                    }
                }
                Text(session.displayName)
                    .font(Grok.sans(16, .semibold)).foregroundStyle(Grok.text).lineLimit(1)
                HStack(spacing: 8) {
                    if let cwd = session.cwd, !cwd.isEmpty {
                        Text(cwd).font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                            .lineLimit(1).truncationMode(.head)
                    }
                    if let n = session.messageCount {
                        Text("· \(n) msg\(n == 1 ? "" : "s")")
                            .font(Grok.mono(11)).foregroundStyle(Grok.textFaint).fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Grok.textFaint)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
}

struct SessionRow: View {
    let session: SessionInfo
    var unread: Bool = false

    private var name: String { session.displayName }

    var body: some View {
        HStack(spacing: 12) {
            // Unread indicator (vector circle — not emoji)
            ZStack {
                if unread {
                    Circle()
                        .fill(Grok.accent)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle().stroke(Grok.bg, lineWidth: 1.5)
                        )
                        .accessibilityLabel("Unread")
                } else {
                    Circle().fill(Color.clear).frame(width: 9, height: 9)
                }
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(session.id.prefix(8))
                        .font(Grok.mono(11, .medium)).foregroundStyle(Grok.textFaint)
                    if session.isSubagentSession {
                        Text((session.agentName?.isEmpty == false ? session.agentName! : "subagent").uppercased())
                            .font(Grok.mono(8, .bold)).tracking(0.6)
                            .foregroundStyle(Grok.textFaint)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Grok.hairline, lineWidth: 1))
                    }
                    if session.isRunning {
                        HStack(spacing: 5) {
                            Circle().fill(Grok.accent).frame(width: 6, height: 6)
                            Text("RUNNING").font(Grok.mono(9, .semibold)).tracking(0.8).foregroundStyle(Grok.accent)
                        }
                    }
                    if unread {
                        Text("NEW")
                            .font(Grok.mono(8, .bold))
                            .tracking(0.6)
                            .foregroundStyle(Grok.bg)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Grok.accent)
                            .clipShape(Capsule())
                    }
                }
                Text(name)
                    .font(Grok.sans(16, unread ? .bold : .semibold))
                    .foregroundStyle(Grok.text)
                    .lineLimit(1)
                if let preview = session.lastPreview, !preview.isEmpty {
                    Text(preview)
                        .font(Grok.mono(12))
                        .foregroundStyle(unread ? Grok.textDim : Grok.textFaint)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 8) {
                        if let cwd = session.cwd, !cwd.isEmpty {
                            Text(cwd).font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Text("· \(session.turnCount) turn\(session.turnCount == 1 ? "" : "s")")
                            .font(Grok.mono(11)).foregroundStyle(Grok.textFaint).fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
}
