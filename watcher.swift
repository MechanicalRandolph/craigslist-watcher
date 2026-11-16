#!/usr/bin/env swift
// Craigslist Albuquerque job watcher
// Run via cron every 30 min — fires macOS notification for new matching posts
// No external dependencies. Uses Apple CFNetwork (same fingerprint as Safari).

import Foundation

// MARK: - Config

let baseDir  = FileManager.default.homeDirectoryForCurrentUser
                 .appendingPathComponent("Code/craigslist_watcher")
let seenFile = baseDir.appendingPathComponent("seen_posts.json")
let logFile  = baseDir.appendingPathComponent("matches.log")

// Craigslist blocks automated requests to these feeds (HTTP 403), so a run
// currently reports BLOCKED rather than finding posts.
let feeds = [
    "https://albuquerque.craigslist.org/search/lbg?format=rss",  // labor gigs
    "https://albuquerque.craigslist.org/search/dmg?format=rss",  // domestic gigs
]

let keywords: [String] = [
    // tree / yard (physical gigs)
    "tree", "trees", "trim", "trimming", "prune", "pruning",
    "branch", "branches", "cottonwood", "stump",
    "yard", "lawn", "mow", "mowing", "weed", "weeds",
    "shrub", "shrubs", "leaf", "leaves", "grass",
    // hauling / junk
    "haul", "hauling", "junk", "removal", "debris",
    "cleanout", "clean out", "cleanup", "clean up", "dump", "trailer",
    // moving
    "mover", "movers", "moving", "furniture", "unload", "load boxes",
    // handyman / trades
    "handyman", "odd job", "odd-job", "assemble", "assembly",
    "mount", "mounting", "install", "repair",
    "electrical", "outlet", "switch", "light fixture", "ceiling fan",
    "plumbing", "toilet", "faucet", "sink", "water line",
    // general labor
    "helper", "labor", "laborer", "general labor", "task", "tasks",
    // CAD & drafting (Randolph's core skills — remote-compatible)
    "cad", "drafting", "drafter", "solidworks", "autocad", "creo",
    "mechanical design", "technical drawing", "technical documentation",
    "gd&t", "geometric", "tolerancing", "design review", "drawing review",
    "assembly drawing", "detail drawing", "engineering drawing",
    // engineering / analysis
    "mechanical engineer", "design engineer", "r&d", "research and development",
    "ansys", "matlab", "finite element", "structural analysis", "thermal analysis",
    "prototype", "testing", "product development",
    // documentation & coordination (remote-compatible)
    "technical writer", "technical writing", "documentation specialist",
    "proposal writer", "proposal writing", "specifications", "spec writing",
    "project coordinator", "project management", "engineering coordinator",
    // design-adjacent (landscape, architecture, construction)
    "landscape design", "landscape drafter", "site plan",
    "architectural drafting", "construction document",
    "revit", "sketchup", "autocad civil",
    // remote/flexible signal words
    "remote", "work from home", "wfh", "telecommute", "flexible hours",
    "part time", "part-time", "nights", "weekends", "freelance", "contract",
]

let excludes: [String] = [
    "research study", "clinical trial", "uber eats", "doordash", "lyft",
    "online survey", "paid survey", "sperm donor", "focus group",
    "food delivery", "deliver food", "train ai", "test ai",
]

// MARK: - Logging

func appendLog(_ msg: String) {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm"
    let line = "\(fmt.string(from: Date())) | \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: logFile.path),
       let handle = try? FileHandle(forWritingTo: logFile) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        try? data.write(to: logFile)
    }
}

// MARK: - macOS Notification

func notify(title: String, body: String) {
    let safe = { (s: String) in s.replacingOccurrences(of: "\"", with: "'") }
    let script = "display notification \"\(safe(body))\" with title \"\(safe(title))\" sound name \"Glass\""
    let p = Process()
    p.launchPath = "/usr/bin/osascript"
    p.arguments  = ["-e", script]
    try? p.run(); p.waitUntilExit()
}

// MARK: - Persistence

func loadSeen() -> [String: String] {
    guard let data = try? Data(contentsOf: seenFile),
          let dict = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return dict
}

func saveSeen(_ seen: [String: String]) {
    if let data = try? JSONEncoder().encode(seen) {
        try? data.write(to: seenFile)
    }
}

// MARK: - RSS Parsing

class FeedParser: NSObject, XMLParserDelegate {
    var items: [[String: String]] = []
    private var cur:  [String: String] = [:]
    private var tag  = ""
    private var text = ""
    private let watchedTags: Set<String> = ["title", "link", "description", "pubDate"]

    func parser(_ p: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if el == "item" { cur = [:] }
        tag = el; text = ""
    }
    func parser(_ p: XMLParser, foundCharacters s: String) {
        if watchedTags.contains(tag) { text += s }
    }
    func parser(_ p: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        if watchedTags.contains(el) {
            cur[el] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if el == "item", let link = cur["link"], !link.isEmpty {
            items.append(cur)
        }
    }
}

var blockedFeeds = 0

func fetchFeed(_ urlStr: String) -> [[String: String]] {
    guard let url = URL(string: urlStr) else { return [] }
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
                 forHTTPHeaderField: "User-Agent")
    req.setValue("application/rss+xml, application/xml;q=0.9, */*;q=0.8",
                 forHTTPHeaderField: "Accept")
    req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    req.setValue("https://albuquerque.craigslist.org/", forHTTPHeaderField: "Referer")

    var result: [[String: String]] = []
    let sema = DispatchSemaphore(value: 0)

    URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sema.signal() }
        guard let data = data else {
            appendLog("ERROR \(urlStr): \(err?.localizedDescription ?? "no data")")
            return
        }
        // Check if blocked
        if let preview = String(data: data.prefix(200), encoding: .utf8),
           preview.contains("blocked") {
            appendLog("BLOCKED by Craigslist on \(urlStr)")
            blockedFeeds += 1
            return
        }
        let p = FeedParser()
        let xp = XMLParser(data: data)
        xp.delegate = p; xp.parse()
        result = p.items
    }.resume()

    sema.wait()
    return result
}

// MARK: - Matching

func isMatch(_ item: [String: String]) -> Bool {
    let text = ((item["title"] ?? "") + " " + (item["description"] ?? "")).lowercased()
    for ex in excludes { if text.contains(ex) { return false } }
    for kw in keywords { if text.contains(kw) { return true } }
    return false
}

// MARK: - Main

try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

var seen     = loadSeen()
var matched: [[String: String]] = []

for feed in feeds {
    for item in fetchFeed(feed) {
        guard let link = item["link"], !link.isEmpty else { continue }
        guard seen[link] == nil else { continue }
        seen[link] = ISO8601DateFormatter().string(from: Date())
        if isMatch(item) {
            matched.append(item)
            appendLog("MATCH | \(item["title"] ?? "(no title)") | \(link)")
        }
    }
}

saveSeen(seen)

for item in matched {
    let title = item["title"] ?? "New job"
    notify(title: "New CL Job 🔔", body: String(title.prefix(80)))
    print("NEW: \(title)")
    print("  \(item["link"] ?? "")\n")
}

let fmt = DateFormatter()
fmt.dateStyle = .none; fmt.timeStyle = .short
let ts = fmt.string(from: Date())
if blockedFeeds > 0 {
    print("\(ts) — BLOCKED by Craigslist on \(blockedFeeds) of \(feeds.count) feeds; nothing was checked")
    if blockedFeeds == feeds.count { exit(1) }
}
print(matched.isEmpty ? "\(ts) — no new matches" : "\(ts) — \(matched.count) new match(es)")
