import SwiftUI

enum Tab: Hashable { case review, mine }

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var tab: Tab
    @Namespace private var tabNS

    init(tab: Tab = .review) { _tab = State(initialValue: tab) }

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
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            tabButton("Review", count: store.toReview.count, tab: .review)
            tabButton("My PRs", count: store.visibleMine.count, tab: .mine)
            Spacer()
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

    @ViewBuilder private var content: some View {
        let isEmpty = tab == .review ? store.toReview.isEmpty : store.visibleMine.isEmpty
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let error = store.error { ErrorBanner(text: error).padding(.bottom, 4) }
                    if tab == .review {
                        section("Needs your review", store.needsReview)
                        section("Back to you", store.reReview)
                    } else {
                        section(nil, store.visibleMine)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder private func section(_ title: String?, _ items: [PRItem]) -> some View {
        if !items.isEmpty {
            if let title {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                    Text("\(items.count)").monospacedDigit()
                }
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            ForEach(items) { item in
                PRRow(item: item, isNew: store.fresh.contains(item.seenKey)) { store.open(item) }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        @Bindable var store = store
        return HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(statusText(now: ctx.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
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
                Toggle("Notifications", isOn: Binding(get: { store.notificationsEnabled }, set: { store.setNotifications($0) }))
                if store.notificationsEnabled {
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

// MARK: - Row

struct PRRow: View {
    let item: PRItem
    let isNew: Bool
    let action: () -> Void
    @State private var hovering = false

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
                    (Text(subtitle).foregroundStyle(.secondary)
                        + Text(item.reason.map { "  \($0)" } ?? "").foregroundStyle(Color.accentColor).fontWeight(.medium))
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.075 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(item.repo) #\(item.number)\n\(item.title)")
        .contextMenu {
            Button("Open in Browser", action: action)
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
        }
    }

    private var subtitle: String {
        if item.kind == .mine {
            let status = switch item.decision {
            case "APPROVED": "Approved"
            case "CHANGES_REQUESTED": "Changes requested"
            default: item.isDraft ? "Draft" : "Awaiting review"
            }
            return "\(item.repoName) #\(item.number) · \(status)"
        }
        return "\(item.repoName) #\(item.number) · \(item.author)"
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
                    Image(systemName: "bubble.left.fill").font(.system(size: 8.5))
                    Text("\(item.unanswered)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.orange)
                .help("\(item.unanswered) unanswered comment\(item.unanswered == 1 ? "" : "s")")
            }
        }
    }
}

// MARK: - Building blocks

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
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
