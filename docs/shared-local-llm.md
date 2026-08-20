# Shared local LLM — Ollama on Proxmox (LXC 179)

Hand this file to any project that wants to use the local model. Throttle is the
primary tenant; everything below is a constraint that comes from sharing one
small GPU with Plex and Frigate.

All numbers here were measured on **2026-08-20** from Kevin's Mac. Re-measure
before trusting them if the box has been rebooted or Plex's VRAM use has changed
— the diagnostics at the end are the same ones that produced them.

## Endpoint

| From | URL |
|---|---|
| LAN (VLAN 1709) | `http://10.9.8.179:11434` |
| Tailnet | `http://100.123.83.107:11434` |

The tailnet address is a DNAT on the Proxmox host (`100.123.83.107:11434 →
10.9.8.179:11434`), persisted by `throttle-ollama-dnat.service`. Standard Ollama
0.32.14 HTTP API. **No authentication of any kind.**

## Models

- **`throttle-worker:latest`** — use this one. It is `qwen3:4b` with
  `PARAMETER num_thread 6` baked in, which exists to stop a specific failure:
  llama.cpp reads the *host's* core count, not the container's cgroup, so an
  unconstrained run spawns far more threads than the LXC has and spinlocks into
  an effectively infinite generation.
- `qwen3:4b` — the base model. Prefer `throttle-worker`.

Do not pull more models without asking. The container has 40 GB of disk and
8 GB of RAM; it cannot hold two resident models (see below).

## The one rule that matters: `num_ctx` ≤ 8192

The Quadro P2000 has 5046 MiB, of which roughly 1188 MiB are held by Plex and
Frigate — leaving about **3858 MiB free**. The model itself is 2375 MiB and fits
easily. The KV cache is what does not.

| `num_ctx` | KV cache | Layers on GPU | Result |
|---|---|---|---|
| 16384 | 2304 MiB | **0 / 37** | falls back to CPU — 78 s for one bounded extraction |
| 8192 | 864 MiB | 28 / 37 | ~11 tok/s |
| 4096 | ~432 MiB | more still | ~19 tok/s reported 2026-08-19 |

At 16384 llama.cpp projects 4770 MiB against 3858 free, gives up on the GPU
entirely, and runs every layer on CPU. There is no warning in the API response —
the request simply takes 15× longer. **Never exceed 8192 without checking free
VRAM first.**

Throttle sizes its own window per request (`LocalWorkerRouter.contextWindow`)
rather than asking for the worst case every time. Do the same, or just pin 8192.

## Latency profile

- **Cold load: ~29 s.** `OLLAMA_KEEP_ALIVE` is 5 minutes, so a project that
  calls the model sporadically pays this on nearly every request.
- **Warm generation: ~11 tok/s** at `num_ctx` 8192.

This is a batch / sidecar resource. It is not usable for anything interactive.

## Sharing rules

There is no concurrency configuration yet — neither `OLLAMA_NUM_PARALLEL` nor
`OLLAMA_MAX_LOADED_MODELS` is set, so Ollama picks defaults based on free memory
and that choice can change on its own. Deep research on 2026-08-20 recommends
pinning both to `1` on a box with this little VRAM, because Ollama's own docs
state that parallel requests multiply the context memory proportionally. **That
change is not applied yet** — until it is, expect the default behaviour
described below.

In practice:

1. **Requests queue.** A Throttle delegation can hold the box for 30–80 s. Your
   request waits behind it.
2. **Use the same model and the same `num_ctx` as Throttle.** The LXC's 8 GB
   cannot hold two resident models (`throttle-worker` alone is 5.09 GB), so a
   second configuration forces an eviction and a 5 GB reload — about 29 s burned
   every time the two projects alternate.
3. If your project genuinely needs a *different* model, do not share this box.
   Ask for a second LXC instead. The researched recommendation is one standard
   extraction model shared by every client project, not one model per project.

Note on `keep_alive`: raising it (even to `-1`) is **not** an eviction lock.
Ollama's scheduler may still unload an idle model when another request needs
memory it cannot find. The only real guarantee that the model stays resident is
that nobody sends a *different* model to this instance — which is why rule 2
matters more than any timeout setting.

## Do not

- **`DELETE /api/delete`** — there is no auth, so this would remove
  `throttle-worker` for every tenant.
- Pull large models onto the 40 GB volume without checking first.
- Assume `qwen3` answers directly. It reasons by default: send `"think": false`
  or you will get prose where you expected a result.

## Example

```bash
curl -X POST http://100.123.83.107:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "throttle-worker",
    "stream": false,
    "think": false,
    "prompt": "…",
    "options": { "num_ctx": 8192, "num_predict": 384, "temperature": 0.2 }
  }'
```

From a Claude Code shell, `curl` output may be rewritten into a pseudo-schema
summary. Use `curl --noproxy '*' … -o file` and read the file to see raw JSON.

## Diagnosing

Is a model resident right now, and what is it costing?

```bash
curl -s --noproxy '*' http://100.123.83.107:11434/api/ps -o /tmp/ps.json
```

Did the last request actually reach the GPU?

```bash
ssh -i ~/.ssh/proxmox_nopass root@100.123.83.107 \
  "pct exec 179 -- journalctl -u ollama --no-pager -n 200 \
   | grep -E 'memory breakdown|projected to use|offloaded|CUDA0'"
```

`offloaded N/37 layers to GPU` is the line that matters. `projected to use X MiB
of device memory vs. Y MiB of free device memory` tells you why when N is 0.

Live tail of every HTTP call, to confirm your client is actually hitting the box:

```bash
ssh -i ~/.ssh/proxmox_nopass root@100.123.83.107 \
  "pct exec 179 -- journalctl -u ollama -f -n 0 --no-pager"
```

## Host facts

- LXC **179** `throttle-ollama` on `pve`: Debian 13, 8 cores, 8 GB RAM, 2 GB
  swap, 40 GB on rpool-ct, `vmbr2` tag 1709, IP `10.9.8.179`, starts on boot.
- GPU: Quadro P2000 5 GB passed through unprivileged, driver 580.159.04, shared
  with Plex/Frigate. `nvidia-smi` is not on the host `PATH` — use
  `LD_LIBRARY_PATH=/opt/nvidia-libs /opt/nvidia-libs/nvidia-smi`.
- Proxmox host: 32 cores, typically around load 23 — busy but not saturated.
