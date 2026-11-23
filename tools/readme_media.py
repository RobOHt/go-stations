"""Makes the README's media (docs/media) from what the README media workflow
recorded (.github/workflows/readme-media.yml, pushed to the readme-media-raw
branch): screenshots with the iPhone's rounded corners, short looping GIFs of the
clips (sped up where trains move slowly), and full-quality MP4s of them.

    python3 tools/readme_media.py --fetch    # downloads readme-media-raw first
    python3 tools/readme_media.py            # from what was downloaded before

Needs ffmpeg, ImageMagick and Pillow, and the GitHub CLI (gh) to fetch."""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "build", "readme-media-raw")
OUT = os.path.join(ROOT, "docs", "media")
REPO = "RobOHt/go-stations"

# The iPhone's screen corners, as a share of its width (iPhone Air: about 62 of 420 pt).
CORNER = 0.145

# Screenshots for the README, by the workflow's name: width in pixels (shown at half).
SCREENS = {
    "trains": 560,
    "board": 560,
    "board-sample": 560,
    "trip-late": 560,
    "trip-late-end": 560,
    "tracked": 560,
    "plan": 560,
    "plan-open": 560,
    "plan-change": 560,
    "journey": 560,
    "lock-screen": 560,
    "activity-gallery": 560,
    "board-light": 560,
    "map-light": 560,
}

# Clips: (name, start s, length s, speed, width px, frames a second). Start and
# length are in the recording's own time (the app launches about 2 s in); speed > 1
# plays it faster: trains move slowly at the scale of the network.
CLIPS = [
    ("trains", 10, 34, 8, 320, 12),
    ("board", 5.2, 6.5, 1, 320, 12),
    ("trip", 4.2, 8, 1, 320, 12),
    ("tracked", 6, 40, 8, 320, 12),
    ("island", 33, 15, 1, 320, 12),
    ("plan", 3.2, 7, 1, 320, 12),
]


def run(*command, capture=False):
    result = subprocess.run(command, check=True, capture_output=capture, text=capture)
    return result.stdout if capture else None


def fetch():
    """Downloads the readme-media-raw branch into build/readme-media-raw."""
    os.makedirs(RAW, exist_ok=True)
    tree = json.loads(run("gh", "api", f"repos/{REPO}/git/trees/readme-media-raw?recursive=1", capture=True))
    for item in tree["tree"]:
        if item["type"] != "blob":
            continue
        blob = json.loads(run("gh", "api", f"repos/{REPO}/git/blobs/{item['sha']}", capture=True))
        with open(os.path.join(RAW, item["path"]), "wb") as out:
            out.write(base64.b64decode(blob["content"]))
        print("fetched", item["path"], item["size"])


def corners(size, radius, scale=4):
    """An alpha mask with rounded corners, drawn large and scaled down for smooth edges."""
    big = Image.new("L", (size[0] * scale, size[1] * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, big.width - 1, big.height - 1), radius * scale, fill=255)
    return big.resize(size, Image.LANCZOS)


def screen(name, width):
    source = os.path.join(RAW, f"{name}.png")
    if not os.path.exists(source):
        print("missing", name)
        return
    image = Image.open(source).convert("RGB")
    height = round(image.height * width / image.width)
    image = image.resize((width, height), Image.LANCZOS).convert("RGBA")
    image.putalpha(corners(image.size, round(width * CORNER)))
    path = os.path.join(OUT, f"{name}.png")
    # 256 colours: a third of the size, and the same to the eye at this size.
    image.quantize(256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG).save(path, optimize=True)
    print("screen", name, os.path.getsize(path) // 1024, "KB")


def probe(path):
    info = json.loads(run("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height", "-of", "json", path, capture=True))
    stream = info["streams"][0]
    return stream["width"], stream["height"]


def clip(name, start, length, speed, width, fps):
    source = os.path.join(RAW, f"{name}.mp4")
    if not os.path.exists(source):
        print("missing", name)
        return
    w, h = probe(source)
    height = round(width * h / w / 2) * 2
    with tempfile.TemporaryDirectory() as scratch:
        mask = os.path.join(scratch, "mask.png")
        corners((width, height), round(width * CORNER)).save(mask)
        timing = f"setpts=PTS/{speed},fps={fps},scale={width}:{height}:flags=lanczos"
        gif = os.path.join(OUT, f"{name}.gif")
        run("ffmpeg", "-v", "error", "-y", "-ss", str(start), "-t", str(length), "-i", source, "-i", mask,
            "-filter_complex",
            f"[0:v]{timing},format=rgba[v];[1:v]format=gray[m];[v][m]alphamerge,split[a][b];"
            "[a]palettegen=reserve_transparent=1:stats_mode=diff:max_colors=160[p];"
            "[b][p]paletteuse=dither=none:diff_mode=rectangle:alpha_threshold=128",
            "-loop", "0", os.path.join(scratch, "frames.gif"))
        # Each frame cut down to what changed (with the corners see-through, ffmpeg's own
        # GIF writer gives up on that, and the file is ten times the size).
        run("convert", os.path.join(scratch, "frames.gif"), "-layers", "Optimize", gif)
    # The whole clip at full size, for "watch in full quality".
    mp4 = os.path.join(OUT, f"{name}.mp4")
    run("ffmpeg", "-v", "error", "-y", "-ss", str(start), "-t", str(length), "-i", source,
        "-vf", f"setpts=PTS/{speed},scale=trunc(iw/2)*2:trunc(ih/2)*2", "-an", "-c:v", "libx264",
        "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4)
    print("clip", name, os.path.getsize(gif) // 1024, "KB gif,", os.path.getsize(mp4) // 1024, "KB mp4")


def icon():
    image = Image.open(os.path.join(ROOT, "Departures/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
    image = image.convert("RGB").resize((208, 208), Image.LANCZOS).convert("RGBA")
    image.putalpha(corners(image.size, round(208 * 0.2237)))
    image.save(os.path.join(OUT, "icon.png"), optimize=True)


BANNER = """<!doctype html>
<html><head><meta charset="utf-8"><style>
  html, body { margin: 0; width: 1280px; height: 640px; overflow: hidden; }
  body {
    background:
      radial-gradient(900px 600px at 8% 0%, rgba(0, 133, 63, 0.30), transparent 60%),
      radial-gradient(700px 520px at 100% 100%, rgba(40, 90, 200, 0.22), transparent 60%),
      #0a0c0f;
    font-family: Inter, sans-serif; color: #fff; position: relative;
  }
  .dots { position: absolute; inset: 0; opacity: 0.18;
    background-image: radial-gradient(circle, #8a94a6 1.2px, transparent 1.6px); background-size: 22px 22px;
    mask-image: linear-gradient(90deg, #000 0%, transparent 55%); }
  .text { position: absolute; left: 84px; top: 118px; width: 560px; }
  .icon { width: 104px; height: 104px; border-radius: 24px; box-shadow: 0 10px 30px rgba(0,0,0,.45); }
  h1 { font-family: "Inter Display", Inter, sans-serif; font-weight: 800; font-size: 82px; letter-spacing: -2px;
    margin: 30px 0 14px; line-height: 1; }
  p { font-size: 27px; line-height: 1.38; color: #c3cad6; margin: 0 0 30px; font-weight: 400; }
  .tags { display: flex; flex-wrap: wrap; gap: 10px; }
  .tags span { font-size: 17px; font-weight: 600; color: #e8edf5; padding: 8px 14px; border-radius: 999px;
    background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.14); }
  .phone { position: absolute; width: 238px; filter: drop-shadow(0 24px 40px rgba(0,0,0,0.55)); }
  .phone img { width: 100%; display: block; }
  .a { left: 676px; top: 96px; }
  .b { left: 852px; top: 46px; z-index: 2; width: 252px; }
  .c { left: 1040px; top: 128px; }
</style></head><body>
  <div class="dots"></div>
  <div class="text">
    <img class="icon" src="icon.png">
    <h1>GO Stations</h1>
    <p>GO Transit's departure boards, every train live on the map, and your train on the Lock Screen.</p>
    <div class="tags"><span>SwiftUI</span><span>MapKit</span><span>Live Activities</span><span>Cloudflare Workers</span></div>
  </div>
  <div class="phone a"><img src="{left}"></div>
  <div class="phone b"><img src="{middle}"></div>
  <div class="phone c"><img src="{right}"></div>
</body></html>
"""


def banner(left="trains.png", middle="board.png", right="lock-screen.png"):
    """The repository's social preview (1280 by 640, for Settings → Social preview)."""
    from playwright.sync_api import sync_playwright

    page_path = os.path.join(OUT, "banner.html")
    with open(page_path, "w") as page:
        page.write(BANNER.replace("{left}", left).replace("{middle}", middle).replace("{right}", right))
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            page = browser.new_page(viewport={"width": 1280, "height": 640}, device_scale_factor=1)
            page.goto("file://" + page_path)
            page.wait_for_timeout(500)
            png = os.path.join(OUT, "social-preview.png")
            page.screenshot(path=png)
            browser.close()
    finally:
        os.remove(page_path)
    print("banner", os.path.getsize(png) // 1024, "KB")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fetch", action="store_true", help="download the readme-media-raw branch first")
    args = parser.parse_args()
    if args.fetch:
        fetch()
    if not os.path.isdir(RAW):
        sys.exit("Nothing recorded yet: run with --fetch")
    os.makedirs(OUT, exist_ok=True)
    icon()
    for name, width in SCREENS.items():
        screen(name, width)
    for each in CLIPS:
        clip(*each)
    banner()


if __name__ == "__main__":
    main()
