# Releasing Throttle (Developer ID + Sparkle)

The public site is the source of truth: `https://lorislab.fr/throttle/appcast.xml` and
`https://lorislab.fr/throttle/`. The `lorislab-website` checkout drifts behind it and is
never the thing a release reads from. Every step below is fail-closed and byte-verified.

## 0. Lane

- Branch `release/<version>-<build>`, worktree under **`$HOME`** (e.g. `.claude/worktrees/`),
  not `/tmp`: a SwiftLint baseline regenerated under `/tmp` stores absolute paths and CI goes red.
- Journal: `audit-output/release-<version>.md` (checkbox ledger; commit with `-f`, the dir is ignored).
- Bump **both** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Sparkle
  compares `CFBundleVersion` only; a release with a reused build number is never offered.

## 1. Test

```
xcodebuild -scheme Throttle -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/throttle-<ver>-derived \
  -skipPackagePluginValidation -skipMacroValidation test
```
~4–5 GB of DerivedData: check `df` first, delete it afterwards.

## 2. Build, sign, notarize, sign the appcast entry

```
PROJECT_DIR=<worktree> THROTTLE_RELEASE_BUILD_DIR=<worktree>/build scripts/build-dmg.sh --notarize
```
Refuses to run if the build number is already in the live appcast or the lint baseline holds
absolute paths. Produces `build/Throttle-<ver>.dmg` (stapled) and `build/appcast-entry-<ver>.xml`
(EdDSA signature + length of the final DMG).

## 3. Stage (isolated directory, nothing uploaded)

```
scripts/stage-release.py --notes release-notes.html      # version read from project.yml
```
Fetches the live appcast and page, strips the Cloudflare/WebMCP response transformations from
the page, prepends the item, updates version/link/size, and writes `build/stage/throttle/`
(`appcast.xml`, `index.html`, the DMG). Prints sizes and SHA-256s for the ledger.

## 4. Publish (one archive, merge-extracted over `public_html/`)

```
HOSTINGER_API_TOKEN=… node scripts/publish-release.mjs build/stage
```
Only the three staged files move. The deploy trigger's status code is not evidence; the stamp is.

## 5. Verify as a client

```
scripts/verify-public-release.sh build/stage
```
DMG HTTP 200 + exact length through plain and cache-busted requests, full download SHA-256
equal to the staged DMG, appcast byte-identical with the new build on top (fresh and
edge-cached), page linking the new DMG. Record the hashes in the ledger.

## 6. Afterwards

- Copy the staged `appcast.xml` and `index.html` into `lorislab-website/throttle/` and commit,
  so the repo stops drifting (the DMG is git-ignored there; keep a copy next to the others).
- Installing/relaunching the app on the build machine is a separate decision — never implied.
