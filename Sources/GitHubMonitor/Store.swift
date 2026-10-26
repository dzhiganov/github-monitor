import AppKit
import Observation
import ServiceManagement

enum Grouping: String, CaseIterable {
    case none, user, organization, repository

    var title: String {
        switch self {
        case .none: "None"
        case .user: "User"
        case .organization: "Organization"
        case .repository: "Repository"
        }
    }
}

struct PRGroup: Identifiable {
    let id: String
    let imageURL: URL?
    let items: [PRItem]
}

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
    /// Bumped each time the popover opens, so the list can reset its focus and filter.
    private(set) var openCount = 0
    /// Shows snoozed and muted PRs (dimmed) instead of hiding them.
    var showHidden = false
    /// PR id → time until which it's snoozed.
    private(set) var snoozedUntil: [String: Double]
    /// PR id → its `updatedAt` when snoozed; it stays hidden until GitHub reports newer activity.
    private(set) var snoozedActivity: [String: Double]
    private(set) var mutedRepos: Set<String>

    var showDrafts: Bool {
        didSet {
            UserDefaults.standard.set(showDrafts, forKey: Keys.showDrafts)
            if isOpen { markVisibleSeen() } else { notify() }
        }
    }
    var reviewNewestFirst: Bool {
        didSet { UserDefaults.standard.set(reviewNewestFirst, forKey: Keys.reviewNewestFirst) }
    }
    var mineNewestFirst: Bool {
        didSet { UserDefaults.standard.set(mineNewestFirst, forKey: Keys.mineNewestFirst) }
    }
    var grouping: Grouping {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: Keys.grouping) }
    }
    var intervalMinutes: Int {
        didSet { UserDefaults.standard.set(intervalMinutes, forKey: Keys.interval); startPolling(refreshNow: false) }
    }
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notifications) }
    }
    var notifyCIFailures: Bool {
        didSet { UserDefaults.standard.set(notifyCIFailures, forKey: Keys.notifyCI) }
    }

    @ObservationIgnored var onBadgeChange: ((Bool) -> Void)?
    @ObservationIgnored var dismiss: (() -> Void)?
    @ObservationIgnored var onNotify: (([PRItem]) -> Void)?
    @ObservationIgnored var onCIFailure: (([PRItem]) -> Void)?
    @ObservationIgnored var requestNotificationPermission: ((@escaping @Sendable (Bool) -> Void) -> Void)?

    /// seenKey → timestamp of the latest event the user has seen for it.
    @ObservationIgnored private var seen: [String: Double]
    /// Same shape as `seen`, but for events already announced with a system notification.
    @ObservationIgnored private var notified: [String: Double]
    /// PR id → (head commit, checks failed) from the previous refresh, to spot new CI failures.
    @ObservationIgnored private var lastChecks: [String: (oid: String?, failed: Bool)] = [:]
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isOpen = false
    private let client = GitHubClient()

    private enum Keys {
        static let showDrafts = "showDrafts", interval = "intervalMinutes", seen = "seenEvents"
        static let notified = "notifiedEvents", notifications = "notificationsEnabled"
        static let reviewNewestFirst = "reviewNewestFirst", mineNewestFirst = "mineNewestFirst", grouping = "grouping"
        static let notifyCI = "notifyCIFailures", snoozedUntil = "snoozedUntil", snoozedActivity = "snoozedActivity"
        static let mutedRepos = "mutedRepos"
    }

    init() {
        let d = UserDefaults.standard
        showDrafts = d.bool(forKey: Keys.showDrafts)
        intervalMinutes = max(2, d.object(forKey: Keys.interval) as? Int ?? 3)
        seen = d.dictionary(forKey: Keys.seen) as? [String: Double] ?? [:]
        notified = d.dictionary(forKey: Keys.notified) as? [String: Double] ?? [:]
        notificationsEnabled = d.object(forKey: Keys.notifications) as? Bool ?? true
        reviewNewestFirst = d.object(forKey: Keys.reviewNewestFirst) as? Bool ?? true
        mineNewestFirst = d.object(forKey: Keys.mineNewestFirst) as? Bool ?? true
        grouping = d.string(forKey: Keys.grouping).flatMap(Grouping.init) ?? .none
        notifyCIFailures = d.object(forKey: Keys.notifyCI) as? Bool ?? true
        snoozedUntil = d.dictionary(forKey: Keys.snoozedUntil) as? [String: Double] ?? [:]
        snoozedActivity = d.dictionary(forKey: Keys.snoozedActivity) as? [String: Double] ?? [:]
        mutedRepos = Set(d.stringArray(forKey: Keys.mutedRepos) ?? [])
    }

    // MARK: Derived

    /// Not snoozed or muted: these count in the tabs, the badge and notifications.
    var activeReview: [PRItem] { toReview.filter { !isHidden($0) } }
    var activeMine: [PRItem] { mine.filter { (showDrafts || !$0.isDraft) && !isHidden($0) } }
    /// What the list shows: active items, plus hidden ones while `showHidden` is on.
    var listedReview: [PRItem] { sorted(showHidden ? toReview : activeReview, newestFirst: reviewNewestFirst) }
    var listedMine: [PRItem] {
        sorted(showHidden ? mine.filter { showDrafts || !$0.isDraft } : activeMine, newestFirst: mineNewestFirst)
    }
    var hiddenReviewCount: Int { toReview.filter(isHidden).count }
    var hiddenMineCount: Int { mine.filter { (showDrafts || !$0.isDraft) && isHidden($0) }.count }

    func isSnoozed(_ item: PRItem) -> Bool {
        if let until = snoozedUntil[item.id], until > Date.now.timeIntervalSince1970 { return true }
        if let at = snoozedActivity[item.id], item.updatedAt.timeIntervalSince1970 <= at { return true }
        return false
    }
    func isMuted(_ item: PRItem) -> Bool { mutedRepos.contains(item.repo) }
    func isHidden(_ item: PRItem) -> Bool { isSnoozed(item) || isMuted(item) }

    private func sorted(_ items: [PRItem], newestFirst: Bool) -> [PRItem] {
        items.sorted { newestFirst ? $0.openSince > $1.openSince : $0.openSince < $1.openSince }
    }

    /// Splits already-sorted items into groups (alphabetical); each group keeps the items' order.
    func groups(_ items: [PRItem]) -> [PRGroup] {
        let key: (PRItem) -> String = switch grouping {
        case .none: { _ in "" }
        case .user: \.author
        case .organization: \.owner
        case .repository: \.repo
        }
        return Dictionary(grouping: items, by: key).map { name, items in
            PRGroup(id: name, imageURL: grouping == .user ? items[0].avatarURL : items[0].ownerAvatarURL, items: items)
        }.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }
    private var attentionItems: [PRItem] { (activeReview + activeMine).filter(\.wantsAttention) }
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
        openCount += 1
        showHidden = false
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
            announceCIFailures()
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
        lastChecks = [:]
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
        let sample = toReview.first ?? mine.first ?? PRItem(
            id: "test", number: 42, title: "Notifications are working", url: URL(string: "https://github.com/pulls")!,
            repo: "github-monitor/test", author: "github-monitor", avatarURL: nil, isDraft: false,
            openSince: .now, updatedAt: .now, kind: .needsReview)
        onNotify?([sample])
    }

    func open(_ item: PRItem) {
        NSWorkspace.shared.open(item.url)
        dismiss?()
    }

    // MARK: Snooze & mute

    /// Hides the PR until 9:00 tomorrow.
    func snoozeUntilTomorrow(_ item: PRItem) {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now))!
        snoozedUntil[item.id] = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!.timeIntervalSince1970
        snoozeChanged()
    }

    func snoozeUntilActivity(_ item: PRItem) {
        snoozedActivity[item.id] = item.updatedAt.timeIntervalSince1970
        snoozeChanged()
    }

    func unsnooze(_ item: PRItem) {
        snoozedUntil[item.id] = nil
        snoozedActivity[item.id] = nil
        snoozeChanged()
    }

    func setMuted(_ repo: String, _ muted: Bool) {
        if muted { mutedRepos.insert(repo) } else { mutedRepos.remove(repo) }
        snoozeChanged()
    }

    private func snoozeChanged() {
        let d = UserDefaults.standard
        d.set(snoozedUntil, forKey: Keys.snoozedUntil)
        d.set(snoozedActivity, forKey: Keys.snoozedActivity)
        d.set(mutedRepos.sorted(), forKey: Keys.mutedRepos)
        if isOpen { markVisibleSeen() } else { notify() }
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

    /// Notifies about my PRs whose checks just started failing: a new failure on the same commit,
    /// or a new commit that fails. PRs first seen in this session are only recorded.
    private func announceCIFailures() {
        let failing = mine.filter { item in
            guard item.checksFailed, !isHidden(item), let prev = lastChecks[item.id] else { return false }
            return !(prev.failed && prev.oid == item.headOid)
        }
        lastChecks = Dictionary(uniqueKeysWithValues: mine.map { ($0.id, ($0.headOid, $0.checksFailed)) })
        if !isOpen && notificationsEnabled && notifyCIFailures && !failing.isEmpty { onCIFailure?(failing) }
    }

    /// Forget old entries for items that are gone. Recent ones are kept so a PR that briefly
    /// drops out of search results doesn't come back as "new".
    private func pruneSeen() {
        let current = Set((toReview + mine).map(\.seenKey))
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970
        seen = seen.filter { current.contains($0.key) || $0.value > cutoff }
        notified = notified.filter { current.contains($0.key) || $0.value > cutoff }
        persistSeen()
        // Timed snoozes that ran out, and activity snoozes for PRs that are gone or have moved on.
        let now = Date.now.timeIntervalSince1970
        let updated = Dictionary((toReview + mine).map { ($0.id, $0.updatedAt.timeIntervalSince1970) }, uniquingKeysWith: max)
        let until = snoozedUntil.filter { $0.value > now }
        let activity = snoozedActivity.filter { id, at in updated[id].map { $0 <= at } ?? false }
        if until != snoozedUntil || activity != snoozedActivity {
            snoozedUntil = until
            snoozedActivity = activity
            snoozeChanged()
        }
    }

    private func persistSeen() {
        UserDefaults.standard.set(seen, forKey: Keys.seen)
        UserDefaults.standard.set(notified, forKey: Keys.notified)
    }

    private func notify() {
        onBadgeChange?(hasUnseen)
    }
}
