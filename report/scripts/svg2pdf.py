"""
svg2pdf.py - convert SVG drawings (netlistsvg schematics, nextpnr layouts)
into tightly-cropped vector PDFs for LaTeX, using headless Chrome/Edge.

Usage: python svg2pdf.py <in.svg> <out.pdf> [--bg white] [--max-px 4000]

The SVG is embedded in a one-page HTML document whose @page size equals
the drawing size, then printed with --print-to-pdf.
"""
import os
import re
import subprocess
import sys
import tempfile

BROWSERS = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "google-chrome", "chromium", "chromium-browser",
]


def svg_size(text):
    m = re.search(r'<svg[^>]*?\swidth="([\d.]+)(?:px)?"[^>]*?\sheight="([\d.]+)(?:px)?"', text, re.S)
    if m:
        return float(m.group(1)), float(m.group(2))
    m = re.search(r'viewBox="\s*[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+([\d.]+)"', text)
    if m:
        return float(m.group(1)), float(m.group(2))
    raise SystemExit("cannot determine SVG size")


def main():
    src, dst = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    bg = sys.argv[sys.argv.index("--bg") + 1] if "--bg" in sys.argv else "white"
    max_px = float(sys.argv[sys.argv.index("--max-px") + 1]) if "--max-px" in sys.argv else 4000
    text = open(src, encoding="utf-8").read()
    w, h = svg_size(text)
    s = min(1.0, max_px / max(w, h))          # keep page within Chrome's limits
    W, H = w * s, h * s
    html = ("<!doctype html><html><head><meta charset='utf-8'><style>"
            "@page{size:%.1fpx %.1fpx;margin:0}html,body{margin:0;padding:0;background:%s}"
            "img{display:block;width:%.1fpx;height:%.1fpx}</style></head>"
            "<body><img src='file:///%s'></body></html>"
            % (W, H, bg, W, H, src.replace("\\", "/")))
    fd, tmp = tempfile.mkstemp(suffix=".html")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(html)
    exe = next((b for b in BROWSERS if os.path.exists(b)), BROWSERS[-1])
    subprocess.run([exe, "--headless=new", "--disable-gpu", "--allow-file-access-from-files",
                    "--no-pdf-header-footer", "--print-to-pdf=" + dst, "file:///" + tmp.replace("\\", "/")],
                   check=True, capture_output=True)
    os.remove(tmp)
    print("%s -> %s (%.0fx%.0f px)" % (os.path.basename(src), os.path.basename(dst), W, H))


if __name__ == "__main__":
    main()
