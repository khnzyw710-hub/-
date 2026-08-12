#!/usr/bin/env python3
"""
YOURZON — Automated Marketing Post Creator & Organizer

Complete workflow:
  1. ChatGPT Chat #1: Generate 5 marketing post texts for YOURZON
  2. ChatGPT Chat #2: Set brand/design guidelines, then for each post —
     paste the text and generate a branded image
  3. Download all generated post images
  4. Create a dated Desktop folder and organize the files

Modes:
  api        Use OpenAI API directly (default, requires OPENAI_API_KEY)
  browser    Automate ChatGPT in Chrome with Playwright
  organize   Just organize recently downloaded files (no generation)

Requirements (api mode):
  pip install openai
  export OPENAI_API_KEY="sk-..."

Requirements (browser mode):
  pip install playwright
  playwright install chromium

Usage:
  python yourzon-download.py                        # Full workflow via API
  python yourzon-download.py api --posts 3          # Generate 3 posts
  python yourzon-download.py browser                # Automate ChatGPT in Chrome
  python yourzon-download.py organize               # Just organize downloads
  python yourzon-download.py organize -m 30         # Wider time window
  python yourzon-download.py api --dry-run          # Preview prompts only
"""

import argparse
import json
import os
import re
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path
from urllib.request import urlretrieve

HEBREW_DAYS = {
    0: "שני", 1: "שלישי", 2: "רביעי", 3: "חמישי",
    4: "שישי", 5: "שבת", 6: "ראשון",
}

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg"}

POSTS_PROMPT = "תכתוב לי {n} פוסטים ליורזון"

BRAND_DESIGN_PROMPT = """\
כל פוסט שאני נותן לך עכשיו אתה יוצר אותו בדיוק לפי זה בדיוק -

Design a professional logo for a digital marketing
company called "YourZon".

LOGO STRUCTURE:

- The word "YOUR" in Deep Red color
- The word "ZON" in Dark Navy color
- Both words use a gradient that flows from
  Deep Red (left) to Dark Navy (right)
- A small computer cursor/arrow icon placed
  at the bottom-right of the letter "N"
- The cursor is dark navy colored
- Font: Extra Bold, Heavy Weight, Sans-Serif
  (similar to Black Han Sans or Bebas Neue)
- Letters are uppercase only
- Tight letter spacing — letters sit close together
- No outlines, no shadows, clean flat style

BRAND COLORS — EXACT VALUES:

- Deep Red:     #8B0000  /  RGB(139, 0, 0)
- Dark Navy:    #1A2340  /  RGB(26, 35, 64)
- Light Gray:   #F2F2F2  /  RGB(242, 242, 242)
- White:        #FFFFFF
  ⚠️ NO other colors allowed

BACKGROUND OPTIONS:
Option A — Light gray #F2F2F2 with:

- Faint network/node graph pattern on LEFT side
  (small dots connected by thin lines, deep red
  at 10% opacity)
- Faint topographic contour lines on RIGHT side
  (dark navy at 8% opacity, organic curved lines)

Option B — Pure white #FFFFFF, logo centered only

LOGO VERSIONS NEEDED:

1. Horizontal version — YOUR ZON on one line
2. Stacked version — YOUR on top / ZON below
3. Icon only — cursor arrow in deep red + navy gradient
4. White version — for dark backgrounds

STYLE KEYWORDS:
Premium, Corporate, Digital, Trustworthy,
Modern, Clean, Minimal, Bold, Professional

DO NOT include:

- Gradients other than red-to-navy
- Drop shadows or 3D effects
- Decorative fonts or script styles
- Any colors outside the brand palette
- Emojis or decorative symbols
- Tagline in the logo itself

OUTPUT FORMAT:

- SVG vector format preferred
- Transparent background (PNG as backup)
- Minimum size: 2000x2000px"""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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


def parse_posts(text):
    """Split ChatGPT response into individual posts."""
    chunks = re.split(r'\n\s*(?:\d+[\.\)]\s*|#{1,3}\s+פוסט\s*\d+|---+)', text)
    posts = [c.strip() for c in chunks if c.strip() and len(c.strip()) > 20]
    if not posts:
        posts = [text.strip()]
    return posts


# ---------------------------------------------------------------------------
# API mode — OpenAI API directly
# ---------------------------------------------------------------------------

def cmd_api(args):
    try:
        from openai import OpenAI
    except ImportError:
        print("openai package required:  pip install openai")
        sys.exit(1)

    api_key = args.api_key or os.environ.get("OPENAI_API_KEY")
    if not api_key:
        print("Set OPENAI_API_KEY or pass --api-key")
        sys.exit(1)

    client = OpenAI(api_key=api_key)
    desktop = Path(args.desktop_dir) if args.desktop_dir else get_desktop()
    folder_name = dated_folder_name(args.folder_name)
    folder = desktop / folder_name
    num_posts = args.posts
    chat_model = args.chat_model
    image_model = args.image_model

    print("=== YOURZON Post Creator ===\n")

    # --- Step 1: Generate post texts (Chat #1) ---
    print(f"Step 1: Generating {num_posts} post texts...")
    prompt = POSTS_PROMPT.format(n=num_posts)

    if args.dry_run:
        print(f"  [DRY RUN] Would send to {chat_model}: \"{prompt}\"")
        print(f"  [DRY RUN] Then generate {num_posts} images with {image_model}")
        print(f"  [DRY RUN] Save to: {folder}")
        return

    response = client.chat.completions.create(
        model=chat_model,
        messages=[{"role": "user", "content": prompt}],
    )
    full_text = response.choices[0].message.content
    posts = parse_posts(full_text)[:num_posts]

    print(f"  Generated {len(posts)} posts:\n")
    for i, p in enumerate(posts, 1):
        preview = p[:80].replace("\n", " ")
        print(f"  {i}. {preview}{'...' if len(p) > 80 else ''}")

    # --- Step 2: Generate branded image for each post (Chat #2) ---
    print(f"\nStep 2: Generating branded images ({image_model})...\n")

    folder.mkdir(parents=True, exist_ok=True)
    saved_files = []

    for i, post_text in enumerate(posts, 1):
        print(f"  Generating image {i}/{len(posts)}...", end=" ", flush=True)

        image_prompt = f"{BRAND_DESIGN_PROMPT}\n\nהפוסט:\n{post_text}"

        try:
            img_response = client.images.generate(
                model=image_model,
                prompt=image_prompt,
                size="1024x1024",
                quality="hd" if image_model == "dall-e-3" else "auto",
                n=1,
            )

            image_url = img_response.data[0].url
            filename = f"yourzon_post_{i}.png"
            filepath = folder / filename
            urlretrieve(image_url, str(filepath))
            saved_files.append(filepath)
            print(f"saved: {filename}")

        except Exception as e:
            print(f"error: {e}")
            continue

    # --- Step 3: Summary ---
    print(f"\nStep 3: Done!")
    print(f"  Saved {len(saved_files)} post(s) to: {folder}")
    for f in saved_files:
        sz = f.stat().st_size / 1048576
        print(f"  {f.name}  ({sz:.2f} MB)")

    open_folder(folder)
    print("\nDone!")


# ---------------------------------------------------------------------------
# Browser mode — automate ChatGPT in Chrome via Playwright
# ---------------------------------------------------------------------------

def cmd_browser(args):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("Playwright required:  pip install playwright && playwright install chromium")
        sys.exit(1)

    downloads_dir = Path(args.downloads_dir) if args.downloads_dir else get_downloads()
    desktop = Path(args.desktop_dir) if args.desktop_dir else get_desktop()
    num_posts = args.posts
    stamp = time.time()

    print("=== YOURZON Post Creator — Browser Mode ===\n")

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
            ctx = browser.new_context(accept_downloads=True)
            page = ctx.new_page()

        # --- Chat #1: Generate post texts ---
        print("Step 1: Opening ChatGPT for post generation...")
        page.goto("https://chatgpt.com", wait_until="domcontentloaded", timeout=30_000)
        try:
            page.wait_for_load_state("networkidle", timeout=15_000)
        except Exception:
            pass

        prompt_text = POSTS_PROMPT.format(n=num_posts)
        print(f"  Prompt: \"{prompt_text}\"")

        # Try to find and fill the chat input
        input_sel = 'textarea, [contenteditable="true"], #prompt-textarea, div[role="textbox"]'
        try:
            chat_input = page.locator(input_sel).first
            chat_input.wait_for(state="visible", timeout=30_000)
            chat_input.fill(prompt_text)
            time.sleep(0.5)

            # Submit
            send_btn = page.locator('button[data-testid="send-button"], button[aria-label="Send"], button:has-text("Send")').first
            if send_btn.is_visible(timeout=3_000):
                send_btn.click()
            else:
                page.keyboard.press("Enter")

            print("  Prompt sent. Waiting for response...")
            time.sleep(5)

            # Wait for response to complete (stop button disappears)
            for _ in range(60):
                stop_btn = page.locator('button[aria-label="Stop"], button:has-text("Stop")')
                if stop_btn.count() == 0 or not stop_btn.first.is_visible():
                    break
                time.sleep(2)

            print("  Response received.")
            print("\n  Now copy the posts from Chat #1.")

        except Exception as e:
            print(f"  Could not auto-type. Please type the prompt manually: \"{prompt_text}\"")

        input("\n  Press Enter when Chat #1 posts are ready...")

        # --- Chat #2: Brand guidelines + generate images ---
        print("\nStep 2: Opening new chat for image generation...")
        print("  Pasting brand/design guidelines...\n")

        # Open new chat
        try:
            new_chat_btn = page.locator('a[href="/"], button:has-text("New chat"), nav a:first-child').first
            if new_chat_btn.is_visible(timeout=5_000):
                new_chat_btn.click()
                time.sleep(2)
        except Exception:
            page.goto("https://chatgpt.com", wait_until="domcontentloaded", timeout=30_000)
            time.sleep(3)

        # Send brand guidelines
        try:
            chat_input = page.locator(input_sel).first
            chat_input.wait_for(state="visible", timeout=15_000)
            chat_input.fill(BRAND_DESIGN_PROMPT)
            time.sleep(0.5)

            send_btn = page.locator('button[data-testid="send-button"], button[aria-label="Send"]').first
            if send_btn.is_visible(timeout=3_000):
                send_btn.click()
            else:
                page.keyboard.press("Enter")

            print("  Brand guidelines sent.")
            time.sleep(5)

            for _ in range(30):
                stop_btn = page.locator('button[aria-label="Stop"], button:has-text("Stop")')
                if stop_btn.count() == 0 or not stop_btn.first.is_visible():
                    break
                time.sleep(2)

        except Exception:
            print("  Could not auto-paste. Please paste the brand guidelines manually.")

        print("\n  Now paste each post from Chat #1 into this chat, one at a time.")
        print("  ChatGPT will generate a branded image for each post.")
        print("  Download each generated image when ready.")
        input("\n  Press Enter when all images are downloaded...")

        ctx.close()
        if not use_profile:
            browser.close()

    # --- Organize downloaded files ---
    print("\nStep 3: Organizing downloaded files...")
    files = find_recent_images(downloads_dir, since_ts=stamp)
    if not files:
        files = find_recent_images(downloads_dir, minutes=30)

    if not files:
        print("No downloaded images found.")
        return

    folder_name = dated_folder_name(args.folder_name)
    folder = desktop / folder_name

    if args.dry_run:
        print(f"  [DRY RUN] Would move {len(files)} file(s) to: {folder}")
        return

    moved = move_files(files, folder)
    print(f"  Moved {len(moved)} file(s) to: {folder}")
    for _, dst in moved:
        print(f"    {dst.name}")
    open_folder(folder)
    print("\nDone!")


# ---------------------------------------------------------------------------
# Organize mode — just move recent downloads
# ---------------------------------------------------------------------------

def cmd_organize(args):
    downloads = Path(args.downloads_dir) if args.downloads_dir else get_downloads()
    desktop = Path(args.desktop_dir) if args.desktop_dir else get_desktop()

    print(f"Scanning: {downloads}")
    print(f"Looking for images from the last {args.minutes} minutes...")

    files = find_recent_images(downloads, minutes=args.minutes)
    if not files:
        print("No recent image files found.")
        print(f"Tip: try  -m {args.minutes * 3}")
        return

    total = sum(f.stat().st_size for f in files)
    print(f"\nFound {len(files)} image(s) ({total / 1048576:.2f} MB):")
    for f in files:
        sz = f.stat().st_size / 1048576
        ts = datetime.fromtimestamp(f.stat().st_mtime).strftime("%H:%M:%S")
        print(f"  {f.name}  ({sz:.2f} MB, {ts})")

    folder_name = dated_folder_name(args.folder_name)
    folder = desktop / folder_name

    if args.dry_run:
        print(f"\n[DRY RUN] Would create: {folder}")
        print(f"[DRY RUN] Would move {len(files)} file(s)")
        return

    moved = move_files(files, folder)
    print(f"\nMoved {len(moved)} file(s) to: {folder}")
    for _, dst in moved:
        print(f"  {dst.name}")
    open_folder(folder)
    print("\nDone!")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="YOURZON — Automated Marketing Post Creator & Organizer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  %(prog)s                              Full workflow via OpenAI API
  %(prog)s api --posts 3                Generate 3 posts
  %(prog)s browser                      Automate ChatGPT in Chrome
  %(prog)s organize                     Just organize recent downloads
  %(prog)s organize -m 30               Wider time window
  %(prog)s api --dry-run                Preview prompts without generating
""",
    )

    sub = parser.add_subparsers(dest="mode")

    # --- api mode ---
    p_api = sub.add_parser("api", help="Use OpenAI API directly (default)")
    p_api.add_argument("--api-key", help="OpenAI API key (or set OPENAI_API_KEY)")
    p_api.add_argument("--posts", type=int, default=5, help="Number of posts (default: 5)")
    p_api.add_argument("--chat-model", default="gpt-4o", help="Model for text generation (default: gpt-4o)")
    p_api.add_argument("--image-model", default="dall-e-3", help="Model for image generation (default: dall-e-3)")
    p_api.add_argument("--folder-name", help="Custom folder name")
    p_api.add_argument("--desktop-dir", help="Custom desktop path")
    p_api.add_argument("--dry-run", action="store_true")

    # --- browser mode ---
    p_br = sub.add_parser("browser", help="Automate ChatGPT in Chrome browser")
    p_br.add_argument("--no-profile", action="store_true", help="Fresh browser session")
    p_br.add_argument("--posts", type=int, default=5, help="Number of posts (default: 5)")
    p_br.add_argument("--folder-name", help="Custom folder name")
    p_br.add_argument("--downloads-dir", help="Custom downloads path")
    p_br.add_argument("--desktop-dir", help="Custom desktop path")
    p_br.add_argument("--dry-run", action="store_true")

    # --- organize mode ---
    p_org = sub.add_parser("organize", help="Organize recently downloaded files only")
    p_org.add_argument("-m", "--minutes", type=int, default=10, help="Time window (default: 10)")
    p_org.add_argument("--folder-name", help="Custom folder name")
    p_org.add_argument("--downloads-dir", help="Custom downloads path")
    p_org.add_argument("--desktop-dir", help="Custom desktop path")
    p_org.add_argument("--dry-run", action="store_true")

    args = parser.parse_args()

    if args.mode is None or args.mode == "api":
        if not hasattr(args, "api_key"):
            args.api_key = None
            args.posts = 5
            args.chat_model = "gpt-4o"
            args.image_model = "dall-e-3"
            args.folder_name = None
            args.desktop_dir = None
            args.dry_run = False
        cmd_api(args)
    elif args.mode == "browser":
        cmd_browser(args)
    elif args.mode == "organize":
        cmd_organize(args)


if __name__ == "__main__":
    main()
