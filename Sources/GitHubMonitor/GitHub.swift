import Foundation

// MARK: - Domain

struct PRItem: Identifiable, Hashable {
    enum Kind { case needsReview, reReview, mine }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: String
    let avatarURL: URL?
    let isDraft: Bool
    /// When the PR became ready for review (or was opened non-draft).
    let openSince: Date
    let updatedAt: Date
    let kind: Kind
    var reason: String? = nil
    var unanswered: Int = 0
    /// Avatars of the people behind unanswered comments, most recent first (at most 3).
    var commenters: [URL] = []
    var decision: String? = nil
    /// Time of the latest event that deserves attention. The item counts as new while this is
    /// later than what the user has already seen for `seenKey`, so it never goes "backwards".
    var eventDate: Date = .distantPast
    /// Avatar of the user or organization that owns the repository.
    var ownerAvatarURL: URL? = nil
    /// Combined CI state of the head commit: SUCCESS, FAILURE, ERROR, PENDING or EXPECTED.
    var checks: String? = nil
    var headOid: String? = nil
    var hasConflicts = false

    var seenKey: String {
        switch kind {
        case .needsReview: "\(id)|new"
        case .reReview: "\(id)|rr"
        case .mine: "\(id)|mine"
        }
    }
    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var owner: String { repo.split(separator: "/").first.map(String.init) ?? repo }
    var checksFailed: Bool { checks == "FAILURE" || checks == "ERROR" }
    /// Items that count toward the menu bar badge.
    var wantsAttention: Bool { kind != .mine || unanswered > 0 }
}

// MARK: - GraphQL

enum APIError: LocalizedError {
    case unauthorized, http(Int), graphQL(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub rejected the token."
        case .http(let code): "GitHub returned HTTP \(code)."
        case .graphQL(let msg): msg
        }
    }
}

struct GitHubClient {
    private static let query = """
    query($q1: String!, $q2: String!, $q3: String!, $q4: String!) {
      viewer { login }
      requested: search(query: $q1, type: ISSUE, first: 25) { nodes { ...PR } }
      reviewed: search(query: $q2, type: ISSUE, first: 25) { nodes { ...PR } }
      assigned: search(query: $q3, type: ISSUE, first: 15) { nodes { ...PR } }
      mine: search(query: $q4, type: ISSUE, first: 25) { nodes { ...PR } }
    }
    fragment A on Actor { login avatarUrl(size: 64) __typename }
    fragment C on PullRequestReviewComment { author { ...A } createdAt state }
    fragment PR on PullRequest {
      id number title url isDraft createdAt updatedAt reviewDecision mergeable
      repository { nameWithOwner owner { avatarUrl(size: 64) } }
      author { ...A }
      readyEvents: timelineItems(itemTypes: [READY_FOR_REVIEW_EVENT], last: 1) { nodes { ... on ReadyForReviewEvent { createdAt } } }
      requestEvents: timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 10) { nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } } } } }
      pushEvents: timelineItems(itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT], last: 1) { nodes { ... on HeadRefForcePushedEvent { createdAt } } }
      reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } } } }
      reviews(last: 40) { nodes { author { ...A } state submittedAt body } }
      comments(last: 40) { nodes { author { ...A } createdAt } }
      reviewThreads(last: 30) { nodes { isResolved head: comments(first: 1) { nodes { ...C } } tail: comments(last: 2) { nodes { ...C } } } }
      commits(last: 1) { nodes { commit { oid committedDate statusCheckRollup { state } } } }
    }
    """

    private static let variables = [
        "q1": "is:pr is:open draft:false archived:false review-requested:@me sort:updated-desc",
        "q2": "is:pr is:open draft:false archived:false reviewed-by:@me -author:@me sort:updated-desc",
        "q3": "is:pr is:open draft:false archived:false assignee:@me -author:@me sort:updated-desc",
        "q4": "is:pr is:open archived:false author:@me sort:updated-desc",
    ]

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func fetch(token: String) async throws -> Result {
        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": Self.query, "variables": Self.variables])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw APIError.unauthorized }
        guard status == 200 else { throw APIError.http(status) }
        return try Self.decode(data)
    }

    struct Result {
        let payload: Payload
        /// Partial errors (e.g. an org requiring SSO) that came alongside usable data.
        let warning: String?
    }

    static func decode(_ data: Data) throws -> Result {
        let res = try decoder.decode(Response.self, from: data)
        guard let payload = res.data else {
            throw APIError.graphQL(res.errors?.first?.message ?? "Empty response from GitHub.")
        }
        return Result(payload: payload, warning: res.errors?.first?.message)
    }

    struct Response: Decodable {
        let data: Payload?
        let errors: [Message]?
        struct Message: Decodable { let message: String }
    }

    struct Payload: Decodable {
        let viewer: Login
        let requested, reviewed, assigned, mine: Search
    }

    struct Search: Decodable {
        let prs: [RawPR]
        enum CodingKeys: String, CodingKey { case nodes }
        init(from decoder: Decoder) throws {
            // Inaccessible or non-PR nodes decode as empty objects; skip them instead of failing.
            let c = try decoder.container(keyedBy: CodingKeys.self)
            prs = try c.decode([Lenient<RawPR>].self, forKey: .nodes).compactMap(\.value)
        }
    }
}

struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct Nodes<T: Decodable>: Decodable {
    let nodes: [T]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decode([Lenient<T>].self, forKey: .nodes).compactMap(\.value)
    }
    enum CodingKeys: String, CodingKey { case nodes }
}

struct Login: Decodable { let login: String? }

struct Actor: Decodable {
    let login: String
    let avatarUrl: URL?
    let typename: String
    enum CodingKeys: String, CodingKey { case login, avatarUrl, typename = "__typename" }
    var isBot: Bool { typename == "Bot" || login.hasSuffix("[bot]") }
}

struct RawPR: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let reviewDecision: String?
    let mergeable: String?
    let repository: Repo
    let author: Actor?
    let readyEvents: Nodes<Dated>
    let requestEvents: Nodes<RequestEvent>
    let pushEvents: Nodes<Dated>
    let reviewRequests: Nodes<ReviewRequest>
    let reviews: Nodes<Review>
    let comments: Nodes<Comment>
    let reviewThreads: Nodes<ReviewThread>
    let commits: Nodes<CommitNode>

    struct Repo: Decodable {
        let nameWithOwner: String
        let owner: Owner?
        struct Owner: Decodable { let avatarUrl: URL? }
    }
    struct Dated: Decodable { let createdAt: Date }
    struct RequestEvent: Decodable { let createdAt: Date; let requestedReviewer: Login? }
    struct ReviewRequest: Decodable { let requestedReviewer: Login? }
    struct Review: Decodable { let author: Actor?; let state: String; let submittedAt: Date?; let body: String? }
    struct Comment: Decodable {
        let author: Actor?
        let createdAt: Date
        /// Only set for inline review comments; "PENDING" ones belong to an unsubmitted review.
        let state: String?
        var isSubmitted: Bool { state != "PENDING" }
    }
    struct ReviewThread: Decodable {
        let isResolved: Bool
        let head: Nodes<Comment>
        let tail: Nodes<Comment>
        /// First and last *submitted* comments; nil when the thread only exists in a pending review.
        var first: Comment? { head.nodes.first.flatMap { $0.isSubmitted ? $0 : nil } }
        var last: Comment? { tail.nodes.last(where: \.isSubmitted) }
    }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commit: Decodable {
        let oid: String?
        let committedDate: Date
        let statusCheckRollup: Rollup?
        struct Rollup: Decodable { let state: String }
    }
}

// MARK: - Classification

enum Classifier {
    /// Builds the "to review" list: PRs that are new to the user, or where everything the user
    /// said has been answered (or they were re-requested) so it's worth another look.
    static func reviewItems(_ p: GitHubClient.Payload) -> [PRItem] {
        let me = p.viewer.login ?? ""
        let requestedIDs = Set(p.requested.prs.map(\.id))
        let assignedIDs = Set(p.assigned.prs.map(\.id))
        var seen = Set<String>()
        var out: [PRItem] = []
        for pr in p.requested.prs + p.assigned.prs + p.reviewed.prs where !pr.isDraft && seen.insert(pr.id).inserted {
            let requested = requestedIDs.contains(pr.id)
            guard let item = classifyReview(pr, me: me, requested: requested) else { continue }
            // A PR found only via `reviewed-by:@me` whose review fell outside the fetched window
            // would otherwise look untouched.
            if item.kind == .needsReview && !requested && !assignedIDs.contains(pr.id) { continue }
            out.append(item)
        }
        return out
    }

    static func myItems(_ p: GitHubClient.Payload) -> [PRItem] {
        let me = p.viewer.login ?? ""
        return p.mine.prs.map { classifyMine($0, me: me) }
    }

    static func classifyReview(_ pr: RawPR, me: String, requested: Bool) -> PRItem? {
        let isMe = { (a: Actor?) in a?.login.caseInsensitiveCompare(me) == .orderedSame }
        let isOther = { (a: Actor?) in a != nil && !isMe(a) && !a!.isBot }
        let threads = pr.reviewThreads.nodes

        let myReviews = pr.reviews.nodes.filter { isMe($0.author) && $0.state != "PENDING" && $0.submittedAt != nil }
        let myLastReview = myReviews.compactMap(\.submittedAt).max()
        var myTimes = myReviews.compactMap(\.submittedAt)
        myTimes += pr.comments.nodes.filter { isMe($0.author) }.map(\.createdAt)
        myTimes += threads.flatMap { [$0.first, $0.last].compactMap { $0 } }.filter { isMe($0.author) }.map(\.createdAt)

        // Latest time I was asked to review (directly, or via a team: those have no User login).
        let lastRequest = pr.requestEvents.nodes.filter {
            guard let login = $0.requestedReviewer?.login else { return true }
            return login.caseInsensitiveCompare(me) == .orderedSame
        }.map(\.createdAt).max()

        guard let myLast = myTimes.max() else {
            return item(pr, kind: .needsReview, eventDate: lastRequest ?? pr.createdAt)
        }

        if requested {
            // Still requested but never submitted a review: the first review is still owed.
            guard let myLastReview else {
                return item(pr, kind: .needsReview, eventDate: lastRequest ?? pr.createdAt)
            }
            // GitHub clears a request when you submit a review, so a newer request is a re-request.
            if let lastRequest, lastRequest > myLastReview {
                return item(pr, kind: .reReview, reason: "Re-requested", eventDate: lastRequest)
            }
        }

        // Inline replies create COMMENTED reviews, so judge approval by the last decisive review.
        let decisive = myReviews.filter { ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains($0.state) }
        if decisive.max(by: { $0.submittedAt! < $1.submittedAt! })?.state == "APPROVED" { return nil }

        // A thread I started where I still have the last word: the author owes me an answer.
        let awaitingAuthor = threads.contains { !$0.isResolved && isMe($0.first?.author) && isMe($0.last?.author) }
        if awaitingAuthor { return nil }

        let threadReplies = threads.compactMap { t -> Date? in
            guard isMe(t.first?.author), let last = t.last, isOther(last.author), last.createdAt > myLast else { return nil }
            return last.createdAt
        }
        let prAuthor = pr.author?.login
        let prReplies = pr.comments.nodes.filter {
            isOther($0.author) && $0.author?.login.caseInsensitiveCompare(prAuthor ?? "") == .orderedSame && $0.createdAt > myLast
        }.map(\.createdAt)
        let replies = threadReplies + prReplies
        // `committedDate` can predate the push; a force-push event gives the real push time.
        let pushed = [pr.commits.nodes.last?.commit.committedDate, pr.pushEvents.nodes.last?.createdAt].compactMap { $0 }.max()
        let newCommit = pushed.flatMap { $0 > myLast ? $0 : nil }

        let reason: String
        switch (!replies.isEmpty, newCommit != nil) {
        case (true, true): reason = "Replied · new commits"
        case (true, false): reason = "Replied"
        case (false, true): reason = "New commits"
        case (false, false): return nil
        }
        let latest = (replies + [newCommit].compactMap { $0 }).max()!
        return item(pr, kind: .reReview, reason: reason, eventDate: latest)
    }

    static func classifyMine(_ pr: RawPR, me: String) -> PRItem {
        let isMe = { (a: Actor?) in a?.login.caseInsensitiveCompare(me) == .orderedSame }
        let isOther = { (a: Actor?) in a != nil && !isMe(a) && !a!.isBot }
        let hasBody = { (r: RawPR.Review) in !(r.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Inline threads: unresolved, and someone else spoke last.
        let threadEvents = pr.reviewThreads.nodes.compactMap { t -> (Date, Actor?)? in
            guard !t.isResolved, let last = t.last, isOther(last.author) else { return nil }
            return (last.createdAt, last.author)
        }

        // Conversation tab: comments and review summaries from others after my last top-level reply.
        // (Inline replies create body-less reviews, so only reviews with a body count as top-level.)
        let myLastTop = (pr.comments.nodes.filter { isMe($0.author) }.map(\.createdAt)
            + pr.reviews.nodes.filter { isMe($0.author) && hasBody($0) }.compactMap(\.submittedAt)).max() ?? .distantPast
        let commentEvents = pr.comments.nodes.filter { isOther($0.author) && $0.createdAt > myLastTop }.map { ($0.createdAt, $0.author) }
        let reviewEvents = pr.reviews.nodes.compactMap { r -> (Date, Actor?)? in
            guard isOther(r.author), r.state != "PENDING", hasBody(r), let at = r.submittedAt, at > myLastTop else { return nil }
            return (at, r.author)
        }

        let all = (threadEvents + commentEvents + reviewEvents).sorted { $0.0 > $1.0 }
        var logins = Set<String>()
        let commenters = all.compactMap(\.1).filter { logins.insert($0.login.lowercased()).inserted }.compactMap(\.avatarUrl)
        var out = item(pr, kind: .mine, unanswered: all.count, eventDate: all.first?.0 ?? .distantPast)
        out.commenters = Array(commenters.prefix(3))
        return out
    }

    private static func item(_ pr: RawPR, kind: PRItem.Kind, reason: String? = nil, unanswered: Int = 0, eventDate: Date) -> PRItem {
        let head = pr.commits.nodes.last?.commit
        return PRItem(
            id: pr.id, number: pr.number, title: pr.title, url: pr.url,
            repo: pr.repository.nameWithOwner,
            author: pr.author?.login ?? "ghost", avatarURL: pr.author?.avatarUrl,
            isDraft: pr.isDraft,
            openSince: pr.readyEvents.nodes.last?.createdAt ?? pr.createdAt,
            updatedAt: pr.updatedAt,
            kind: kind, reason: reason, unanswered: unanswered, decision: pr.reviewDecision,
            eventDate: eventDate, ownerAvatarURL: pr.repository.owner?.avatarUrl,
            checks: head?.statusCheckRollup?.state, headOid: head?.oid, hasConflicts: pr.mergeable == "CONFLICTING"
        )
    }
}

// MARK: - Formatting

enum Age {
    static func short(since d: Date, now: Date = .now) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(d)) / 60)
        let hours = minutes / 60, days = hours / 24
        if minutes < 60 { return "\(max(minutes, 1))m" }
        if hours < 24 { return "\(hours)h" }
        if days < 60 { return "\(days)d" }
        return "\(days / 30)mo"
    }

    static func long(since d: Date, now: Date = .now) -> String {
        let hours = Int(max(0, now.timeIntervalSince(d)) / 3600), days = hours / 24
        if hours < 1 { return "Open for less than an hour" }
        if days < 1 { return "Open for \(hours) hour\(hours == 1 ? "" : "s")" }
        return "Open for \(days) day\(days == 1 ? "" : "s")"
    }

    static func days(since d: Date, now: Date = .now) -> Int { Int(max(0, now.timeIntervalSince(d)) / 86_400) }
}
