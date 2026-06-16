# Design — Semantic dedup cache (notebook Q3 #2)

**Idea:** local MLX embeddings + a SQLite vector store intercept repetitive
prompts / tool calls and serve a CACHED prior response instead of paying the API
again — claimed up to 60% on redundant calls.

## Why this is the riskiest token-saver of all
1. **Correctness.** Serving a cached LLM/tool response for a "similar" prompt is
   semantically unsafe: near-identical prompts can need different answers (the
   repo changed, the date changed, context differs). A wrong cache hit silently
   feeds the user stale/incorrect output — far worse than spending tokens.
2. **No safe interception point.** To substitute a response, Throttle would have
   to sit in the request path (a proxy) — which is an explicit non-goal
   ("never a data-path proxy"). A hook can't fabricate a model response.
3. **Embedding cost/complexity.** MLX embeddings per prompt + a vector store +
   similarity tuning is heavy infra for a feature whose upside is capped by how
   often truly-identical work repeats (rare in real dev sessions).

## The only doctrine-safe shape
NOT response substitution. At most: **detect** repeated/near-duplicate tool
calls or prompts and *surface* them ("you've run this same query 6× — cache the
result yourself?") — an advisory, read-only insight in the Optimizer. No serving,
no proxy. That's a much smaller, safe feature, but also a much smaller win.

## Verdict
**Do NOT build the response-serving cache** — it violates the no-proxy non-goal
and risks silently-wrong output (the cardinal sin). If anything, ship only the
**advisory "you're repeating this" insight** later, low priority. The real,
safe token wins are already covered (TokoptHook compression, TOON, read-firewall,
cache hygiene). Lowest priority / mostly a no.
