import SwiftUI

enum Tab: Hashable { case review, mine }

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var tab: Tab
    /// Row under the keyboard cursor (or the mouse).
    @State private var selection: String?
    /// Type-to-filter query.
    @State private var filter = ""
    /// Bumped by keyboard moves so only they scroll the list, not hovering.
    @State private var scrollTick = 0
    @FocusState private var focused: Bool
    @Namespace private var tabNS

    init(tab: Tab = .review, filter: String = "") {
        _tab = State(initialValue: tab)
        _filter = State(initialValue: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                if store.needsToken || store.editingToken {
                    TokenView()
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 380, height: 520)
        .background(shortcuts)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: [.down, .repeat], action: handleKey)
        .onAppear { focused = true }
        .onChange(of: store.openCount) {
            focused = true
            filter = ""
            selection = nil
        }
        .onChange(of: filter) { selection = displayed.first?.id }
        .onChange(of: tab) { selection = filter.isEmpty ? nil : displayed.first?.id }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            tabButton("Review", count: store.activeReview.count, tab: .review)
            tabButton("My PRs", count: store.activeMine.count, tab: .mine)
            Spacer()
            sortButton
            Button { Task { await store.refresh() } } label: {
                ZStack {
                    if store.isLoading {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh (⌘R)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var sortButton: some View {
        @Bindable var store = store
        let newestFirst = tab == .review ? $store.reviewNewestFirst : $store.mineNewestFirst
        return Button {
            withAnimation(.snappy(duration: 0.22)) { newestFirst.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: newestFirst.wrappedValue ? "arrow.down" : "arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                Text(newestFirst.wrappedValue ? "Newest" : "Oldest")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle())
        .help(newestFirst.wrappedValue ? "Newest first. Click to show oldest first." : "Oldest first. Click to show newest first.")
    }

    private func tabButton(_ title: String, count: Int, tab t: Tab) -> some View {
        let selected = tab == t
        return Button {
            withAnimation(.snappy(duration: 0.22)) { tab = t }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.primary.opacity(selected ? 0.12 : 0.07)))
                }
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if selected {
                    Capsule().fill(.primary.opacity(0.08)).matchedGeometryEffect(id: "tab", in: tabNS)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    private struct ListSection: Identifiable {
        enum Header { case none, caption(String), group(PRGroup) }
        let id: String
        let header: Header
        let items: [PRItem]
    }

    private var listed: [PRItem] { tab == .review ? store.listedReview : store.listedMine }

    private var sections: [ListSection] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let items = query.isEmpty ? listed : listed.filter { item in
            [item.title, item.repo, item.author, "#\(item.number)"].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        if store.grouping != .none {
            return store.groups(items).map { ListSection(id: "g:\($0.id)", header: .group($0), items: $0.items) }
        }
        if tab == .review {
            return [
                ListSection(id: "new", header: .none, items: items.filter { $0.kind == .needsReview }),
                ListSection(id: "back", header: .caption("Back to you"), items: items.filter { $0.kind == .reReview }),
            ].filter { !$0.items.isEmpty }
        }
        return [ListSection(id: "mine", header: .none, items: items)]
    }

    /// Rows in on-screen order, for keyboard navigation.
    private var displayed: [PRItem] { sections.flatMap(\.items) }

    @ViewBuilder private var content: some View {
        let isEmpty = listed.isEmpty
        if isEmpty && store.lastUpdated == nil {
            if let error = store.error {
                EmptyState(symbol: "exclamationmark.triangle", title: "Couldn’t load", subtitle: error)
            } else {
                ProgressView().controlSize(.small)
            }
        } else if isEmpty {
            VStack(spacing: 0) {
                if let error = store.error { ErrorBanner(text: error).padding(8) }
                tab == .review
                    ? EmptyState(symbol: "checkmark.circle", title: "All caught up", subtitle: "Nothing is waiting for your review.")
                    : EmptyState(symbol: "tray", title: "No open pull requests", subtitle: store.showDrafts ? "You have no open PRs." : "Drafts are hidden.")
            }
        } else {
            let sections = self.sections
            VStack(spacing: 0) {
                if !filter.isEmpty { FilterBar(text: filter) { filter = "" } }
                if sections.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No matches", subtitle: "Nothing matches “\(filter)”.")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                if let error = store.error { ErrorBanner(text: error).padding(.bottom, 4) }
                                ForEach(sections) { section in
                                    Section {
                                        ForEach(section.items) { item in
                                            // Indent rows under a group header so they read as its children.
                                            row(item).padding(.leading, store.grouping == .none ? 0 : 12)
                                        }
                                    } header: {
                                        sectionHeader(section.header, count: section.items.count)
                                    }
                                }
                            }
                            .padding(6)
                        }
                        .scrollIndicators(.never)
                        .onChange(of: scrollTick) {
                            if let selection { proxy.scrollTo(selection) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: PRItem) -> some View {
        PRRow(item: item, isNew: store.fresh.contains(item.seenKey), isSelected: selection == item.id,
              isHidden: store.isHidden(item)) { store.open(item) }
            .onHover { if $0 { selection = item.id } }
            .id(item.id)
    }

    @ViewBuilder private func sectionHeader(_ header: ListSection.Header, count: Int) -> some View {
        switch header {
        case .none:
            EmptyView()
        case .caption(let title):
            HStack(spacing: 6) {
                Text(title.uppercased())
                Text("\(count)").monospacedDigit()
            }
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
        case .group(let group):
            HStack(spacing: 7) {
                GroupImage(url: group.imageURL, round: store.grouping == .user)
                Text(group.id)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !store.needsToken && !store.editingToken,
              press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        switch press.key {
        case .downArrow: move(1)
        case .upArrow: move(-1)
        case .leftArrow: withAnimation(.snappy(duration: 0.22)) { tab = .review }
        case .rightArrow: withAnimation(.snappy(duration: 0.22)) { tab = .mine }
        case .return:
            guard let item = displayed.first(where: { $0.id == selection }) else { return .ignored }
            store.open(item)
        case .escape:
            // An empty filter lets Escape through, which closes the popover.
            guard !filter.isEmpty else { return .ignored }
            filter = ""
        case .delete:
            guard !filter.isEmpty else { return .ignored }
            filter.removeLast()
        default:
            guard press.characters.count == 1, let c = press.characters.first,
                  c.isLetter || c.isNumber || c.isPunctuation || c.isSymbol || (c == " " && !filter.isEmpty)
            else { return .ignored }
            filter.append(c)
        }
        return .handled
    }

    private func move(_ delta: Int) {
        let ids = displayed.map(\.id)
        guard !ids.isEmpty else { return }
        if let selection, let i = ids.firstIndex(of: selection) {
            self.selection = ids[min(max(i + delta, 0), ids.count - 1)]
        } else {
            selection = delta > 0 ? ids.first : ids.last
        }
        scrollTick += 1
    }

    // MARK: Footer

    private var footer: some View {
        @Bindable var store = store
        let hiddenCount = tab == .review ? store.hiddenReviewCount : store.hiddenMineCount
        return HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(statusText(now: ctx.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if hiddenCount > 0 {
                Button { store.showHidden.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: store.showHidden ? "eye" : "eye.slash").font(.system(size: 10))
                        Text("\(hiddenCount) hidden").font(.system(size: 11))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(IconButtonStyle())
                .help(store.showHidden ? "Hide snoozed and muted PRs" : "Show snoozed and muted PRs")
            }
            if tab == .mine {
                Toggle("Drafts", isOn: $store.showDrafts)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Menu {
                Picker("Refresh Every", selection: $store.intervalMinutes) {
                    ForEach([2, 3, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Group By", selection: $store.grouping) {
                    ForEach(Grouping.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if !store.mutedRepos.isEmpty {
                    Menu("Muted Repositories") {
                        ForEach(store.mutedRepos.sorted(), id: \.self) { repo in
                            Button("Unmute \(repo)") { store.setMuted(repo, false) }
                        }
                    }
                }
                Divider()
                Toggle("Notifications", isOn: Binding(get: { store.notificationsEnabled }, set: { store.setNotifications($0) }))
                if store.notificationsEnabled {
                    Toggle("Notify When Checks Fail", isOn: $store.notifyCIFailures)
                    Button("Send Test Notification") { store.sendTestNotification() }
                }
                Toggle("Launch at Login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                Divider()
                Button(store.hasSavedToken ? "Change Access Token…" : "Use Access Token…") { store.editingToken = true }
                if store.hasSavedToken {
                    Button("Remove Saved Token") { store.signOut() }
                }
                Divider()
                Button("Quit GitHub Monitor") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func statusText(now: Date) -> String {
        guard let last = store.lastUpdated else { return store.isLoading ? "Loading…" : "Not updated yet" }
        let s = now.timeIntervalSince(last)
        return s < 60 ? "Updated just now" : "Updated \(Age.short(since: last, now: now)) ago"
    }

    /// Invisible buttons that give the popover keyboard shortcuts.
    private var shortcuts: some View {
        ZStack {
            Button("") { Task { await store.refresh() } }.keyboardShortcut("r")
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q")
            Button("") { withAnimation(.snappy(duration: 0.22)) { tab = .review } }.keyboardShortcut("1")
            Button("") { withAnimation(.snappy(duration: 0.22)) { tab = .mine } }.keyboardShortcut("2")
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

/// Shows the type-to-filter query above the list.
struct FilterBar: View {
    let text: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Clear filter (Esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.06)))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

// MARK: - Row

struct PRRow: View {
    @Environment(Store.self) private var store
    let item: PRItem
    let isNew: Bool
    let isSelected: Bool
    let isHidden: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isNew {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        }
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack(spacing: 6) {
                        subtitle
                            .font(.system(size: 11))
                            .lineLimit(1)
                        if item.kind == .mine && item.hasConflicts {
                            Pill(text: "Conflicts", color: .orange, symbol: "exclamationmark.triangle.fill")
                                .fixedSize()
                                .help("This branch has conflicts that must be resolved")
                        }
                    }
                }
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(isSelected ? 0.075 : 0))
            )
            .opacity(isHidden ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(item.repo) #\(item.number)\n\(item.title)")
        .contextMenu {
            Button("Open in Browser", action: action)
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
            Divider()
            if store.isSnoozed(item) {
                Button("Unsnooze") { store.unsnooze(item) }
            } else {
                Button("Snooze Until Tomorrow") { store.snoozeUntilTomorrow(item) }
                Button("Snooze Until New Activity") { store.snoozeUntilActivity(item) }
            }
            if store.isMuted(item) {
                Button("Unmute \(item.repo)") { store.setMuted(item.repo, false) }
            } else {
                Button("Mute \(item.repo)") { store.setMuted(item.repo, true) }
            }
        }
    }

    private var subtitle: Text {
        let base = Text(verbatim: "\(item.repoName) #\(item.number) · ").foregroundStyle(.secondary)
        guard item.kind == .mine else {
            return base + Text(item.author).foregroundStyle(.secondary)
                + Text(item.reason.map { "  \($0)" } ?? "").foregroundStyle(Color.accentColor).fontWeight(.medium)
        }
        let status = switch item.decision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        default: item.isDraft ? "Draft" : "Awaiting review"
        }
        // CI goes before the status as a bare icon, so a long status (or the Conflicts badge) truncates the status, not CI.
        var text = base
        if let checks = item.checks {
            let (symbol, color): (String, Color) = switch checks {
            case "SUCCESS": ("checkmark", .secondary)
            case "FAILURE", "ERROR": ("xmark", .red)
            default: ("hourglass", .secondary)
            }
            text = text + Text(Image(systemName: symbol)).foregroundStyle(color) + Text(" ")
        }
        text = text + Text(status).foregroundStyle(.secondary)
        return text
    }

    @ViewBuilder private var leading: some View {
        if item.kind == .mine {
            let (symbol, color): (String, Color) = switch (item.isDraft, item.decision) {
            case (true, _): ("circle.dashed", .secondary)
            case (_, "APPROVED"): ("checkmark.circle.fill", .green)
            case (_, "CHANGES_REQUESTED"): ("exclamationmark.circle.fill", .orange)
            default: ("clock", .secondary)
            }
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
        } else {
            AsyncImage(url: item.avatarURL) { phase in
                if let image = phase.image {
                    image.resizable().interpolation(.high)
                } else {
                    Circle().fill(.quaternary)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    @ViewBuilder private var trailing: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if item.isDraft {
                Pill(text: "Draft", color: .secondary)
            } else {
                let days = Age.days(since: item.openSince)
                Pill(text: Age.short(since: item.openSince), color: days >= 14 ? .red : days >= 7 ? .orange : .secondary)
                    .help(Age.long(since: item.openSince))
            }
            if item.unanswered > 0 {
                HStack(spacing: 3) {
                    if !item.commenters.isEmpty {
                        AvatarStack(urls: item.commenters).padding(.trailing, 2)
                    }
                    Image(systemName: "bubble.left.fill").font(.system(size: 8.5))
                    Text("\(item.unanswered)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .help("\(item.unanswered) unanswered comment\(item.unanswered == 1 ? "" : "s")")
            }
        }
    }
}

// MARK: - Building blocks

/// Small overlapping avatars. Each one under another has a crescent cut out of it, leaving a
/// transparent gap that looks right on the translucent popover and the hover highlight alike.
struct AvatarStack: View {
    let urls: [URL]
    private let size: CGFloat = 16, overlap: CGFloat = 4.5, gap: CGFloat = 1.5

    var body: some View {
        HStack(spacing: -overlap) {
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.high)
                    } else {
                        Circle().fill(.quaternary)
                    }
                }
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .mask {
                    Circle().overlay {
                        if index > 0 {
                            Circle()
                                .frame(width: size + gap * 2, height: size + gap * 2)
                                .offset(x: overlap - size)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
                }
            }
        }
    }
}

/// Avatar for a group header: round for users, rounded square for orgs and repositories (as on GitHub).
struct GroupImage: View {
    let url: URL?
    let round: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: round ? 8 : 4, style: .continuous)
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                shape.fill(.quaternary)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
            Text(text)
        }
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

struct IconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0))
            )
            .onHover { hovering = $0 }
    }
}

// MARK: - Token entry

struct TokenView: View {
    @Environment(Store.self) private var store
    @State private var value = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Connect to GitHub").font(.system(size: 14, weight: .semibold))
            Text("Run `gh auth login` in Terminal and press Retry, or paste a personal access token with the **repo** and **read:org** scopes.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Personal access token", text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .padding(.top, 4)
            HStack {
                Link("Create a token ↗", destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org&description=GitHub%20Monitor")!)
                    .font(.system(size: 11.5))
                Spacer()
                if store.needsToken {
                    Button("Retry") { Task { await store.refresh() } }
                } else {
                    Button("Cancel") { store.editingToken = false }
                }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save() {
        store.saveToken(value)
        value = ""
    }
}
