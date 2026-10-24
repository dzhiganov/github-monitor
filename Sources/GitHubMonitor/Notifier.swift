import AppKit
import UserNotifications

/// Posts macOS notifications for new PR activity. Clicking a single-PR notification opens it in
/// the browser; clicking a summary opens the popover.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpenSummary: (@MainActor () -> Void)?

    /// UNUserNotificationCenter traps when the process isn't running from an app bundle.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil

    func setup() {
        center?.delegate = self
        requestAuthorization { _ in }
    }

    func requestAuthorization(_ done: @escaping @Sendable (Bool) -> Void) {
        guard let center else { return done(false) }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in done(granted) }
    }

    func post(_ items: [PRItem]) {
        guard let center, !items.isEmpty else { return }
        if items.count <= 3 {
            for item in items {
                let content = UNMutableNotificationContent()
                content.title = Self.title(for: item)
                content.subtitle = item.kind == .mine ? "\(item.repoName) #\(item.number)" : "\(item.repoName) #\(item.number) · \(item.author)"
                content.body = item.title
                content.sound = .default
                content.threadIdentifier = "pr"
                content.userInfo = ["url": item.url.absoluteString]
                // Same identifier per PR + kind, so a newer update replaces the older banner.
                center.add(UNNotificationRequest(identifier: item.seenKey, content: content, trigger: nil))
            }
        } else {
            let content = UNMutableNotificationContent()
            content.title = "\(items.count) pull request updates"
            content.body = Self.summary(items)
            content.sound = .default
            content.threadIdentifier = "pr"
            center.add(UNNotificationRequest(identifier: "summary", content: content, trigger: nil))
        }
    }

    private static func title(for item: PRItem) -> String {
        switch item.kind {
        case .needsReview: "Review requested"
        case .reReview: "Back to you · \(item.reason ?? "Updated")"
        case .mine: item.unanswered == 1 ? "New comment on your PR" : "\(item.unanswered) unanswered comments"
        }
    }

    private static func summary(_ items: [PRItem]) -> String {
        let review = items.filter { $0.kind == .needsReview }.count
        let back = items.filter { $0.kind == .reReview }.count
        let mine = items.filter { $0.kind == .mine }.count
        return [
            review > 0 ? "\(review) to review" : nil,
            back > 0 ? "\(back) back to you" : nil,
            mine > 0 ? "\(mine) with new comments" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let url = (response.notification.request.content.userInfo["url"] as? String).flatMap(URL.init(string:))
        DispatchQueue.main.async { [weak self] in
            if let url {
                NSWorkspace.shared.open(url)
            } else {
                MainActor.assumeIsolated { self?.onOpenSummary?() }
            }
        }
        completionHandler()
    }
}
