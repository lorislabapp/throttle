#!/usr/bin/env python3
"""Stage a Throttle release for publication — the step between build-dmg.sh and publish-release.mjs.

Produces an ISOLATED directory holding only what a release changes on the site:

    <stage>/throttle/appcast.xml      live appcast + the new item on top
    <stage>/throttle/index.html       live product page with version, link and size updated
    <stage>/throttle/Throttle-X.dmg   the exact stapled DMG

The public site is the source of truth (the lorislab-website checkout drifts), so both the
appcast and the page are fetched live, and the page is stripped of the Cloudflare
rocket-loader / WebMCP response transformations so the uploaded source is clean.

Usage:
    scripts/stage-release.py [--version 3.5.2] [--build-dir build] [--notes notes.html]
                             [--stage /path] [--live-appcast file] [--live-page file]

--live-appcast / --live-page take local snapshots instead of fetching (offline runs, tests).
Nothing is uploaded; see publish-release.mjs.
"""
import argparse, hashlib, os, re, shutil, sys, urllib.request

SITE = "https://lorislab.fr/throttle"
PROJECT_YML = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "project.yml")


def fetch(url):
    req = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "throttle-stage-release"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8")


def strip_edge_transforms(html):
    """Undo what Cloudflare injects into the served page so the source stays clean."""
    html = re.sub(r'<script type="module" src="https://lorislab\.fr/\.webmcp/bridge\.js"[^>]*></script>', "", html)
    html = re.sub(r'<script src="/cdn-cgi/scripts/[^"]+/cloudflare-static/rocket-loader\.min\.js"[^>]*></script>', "", html)
    html = re.sub(r' type="[0-9a-f]+-text/javascript"', "", html)
    for marker in ("cdn-cgi", "webmcp", "-text/javascript"):
        if marker in html:
            sys.exit(f"page still carries an edge transformation: {marker}")
    return html


def sha256(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version")
    ap.add_argument("--build-dir", default="build")
    ap.add_argument("--notes", help="HTML fragment for the Sparkle release notes (optional)")
    ap.add_argument("--stage", help="output directory (default: <build-dir>/stage)")
    ap.add_argument("--live-appcast", help="local snapshot of the live appcast instead of fetching")
    ap.add_argument("--live-page", help="local snapshot of the live product page instead of fetching")
    a = ap.parse_args()

    version = a.version or re.search(r'MARKETING_VERSION:\s*"([^"]+)"', open(PROJECT_YML).read()).group(1)
    build_dir = os.path.abspath(a.build_dir)
    dmg = f"{build_dir}/Throttle-{version}.dmg"
    entry_path = f"{build_dir}/appcast-entry-{version}.xml"
    for p in (dmg, entry_path):
        if not os.path.exists(p):
            sys.exit(f"missing {p} — run scripts/build-dmg.sh --notarize first")

    entry = open(entry_path).read()
    sig = re.search(r'sparkle:edSignature="([^"]+)"', entry).group(1)
    length = int(re.search(r'length="(\d+)"', entry).group(1))
    build = re.search(r"<sparkle:version>(\d+)</sparkle:version>", entry).group(1)
    pub = re.search(r"<pubDate>([^<]+)</pubDate>", entry).group(1)
    if os.path.getsize(dmg) != length:
        sys.exit(f"DMG size {os.path.getsize(dmg)} != signed length {length}: the entry was signed for another file")

    live = open(a.live_appcast, encoding="utf-8").read() if a.live_appcast else fetch(f"{SITE}/appcast.xml")
    if f"<sparkle:version>{build}</sparkle:version>" in live:
        sys.exit(f"build {build} is already in the live appcast — Sparkle compares CFBundleVersion; bump it")
    anchor = "        <language>en</language>\n"
    if live.count(anchor) != 1:
        sys.exit("live appcast does not have the expected <language> anchor")

    notes_xml = ""
    if a.notes:
        notes_xml = f"                <description><![CDATA[{open(a.notes, encoding='utf-8').read().strip()}]]></description>\n"
    item = (f"            <item>\n"
            f"                <title>Version {version}</title>\n"
            f"{notes_xml}"
            f"                <pubDate>{pub}</pubDate>\n"
            f"                <sparkle:version>{build}</sparkle:version>\n"
            f"                <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
            f"                <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n"
            f"                <enclosure url=\"{SITE}/Throttle-{version}.dmg\"\n"
            f"                           type=\"application/octet-stream\"\n"
            f"                           sparkle:edSignature=\"{sig}\" length=\"{length}\" />\n"
            f"            </item>\n")
    appcast = live.replace(anchor, anchor + item, 1)

    page = open(a.live_page, encoding="utf-8").read() if a.live_page else fetch(f"{SITE}/")
    page = strip_edge_transforms(page)
    prev = re.search(r'href="Throttle-([0-9.]+)\.dmg"', page)
    meta = re.search(r'<span class="mono">v([0-9.]+)</span> · ([0-9.]+) MB', page)
    if not prev or not meta or prev.group(1) != meta.group(1):
        sys.exit("could not find a single consistent previous version on the live page")
    old = prev.group(1)
    mb = f"{length / 1_000_000:.1f}"
    page = page.replace(f'href="Throttle-{old}.dmg"', f'href="Throttle-{version}.dmg"', 1)
    page = page.replace(f'<span class="mono">v{old}</span> · {meta.group(2)} MB',
                        f'<span class="mono">v{version}</span> · {mb} MB', 1)
    if old in page and old != version:
        sys.exit(f"the previous version {old} still appears on the page after the update")

    stage = os.path.abspath(a.stage or f"{build_dir}/stage")
    out = f"{stage}/throttle"
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(out)
    open(f"{out}/appcast.xml", "w", encoding="utf-8").write(appcast)
    open(f"{out}/index.html", "w", encoding="utf-8").write(page)
    shutil.copy2(dmg, f"{out}/Throttle-{version}.dmg")

    print(f"staged {version} ({build}) in {stage}")
    for f in sorted(os.listdir(out)):
        p = f"{out}/{f}"
        print(f"  {f}: {os.path.getsize(p)} bytes  sha256 {sha256(p)}")
    print(f"  page: {old} → {version}, {mb} MB | appcast items: {appcast.count('<item>')}")
    print(f"next: node scripts/publish-release.mjs {stage}")


if __name__ == "__main__":
    main()
