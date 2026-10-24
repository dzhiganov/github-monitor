import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class Store {
    private(set) var toReview: [PRItem] = []
    private(set) var mine: [PRItem] = []
    private(set) var isLoading = false
    private(set) var lastUpdated: Date?
    private(set) var error: String?
    private(set) var needsToken = false
    private(set) var hasSavedToken = Keychain.read() != nil
    /// Keys that were unseen when the popover opened; rows use this for their "new" dot.
    private(set) var fresh: Set<String> = []
    var editingToken = false

    var showDrafts: Bool {
        didSet {
            UserDefaults.standard.set(showDrafts, forKey: Keys.showDrafts)
            if isOpen { markVisibleSeen() } else { notify() }
        }
    }
    var intervalMinutes: Int {
        didSet { UserDefaults.standard.set(intervalMinutes, forKey: Keys.interval); startPolling(refreshNow: false) }
    }
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    @ObservationIgnored var onBadgeChange: ((Bool) -> Void)?
    @ObservationIgnored var dismiss: (() -> Void)?
    @ObservationIgnored var onNotify: (([PRItem]) -> Void)?
    @ObservationIgnored var requestNotificationPermission: ((@escaping @Sendable (Bool) -> Void) -> Void)?

    /// seenKey → timestamp of the latest event the user has seen for it.
    @ObservationIgnored private var seen: [String: Double]
    /// Same shape as `seen`, but for events already announced with a system notification.
    @ObservationIgnored private var notified: [String: Double]
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isOpen = false
    private let client = GitHubClient()

    private enum Keys {
        static let showDrafts = "showDrafts", interval = "intervalMinutes", seen = "seenEvents"
        static let notified = "notifiedEvents", notifications = "notificationsEnabled"
    }

    init() {
        let d = UserDefaults.standard
        showDrafts = d.bool(forKey: Keys.showDrafts)
        intervalMinutes = max(2, d.object(forKey: Keys.interval) as? Int ?? 3)
        seen = d.dictionary(forKey: Keys.seen) as? [String: Double] ?? [:]
        notified = d.dictionary(forKey: Keys.notified) as? [String: Double] ?? [:]
        notificationsEnabled = d.object(forKey: Keys.notifications) as? Bool ?? true
    }

    // MARK: Derived

    var needsReview: [PRItem] { toReview.filter { $0.kind == .needsReview }.sorted { $0.openSince < $1.openSince } }
    var reReview: [PRItem] { toReview.filter { $0.kind == .reReview }.sorted { $0.openSince < $1.openSince } }
    var visibleMine: [PRItem] {
        mine.filter { showDrafts || !$0.isDraft }.sorted {
            ($0.unanswered > 0) != ($1.unanswered > 0) ? $0.unanswered > 0 : $0.updatedAt > $1.updatedAt
        }
    }
    private var attentionItems: [PRItem] { (toReview + visibleMine).filter(\.wantsAttention) }
    private func isUnseen(_ item: PRItem) -> Bool { isNewer(item, than: seen) }
    private func isNewer(_ item: PRItem, than marks: [String: Double]) -> Bool {
        guard let at = marks[item.seenKey] else { return true }
        return item.eventDate.timeIntervalSince1970 > at
    }
    var hasUnseen: Bool { attentionItems.contains(where: isUnseen) }

    // MARK: Lifecycle

    func start() {
        startPolling()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.startPolling() }
        }
    }

    private func startPolling(refreshNow: Bool = true) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var first = refreshNow
            while !Task.isCancelled {
                if !first {
                    // Retry sooner after a failure (e.g. network not up yet after wake).
                    let delay = self?.error == nil ? (self?.intervalMinutes ?? 3) * 60 : 60
                    try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(20))
                    if Task.isCancelled { return }
                }
                first = false
                await self?.refresh(force: true)
            }
        }
    }

    func popoverOpened() {
        isOpen = true
        fresh = Set(attentionItems.filter(isUnseen).map(\.seenKey))
        markVisibleSeen()
        if let last = lastUpdated, Date.now.timeIntervalSince(last) > 60 { Task { await refresh() } }
    }

    func popoverClosed() {
        isOpen = false
    }

    /// `force` supersedes a refresh already in flight instead of skipping.
    func refresh(force: Bool = false) async {
        if isLoading && !force { return }
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }

        if token == nil { token = await Auth.resolveToken() }
        guard gen == generation else { return }
        guard let used = token else { needsToken = true; return }

        do {
            let result = try await client.fetch(token: used)
            guard gen == generation, token == used else { return }
            toReview = Classifier.reviewItems(result.payload)
            mine = Classifier.myItems(result.payload)
            lastUpdated = .now
            error = result.warning
            needsToken = false
            if isOpen {
                fresh.formUnion(attentionItems.filter(isUnseen).map(\.seenKey))
                markVisibleSeen()
            }
            announce()
            pruneSeen()
            notify()
        } catch APIError.unauthorized {
            guard gen == generation, token == used else { return }
            token = nil
            if Keychain.read() == used {
                Keychain.delete()
                hasSavedToken = false
            }
            // If the fallback is the same rejected token, ask the user for a new one.
            let fallback = await Auth.resolveToken()
            needsToken = fallback == nil || fallback == used
            error = APIError.unauthorized.errorDescription
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            if gen == generation { self.error = error.localizedDescription }
        }
    }

    func saveToken(_ value: String) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Keychain.save(t)
        hasSavedToken = true
        token = t
        needsToken = false
        editingToken = false
        error = nil
        startPolling()
    }

    func signOut() {
        Keychain.delete()
        hasSavedToken = false
        token = nil
        toReview = []
        mine = []
        lastUpdated = nil
        startPolling()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        } catch {
            self.error = "Couldn’t change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setNotifications(_ on: Bool) {
        notificationsEnabled = on
        guard on else { return }
        requestNotificationPermission? { granted in
            guard !granted else { return }
            Task { @MainActor [weak self] in
                self?.error = "Notifications are off for GitHub Monitor in System Settings › Notifications."
            }
        }
    }

    func sendTestNotification() {
        let sample = toReview.first ?? visibleMine.first ?? PRItem(
            id: "test", number: 42, title: "Notifications are working", url: URL(string: "https://github.com/pulls")!,
            repo: "github-monitor/test", author: "github-monitor", avatarURL: nil, isDraft: false,
            openSince: .now, updatedAt: .now, kind: .needsReview)
        onNotify?([sample])
    }

    func open(_ item: PRItem) {
        NSWorkspace.shared.open(item.url)
        dismiss?()
    }

    #if DEBUG
    func loadPreview(review: [PRItem], mine: [PRItem], fresh: Set<String>) {
        toReview = review
        self.mine = mine
        self.fresh = fresh
        lastUpdated = .now.addingTimeInterval(-120)
    }
    #endif

    // MARK: Seen tracking

    private func markVisibleSeen() {
        for item in attentionItems where isUnseen(item) {
            seen[item.seenKey] = item.eventDate.timeIntervalSince1970
        }
        persistSeen()
        notify()
    }

    /// Fires a system notification for events that are unseen and not yet announced.
    private func announce() {
        let items = attentionItems.filter { isUnseen($0) && isNewer($0, than: notified) }
        for item in attentionItems where isNewer(item, than: notified) {
            notified[item.seenKey] = item.eventDate.timeIntervalSince1970
        }
        if !isOpen && notificationsEnabled && !items.isEmpty { onNotify?(items) }
    }

    /// Forget old entries for items that are gone. Recent ones are kept so a PR that briefly
    /// drops out of search results doesn't come back as "new".
    private func pruneSeen() {
        let current = Set((toReview + mine).map(\.seenKey))
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970
        seen = seen.filter { current.contains($0.key) || $0.value > cutoff }
        notified = notified.filter { current.contains($0.key) || $0.value > cutoff }
        persistSeen()
    }

    private func persistSeen() {
        UserDefaults.standard.set(seen, forKey: Keys.seen)
        UserDefaults.standard.set(notified, forKey: Keys.notified)
    }

    private func notify() {
        onBadgeChange?(hasUnseen)
    }
}
