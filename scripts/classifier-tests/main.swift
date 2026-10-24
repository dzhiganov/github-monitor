// Classification tests against synthetic GraphQL payloads. Run: ./scripts/test.sh
import Foundation
func d(_ t: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_000 + t * 3600)) }
func a(_ l: String) -> [String: Any] { ["login": l, "avatarUrl": "https://x/y.png", "__typename": l.hasSuffix("bot") ? "Bot" : "User"] }
// thread: (resolved, headAuthor, headT, tailAuthor, tailT, tailPending)
func pr(_ id: String, author: String = "alice", reviews: [(String, String, Double, String)] = [], comments: [(String, Double)] = [],
        threads: [(Bool, String, Double, String, Double, Bool)] = [], commit: Double = 0, forcePush: Double? = nil,
        requests: [String] = [], requestEvents: [(String, Double)] = []) -> [String: Any] {
  ["id": id, "number": 1, "title": "T \(id)", "url": "https://github.com/o/r/pull/1", "isDraft": false,
   "createdAt": d(0), "updatedAt": d(0), "reviewDecision": NSNull(), "repository": ["nameWithOwner": "o/r"], "author": a(author),
   "readyEvents": ["nodes": []],
   "requestEvents": ["nodes": requestEvents.map { ["createdAt": d($0.1), "requestedReviewer": ["login": $0.0]] }],
   "pushEvents": ["nodes": forcePush.map { [["createdAt": d($0)]] } ?? []],
   "reviewRequests": ["nodes": requests.map { ["requestedReviewer": ["login": $0]] }],
   "reviews": ["nodes": reviews.map { ["author": a($0.0), "state": $0.1, "submittedAt": d($0.2), "body": $0.3] }],
   "comments": ["nodes": comments.map { ["author": a($0.0), "createdAt": d($0.1)] }],
   "reviewThreads": ["nodes": threads.map { t -> [String: Any] in
      let head: [String: Any] = ["author": a(t.1), "createdAt": d(t.2), "state": "SUBMITTED"]
      let tail: [String: Any] = ["author": a(t.3), "createdAt": d(t.4), "state": t.5 ? "PENDING" : "SUBMITTED"]
      return ["isResolved": t.0, "head": ["nodes": [head]], "tail": ["nodes": t.2 == t.4 && t.1 == t.3 ? [head] : [head, tail]]] }],
   "commits": ["nodes": [["commit": ["committedDate": d(commit)]]]]]
}
// (name, pr, inRequestedSearch, expected)
let cases: [(String, [String: Any], Bool, String)] = [
  ("fresh request", pr("a", requests: ["me"], requestEvents: [("me", 1)]), true, "needsReview"),
  ("re-requested after review", pr("b", reviews: [("me", "COMMENTED", 2, "x")], requests: ["me"], requestEvents: [("me", 1), ("me", 5)]), true, "Re-requested"),
  ("comment only while requested (M1)", pr("b2", comments: [("me", 2)], requests: ["me"], requestEvents: [("me", 1)]), true, "needsReview"),
  ("approved", pr("c", reviews: [("me", "APPROVED", 2, "")], commit: 5), false, "hidden"),
  ("approved then inline reply (H4)", pr("c2", reviews: [("me", "APPROVED", 2, ""), ("me", "COMMENTED", 3, "")], comments: [("alice", 4)], commit: 5), false, "hidden"),
  ("waiting on author", pr("d", reviews: [("me", "CHANGES_REQUESTED", 2, "x")], threads: [(false, "me", 2, "me", 2, false), (false, "me", 2, "alice", 3, false)]), false, "hidden"),
  ("all answered", pr("e", reviews: [("me", "CHANGES_REQUESTED", 2, "x")], threads: [(false, "me", 2, "alice", 3, false), (true, "me", 2, "me", 2, false)]), false, "Replied"),
  ("author conversation reply", pr("f", reviews: [("me", "COMMENTED", 2, "x")], comments: [("me", 2), ("alice", 4)]), false, "Replied"),
  ("other reviewer +1 ignored (M4)", pr("f2", reviews: [("me", "COMMENTED", 2, "x")], comments: [("me", 2), ("bob", 4)]), false, "hidden"),
  ("bot reply ignored", pr("g", reviews: [("me", "COMMENTED", 2, "x")], comments: [("ci-bot", 4)]), false, "hidden"),
  ("new commits", pr("h", reviews: [("me", "CHANGES_REQUESTED", 2, "x")], commit: 5), false, "New commits"),
  ("old commit force-pushed (M6)", pr("h2", reviews: [("me", "CHANGES_REQUESTED", 2, "x")], commit: 1, forcePush: 6), false, "New commits"),
  ("already re-checked", pr("i", reviews: [("me", "CHANGES_REQUESTED", 2, "x"), ("me", "COMMENTED", 6, "x")], threads: [(false, "me", 2, "alice", 3, false)], commit: 4), false, "hidden"),
  ("only pending draft comment (M2)", pr("j", threads: [(false, "alice", 1, "me", 2, true)], requests: ["me"], requestEvents: [("me", 0)]), true, "needsReview"),
]
var req: [[String: Any]] = [], rev: [[String: Any]] = []
for c in cases { if c.2 { req.append(c.1) } else { rev.append(c.1) } }
let mine: [[String: Any]] = [
  pr("m1", author: "me", reviews: [("bob", "CHANGES_REQUESTED", 1, "please fix")], comments: [("bob", 2), ("me", 3), ("carol", 4), ("dep-bot", 5)],
     threads: [(false, "bob", 1, "bob", 1, false), (false, "bob", 1, "me", 2, false), (true, "bob", 1, "bob", 1, false)]),
  pr("m2", author: "me", comments: [("bob", 1), ("me", 2)]),
  // M5: top-level question from bob, then I reply to an unrelated inline thread (body-less COMMENTED review)
  pr("m3", author: "me", reviews: [("me", "COMMENTED", 3, "")], comments: [("bob", 2)], threads: [(false, "carol", 1, "me", 3, false)]),
  // M2: my pending reply doesn't count as answered
  pr("m4", author: "me", threads: [(false, "bob", 1, "me", 2, true)]),
]
let json: [String: Any] = ["data": ["viewer": ["login": "me"], "requested": ["nodes": req + [[:]]], "reviewed": ["nodes": rev], "assigned": ["nodes": []], "mine": ["nodes": mine]]]
let p = try GitHubClient.decode(try JSONSerialization.data(withJSONObject: json)).payload
let items = Dictionary(uniqueKeysWithValues: Classifier.reviewItems(p).map { ($0.id, $0) })
var fails = 0
for c in cases {
  let id = c.1["id"] as! String
  let got = items[id].map { $0.kind == .needsReview ? "needsReview" : ($0.reason ?? "?") } ?? "hidden"
  print(got == c.3 ? "PASS" : "FAIL", c.0, "->", got); if got != c.3 { fails += 1 }
}
let m = Dictionary(uniqueKeysWithValues: Classifier.myItems(p).map { ($0.id, $0.unanswered) })
for (id, exp) in [("m1", 2), ("m2", 0), ("m3", 1), ("m4", 1)] { let ok = m[id] == exp; print(ok ? "PASS" : "FAIL", "mine \(id) unanswered", m[id]!, "expected", exp); if !ok { fails += 1 } }
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
