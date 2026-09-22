#!/usr/bin/env python3
"""Refuse release build numbers without an attributable, valid live appcast.

No signing/build/publication. Importing this module performs no network work.
New builds use Throttle's integer policy. Published history may also contain
Sparkle's numeric x.y or x.y.z versions; unknown formats still refuse.
"""
import argparse
import hashlib
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

FEED_URL = "https://lorislab.fr/throttle/appcast.xml"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MAXIMUM_FEED_BYTES = 2 * 1024 * 1024


class GateFailure(ValueError):
    pass


def build_number(raw):
    if not isinstance(raw, str) or re.fullmatch(r"[0-9]{1,18}", raw) is None:
        raise GateFailure("missing or non-numeric CFBundleVersion; release refused")
    return int(raw)


def published_version(raw):
    """Compare the supported numeric subset like Sparkle, padding missing zeros.

    Do not strip suffixes or ignore an older item: either could hide a newer
    release. Each component fits Sparkle's signed 64-bit numeric comparison.
    """
    if not isinstance(raw, str) or re.fullmatch(r"[0-9]{1,18}(?:\.[0-9]{1,18}){0,2}", raw) is None:
        raise GateFailure("unsupported published CFBundleVersion; release refused")
    parts = tuple(int(part) for part in raw.split("."))
    return parts + (0,) * (3 - len(parts))


def validate_feed(feed, candidate):
    planned = build_number(candidate)
    if not feed or len(feed) > MAXIMUM_FEED_BYTES:
        raise GateFailure("empty or oversized appcast; public version UNKNOWN")
    try:
        text = feed.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise GateFailure("appcast must be UTF-8; public version UNKNOWN") from error
    if "<!DOCTYPE" in text.upper() or "<!ENTITY" in text.upper():
        raise GateFailure("appcast declarations are unsupported; public version UNKNOWN")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as error:
        raise GateFailure("malformed appcast XML; public version UNKNOWN") from error
    channels = root.findall("channel")
    if root.tag != "rss" or len(channels) != 1:
        raise GateFailure("expected one RSS channel; public version UNKNOWN")
    items = channels[0].findall("item")
    if not items:
        raise GateFailure("appcast has no release items; public version UNKNOWN")
    builds = []
    for item in items:
        versions = item.findall("{" + SPARKLE + "}version")
        if len(versions) != 1 or versions[0].text is None:
            raise GateFailure("release item has missing or ambiguous version; public version UNKNOWN")
        version = versions[0].text.strip()
        builds.append((published_version(version), version))
    maximum_key, maximum_text = max(builds)
    if (planned, 0, 0) <= maximum_key:
        raise GateFailure(f"candidate build {planned} must exceed published maximum {maximum_text}; release refused")
    return int(maximum_text) if "." not in maximum_text else maximum_text


def fetch_feed(opener=None):
    opener = opener or urllib.request.urlopen
    request = urllib.request.Request(FEED_URL, headers={
        "Cache-Control": "no-cache", "User-Agent": "throttle-release-build-gate"})
    try:
        with opener(request, timeout=10) as response:
            if response.status != 200 or response.geturl() != FEED_URL:
                raise GateFailure("unexpected appcast HTTP status or redirect; public version UNKNOWN")
            data = response.read(MAXIMUM_FEED_BYTES + 1)
    except (urllib.error.URLError, OSError, TimeoutError) as error:
        raise GateFailure("appcast unavailable (HTTP/transport); public version UNKNOWN; release refused") from error
    if len(data) > MAXIMUM_FEED_BYTES:
        raise GateFailure("oversized appcast; public version UNKNOWN")
    return data


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True)
    args = parser.parse_args(argv)
    try:
        build_number(args.candidate)  # Refuse invalid local input before network.
        feed = fetch_feed()
        maximum = validate_feed(feed, args.candidate)
    except GateFailure as error:
        print(str(error), file=sys.stderr)
        return 65
    print(f"Build {args.candidate} > published maximum {maximum}; "
          f"appcast sha256={hashlib.sha256(feed).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
