// Renders docs/*.png from mock data. Run: ./scripts/screenshots.sh
import SwiftUI

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let avatarDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ghm-avatars")
try? FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)

/// Generates a colored initials avatar on disk so AsyncImage can load it via file://.
func avatar(_ name: String, _ hue: CGFloat) -> URL {
    let px = 128
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: px, height: px).fill()
    let text = String(name.prefix(1)).uppercased() as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 60, weight: .semibold), .foregroundColor: NSColor.white]
    let size = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (CGFloat(px) - size.width) / 2, y: (CGFloat(px) - size.height) / 2), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    let url = avatarDir.appendingPathComponent("\(name).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

func item(_ id: String, _ title: String, repo: String, number: Int, author: String, hue: CGFloat = 0.6, days: Double,
          kind: PRItem.Kind, reason: String? = nil, unanswered: Int = 0, draft: Bool = false, decision: String? = nil) -> PRItem {
    PRItem(id: id, number: number, title: title, url: URL(string: "https://github.com")!, repo: repo, author: author,
           avatarURL: avatar(author, hue), isDraft: draft, openSince: .now.addingTimeInterval(-days * 86400),
           updatedAt: .now.addingTimeInterval(-days * 3600), kind: kind, reason: reason, unanswered: unanswered, decision: decision)
}

/// Draws the panel with rounded corners and a soft shadow on a transparent canvas.
func frame(_ rep: NSBitmapImageRep, dark: Bool) -> Data {
    let pad = 64.0, w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
    let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w + pad * 2), pixelsHigh: Int(h + pad * 2), bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    let rect = NSRect(x: pad, y: pad, width: w, height: h)
    let path = NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.22)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    path.addClip()
    rep.draw(in: rect)
    NSColor.white.withAlphaComponent(dark ? 0.12 : 0).setStroke()
    path.lineWidth = 2
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return canvas.representation(using: .png, properties: [:])!
}

MainActor.assumeIsolated {
    let store = Store()
    store.loadPreview(review: [
        item("1", "Add retry with exponential backoff to webhook dispatcher", repo: "acme/platform", number: 2481, author: "sarah", hue: 0.58, days: 0.2, kind: .needsReview),
        item("2", "Migrate billing service to the new pricing tables", repo: "acme/billing", number: 913, author: "marco", hue: 0.08, days: 9, kind: .needsReview),
        item("3", "Fix race condition in session refresh", repo: "acme/web", number: 3307, author: "jun", hue: 0.33, days: 23, kind: .needsReview),
        item("4", "Refactor feature flag evaluation into its own module", repo: "acme/platform", number: 2455, author: "priya", hue: 0.85, days: 3, kind: .reReview, reason: "Replied · new commits"),
        item("5", "Bump Node to 22 LTS", repo: "acme/infra", number: 418, author: "tom", hue: 0.15, days: 1, kind: .reReview, reason: "Re-requested"),
    ], mine: [
        item("6", "Search: debounce queries and cancel stale requests", repo: "acme/web", number: 3312, author: "me", days: 4, kind: .mine, unanswered: 3, decision: "CHANGES_REQUESTED"),
        item("7", "Add OpenTelemetry tracing to the API gateway", repo: "acme/platform", number: 2490, author: "me", days: 1, kind: .mine, decision: "APPROVED"),
        item("8", "Dark mode for the settings page", repo: "acme/web", number: 3290, author: "me", days: 15, kind: .mine, unanswered: 1),
        item("9", "WIP: offline sync prototype", repo: "acme/mobile", number: 77, author: "me", days: 2, kind: .mine, draft: true),
    ].map { i in
        var i = i
        if i.id == "6" { i.commenters = [avatar("sarah", 0.58), avatar("marco", 0.08), avatar("jun", 0.33)] }
        if i.id == "8" { i.commenters = [avatar("priya", 0.85)] }
        return i
    }, fresh: ["1|new", "4|rr", "6|mine"])
    store.showDrafts = true
    store.grouping = .none
    store.reviewNewestFirst = true
    store.mineNewestFirst = true

    for (name, tab, dark) in [("review-light", Tab.review, false), ("review-dark", Tab.review, true),
                              ("mine-light", Tab.mine, false), ("mine-dark", Tab.mine, true)] {
        let view = ContentView(tab: tab).environment(store)
            .background(dark ? Color(white: 0.15) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 1.5) // let avatars load
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try! frame(rep, dark: dark).write(to: out.appendingPathComponent("\(name).png"))
    }
    print("Wrote screenshots to \(out.path)")
}
