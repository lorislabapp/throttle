# Output styles / caveman — deep research 2026-07-14

73/105 agents (32 tues par la limite de depense mensuelle, synthese incluse) — 15 claims verifies 3-0 ou 2-1 sur sources primaires.

## 1. [3-0] The community-published ~63% output-token reduction claim for a terse 'token-efficient' CLAUDE.md does NOT reproduce under an automated harness (headless `claude -p --output-format json`, N=5 per cell, fresh /tmp dirs, `--setting-sources project`): the minimal profile's real effect is only about -2% (haiku) to -11% (opus, excluding the format-test prompt). This directly undercuts the 65-75% savings figures in circulation — note the mechanism tested is a CLAUDE.md instruction file, not the outputStyle setting, but it measures the same 'terse-instructions' lever.

Source: https://github.com/drona23/claude-token-efficient/benchmark/SUMMARY.md
> **The published 63% reduction does not reproduce on the current minimal CLAUDE.md.** Real effect ranges from ~-2% (haiku) to -11% (opus, excl. T4). It does reproduce with `profiles/CLAUDE.compressed.md` on opus (-62%).

## 2. [2-1] Large output-token savings ARE achievable, but only with an aggressive 'compressed' profile that trades away safety guards: measured -22% (haiku), -32% (sonnet), -62% (opus, 1936→727 tokens) with the same harness, while explicitly dropping fabrication and re-read guards.

Source: https://github.com/drona23/claude-token-efficient/benchmark/SUMMARY.md
> | opus   | 1936 to 727 **-62%**  | $0.3997 to $0.3451 | ... The compressed profile drops fabrication and re-read guards in exchange for shorter output. Use when token cost dominates and the workload is low-risk.

## 3. [2-1] For short prompts, a terse-instructions profile is roughly cost-neutral: the persistent per-turn input-token overhead of the injected instructions cancels the output savings, so net savings require high output volume — a key sizing consideration for any tool (like Throttle) auto-configuring this.

Source: https://github.com/drona23/claude-token-efficient/benchmark/SUMMARY.md
> **On short prompts the minimal profile is roughly cost-neutral.** Per-turn input overhead cancels output saving. Net savings need high output volume to offset the persistent input cost.

## 4. [3-0] Custom output styles are appended to the end of the system prompt and, by default (keep-coding-instructions defaults to false), REMOVE Claude Code's built-in software engineering instructions — so a 'caveman' compression style without keep-coding-instructions: true changes coding behavior, not just verbosity.

Source: https://code.claude.com/docs/en/output-styles
> All output styles have their own custom instructions added to the end of the system prompt. ... Custom output styles leave out Claude Code's built-in software engineering instructions, such as how to scope changes, write comments, and verify work, unless `keep-coding-instructions` is set to `true`.

## 5. [3-0] Output style changes do NOT apply to a running session: the system prompt is read once at session start, and a style change only takes effect after /clear or a new session — a direct explanation for 'the style is active in settings.json but has no visible effect'. The docs also link this to a prompt-cache impact when changing style.

Source: https://code.claude.com/docs/en/output-styles
> Output style is part of the system prompt, which Claude Code reads once at session start. Changes take effect after `/clear` or a new session. See [How Claude Code uses prompt caching](/en/prompt-caching#changing-output-style) for what an output style change does to the cache.

## 6. [3-0] Claude Code injects in-conversation reminders to keep the model complying with the active output style — the documented mechanism against drift in long sessions.

Source: https://code.claude.com/docs/en/output-styles
> All output styles trigger reminders for Claude to adhere to the output style instructions during the conversation.

## 7. [3-0] The standalone /output-style command was deprecated in v2.1.73 and removed in v2.1.91; style selection now goes through /config or the outputStyle settings key, and the /config menu writes the choice to .claude/settings.local.json at the local project level (so a project-local file can shadow a global setting).

Source: https://code.claude.com/docs/en/output-styles
> The standalone `/output-style` command was deprecated in v2.1.73 and removed in v2.1.91. Use `/config` or edit the `outputStyle` setting directly. ... Your selection is saved to `.claude/settings.local.json` at the [local project level](/en/settings).

## 8. [3-0] L'output style fait partie du system prompt et n'est lu qu'une seule fois au démarrage de la session : le changer en cours de session (via /config ou le setting outputStyle) ne s'applique PAS — Claude continue avec le style chargé au départ, et le nouveau style ne prend effet qu'au prochain /clear ou redémarrage. Cela explique directement le symptôme « le style est actif dans settings.json mais l'effet ne se voit pas » si le changement a été fait en cours de session.

Source: https://code.claude.com/docs/en/prompt-caching
> Output style is part of the system prompt, which Claude Code reads once at session start. Changing it via /config or the outputStyle setting mid-session does not invalidate the cache, but the change also doesn't apply. Claude keeps working with the style that was loaded at session start. The new style loads on the next /clear or restart.

## 9. [3-0] L'output style vit dans la couche « system prompt » du prompt (avec les instructions core et les définitions d'outils), et toute modification du system prompt invalide l'intégralité du cache — donc démarrer une nouvelle session avec un style différent recompute tout le préfixe (coût one-shot), mais le style est « fixé au démarrage de session » et un changement mid-session ne casse PAS le cache (parce qu'il ne s'applique pas).

Source: https://code.claude.com/docs/en/prompt-caching
> System prompt | Core instructions, tool definitions, output style [...] A change to the system prompt invalidates everything, because all later content now sits behind a different prefix. The third column gives common triggers rather than an exhaustive list, and the sections below cover the full set, including content such as output style that is fixed at session start.

## 10. [3-0] Custom output styles REMOVE Claude Code's built-in software engineering instructions from the system prompt by default; they are only retained if the frontmatter sets keep-coding-instructions: true (default is false). A 'caveman' compression style without this flag therefore also strips coding guidance, changing behavior beyond verbosity.

Source: https://code.claude.com/docs/en/output-styles.md
> Custom output styles leave out Claude Code's built-in software engineering instructions, such as how to scope changes, write comments, and verify work, unless `keep-coding-instructions` is set to `true`.

## 11. [3-0] The output style is injected into the system prompt and read only once at session start — changing outputStyle mid-session has no effect until /clear or a new session, and the style change interacts with the prompt cache (documented on the prompt-caching page under 'Changing output style').

Source: https://code.claude.com/docs/en/output-styles.md
> Output style is part of the system prompt, which Claude Code reads once at session start. Changes take effect after `/clear` or a new session. See [How Claude Code uses prompt caching](/en/prompt-caching#changing-output-style) for what an output style change does to the cache.

## 12. [3-0] Selecting a style via /config writes outputStyle to .claude/settings.local.json at the LOCAL PROJECT level (not the global ~/.claude/settings.json), and the standalone /output-style command was deprecated in v2.1.73 and removed in v2.1.91 — two concrete scope/version pitfalls for 'the style isn't applying'.

Source: https://code.claude.com/docs/en/output-styles.md
> Your selection is saved to `.claude/settings.local.json` at the [local project level](/en/settings). ... The standalone `/output-style` command was deprecated in v2.1.73 and removed in v2.1.91. Use `/config` or edit the `outputStyle` setting directly.

## 13. [3-0] Anthropic makes no output-token savings claim for custom styles — the docs state output token impact depends entirely on the style's instructions, and that adding style instructions increases input tokens (mitigated by prompt caching after the first request). The 65-75% savings figure is not backed by this primary source.

Source: https://code.claude.com/docs/en/output-styles.md
> Token usage depends on the style. Adding instructions to the system prompt increases input tokens, though prompt caching reduces this cost after the first request in a session. ... For custom styles, output token usage depends on what your instructions tell Claude to produce.

## 14. [2-1] Prompt cache invalidation is hierarchical (tools → system → messages): any modification to the system prompt invalidates both the system cache and the messages cache — so switching a Claude Code output style (which is injected into the system prompt) forces a full re-cache of system + conversation history.

Source: https://platform.claude.com/docs/en/build-with-claude/prompt-caching
> The cache follows the hierarchy: `tools` → `system` → `messages`. Changes at each level invalidate that level and all subsequent levels.

## 15. [1-1] Cache matching uses a cumulative prefix hash, so changing any block at or before a cache breakpoint produces a different hash and a cache miss — a mid-session output-style change cannot preserve any downstream cached content.

Source: https://platform.claude.com/docs/en/build-with-claude/prompt-caching
> Because the hash is cumulative, covering everything up to and including the breakpoint, changing any block at or before the breakpoint produces a different hash on the next request.
