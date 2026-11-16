#!/usr/bin/env python3
"""
Craigslist Albuquerque job watcher.
Runs every 30 min via cron. Checks labor gigs and domestic gigs for new posts
matching skills: tree removal, yard work, hauling, handyman, electrical, plumbing.
Fires a macOS notification and logs every new match.
"""

import json
import os
import subprocess
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

BASE_DIR = Path.home() / "Code" / "craigslist_watcher"
SEEN_FILE = BASE_DIR / "seen_posts.json"
LOG_FILE  = BASE_DIR / "matches.log"

FEEDS = [
    "https://albuquerque.craigslist.org/search/lbg?format=rss",  # labor gigs
    "https://albuquerque.craigslist.org/search/dmg?format=rss",  # domestic gigs
    "https://albuquerque.craigslist.org/search/hss?format=rss",  # household services
]

KEYWORDS = [
    # tree work
    "tree", "trees", "trim", "trimming", "prune", "pruning",
    "branch", "branches", "stump", "cottonwood", "pine", "elm",
    # yard
    "yard", "lawn", "mow", "mowing", "weed", "weeds",
    "shrub", "shrubs", "leaf", "leaves", "grass", "garden",
    # hauling / junk
    "haul", "hauling", "junk", "removal", "debris",
    "cleanout", "clean out", "cleanup", "clean up", "dump",
    "trailer", "truck and trailer",
    # moving
    "mover", "movers", "moving", "furniture", "unload", "load",
    # handyman
    "handyman", "handy man", "odd job", "odd-job", "assemble",
    "assembly", "mount", "mounting", "install", "repair",
    # electrical
    "electrical", "outlet", "switch", "light fixture", "ceiling fan", "wiring",
    # plumbing
    "plumbing", "toilet", "faucet", "pipe", "sink", "water line",
    # general
    "helper", "labor", "laborer", "general labor", "task", "tasks",
]

EXCLUDE = [
    "research study", "clinical trial", "uber eats", "doordash",
    "lyft", "online survey", "paid survey", "sperm donor",
    "focus group", "amazon mturk", "mechanical turk",
    "ai training", "train ai", "test ai",
    "delivery driver", "food delivery",
]


def load_seen():
    if SEEN_FILE.exists():
        try:
            return json.loads(SEEN_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_seen(seen):
    SEEN_FILE.write_text(json.dumps(seen, indent=2))


def notify(title, body):
    safe_title = title.replace('"', "'")
    safe_body  = body.replace('"', "'")
    script = f'display notification "{safe_body}" with title "{safe_title}" sound name "Glass"'
    subprocess.run(["osascript", "-e", script], capture_output=True)


def log(text):
    with open(LOG_FILE, "a") as f:
        f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M')} | {text}\n")


def fetch_feed(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.read()
    except Exception as e:
        log(f"ERROR fetching {url}: {e}")
        return None


def parse_feed(xml_bytes):
    items = []
    try:
        root = ET.fromstring(xml_bytes)
        for item in root.iter("item"):
            title = (item.findtext("title") or "").strip()
            link  = (item.findtext("link")  or "").strip()
            desc  = (item.findtext("description") or "").strip()
            date  = (item.findtext("pubDate") or "").strip()
            if link:
                items.append({"title": title, "link": link, "desc": desc, "date": date})
    except Exception as e:
        log(f"ERROR parsing feed: {e}")
    return items


def is_match(item):
    text = (item["title"] + " " + item["desc"]).lower()
    for ex in EXCLUDE:
        if ex in text:
            return False
    for kw in KEYWORDS:
        if kw in text:
            return True
    return False


def main():
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    seen = load_seen()
    new_matches = []

    for url in FEEDS:
        xml_bytes = fetch_feed(url)
        if not xml_bytes:
            continue
        for item in parse_feed(xml_bytes):
            link = item["link"]
            if link in seen:
                continue
            seen[link] = datetime.now().isoformat()
            if is_match(item):
                new_matches.append(item)
                log(f"MATCH | {item['title']} | {link}")

    save_seen(seen)

    for item in new_matches:
        notify("New CL Job", item["title"][:80])
        print(f"\nNEW MATCH: {item['title']}")
        print(f"  {item['link']}")

    if not new_matches:
        print(f"{datetime.now().strftime('%H:%M')} — checked, no new matches")
    else:
        print(f"\n{len(new_matches)} new match(es) found.")


if __name__ == "__main__":
    main()
