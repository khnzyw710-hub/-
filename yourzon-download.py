#!/usr/bin/env python3
"""
YOURZON Promotional Content Downloader

Automates downloading promotional images/posts from the YOURZON platform
and organizing them in dated folders on the Desktop.

Workflow (reconstructed from screen recording):
1. Open YOURZON website
2. Download promotional images/posts
3. Create a dated folder on Desktop (e.g., "פוסטים יורזון יום רביעי 5")
4. Move downloaded files to the dated folder
"""

import os
import sys
import shutil
import argparse
from datetime import datetime
from pathlib import Path

HEBREW_DAYS = {
    0: "שני",      # Monday
    1: "שלישי",    # Tuesday
    2: "רביעי",    # Wednesday
    3: "חמישי",    # Thursday
    4: "שישי",     # Friday
    5: "שבת",      # Saturday
    6: "ראשון",    # Sunday
}

YOURZON_URL = "https://www.yourzon.com"

def get_desktop_path():
    """Get the Desktop folder path (Windows or Linux)."""
    if sys.platform == "win32":
        return Path(os.path.expanduser("~/Desktop"))
    elif sys.platform == "darwin":
        return Path(os.path.expanduser("~/Desktop"))
    else:
        desktop = Path(os.path.expanduser("~/Desktop"))
        if desktop.exists():
            return desktop
        xdg = os.environ.get("XDG_DESKTOP_DIR")
        if xdg:
            return Path(xdg)
        return desktop


def get_downloads_path():
    """Get the Downloads folder path."""
    if sys.platform == "win32":
        return Path(os.path.expanduser("~/Downloads"))
    else:
        downloads = Path(os.path.expanduser("~/Downloads"))
        if downloads.exists():
            return downloads
        xdg = os.environ.get("XDG_DOWNLOAD_DIR")
        if xdg:
            return Path(xdg)
        return downloads


def create_dated_folder(desktop_path, custom_name=None):
    """Create a dated folder on the Desktop for YOURZON posts.

    Default naming pattern: "פוסטים יורזון יום {day_name} {day_number}"
    Example: "פוסטים יורזון יום רביעי 5"
    """
    now = datetime.now()
    day_name = HEBREW_DAYS[now.weekday()]
    day_number = now.day

    if custom_name:
        folder_name = custom_name
    else:
        folder_name = f"פוסטים יורזון יום {day_name} {day_number}"

    folder_path = desktop_path / folder_name
    folder_path.mkdir(parents=True, exist_ok=True)
    return folder_path


def find_recent_downloads(downloads_path, minutes=10, extensions=None):
    """Find recently downloaded files (images by default).

    Args:
        downloads_path: Path to Downloads folder
        minutes: Look for files modified within this many minutes
        extensions: File extensions to look for (default: image formats)
    """
    if extensions is None:
        extensions = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg"}

    now = datetime.now().timestamp()
    cutoff = now - (minutes * 60)
    recent_files = []

    if not downloads_path.exists():
        return recent_files

    for f in downloads_path.iterdir():
        if not f.is_file():
            continue
        if f.suffix.lower() not in extensions:
            continue
        if f.stat().st_mtime >= cutoff:
            recent_files.append(f)

    recent_files.sort(key=lambda f: f.stat().st_mtime, reverse=True)
    return recent_files


def move_files_to_folder(files, destination):
    """Move files to the destination folder.

    Returns list of (source, destination) tuples for moved files.
    """
    moved = []
    for f in files:
        dest = destination / f.name
        if dest.exists():
            stem = f.stem
            suffix = f.suffix
            counter = 1
            while dest.exists():
                dest = destination / f"{stem}_{counter}{suffix}"
                counter += 1
        shutil.move(str(f), str(dest))
        moved.append((f, dest))
    return moved


def open_yourzon_in_browser():
    """Open the YOURZON website in the default browser."""
    import webbrowser
    webbrowser.open(YOURZON_URL)


def main():
    parser = argparse.ArgumentParser(
        description="YOURZON Promotional Content Downloader - "
                    "Download and organize YOURZON posts in dated Desktop folders"
    )

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # "open" command - open YOURZON in browser
    subparsers.add_parser("open", help="Open YOURZON website in the browser")

    # "organize" command - move recent downloads to dated folder
    organize_parser = subparsers.add_parser(
        "organize",
        help="Move recently downloaded images to a dated Desktop folder"
    )
    organize_parser.add_argument(
        "--minutes", type=int, default=10,
        help="Look for files downloaded within N minutes (default: 10)"
    )
    organize_parser.add_argument(
        "--folder-name", type=str, default=None,
        help="Custom folder name (default: 'פוסטים יורזון יום {day} {date}')"
    )
    organize_parser.add_argument(
        "--downloads-dir", type=str, default=None,
        help="Custom downloads directory path"
    )
    organize_parser.add_argument(
        "--desktop-dir", type=str, default=None,
        help="Custom desktop directory path"
    )
    organize_parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would be moved without actually moving"
    )

    # "full" command - open browser + wait + organize
    full_parser = subparsers.add_parser(
        "full",
        help="Full workflow: open YOURZON, wait for downloads, then organize"
    )
    full_parser.add_argument(
        "--folder-name", type=str, default=None,
        help="Custom folder name"
    )
    full_parser.add_argument(
        "--wait", type=int, default=0,
        help="Seconds to wait after opening browser before organizing (0 = prompt)"
    )

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        print("\n--- דוגמאות שימוש / Usage Examples ---")
        print("  python yourzon-download.py open          # Open YOURZON in browser")
        print("  python yourzon-download.py organize      # Move recent downloads to folder")
        print("  python yourzon-download.py full           # Full workflow")
        print("  python yourzon-download.py organize --dry-run  # Preview without moving")
        return

    if args.command == "open":
        print(f"Opening YOURZON: {YOURZON_URL}")
        open_yourzon_in_browser()
        print("Browser opened. Download the posts you need, then run:")
        print("  python yourzon-download.py organize")

    elif args.command == "organize":
        downloads_dir = Path(args.downloads_dir) if args.downloads_dir else get_downloads_path()
        desktop_dir = Path(args.desktop_dir) if args.desktop_dir else get_desktop_path()

        print(f"Scanning downloads: {downloads_dir}")
        print(f"Looking for images downloaded in the last {args.minutes} minutes...")

        recent = find_recent_downloads(downloads_dir, minutes=args.minutes)

        if not recent:
            print("No recent image files found in Downloads.")
            print(f"Try increasing the time window: --minutes 30")
            return

        print(f"\nFound {len(recent)} recent image(s):")
        total_size = 0
        for f in recent:
            size = f.stat().st_size
            total_size += size
            mtime = datetime.fromtimestamp(f.stat().st_mtime).strftime("%H:%M:%S")
            print(f"  {f.name} ({size / 1024 / 1024:.2f} MB, {mtime})")
        print(f"  Total: {total_size / 1024 / 1024:.2f} MB")

        folder = create_dated_folder(desktop_dir, args.folder_name)
        print(f"\nDestination folder: {folder}")

        if args.dry_run:
            print("\n[DRY RUN] Files would be moved to the folder above.")
            return

        moved = move_files_to_folder(recent, folder)
        print(f"\nMoved {len(moved)} file(s):")
        for src, dst in moved:
            print(f"  {src.name} -> {dst}")
        print("\nDone!")

    elif args.command == "full":
        desktop_dir = get_desktop_path()
        downloads_dir = get_downloads_path()

        print(f"Opening YOURZON: {YOURZON_URL}")
        open_yourzon_in_browser()

        if args.wait > 0:
            import time
            print(f"Waiting {args.wait} seconds for you to download posts...")
            time.sleep(args.wait)
        else:
            input("\nDownload the posts you need from YOURZON, then press Enter to continue...")

        print("\nScanning for recently downloaded images...")
        recent = find_recent_downloads(downloads_dir, minutes=15)

        if not recent:
            print("No recent image files found. Make sure you downloaded the posts.")
            return

        folder = create_dated_folder(desktop_dir, args.folder_name)
        print(f"Created folder: {folder}")

        moved = move_files_to_folder(recent, folder)
        print(f"Moved {len(moved)} file(s) to {folder.name}")
        for src, dst in moved:
            print(f"  {src.name}")
        print("\nDone!")


if __name__ == "__main__":
    main()
