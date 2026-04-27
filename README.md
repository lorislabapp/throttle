# Throttle

A macOS menu-bar app that shows your Claude Code usage and (in Pro) optimizes your setup to fit more into every weekly limit.

**Status:** v1.0-alpha — Free tier only.

## Build

Requires:
- Xcode 16+
- XcodeGen (`brew install xcodegen`)
- macOS 14+ for both build and run.

```bash
xcodegen generate
open Throttle.xcodeproj
```

## Tests

```bash
xcodebuild test -project Throttle.xcodeproj -scheme Throttle -destination 'platform=macOS'
```

## Distribution

Notarized direct download from lorislab.fr. Not App Store.

## Identity

Published by **Christine Martin** (LorisLabs).
- Apple Developer Team ID: TDV6D5L785
- Bundle ID: com.lorislab.throttle
