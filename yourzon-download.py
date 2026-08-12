#!/usr/bin/env python3
"""
YOURZON — Automated Marketing Post Downloader

Full browser automation for downloading and organizing marketing posts
from the YOURZON platform.

Workflow (mirrors the manual process):
  1. Launch Chrome with saved profile (persistent login)
  2. Navigate to YOURZON platform
  3. Scroll through the post feed
  4. Detect user's own posts and download them (posts with Remove/↓ controls)
  5. Create a dated Desktop folder (פוסטים יורזון יום {day} {date})
  6. Move downloaded images into the folder
  7. Open the folder in File Explorer

Modes:
  auto       Full browser automation — scroll, detect, download, organize
  browse     Open YOURZON for manual browsing, then auto-organize downloads
  organize   Organize recently downloaded files only (no browser)

Requirements:
  pip install playwright
  playwright install chromium

Usage:
  python yourzon-download.py                     # Full automation (default)
  python yourzon-download.py browse              # Manual browse, auto-organize
  python yourzon-download.py organize            # Just organize recent downloads
  python yourzon-download.py auto --dry-run      # Preview without moving
  python yourzon-download.py organize -m 30      # Wider time window
  python yourzon-download.py auto --url "https://www.yourzon.com/?campaignid=..."
"""

import argparse
import json
import os
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path

YOURZON_URL = "https://www.yourzon.com"

HEBREW_DAYS = {
    0: "שני",
    1: "שלישי",
    2: "רביעי",
    3: "חמישי",
    4: "שישי",
    5: "שבת",
    6: "ראשון",
}

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg"}

CONFIG_PATH = Path.home() / ".yourzon-downloader.json"

DEFAULT_CONFIG = {
    "yourzon_url": YOURZON_URL,
    "scroll_pause_sec": 1.5,
    "max_scrolls": 80,
    "download_wait_sec": 5,
    "selectors": {
        "own_post_markers": [
            "text=Remove",
            "text=הסרה",
            "[data-action='remove']",
        ],
        "download_triggers": [
            "[data-action='download']",
            "a[download]",
            "[aria-label*='download']",
            "[aria-label*='הורדה']",
            "button:has-text('↓')",
        ],
        "post_blocks": [
            "article",
            "[class*='post']",
            "[class*='card']",
            "[role='article']",
        ],
    },
}


def load_config():
    config = DEFAULT_CONFIG.copy()
    if CONFIG_PATH.exists():
        try:
            with open(CONFIG_PATH, encoding="utf-8") as f:
                user = json.load(f)
            config.update(user)
        except (json.JSONDecodeError, OSError):
            pass
    return config


def save_default_config():
    if not CONFIG_PATH.exists():
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(DEFAULT_CONFIG, f, indent=2, ensure_ascii=False)


def get_desktop() -> Path:
    desktop = Path.home() / "Desktop"
    if desktop.exists():
        return desktop
    if sys.platform == "win32":
        return Path(os.environ.get("USERPROFILE", str(Path.home()))) / "Desktop"
    xdg = os.environ.get("XDG_DESKTOP_DIR")
    return Path(xdg) if xdg else desktop


def get_downloads() -> Path:
    downloads = Path.home() / "Downloads"
    if downloads.exists():
        return downloads
    if sys.platform == "win32":
        return Path(os.environ.get("USERPROFILE", str(Path.home()))) / "Downloads"
    xdg = os.environ.get("XDG_DOWNLOAD_DIR")
    return Path(xdg) if xdg else downloads


def chrome_profile_dir() -> Path:
    if sys.platform == "win32":
        return Path(os.environ.get("LOCALAPPDATA", "")) / "Google" / "Chrome" / "User Data"
    elif sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Google" / "Chrome"
    return Path.home() / ".config" / "google-chrome"


def dated_folder_name(custom=None):
    if custom:
        return custom
    now = datetime.now()
    return f"פוסטים יורזון יום {HEBREW_DAYS[now.weekday()]} {now.day}"


def find_recent_images(directory, since_ts=None, minutes=10):
    if since_ts is None:
        since_ts = time.time() - minutes * 60
    results = []
    if not directory.exists():
        return results
    for f in directory.iterdir():
        if f.is_file() and f.suffix.lower() in IMAGE_EXTENSIONS and f.stat().st_mtime >= since_ts:
            results.append(f)
    results.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return results


def move_files(files, dest_dir):
    dest_dir.mkdir(parents=True, exist_ok=True)
    moved = []
    for f in files:
        target = dest_dir / f.name
        if target.exists():
            stem, ext = f.stem, f.suffix
            n = 1
            while target.exists():
                target = dest_dir / f"{stem}_{n}{ext}"
                n += 1
        shutil.move(str(f), str(target))
        moved.append((f, target))
    return moved


def open_folder(path):
    if sys.platform == "win32":
        os.startfile(str(path))
    elif sys.platform == "darwin":
        os.system(f'open "{path}"')
    else:
        os.system(f'xdg-open "{path}" 2>/dev/null &')


def print_files(files, label="Found"):
    total = sum(f.stat().st_size for f in files)
    print(f"\n{label} {len(files)} image(s) ({total / 1048576:.2f} MB):")
    for f in files:
        sz = f.stat().st_size / 1048576
        ts = datetime.fromtimestamp(f.stat().st_mtime).strftime("%H:%M:%S")
        print(f"  {f.name}  ({sz:.2f} MB, {ts})")


def organize_files(files, desktop_dir, folder_name, dry_run=False):
    folder = desktop_dir / folder_name
    if dry_run:
        print(f"\n[DRY RUN] Would create folder: {folder}")
        print(f"[DRY RUN] Would move {len(files)} file(s)")
        return
    moved = move_files(files, folder)
    print(f"\nMoved {len(moved)} file(s) to: {folder}")
    for src, dst in moved:
        print(f"  {dst.name}")
    open_folder(folder)
    print("\nDone!")


# ---------------------------------------------------------------------------
# Mode: organize — just move recent downloads to a dated folder
# ---------------------------------------------------------------------------

def cmd_organize(args):
    downloads = Path(args.downloads_dir) if args.downloads_dir else get_downloads()
    desktop = Path(args.desktop_dir) if args.desktop_dir else get_desktop()

    print(f"Scanning: {downloads}")
    print(f"Looking for images from the last {args.minutes} minutes...")

    files = find_recent_images(downloads, minutes=args.minutes)
    if not files:
        print("No recent image files found.")
        print(f"Tip: try a wider window with  -m {args.minutes * 3}")
        return

    print_files(files)
    organize_files(files, desktop, dated_folder_name(args.folder_name), args.dry_run)


# ---------------------------------------------------------------------------
# Mode: browse — open YOURZON, let user download manually, then organize
# ---------------------------------------------------------------------------

def cmd_browse(args):
    downloads = Path(args.downloads_dir) if args.downloads_dir else get_downloads()
    desktop = Path(args.desktop_dir) if args.desktop_dir else get_desktop()
    config = load_config()
    url = args.url or config["yourzon_url"]

    stamp = time.time()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        import webbrowser
        print(f"Opening YOURZON: {url}")
        webbrowser.open(url)
        input("\nDownload the posts you need, then press Enter...")
        files = find_recent_images(downloads, since_ts=stamp)
        if not files:
            files = find_recent_images(downloads, minutes=15)
        if not files:
            print("No new images found.")
            return
        print_files(files, "Detected")
        organize_files(files, desktop, dated_folder_name(args.folder_name), args.dry_run)
        return

    with sync_playwright() as pw:
        profile = chrome_profile_dir()
        use_profile = profile.exists() and not args.no_profile

        print("=== YOURZON Post Downloader — Browse Mode ===\n")

        if use_profile:
            print(f"Using Chrome profile: {profile}")
            ctx = pw.chromium.launch_persistent_context(
                str(profile),
                channel="chrome",
                headless=False,
                accept_downloads=True,
                viewport={"width": 1280, "height": 900},
                args=["--disable-blink-features=AutomationControlled"],
            )
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
        else:
            browser = pw.chromium.launch(channel="chrome", headless=False)
            ctx = browser.new_context(
                accept_downloads=True,
                viewport={"width": 1280, "height": 900},
            )
            page = ctx.new_page()

        print(f"Navigating to {url} ...")
        page.goto(url, wait_until="domcontentloaded", timeout=30_000)

        try:
            page.wait_for_load_state("networkidle", timeout=15_000)
        except Exception:
            pass

        print("\nBrowse the feed and download the posts you need.")
        input("Press Enter when you're done downloading...")

        ctx.close()
        if not use_profile:
            browser.close()

    files = find_recent_images(downloads, since_ts=stamp)
    if not files:
        files = find_recent_images(downloads, minutes=15)
    if not files:
        print("No new images detected.")
        return

    print_files(files, "Detected")
    organize_files(files, desktop, dated_folder_name(args.folder_name), args.dry_run)


# ---------------------------------------------------------------------------
# Mode: auto — full browser automation
# ---------------------------------------------------------------------------

def cmd_auto(args):
    try:
        from playwright.sync_api import sync_playwright
        from playwright.sync_api import TimeoutError as PwTimeout
    except ImportError:
        print("Playwright is required for auto mode.")
        print("  pip install playwright && playwright install chromium")
        print("\nFalling back to browse mode...")
        cmd_browse(args)
        return

    downloads_dir = Path(args.downloads_dir) if args.downloads_dir else get_downloads()
    desktop_dir = Path(args.desktop_dir) if args.desktop_dir else get_desktop()
    config = load_config()
    save_default_config()
    url = args.url or config["yourzon_url"]
    selectors = config["selectors"]

    stamp = time.time()
    downloaded_count = 0

    print("=== YOURZON Post Downloader — Auto Mode ===\n")

    with sync_playwright() as pw:
        profile = chrome_profile_dir()
        use_profile = profile.exists() and not args.no_profile

        if use_profile:
            print(f"Using Chrome profile: {profile}")
            ctx = pw.chromium.launch_persistent_context(
                str(profile),
                channel="chrome",
                headless=False,
                accept_downloads=True,
                viewport={"width": 1280, "height": 900},
                args=["--disable-blink-features=AutomationControlled"],
            )
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
        else:
            browser = pw.chromium.launch(channel="chrome", headless=False)
            ctx = browser.new_context(
                accept_downloads=True,
                viewport={"width": 1280, "height": 900},
            )
            page = ctx.new_page()

        # Step 1 — Navigate to YOURZON
        print(f"Step 1: Opening YOURZON ({url})...")
        page.goto(url, wait_until="domcontentloaded", timeout=30_000)
        try:
            page.wait_for_load_state("networkidle", timeout=15_000)
        except Exception:
            pass

        # Step 2 — Handle login if needed
        print("Step 2: Checking login state...")
        try:
            login_visible = page.locator("text=Log in").or_(
                page.locator("text=Sign up")
            ).first.is_visible(timeout=3_000)
        except Exception:
            login_visible = False

        if login_visible:
            print("  Login page detected — please log in manually.")
            print("  Waiting for authentication...")
            try:
                page.wait_for_function(
                    """() => !document.body.innerText.includes('Log in')
                          || !document.body.innerText.includes('Sign up')""",
                    timeout=120_000,
                )
            except PwTimeout:
                print("  Login timeout — continuing anyway.")
            try:
                page.wait_for_load_state("networkidle", timeout=10_000)
            except Exception:
                pass
            print("  Logged in.")
        else:
            print("  Already authenticated.")

        # Step 3 — Scroll and download
        print("Step 3: Scrolling through the feed and downloading posts...\n")

        max_scrolls = config.get("max_scrolls", 80)
        pause = config.get("scroll_pause_sec", 1.5)
        dl_wait = config.get("download_wait_sec", 5)
        prev_height = 0
        stale_rounds = 0
        clicked_set = set()

        for scroll_i in range(1, max_scrolls + 1):
            # Find post containers on the visible page
            for sel in selectors["post_blocks"]:
                try:
                    posts = page.locator(sel)
                    if posts.count() == 0:
                        continue

                    for pi in range(posts.count()):
                        post = posts.nth(pi)
                        if not post.is_visible():
                            continue

                        # Check if this is the user's own post (has Remove control)
                        is_own = False
                        for marker_sel in selectors["own_post_markers"]:
                            try:
                                if post.locator(marker_sel).count() > 0:
                                    is_own = True
                                    break
                            except Exception:
                                continue

                        if not is_own:
                            continue

                        # Look for the download button inside this post
                        for dl_sel in selectors["download_triggers"]:
                            try:
                                dl_btns = post.locator(dl_sel)
                                for bi in range(dl_btns.count()):
                                    btn = dl_btns.nth(bi)
                                    if not btn.is_visible():
                                        continue

                                    bbox = btn.bounding_box()
                                    if not bbox:
                                        continue
                                    key = (round(bbox["x"]), round(bbox["y"]))
                                    if key in clicked_set:
                                        continue
                                    clicked_set.add(key)

                                    try:
                                        with page.expect_download(timeout=dl_wait * 1000) as dl_info:
                                            btn.click()
                                        dl = dl_info.value
                                        save_to = downloads_dir / dl.suggested_filename
                                        dl.save_as(str(save_to))
                                        downloaded_count += 1
                                        print(f"  ↓ Downloaded: {dl.suggested_filename}")
                                    except PwTimeout:
                                        btn.click()
                                        time.sleep(2)
                                        new = find_recent_images(downloads_dir, since_ts=stamp)
                                        if len(new) > downloaded_count:
                                            downloaded_count = len(new)
                                            print(f"  ↓ Downloaded (via browser): {new[0].name}")
                            except Exception:
                                continue
                except Exception:
                    continue

            # Scroll down one viewport
            page.evaluate("window.scrollBy(0, window.innerHeight * 0.8)")
            time.sleep(pause)

            cur_height = page.evaluate("document.documentElement.scrollHeight")
            if cur_height == prev_height:
                stale_rounds += 1
                if stale_rounds >= 5:
                    print(f"\n  Reached end of feed after {scroll_i} scrolls.")
                    break
            else:
                stale_rounds = 0
            prev_height = cur_height

            if scroll_i % 10 == 0:
                progress = find_recent_images(downloads_dir, since_ts=stamp)
                print(f"  ... scrolled {scroll_i}/{max_scrolls}, {len(progress)} file(s) so far")

        # If nothing was auto-detected, offer manual fallback
        if downloaded_count == 0:
            check = find_recent_images(downloads_dir, since_ts=stamp)
            if not check:
                print("\n  No downloads detected automatically.")
                print("  The feed selectors may need tuning — check ~/.yourzon-downloader.json")
                print("  Switching to manual mode: browse and download, then press Enter.")
                input("  Press Enter when done...")

        ctx.close()
        if not use_profile:
            browser.close()

    # Step 4 — Collect downloaded files
    print("\nStep 4: Collecting downloads...")
    files = find_recent_images(downloads_dir, since_ts=stamp)
    if not files:
        files = find_recent_images(downloads_dir, minutes=15)
    if not files:
        print("No downloaded images found.")
        return

    print_files(files, "Downloaded")

    # Step 5 — Organize into dated folder
    print(f"\nStep 5: Organizing files...")
    organize_files(files, desktop_dir, dated_folder_name(args.folder_name), args.dry_run)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="YOURZON Marketing Post Downloader — Full Browser Automation",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  %(prog)s                           Full auto: scroll, download, organize
  %(prog)s browse                    Open YOURZON, browse manually, auto-organize
  %(prog)s organize                  Just organize recent downloads
  %(prog)s auto --url "https://..."  Full auto with custom YOURZON URL
  %(prog)s auto --dry-run            Preview without moving files
  %(prog)s organize -m 30            Widen time window to 30 minutes

Config: ~/.yourzon-downloader.json (auto-created on first run)
  Customize CSS selectors for post detection and download buttons.
""",
    )

    sub = parser.add_subparsers(dest="mode")

    # --- auto ---
    p_auto = sub.add_parser("auto", help="Full browser automation (default)")
    p_auto.add_argument("--url", help="YOURZON URL (overrides config)")
    p_auto.add_argument("--no-profile", action="store_true",
                        help="Don't use saved Chrome profile (fresh session)")
    p_auto.add_argument("--folder-name", help="Custom destination folder name")
    p_auto.add_argument("--downloads-dir", help="Custom downloads directory")
    p_auto.add_argument("--desktop-dir", help="Custom desktop directory")
    p_auto.add_argument("--dry-run", action="store_true",
                        help="Preview without moving files")

    # --- browse ---
    p_browse = sub.add_parser("browse",
                              help="Open YOURZON for manual browsing, then organize")
    p_browse.add_argument("--url", help="YOURZON URL")
    p_browse.add_argument("--no-profile", action="store_true")
    p_browse.add_argument("--folder-name", help="Custom folder name")
    p_browse.add_argument("--downloads-dir")
    p_browse.add_argument("--desktop-dir")
    p_browse.add_argument("--dry-run", action="store_true")

    # --- organize ---
    p_org = sub.add_parser("organize",
                           help="Organize recently downloaded files (no browser)")
    p_org.add_argument("-m", "--minutes", type=int, default=10,
                       help="Time window in minutes (default: 10)")
    p_org.add_argument("--folder-name", help="Custom folder name")
    p_org.add_argument("--downloads-dir")
    p_org.add_argument("--desktop-dir")
    p_org.add_argument("--dry-run", action="store_true")

    args = parser.parse_args()

    if args.mode is None or args.mode == "auto":
        if not hasattr(args, "url"):
            args.url = None
            args.no_profile = False
            args.folder_name = None
            args.downloads_dir = None
            args.desktop_dir = None
            args.dry_run = False
        cmd_auto(args)
    elif args.mode == "browse":
        cmd_browse(args)
    elif args.mode == "organize":
        cmd_organize(args)


if __name__ == "__main__":
    main()
