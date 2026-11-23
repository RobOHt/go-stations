"""Cuts a short demo video of the app (1920 by 1080, 30 fps, no sound) from what the
README media workflow recorded: a title card, five features each told beside its
recording, and an end card. It goes into the README by dragging build/demo.mp4 into
GitHub's editor, the only way GitHub plays a video inline (up to 10 MB on a free
plan, so it's kept well under).

    python3 tools/readme_media.py --fetch    # the recording, into build/readme-media-raw
    python3 tools/demo_video.py              # build/demo.mp4
    python3 tools/demo_video.py --frames     # just a few full-size frames, to look at first

Needs ffmpeg, Pillow and Playwright (with Chromium), and the Inter font."""
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "build", "readme-media-raw")
WORK = os.path.join(ROOT, "build", "demo")
OUT = os.path.join(ROOT, "build", "demo.mp4")
ICON = os.path.join(ROOT, "docs", "media", "icon.png")

W, H, FPS = 1920, 1080, 30
SW, SH = 434, 942      # the phone's screen in the frame: the recording's shape, nearly full height
SX, SY = 1250, 69      # where it sits, on the right
CORNER = 0.145         # the screen's corners, as a share of its width (as in readme_media.py)
RIM = 14               # the phone's black rim around the screen
FADE = 0.35            # each scene's words and phone fade in and out over this, over a still background
ENCODE = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
          "-profile:v", "high", "-r", str(FPS), "-g", str(FPS * 2), "-an"]

# Each scene: a recording (start and length in its own time, and how much faster to
# play it: trains move slowly at the scale of the network) or screenshots shown in
# turn (names joined by "+"), and what it says. Start and length depend on the take:
# pick them from the recording each time it's redone.
SCENES = [
    {"kind": "title", "length": 3.2},
    {"kind": "clip", "source": "trains", "start": 2, "length": 40, "speed": 8,
     "eyebrow": "Live map", "title": "Every GO train, live",
     "body": "Each train moves along the real track from GO's GPS feed, and fades out a minute after its last stop."},
    {"kind": "clip", "source": "trip", "start": 4, "length": 9, "speed": 1,
     "eyebrow": "Departure boards", "title": "The board, as it looks in the station",
     "body": "Platforms, delays and cancellations, in English and French. Tap a train for its stops."},
    {"kind": "clip", "source": "plan", "start": 4, "length": 7, "speed": 1,
     "eyebrow": "Trip planning", "title": "Plan a trip from anywhere",
     "body": "Search a station or any place: the trip you'd take right now, changes and all."},
    {"kind": "clip", "source": "tracked", "start": 6, "length": 40, "speed": 8,
     "eyebrow": "Tracking", "title": "Track your train",
     "body": "It moves on the map where it really is, and the stops ahead show how late it's running."},
    {"kind": "stills", "source": "lock-screen+activity-journey", "length": 7.5,
     "eyebrow": "Live Activities", "title": "On the Lock Screen and in the Dynamic Island",
     "body": "Counts down to your train, then to your stop, updated by push even with the app closed."},
    {"kind": "end", "length": 3.8},
]
FEATURES = [scene for scene in SCENES if scene["kind"] in ("clip", "stills")]

STYLE = """
  html, body { margin: 0; width: 1920px; height: 1080px; overflow: hidden; }
  body { font-family: Inter, sans-serif; color: #fff; position: relative; background: transparent; }
  .bg { position: absolute; inset: 0;
    background:
      radial-gradient(1300px 900px at 6% 0%, rgba(0, 133, 63, 0.30), transparent 60%),
      radial-gradient(1100px 800px at 100% 100%, rgba(40, 90, 200, 0.24), transparent 60%),
      #0a0c0f; }
  .dots { position: absolute; inset: 0; opacity: 0.16;
    background-image: radial-gradient(circle, #8a94a6 1.4px, transparent 1.9px); background-size: 28px 28px;
    mask-image: linear-gradient(90deg, #000 0%, transparent 60%); }
  .text { position: absolute; left: 150px; width: 900px; top: 50%; transform: translateY(-50%); }
  .eyebrow { font-weight: 700; font-size: 23px; letter-spacing: 3.5px; text-transform: uppercase;
    color: #4ade80; margin-bottom: 22px; }
  h1 { font-family: "Inter Display", Inter, sans-serif; font-weight: 800; font-size: 78px; line-height: 1.04;
    letter-spacing: -1.6px; margin: 0 0 30px; }
  p { font-size: 33px; line-height: 1.42; color: #c3cad6; margin: 0; max-width: 840px; }
  .steps { position: absolute; left: 150px; bottom: 96px; display: flex; gap: 12px; }
  .steps i { width: 46px; height: 7px; border-radius: 4px; background: rgba(255,255,255,0.22); }
  .steps i.on { background: #fff; }
  .rim { position: absolute; left: {RX}px; top: {RY}px; width: {RW}px; height: {RH}px;
    border-radius: {RR}px; background: #050607; box-sizing: border-box;
    border: 2px solid #343a42; box-shadow: 0 40px 90px rgba(0,0,0,0.6), inset 0 0 0 3px #0d0f12; }
  .center { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center;
    justify-content: center; text-align: center; }
  .center img { border-radius: 22.4%; box-shadow: 0 16px 50px rgba(0,0,0,0.5); }
  .center h1 { font-size: 132px; letter-spacing: -3px; margin: 40px 0 22px; }
  .center p { font-size: 38px; max-width: 1240px; }
  .end h1 { font-size: 104px; margin: 34px 0 30px; }
  .tags { display: flex; gap: 14px; justify-content: center; margin-bottom: 44px; }
  .tags span { font-size: 26px; font-weight: 600; color: #e8edf5; padding: 11px 22px; border-radius: 999px;
    background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.16); }
  .url { font-size: 36px; font-weight: 600; color: #8ab4ff; letter-spacing: 0.3px; }
"""
for key, value in {"RX": SX - RIM, "RY": SY - RIM, "RW": SW + 2 * RIM, "RH": SH + 2 * RIM,
                   "RR": round(SW * CORNER) + RIM}.items():
    STYLE = STYLE.replace("{" + key + "}", str(value))


def run(*command):
    subprocess.run(command, check=True)


def page(body, background=False):
    return ("<!doctype html><html><head><meta charset='utf-8'><style>" + STYLE + "</style></head><body>"
            + ("<div class='bg'></div><div class='dots'></div>" if background else "") + body + "</body></html>")


def layers():
    """The background, and each scene's words (and the phone's rim) on a clear layer
    over it, so a scene can fade without the background flickering between scenes."""
    from playwright.sync_api import sync_playwright

    shutil.copy(ICON, os.path.join(WORK, "icon.png"))
    pages = {"bg": page("", background=True)}
    for index, scene in enumerate(SCENES):
        if scene["kind"] == "title":
            body = ("<div class='center'><img src='icon.png' width='176' height='176'><h1>GO Stations</h1>"
                    "<p>GO Transit's departure boards, every train live on the map, and your train on the "
                    "Lock Screen.</p></div>")
        elif scene["kind"] == "end":
            body = ("<div class='center end'><img src='icon.png' width='144' height='144'><h1>GO Stations</h1>"
                    "<div class='tags'><span>SwiftUI</span><span>MapKit</span><span>ActivityKit</span>"
                    "<span>Cloudflare Workers</span></div><div class='url'>github.com/RobOHt/go-stations</div></div>")
        else:
            step = FEATURES.index(scene)
            steps = "".join(f"<i class='{'on' if i == step else ''}'></i>" for i in range(len(FEATURES)))
            body = (f"<div class='text'><div class='eyebrow'>{scene['eyebrow']}</div><h1>{scene['title']}</h1>"
                    f"<p>{scene['body']}</p></div><div class='steps'>{steps}</div><div class='rim'></div>")
        pages[f"layer{index}"] = page(body)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        tab = browser.new_page(viewport={"width": W, "height": H}, device_scale_factor=1)
        for name, html in pages.items():
            path = os.path.join(WORK, f"{name}.html")
            with open(path, "w") as file:
                file.write(html)
            tab.goto("file://" + path)
            tab.wait_for_timeout(300)
            tab.screenshot(path=os.path.join(WORK, f"{name}.png"), omit_background=name != "bg")
            os.remove(path)
        browser.close()
    mask = Image.new("L", (SW * 4, SH * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, SW * 4 - 1, SH * 4 - 1), radius=round(SW * CORNER) * 4, fill=255)
    mask.resize((SW, SH), Image.LANCZOS).save(os.path.join(WORK, "mask.png"))


def stills(source, length):
    """Screenshots as a clip of the screen's size: each held in turn, the next fading in."""
    images = [Image.open(os.path.join(RAW, f"{name}.png")).convert("RGB").resize((SW, SH), Image.LANCZOS)
              for name in source.split("+")]
    frames = round(length * FPS)
    blend = round(0.6 * FPS)
    hold = (frames - blend * (len(images) - 1)) / len(images)
    out = os.path.join(WORK, "stills.mp4")
    encoder = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                                "-s", f"{SW}x{SH}", "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "veryfast",
                                "-crf", "12", "-pix_fmt", "yuv444p", out], stdin=subprocess.PIPE)
    for frame in range(frames):
        index = min(int(frame // (hold + blend)), len(images) - 1)
        into = frame - index * (hold + blend) - hold
        if index + 1 < len(images) and into >= 0:
            t = (into + 1) / (blend + 1)
            image = Image.blend(images[index], images[index + 1], t * t * (3 - 2 * t))
        else:
            image = images[index]
        encoder.stdin.write(image.tobytes())
    encoder.stdin.close()
    if encoder.wait():
        sys.exit("couldn't encode the screenshots")
    return out


def scene(index):
    """One scene, encoded on its own (all alike, so they join without encoding again)."""
    spec = SCENES[index]
    kind = spec["kind"]
    duration = spec["length"] / spec.get("speed", 1)
    out = os.path.join(WORK, f"scene{index}.mp4")
    partial = os.path.join(WORK, f"scene{index}.part.mp4")
    inputs = ["-framerate", str(FPS), "-i", os.path.join(WORK, "bg.png"),
              "-framerate", str(FPS), "-i", os.path.join(WORK, f"layer{index}.png")]
    fades = f"fade=t=in:st=0:d={FADE}:alpha=1,fade=t=out:st={duration - FADE:.3f}:d={FADE}:alpha=1"
    if kind in ("title", "end"):
        graph = (f"[0:v]loop=-1:1,trim=duration={duration}[b];"
                 f"[1:v]loop=-1:1,trim=duration={duration},format=rgba,{fades}[c];"
                 f"[b][c]overlay=0:0,format=yuv420p,"
                 + ("fade=t=in:st=0:d=0.6" if kind == "title" else f"fade=t=out:st={duration - 0.9:.3f}:d=0.9"))
    else:
        if kind == "stills":
            inputs += ["-i", stills(spec["source"], duration)]
        else:
            inputs += ["-ss", str(spec["start"]), "-t", str(spec["length"]),
                       "-i", os.path.join(RAW, f"{spec['source']}.mp4")]
        inputs += ["-i", os.path.join(WORK, "mask.png")]
        graph = (f"[0:v]loop=-1:1,trim=duration={duration}[b];"
                 f"[1:v]loop=-1:1,trim=duration={duration},format=rgba[l];"
                 f"[2:v]setpts=(PTS-STARTPTS)/{spec.get('speed', 1)},fps={FPS},scale={SW}:{SH}:flags=lanczos,"
                 f"format=rgba,trim=duration={duration}[v];"
                 f"[3:v]format=gray,loop=-1:1[m];"
                 f"[v][m]alphamerge[s];"
                 f"[l][s]overlay={SX}:{SY}:shortest=1,{fades}[c];"
                 f"[b][c]overlay=0:0,format=yuv420p")
    run("ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", graph, "-t", f"{duration:.3f}", *ENCODE, partial)
    # Renamed only once whole, so a stopped run never leaves a short scene behind.
    os.replace(partial, out)
    return out


def main():
    os.makedirs(WORK, exist_ok=True)
    layers()
    if "--frames" in sys.argv:
        for index, spec in enumerate(SCENES):
            path = scene(index)
            at = spec["length"] / spec.get("speed", 1) * 0.6
            run("ffmpeg", "-v", "error", "-y", "-ss", f"{at:.2f}", "-i", path, "-frames:v", "1",
                os.path.join(WORK, f"frame{index}.png"))
        print("frames in", WORK)
        return
    parts = [scene(index) for index in range(len(SCENES))]
    listing = os.path.join(WORK, "parts.txt")
    with open(listing, "w") as file:
        file.writelines(f"file '{part}'\n" for part in parts)
    partial = OUT + ".part.mp4"
    run("ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing, "-c", "copy",
        "-movflags", "+faststart", partial)
    os.replace(partial, OUT)
    print(OUT, os.path.getsize(OUT) // 1024, "KB")


if __name__ == "__main__":
    main()
