# Throttle release ledger — 3.2.85 (185)

Updated UTC: 2026-08-19T13:00:00Z
Repository: `/Users/kevinnadjarian/GitHub/Throttle`
Channel: Developer ID direct distribution through Sparkle
Authority: user greenlit "ok ont met sa en place?" on 2026-08-19 after choosing auto-failover routing.

## Scope

- App: `com.lorislab.throttle`
- Version/build: 3.2.85 (185)
- Features: LocalWorkerRouter (delegated MCP tasks prefer a user-configured Ollama
  server, health-probed, silent fallback to embedded MLX Qwen, per-backend counters,
  honest Model: attribution) + at-cap menu-bar countdown (exact/Codex reset
  timestamps only, TimelineView every minute, clamps to "now").

## Verification

- Full XCTest suite: PASS (all suites; MenuBarCountdownTests additionally run alone, 4/4).
- Debug build with router: PASS before release.
- First real-world delegation exercised end-to-end the same day (BACKLOG.md extract):
  the 1.7B returned wrong items, validation correctly returned review_required —
  contract working; motivates the server routing this release ships.

## Assets

- Final stapled DMG: `build/Throttle-3.2.85.dmg` (copied to lorislab-website/throttle/).
- Size: 26,469,331 bytes. SHA-256 starts `4db954c9a94aa78fe1e5`.
- Notarization + staple: validate action worked (script pipeline; submission in build log).
- Sparkle EdDSA signature: `UrlHe5cb1ATBpKBsdekJRKNU794r2mf5DAogCkV9f09sBnmrU7ng67N5Y+o+yZebnG4iJ8Cu4SUzyJsTByNZBg==`.

## Publication

- lorislab.fr LIVE (stamp 20260819125153-9nvhiu80, DEPLOY_DMG=1): appcast 3.2.85 with
  release-notes description, landing "Local worker server" New row + v3.2.85 / 26.5 MB.
- Independent post-deploy check: served DMG SHA-256 prefix matches the local artifact.
- User's unrelated arcyra/kernel WIP stashed/held during deploy and fully restored (established consent).

## Infrastructure shipped alongside (not in the app)

- Proxmox LXC 179 `throttle-ollama`: Ollama 0.32.14, qwen3:4b + `throttle-worker`
  (num_thread 6), Quadro P2000 passthrough (19.2 tok/s from the Mac via
  100.123.83.107:11434 DNAT). Endpoint pre-written into the user's defaults
  (`throttleLocalWorkerServerURL`) so 3.2.85 routes to it on first launch.

## Gates left

- User installs the Sparkle update (app currently not running; last check 2026-08-18).
- First SERVED counter increments from real sessions = the loop closed.

## Hotfix 3.2.86 (même journée)

- Le Test du local worker chez Kevin échouait en "No answer" sans détail; le probe ne loggait rien — indiagnosticable à distance (aucune tentative visible côté TCP/CFNetwork, cause encore ouverte).
- 3.2.86: erreur réelle affichée sous Test (statut HTTP ou NSError), os_log LocalWorkerRouter, budget probe 3s→5s.
- Publiée + vérifiée live 2026-08-19 (stamp 20260819171946, DMG hash local = servi).

## Hotfix 3.2.87 — ATS (cause racine du local worker)

- Root cause: NSAllowsLocalNetworking ne couvre pas 100.64/10 (Tailscale CGNAT) -> URLSession refuse en -1022 AVANT tout socket. curl marchait (pas dInfo.plist, donc pas dATS). Les 2 cles ATS ne se combinent pas.
- Verifie empiriquement (mini-app bundlee, 3 variantes) avant correctif.
- Fix: cible Mac = NSAllowsArbitraryLoads seul; iOS non touchee (App Store + transport Network.framework).
- + statut du bouton Test non tronque/selectionnable.
- Suite XCTest complete PASS; DMG notarise+staple verifie (bundle porte bien la cle); live 2026-08-19 stamp 20260819193559, hash local = servi.
