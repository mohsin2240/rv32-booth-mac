"""
build_pages.py - build the GitHub Pages site (docs/index.html) from the page
template and the exported floorplan data.

The Artifact viewer wraps the page in a <!doctype><head><body> skeleton at
publish time; GitHub Pages serves the file as-is, so this script adds that
skeleton (charset, viewport, social-preview tags and the small CSS reset).

Usage:  python report/web/build_pages.py   (writes docs/index.html)
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = HERE
DOCS = os.path.join(HERE, "..", "..", "docs")

page = open(os.path.join(WEB, "page_template.html"), encoding="utf-8").read()
data = open(os.path.join(WEB, "floorplan_data.json"), encoding="utf-8").read()
page = page.replace("__DATA__", data)

cut = page.index("</style>") + len("</style>")
head, body = page[:cut], page[cut:]

DESC = ("A radix-4 Booth multiply-accumulate unit inside a 5-stage RISC-V core: "
        "architecture, interactive ECP5 floorplan, sign-off and FIR performance.")

html = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="description" content="{desc}">
<meta name="author" content="Mohsin Mushtaq, Mubashir Karim Ganaie">
<meta property="og:title" content="RV32 Booth-MAC Core">
<meta property="og:description" content="{desc}">
<meta property="og:type" content="website">
<style>:root{{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}}
body{{margin:0}}img{{max-width:100%}}[hidden]{{display:none!important}}</style>
{head}
</head>
<body>
{body}
</body>
</html>
""".format(desc=DESC, head=head.strip(), body=body.strip())

os.makedirs(DOCS, exist_ok=True)
with open(os.path.join(DOCS, "index.html"), "w", encoding="utf-8") as f:
    f.write(html)
print("wrote", os.path.join(DOCS, "index.html"), len(html), "bytes")
