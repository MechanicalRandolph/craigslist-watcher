# Craigslist Job Watcher — Albuquerque

> **Status: not working.** Craigslist blocks automated requests to its RSS
> feeds (HTTP 403), so this script currently cannot fetch any posts. Every run
> reports `BLOCKED` and exits with an error. The setup steps below are kept for
> reference, but installing the cron job will not find any listings.

Monitors Craigslist labor and domestic gig listings every 30 minutes and fires a macOS notification the moment a new matching post appears. No paid services, no external dependencies, no browser required.

Built for catching yard work, tree removal, hauling, handyman, electrical, and plumbing gigs before anyone else responds.

---

## How it works

- Fetches the Craigslist RSS feeds for **labor gigs** and **domestic gigs**
- Filters each post against a keyword list (see [Customizing](#customizing-keywords))
- Tracks every seen post in `seen_posts.json` so you only get notified about genuinely new listings
- Fires a macOS notification with the job title and logs the match to `matches.log`
- Runs automatically via cron — no action needed after setup

---

## Requirements

- macOS (uses `osascript` for notifications)
- Swift (included with Xcode Command Line Tools)
- No pip installs, no Node, no external packages

To install Command Line Tools if you don't have them:
```
xcode-select --install
```

---

## Setup

**1. Clone the repo**
```
git clone https://github.com/MechanicalRandolph/craigslist-watcher.git
cd craigslist-watcher
```

**2. Test the script once**
```
swift watcher.swift
```
You should see either `no new matches` (all current posts marked as seen) or a list of matching jobs with their links.

**3. Install the cron job (runs every 30 minutes)**
```
(crontab -l 2>/dev/null; echo "*/30 * * * * /usr/bin/swift $(pwd)/watcher.swift >> $(pwd)/cron.log 2>&1") | crontab -
```

**4. Confirm it's installed**
```
crontab -l
```

That's it. Leave it running. You'll get a macOS notification whenever a new matching post appears.

---

## Files

| File | Purpose |
|------|---------|
| `watcher.swift` | Main script — fetch, filter, notify |
| `watcher.py` | Python fallback (requires `playwright` if Craigslist blocks urllib) |
| `seen_posts.json` | Auto-generated — tracks posts already seen (do not edit) |
| `matches.log` | Auto-generated — log of every matched post with timestamp |
| `cron.log` | Auto-generated — cron output for debugging |

`seen_posts.json`, `matches.log`, and `cron.log` are in `.gitignore` and will not be committed.

---

## Customizing keywords

Open `watcher.swift` and find the `keywords` array near the top. Add or remove terms to match the kind of work you want. Keywords are matched case-insensitively against the post title and description.

```swift
let keywords: [String] = [
    "tree", "yard", "haul", "handyman", "plumbing", ...
]
```

To exclude spam or irrelevant posts, edit the `excludes` array:

```swift
let excludes: [String] = [
    "research study", "uber eats", ...
]
```

---

## Changing the city

The script watches Albuquerque by default. To switch cities, replace `albuquerque` in the feed URLs with your city's Craigslist subdomain:

```swift
let feeds = [
    "https://albuquerque.craigslist.org/search/lbg?format=rss",
    "https://albuquerque.craigslist.org/search/dmg?format=rss",
]
```

Find your city's subdomain at [craigslist.org](https://www.craigslist.org).

---

## Changing the check interval

Edit the cron entry to run more or less frequently. The number after `*/` is the interval in minutes:

```
*/30 * * * * ...   ← every 30 minutes
*/15 * * * * ...   ← every 15 minutes
*/60 * * * * ...   ← every hour
```

Edit with:
```
crontab -e
```

---

## Stopping it

To remove the cron job:
```
crontab -r
```
