# Hybrid local / remote model story for a Vision Pro coding cockpit

**Date:** 2026-09-09
**Scope:** Vision Pro + Mac + self-hosted Proxmox/Ollama, for Throttle (LorisLabs)
**Method:** web research this session (Apple primary docs where possible, WWDC session transcripts, arXiv, vendor docs, community benchmarks) plus a read of Throttle's current router/local services.
**Epistemic contract:** every number below carries a source and a date. Anything I could not verify is written as `NOT VERIFIED` with what I searched. I have not invented a benchmark number, a model size, or an API name anywhere in this document.

---

## 1. Verdict (15 lines)

1. The headset is a **display and a control surface, not a compute node**. Ship it that way.
2. Apple's own per-app memory ceiling on visionOS is **5 GB** (Apple DTS engineer, Sept 2025) on a 16 GB device — that rules out anything above a small quantised model, and nobody has published a real on-device LLM benchmark on Vision Pro.
3. The Mac is the only place where local inference is credibly useful; the Proxmox box is the only place where it is *free of the user's RAM budget* — and Kevin's Mac has 16 GB, so the Proxmox box wins by default.
4. In 2026 Apple ships a genuinely better `FoundationModels`: **8192-token** on-device context, image input, tool calling, guided generation, and a `LanguageModel` protocol that lets you plug **`MLXLanguageModel(modelID:)`** — verified in WWDC26 sessions 241/339, and it lists visionOS.
5. **Do not promise AFM 3 Core Advanced.** Apple documents the 20B sparse model; Apple documents no API to request it, and I found no source saying third-party apps get it.
6. Do not promise auto-routing. `LLMRouterBench` (Jan 2026, 400k+ instances) found commercial routers often fail to beat a simple baseline; a 2026 paper argues published routing savings are evaluation artifacts.
7. Do not promise a cost saving that ignores the prompt cache. Anthropic's documented economics — cache read at **0.1×**, cache write at **1.25×/2×** — mean a local detour that strands a frontier cache write can cost *more* than not routing at all.
8. Keep the abstention contract. It is the part of Throttle's design the 2026 literature most clearly supports, and the part competitors keep getting wrong.
9. What is genuinely defensible to build: **cache-aware advisory routing, measured on Kevin's own usage.db, displayed in a spatial cockpit that runs no models itself.**
10. What must never be promised: on-device agentic coding in the headset; a specific token/s figure on Vision Pro; access to Apple's 20B model; a percentage cost saving not measured on a golden set; "the local model knows when it can't."
11. Latency is a solved-enough problem *if* you copy mosh: local echo prediction beats chasing RTT (USENIX ATC 2012 — SSH median 503 ms → predicted-instant).
12. The binding constraint on Vision Pro coding is not latency and not compute — it is **text legibility and comfort at ~30–90 minutes** (independent first-person report, 2024), and the M5 Vision Pro has the same 23-million-pixel display.
13. So the cockpit's value in the headset is *supervision and situational awareness*, not typing. Design for glanceable state, not for an editor.
14. Everything agentic stays on the Mac or on LXC — which is exactly what Throttle already does.
15. Net: this is a **positioning and instrumentation** opportunity, not a modelling one. Build the honest meter, not the clever router.

---

## 2. Evidence

### Q1 — Apple's FoundationModels framework as of 2026

#### 2025 baseline (what shipped in the 26 cycle)

Verified from Apple's WWDC25 session "Meet the Foundation Models framework" (<https://developer.apple.com/videos/play/wwdc2025/286/>):

- On-device model: **~3 billion parameters, 2-bit quantisation**, described by Apple as a "device-scale" model.
- **Guided generation**: `@Generable` / `@Guide` macros with **constrained decoding**, so the framework guarantees *structural* correctness (primitives, arrays, nested and recursive `@Generable` types). Apple's framing: no JSON parsing needed.
- **Tool calling**: `Tool` protocol with a `@Generable Arguments` type and `ToolOutput`; tools must be attached at `LanguageModelSession` init.
- **Streaming**: snapshot-based, not delta-based — `PartiallyGenerated<T>` values with optional properties. Apple notes property declaration order affects output quality.
- **Built-in use case**: `SystemLanguageModel(useCase: .contentTagging)`.
- **Apple's own stated limits**: not for world knowledge; not for advanced reasoning; task decomposition required; prompt-injection mitigation exists but is "not bulletproof"; error surface includes guardrail violation, unsupported language, and context-window-exceeded.

#### Availability (verified from Apple developer documentation)

`SystemLanguageModel` (<https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel>, machine-readable form fetched 2026-09-09):

| Platform | Introduced |
|---|---|
| iOS / iPadOS / Mac Catalyst / macOS / **visionOS** | 26.0 |
| watchOS | 27.0 (per framework landing page) |

Apple documents **three model versions**, aligned to `26.0–26.3`, `26.4`, and `27.0`. This matters more than it looks: Apple explicitly versions the model behind a stable API, so prompt behaviour is not stable across point releases.

Apple's own framework overview text:

> "On-device models excel at a diverse range of text generation tasks, like summarization, entity extraction, text and image understanding, refinement, dialog for games, generating creative content, and more."
> "When you need more reasoning capabilities and context size, use Private Cloud Compute or any server model provider."

Availability is gated on the device and region supporting Apple Intelligence — the framework exposes an `availability` enum, `supportedLanguages`, `supportsLocale(_:)` and `contextSize`. The documentation pages do **not** state a parameter count, a context number, a language list, or rate limits. `NOT VERIFIED`: the exact documented language list for the framework (as opposed to the model card) — Apple's docs point to a runtime property rather than a published list.

#### What is new in 2026 (WWDC26)

Verified from "What's new in the Foundation Models framework" (<https://developer.apple.com/videos/play/wwdc2026/241/>):

- `SystemLanguageModel` rebuilt: better logic and tool calling, **`contextSize` = 8192 tokens**, and **vision input** via `Attachment` (UIImage/NSImage/CGImage/Core Image/CVPixelBuffer/file URLs, any size — larger images cost more tokens and latency).
- **`PrivateCloudComputeLanguageModel`**: **32,000-token** context, reasoning support via `ContextOptions(reasoningLevel:)` with `.light` / `.deep`, no API keys or account setup, and free for apps under 2 million first-time downloads.
- **`DynamicProfile` / `Profile`** — a declarative way to switch instructions, tools, model and reasoning level by app state. This is the closest thing Apple ships to a router primitive, and note that *the developer* writes the switch; Apple does not route for you.
- New instrumentation: `model.tokenCount(for:)` and a `response.usage` with `input.totalTokenCount`, **`input.cachedTokenCount`**, `output.totalTokenCount`, `output.reasoningTokenCount`.
- Built-in system tools: `BarcodeReaderTool`, `OCRTool` (both Vision-backed) and a Spotlight-powered local RAG search tool.
- Ecosystem: an **Evaluations** Swift framework, an **`fm` CLI** on macOS 27, a Foundation Models SDK for Python, and open-sourcing of framework utilities.

Verified from "Bring an LLM provider to the Foundation Models framework" (<https://developer.apple.com/videos/play/wwdc2026/339/>):

```swift
public protocol LanguageModel: Sendable {
    var capabilities: LanguageModelCapabilities { get }
    var executorConfiguration: Executor.Configuration { get }
}

public protocol LanguageModelExecutor: Sendable {
    init(configuration: Configuration) throws
    func prewarm(model: Model, transcript: Transcript)
    func respond(to request: LanguageModelExecutorGenerationRequest,
                 model: Model,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws
}
```

Two Apple-provided local implementations, both listed for **iOS, macOS, visionOS, watchOS**:

- `try await CoreAILanguageModel(resourcesAt: modelURL)` — runs on the **ANE**, model bundled into the app.
- `MLXLanguageModel(modelID: "mlx-community/my-model")` — any MLX-format model from the `mlx-community` Hugging Face org.

Anthropic and Google are named as launch partners publishing Swift packages implementing `LanguageModel`.

`NOT VERIFIED`: which module `MLXLanguageModel` and `CoreAILanguageModel` actually live in. They do **not** appear in the FoundationModels framework symbol index I fetched (which lists `LanguageModelSession`, `SystemLanguageModel`, `PrivateCloudComputeLanguageModel`, `Prompt`, `Instructions`, `GenerationOptions`, `ContextOptions`, `GenerationSchema`, `DynamicGenerationSchema`, `GeneratedContent`, `DynamicProfile`, `Profile`, `DynamicInstructions`, `Tool`, `Attachment`, `ImageAttachmentContent`, `ImageReference`, `LanguageModel`, `LanguageModelExecutor`, `LanguageModelCapabilities`, `LanguageModelError`, `SessionProperty*`). They are presumably separate SPM packages. Confirm before designing around them.

#### visionOS and Vision Pro M2 vs M5

- `SystemLanguageModel` is available on **visionOS 26.0** — same API, same 8192-token model in the 27 cycle. There is no documented visionOS-specific restriction on the framework itself.
- **M2 Vision Pro** (released 2024-02-02) and **M5 Vision Pro** (released 2025-10-22) both have **16 GB unified memory**. Apple's current tech specs page (<https://www.apple.com/apple-vision-pro/specs/>) lists: M5, 10-core CPU (4 performance + 6 efficiency), 10-core GPU, R1 with **12 ms photon-to-photon latency**, 16 GB unified memory, 23 million pixels, refresh up to 120 Hz, **up to 2.5 h general use / 3 h video playback**, 750–800 g headset + 353 g battery.
- Apple's marketing claim for M5 Vision Pro is "AI features up to 50% faster" than M2 (vendor claim, via MacRumors 2025-10-15 — <https://www.macrumors.com/2025/10/15/apple-announces-vision-pro-with-m5-chip/>). `NOT VERIFIED` independently.
- **Reported, not Apple-documented**: visionOS 27 features exclusive to the M5 Vision Pro (adjustable Siri voice, improved dictation), attributed to AFM 3 Core Advanced. Source was a TechTimes article dated 2026-08-11 that returned HTTP 403 on fetch; I have only the search-result summary. Treat as **reported, unverified**.
- The **decisive limit is not the framework, it is memory**: an Apple Vision Pro engineer states on the developer forums (thread 801491, Sept 2025, <https://developer.apple.com/forums/thread/801491>):
  > "The memory limit for an app on visionOS is 5 GB, but you should always try to stay far below that number."

---

### Q2 — AFM 3 Core Advanced (~20B)

**Documented by Apple** (Apple Machine Learning Research, "Introducing the Third Generation of Apple's Foundation Models", June 2026 — <https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models>):

| Model | Where | Size |
|---|---|---|
| AFM 3 Core | on-device | 3B dense |
| **AFM 3 Core Advanced** | on-device | **20B sparse**, 1–4B activated per request |
| AFM 3 Cloud | Private Cloud Compute | not stated |
| ADM 3 Cloud (Image) | PCC | not stated |
| AFM 3 Cloud Pro | NVIDIA GPUs in Google Cloud | not stated |

Apple's stated mechanism: **Instruction-Following Pruning (IFP)**, "always-active shared experts alongside input-dependent routed experts", with the full model held in **flash (NAND)** and only the routed slice loaded into DRAM per prompt. Quantisation-aware training applied across the family. Apple's stated hardware framing is qualitative — "unlocked by and optimized for our most capable Apple silicon systems" — **with no RAM number in Apple's own text.**

Apple's stated quality numbers (human preference, Apple's own evaluation): AFM 3 Core preferred on 45.6% of prompts vs 23.3% for the baseline; AFM 3 Cloud 64.7% vs 8.7%; image understanding preferred >61%; TTS MOS 4.15 vs 3.87. These are vendor-run preference evaluations, not third-party benchmarks.

**Reported but not Apple-documented**: a 12 GB RAM floor, and a device list of iPhone Air / iPhone 17 Pro & Pro Max / M4+ iPad / M3+ Mac / M5 Vision Pro. This circulated via a leak account and secondary press (KuCoin, TechRadar, Memeburn summaries) before WWDC. `NOT VERIFIED` against any Apple page.

**Can third-party apps use it? I could not verify that they can, and I found no evidence that they can.**

- The Foundation Models API surface has exactly one on-device entry point, `SystemLanguageModel`, with **no documented model-tier selector**. `SystemLanguageModel.contextSize` is shown as `8192` in WWDC26 session 241 regardless of hardware.
- The WWDC26 community writeup describing the framework's model options characterises the on-device model as "about 3B parameters" (<https://dev.to/arshtechpro/wwdc-2026-apple-just-opened-the-foundation-models-framework-to-any-llm-provider-5ejn>) — consistent with AFM 3 Core, not Core Advanced.
- A 2026-06-17 analysis states "AFM 3 is Apple's proprietary model, exposed only through the Foundation Models framework on Apple devices" (<https://runaihome.com/blog/wwdc-2026-apple-ai-home-lab-verdict-2026/>) — which says the framework is the only door, but says nothing about which tier is behind it.

**Conclusion, stated as uncertainty:** the honest position is that Apple has documented a 20B on-device model and has *not* documented an API to request it. If `SystemLanguageModel` silently upgrades on 12 GB+ hardware, Apple has not said so in anything I could fetch. **Throttle must not build a feature, a marketing line, or a cost model on Core Advanced.** The one API-observable signal that would settle it is `SystemLanguageModel.default.contextSize` and measured quality differing across a 8 GB Mac and a 16 GB+ Mac on the same OS build — that is a cheap experiment Kevin can run himself, and it is the correct way to close this gap.

---

### Q3 — Local models on Apple silicon in 2026

#### MLX maturity

- `mlx-swift-lm` declares platform targets **macOS 14, iOS 17, tvOS 17, visionOS 1** in its `Package.swift` (<https://github.com/ml-explore/mlx-swift-lm/blob/main/Package.swift>) — visionOS is a first-class target, not an afterthought. Swift Package Index shows active releases through early September 2026.
- `mlx-swift-examples` ships a **VLMEval sample documented as supporting visionOS** — the strongest direct evidence MLX inference actually executes on visionOS rather than merely compiling. (Community source; the repo's release-date metadata came back internally inconsistent, so treat version↔date pairings as `NOT VERIFIED`.)
- Apple has endorsed MLX at WWDC25 (session 315, "Get started with MLX for Apple silicon") and at WWDC26 (session 233, "Explore distributed inference and training with MLX"). **Distributed MLX requires RDMA over Thunderbolt 5** and macOS 26.2+, with a new Apple collective-comms library (JACCL); the demo used 4× M3 Ultra. This is irrelevant to a headset and confirms Apple's own view that scaling local inference means *wiring Macs together*, not shrinking into a device.
- MLX targets **CPU + GPU/Metal**, not the ANE, for LLM inference as of this research (`NOT VERIFIED` from a primary source; supported indirectly by 2026 arXiv work — "Orion" 2603.06728, "ANEForge" 2606.17090 — that treats programming the ANE as an open research problem). Apple's `CoreAILanguageModel` is the ANE path.

#### Quantisation

From `mlx-lm`'s own `LEARNED_QUANTS.md` (<https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LEARNED_QUANTS.md>): four approaches — **DWQ** (distilled, best at 2–4 bit, slowest), **AWQ** (activation-aware, default 4-bit), **GPTQ** (default 4-bit), and **dynamic** (mixed, default 5-bit for sensitive layers / 4-bit elsewhere). Bit widths 2/3/4/6/8; default group size 64.

Community comparison against GGUF (contracollective.com, 2026-05-28, methodology not independently audited — treat as **community-reported**): MLX 20–40% faster decode than llama.cpp/GGUF on the same Mac (M3 Max, Llama 3.1 8B: MLX 71 tok/s vs GGUF 58 tok/s), while GGUF's mixed-precision K-quants hold a small quality edge below 8B on coding tasks (MMLU drop −0.4 to −0.8 pts for GGUF Q4_K_M vs −0.6 to −1.2 pts for MLX 4-bit). **The direction that matters for Throttle: for small models on coding-adjacent work, the quantisation format is a real quality variable, not a free speed win.**

#### Measured throughput

**Real measurements** (llama.cpp Discussion #4167, community-run but hardware-specific and reproducible, 7B model, `PP` = prompt processing bs=512, `TG` = generation bs=1, Q4_0 — <https://github.com/ggml-org/llama.cpp/discussions/4167>):

| Chip | PP tok/s | TG tok/s |
|---|---|---|
| M1 Pro (16 GPU) | 266 | 36.4 |
| M2 Pro (16 GPU) | 294 | 37.9 |
| M2 Ultra (76 GPU) | 1238 | 94.3 |
| M3 Pro (18 GPU) | 341 | 30.7 |
| M3 Max (40 GPU) | 759 | 66.3 |
| M4 (10 GPU) | 221 | 24.1 |
| M4 Max (40 GPU) | 885 | 83.1 |

The structural fact from that thread, and the single most useful mental model here: **prompt processing is compute-bound; token generation is memory-bandwidth-bound.**

**Apple's own M5 numbers** (Apple Machine Learning Research, "Exploring LLMs with MLX and the M5 Neural Accelerators", **published 2025-11-19** — <https://machinelearning.apple.com/research/exploring-llms-mlx-m5>):

- Time-to-first-token speedup M5 vs M4: Qwen 1.7B BF16 **3.57×**; Qwen 8B BF16 **3.62×**; Qwen 8B 4-bit **3.97×**; Qwen 14B 4-bit **4.06×**; GPT-OSS 20B MXFP4 **3.33×**; Qwen 30B MoE 4-bit **3.52×**.
- Generation speed: **+19% to +27%**, tracking memory bandwidth going **120 GB/s (M4) → 153 GB/s (M5)**, i.e. +28%.
- Apple's own memory guidance: a 24 GB MacBook Pro "can easily hold a 8B in BF16 precision or a 30B MoE 4-bit quantized, keeping the inference workload under 18GB for both."

This is a vendor benchmark on a Mac, and it is the closest thing to an M5 datapoint. Apple published **no Vision Pro inference numbers**, and neither did anyone else.

#### Memory footprints

`NOT VERIFIED` as a clean sourced table for 3B / 14B / 20B at 4-bit. What I *can* cite: Llama 3.1 8B is **4.53 GB** as MLX 4-bit and 4.92 GB as GGUF Q4_K_M; Qwen 2.5 32B is **17.9 GB** MLX 4-bit vs 19.8 GB GGUF (contracollective.com, 2026-05-28, community-reported).

Weight arithmetic — **this is arithmetic, not a benchmark, and it excludes the KV cache**: at 4 bits, weights ≈ 0.5 GB per billion parameters. So ~1.5 GB for 3B, ~4 GB for 8B, ~7 GB for 14B, ~10 GB for 20B dense. KV cache and runtime overhead add on top and scale with context.

#### What this means inside the headset

Against Apple's **5 GB per-app visionOS ceiling**, and staying "far below" it as Apple's engineer advises:

- A 3B model at 4-bit (~1.5 GB weights) is the only comfortable fit, with 8K context.
- An 8B at 4-bit (~4.5 GB measured for Llama 3.1 8B) leaves essentially nothing for the KV cache, the renderer, or the rest of the app on a device that also has to composite a passthrough scene at up to 120 Hz.
- 14B and 20B are out.
- Layer on **2.5 hours of battery** and a fanless-thermal design Apple describes only in marketing terms, and sustained inference in the headset is a bad trade even where it technically fits.

**Nobody has published a measured local-LLM benchmark running natively on Vision Pro.** I searched for one and could not find an independent report giving a model and a tok/s figure on Vision Pro hardware. The one visionOS app I found claiming local inference (ondevice-ai.app, self-published marketing, `NOT VERIFIED` as a shipped App Store product) *also* offers a mode where a networked Mac acts as the inference server, and says why: "executing massive language models inside a headset is constrained by physical thermal and battery limits." The ecosystem's own workaround is the finding.

---

### Q4 — Small-model reliability for coding-adjacent tasks

#### The current lineup

- **Qwen3.5 small series** — 0.8B / 2B / 4B / 9B, natively multimodal, announced by the official Alibaba_Qwen account (<https://x.com/Alibaba_Qwen/status/2028460046510965160>). Vendor-claimed; the exact announcement month is approximate.
- **IBM Granite 4.1** (3B / 8B / 30B, ~May 2026, <https://research.ibm.com/blog/granite-4-1-ai-foundation-models>) and **Granite 4.2** (3B / 8B / 30B, reported 2026-08-25, Apache 2.0, 128K context, explicit thinking-effort toggle) — the 4.2 details are secondary-sourced.
- `NOT VERIFIED / contested`: "Qwen3.8" branding and its associated Terminal-Bench figures, plus a cluster of model names ("GPT-5.4 mini", "Tiny Aya", "North Mini Code") that appeared only in SEO listicles. **Do not cite these.** They conflict with the officially confirmed Qwen3.5 naming found in the same search pass.

#### Where small models are genuinely useful

The strongest *specific* evidence is about structured output, and it cuts both ways.

**JSONSchemaBench** (arXiv 2501.10868, Jan 2025, updated through 2026 — <https://arxiv.org/abs/2501.10868>): 9,558 real-world JSON schemas across six constrained-decoding frameworks. **Coverage collapses from 86% on simple schemas to 3% on complex ones**, regardless of engine. The correct reading is not "structured output is broken" — it is *keep the schema small*. Throttle's `@Generable` types must stay flat and shallow.

And the caveat that matters more than the number: **constrained decoding guarantees the shape, not the content.** A small model under a grammar will emit schema-valid JSON with wrong field values, and a wrong value propagates silently where a parse error would have been caught.

`NOT VERIFIED`: dated benchmark numbers for small models specifically on summarisation, intent classification, reranking, or log triage. This is the most commonly asserted claim about small models and I could not find a citable 2026 evaluation for it in this pass. That is a real gap, and it argues for Throttle measuring its own golden set rather than citing anyone.

#### Where they fail

- **Aider polyglot leaderboard** (<https://aider.chat/docs/leaderboards/>, checked 2026-09-09): **no open-weight model under 10B parameters appears on the leaderboard at all.** The smallest entries are commercial. This is a primary-source absence of evidence, and it is worth more than most of the numbers below: the coding-agent community has not found sub-10B local models worth listing.
- **SWE-bench Verified**: small models (7B–13B) reported below 5% baseline (benchmarkingagents.com, aggregator, moderate-low confidence). Specialised RL/collaboration-trained 7–8B variants are reported at 11%–42% (SWE-Protégé arXiv 2602.22124, SWE-Dev-7B, Seed-Coder-8B arXiv 2506.03524) — but **these figures came from search snippets, not confirmed full-text extraction, and must be re-verified before citing.** The gap between "<5% off the shelf" and "18–42% with a bespoke training recipe" is exactly the scaffold effect that makes small-model coding claims unreliable.
- **LiveCodeBench pass@1** for 7–8B (leaderboard aggregation, version unclear, moderate confidence): Qwen2.5-Coder-7B-Instruct 35.4%, DeepSeek-Coder-6.7B-Instruct 33.9%, Seed-Coder-8B-Instruct 24.7%, Llama-3.1-8B-Instruct 24.3%, CodeLlama-7B-Instruct 14.6%. Single-shot code generation, not agentic work.
- `NOT VERIFIED`: Terminal-Bench numbers for any small model. The only figures found were attached to the contested "Qwen3.8" naming.
- `NOT VERIFIED`: any direct contamination analysis for small-model coding benchmarks. Contested by default.

#### Abstention — the part Throttle already bet on

- **"Why Language Models Hallucinate"** (OpenAI, arXiv 2509.04664, Sept 2025 — <https://arxiv.org/html/2509.04664v1>): the mechanism is evaluation, not architecture. Binary 0-1 scoring **rewards confident guessing over abstention**, so models are trained into overconfidence. The paper does **not** break calibration down by parameter count, so it does not establish that small models are specifically worse.
- **AbstentionBench** (NeurIPS 2025, secondary-sourced, `needs primary verification`): reasoning fine-tuning **degrades** abstention ability by 24%. If it holds, it is the sharpest available warning against assuming a "thinking" small model knows its limits better.
- **"Trust or Escalate"** (ICLR 2025, via citation): external verification with provable guarantees **outperforms** single-model internal-confidence-based escalation. This is the single most actionable finding in this section — *do not ask the local model whether it can do the job.*
- **"Second Guess"** (arXiv 2605.25394, 2026 — <https://arxiv.org/abs/2605.25394>): tests 2B–8B models specifically, reporting up to **10.81% composite risk improvement** from a parameter-free answer-stability method. The existence of dedicated 2026 research into small-model abstention is itself evidence that baseline small-model calibration is considered weak.
- **Honest statement of the gap**: I found *no* paper stating "small models are X% worse calibrated than large models." The claim is plausible and actively researched, not quantified.

#### The NVIDIA position paper

Belcak et al., **"Small Language Models are the Future of Agentic AI"**, arXiv:2506.02153 (submitted 2025-06-02, v2 2025-09-15 — <https://arxiv.org/abs/2506.02153>). It argues SLMs under 10B are "sufficiently powerful, inherently more suitable, and necessarily more economical for many invocations in agentic systems," and recommends **heterogeneous** systems where conversational generality is needed. It is a **position paper: no proofs, no experimental validation, no comparative benchmarks** — the authors run a correspondence page soliciting community response. It is widely cited as if it were empirical. It is not. Cite it as an argument Throttle agrees with, never as evidence.

---

### Q5 — Hybrid routing: what is measured, what is marketing

#### Published routing results (treat every figure as an upper bound)

| Work | Claim | Caveat |
|---|---|---|
| **RouteLLM** (LMSYS, arXiv 2406.18665, 2024-07-01, <https://www.lmsys.org/blog/2024-07-01-routellm/>) | Matrix-factorisation router reaches 95% of GPT-4 quality using **26% GPT-4 calls**; >85% cost reduction on MT-Bench, 45% MMLU, 35% GSM8K | Two-model strong/weak setup; trained and evaluated on Chatbot Arena preference data |
| **Hybrid LLM** (ICLR 2024) | Up to **40% fewer large-model calls** with no quality drop | Author-reported, single setup; small model is edge-deployable — closest analogue to Throttle |
| **FrugalGPT** (arXiv 2305.05176, 2023) | Up to **98% cost reduction** matching GPT-4 | Benchmark-specific curated QA/classification; the "is this answer reliable" scorer is itself an imperfect classifier |
| **BEST-Route** (Microsoft, arXiv 2506.22716) | Up to **60% cost cut**, <1% performance drop | Vendor-affiliated |
| **RouterBench** (arXiv 2403.12031, 2024) | 405k+ precomputed outputs, 11 LLMs, 7 tasks | A dataset, not a router |

And then the correction:

- **"Unsolvability Ceiling in Multi-LLM Routing: An Empirical Study of Evaluation Artifacts"** (arXiv 2605.07395, 2026 — <https://arxiv.org/pdf/2605.07395>): routers are trained and evaluated on the same benchmark distributions, producing ceiling effects that do not generalise; published cost-reduction figures depend on these artifacts and real-world effectiveness is **substantially lower**.
- **LLMRouterBench** (arXiv 2601.07206, Jan 2026 — <https://arxiv.org/abs/2601.07206>): 400,000+ instances, 21 datasets, 33 models, 10 routing baselines. Finding: **"many routing methods exhibit similar performance"** and **"several recent approaches, including commercial routers, fail to reliably outperform a simple baseline."**

**This is the empirical justification for Throttle's advisory-only doctrine, and it is stronger in 2026 than it was in 2025.**

#### Cascades and speculative decoding

Speculative decoding is a **latency** technique, not a cost-routing technique — the two are treated as distinct in the current survey literature (arXiv 2603.04445, 2026).

**Cross-network local-draft / remote-verify is an open research problem, not a shipped capability.** A 2026 paper on edge-cloud speculative decoding (arXiv 2603.19133) states that existing methods "perform well in data centers with high-speed interconnects (like NVLink) but struggle in high-latency Edge-Cloud environment," citing a mismatch between communication cost and latency masking and a lack of system design for "high-latency, low-bandwidth, and state-separated environments." A second 2026 paper (WISV, arXiv 2604.17701) exists specifically to attack the same gap. **Verdict: do not build this. It is not ready, and Throttle's Mac↔LXC-over-Tailscale link is precisely the "high-latency, state-separated environment" these papers say breaks it.**

#### Shipped products — what they actually do

- **Apple (PCC)**: Apple provides `DynamicProfile` so *the developer* switches between `SystemLanguageModel` and `PrivateCloudComputeLanguageModel`. Apple's guidance is to make routing decisions from evaluation data. **Apple publishes no automatic confidence-threshold routing algorithm.** (`NOT VERIFIED`: a single secondary blog claimed Gemini models run inside the PCC enclave — not corroborated by Apple's own security or developer content; do not repeat it.)
- **Claude Code**: primary docs (<https://code.claude.com/docs/en/costs>) document Bedrock, Google Cloud Agent Platform, Microsoft Foundry, and self-hosted LLM gateways (LiteLLM, explicitly flagged by Anthropic as unaffiliated and unaudited). **No local-model inference and no hybrid local/frontier routing is documented.** This is a real, checkable gap in the market and it is where Throttle sits.
- **Cursor**: "Cursor Router" (Teams/Enterprise) picks among *cloud* frontier models by Cost/Balance/Intelligence mode. Cloud-to-cloud only; no local model support in the docs (<https://cursor.com/docs/models>).
- **OpenRouter**: real routing infrastructure — automatic fallback on 5xx/rate-limit/moderation/context errors, `:floor` price sorting, providers weighted by inverse-square of price with 30-second outage exclusion, and an Auto Router with a `cost_tier` knob. Cloud-to-cloud.
- **Tailscale Aperture**: verified from Tailscale's own docs (<https://tailscale.com/docs/aperture/what-is-aperture>) — an **authentication and observability gateway**, not a router. It can register a self-hosted LLM on the tailnet, but model selection is client-requested or admin-configured. **There is no automatic complexity-based local-vs-cloud routing in Aperture.** This directly refutes any framing of Aperture as a smart hybrid router, and it de-risks the "Aperture occupies our lane" note in Throttle's memory.
- `NOT VERIFIED` in this pass: Windows Copilot local+cloud, Gemini Nano + cloud, Continue.dev's current hybrid feature set, and the reported Ollama/LM Studio cloud-hybrid pricing.

#### Confidence as a routing signal

Consistent across sources: **verbalised self-confidence is the worst available signal.** Probe-based (trained classifier) and perplexity-based signals outperform it, and external verification (Trust or Escalate, ICLR 2025) outperforms both. None is production-reliable. `NOT VERIFIED`: a widely repeated "models say 95% sure while wrong 30% of the time" figure — community paraphrase, no primary source found.

#### Honest cost accounting — the section that decides the design

**Anthropic prompt caching, from the primary docs** (<https://platform.claude.com/docs/en/build-with-claude/prompt-caching>):

- 5-minute cache **write: 1.25×** base input price
- 1-hour cache **write: 2×** base input price
- Cache **read: 0.1×** base input price (Claude Fable 5.1 / Mythos 5.1: 0.025×)
- Minimum cacheable prompt: 512–4,096 tokens depending on model
- Max 4 breakpoints per request, 20-block lookback per breakpoint
- **Invalidation is hierarchical: tools → system → messages.** Changing tool definitions invalidates *everything*. Changing web-search/citations toggles or the speed setting invalidates system + messages. Adding/removing an image or changing thinking effort invalidates messages.

From Anthropic's Claude Code docs (<https://code.claude.com/docs/en/costs>): `/usage` surfaces a live "Prompt cache (main)" line — the documented example reads **"14 requests · 91% of input tokens from cache · 2 misses ... warm (1h TTL)"**. Cache TTL is **1 hour on subscription plans**, dropping to 5 minutes once drawing on usage credits. A miss is counted when >5% and ≥2,000 tokens are reprocessed, and the docs distinguish expected rebuilds (compaction, tool-result clearing) from real misses. The docs also state plainly that "a one-line question in a session that has been open all day still draws usage for the whole conversation."

**The consequence for hybrid routing, and it is the crux of this report:**

Prompt caches are **scoped to a model**. If turn *n* goes to Claude and turn *n+1* goes to a local model, the cache written at turn *n* is never read. A cache write that is never re-read is a **straight loss of 1.25×–2× base input price** relative to an uncached call. So a "cheap" local detour inserted into a live Claude Code session can cost **more** than not routing at all — the saving on the local turn is real but bounded by that turn's small size, while the stranded frontier cache write is proportional to the *whole conversation*.

This is not a theoretical worry. **"Don't Break the Cache"** (arXiv 2601.06007, 2026 — <https://arxiv.org/pdf/2601.06007>, Lumer et al.) evaluates prompt-caching efficiency across long-horizon agentic tasks on OpenAI, Anthropic and Google, and concludes that **naive caching implementations may provide minimal or negative returns in agentic scenarios despite theoretical advantages**. `NOT VERIFIED`: the paper's quantified tables — WebFetch could not extract them. Read the PDF directly before quoting a number from it.

The mitigation the field has converged on is **session affinity**: pin a session to one model after the first routing decision, precisely to preserve cache continuity. Which is another way of saying: **route between sessions, never within one.**

`NOT VERIFIED` and explicitly flagged: a widely circulated "98.7% → 0.7% cache hit rate after adding one timestamp line" figure, and a "Claude Code achieves 92% cache hit rate" figure. Both are third-party blog claims. Anthropic's own docs example shows 91% for one session — an illustration, not a platform statistic.

---

### Q6 — Low-latency remote UI, headset ↔ Mac

#### What humans notice

- **Pavel Fatin, "Typing with pleasure" (2015-12-20, <https://pavelfatin.com/typing-with-pleasure/>)** — measured editor end-to-end latency with a purpose-built tool (Typometer). Windows/XML: GVim 0.9 ms, IntelliJ "zero-latency" 2.9 ms, Notepad++ 4.3 ms, Emacs 5.3 ms, Sublime 8.2 ms, Eclipse 10.1 ms, IDEA default 24.7 ms, Atom 49.4 ms. Cites ~40 ms human visual processing and ~200 ms full sensory-to-muscle reaction, and notes Microsoft Research demonstrated perceptible improvement down to **1 ms**.
- **Dan Luu, terminal latency (<https://danluu.com/term-latency/>)** — high-speed-camera measurement, keypress-to-pixel, idle p50/p99.9 ms: Terminal.app 6/25, emacs-eshell 5/17, alacritty 31/36, hyper 32/49, iTerm2 44/60, st 25/63. Under load Terminal.app 13/30, iTerm2 45/81. Luu's point: **the tail latencies of most terminals are already in the perceptible range**, and some terminals' internal path is slower than a Boston–Seattle round trip.
- **Microsoft Research touch latency**: 1 ms prototype vs ~100 ms commercial baseline (1 kHz sensor, FPGA, 32,000 fps projector). `NOT VERIFIED` for original publication date — secondary tech-press coverage only.
- `NOT VERIFIED / secondary`: a "2–11 ms JND for touchscreen dragging" figure (traced only to a citation inside arXiv 2408.02525) and a VR "20 ms fine / 50 ms laggy / 150 ms unbearable" rule of thumb (relayed via Fatin/Luu, no primary source found).

**The usable conclusion**: budget under ~40 ms end-to-end for keystroke echo to feel local. Terminal.app's own p50 is 6 ms, so a remote path has roughly 30 ms of headroom before it feels worse than a local terminal — which is *not much* once you add a network hop, a WebSocket, and a compositor.

#### Which protocols actually work

- **mosh** (USENIX ATC 2012, Winstein & Balakrishnan) is the answer, and the reason is architectural rather than network: **local echo prediction**. Reported: median keystroke response 503 ms (SSH) → predicted-instant with mosh, >70% of keystrokes displayed immediately; mean 515 ms → 173 ms; MIT–Singapore SSH median 273 ms vs mosh <5 ms; Verizon LTE under concurrent download SSH 5.36 s vs mosh <0.005 s. **Caveat that must be stated: the "instant" figure is client-side prediction, not round trip. Predictions can be wrong and get visibly corrected.** (Figures via a search summary of the paper; the PDF fetch failed — re-verify <https://www.usenix.org/system/files/conference/atc12/atc12-final32.pdf> before quoting.)
- `NOT VERIFIED`: ttyd/WebSocket terminal latency benchmarks, tmux-over-SSH benchmarks, and WebRTC vs gRPC vs WebSocket per-keystroke overhead. No published measurements found. A single JetBrains community anecdote reports Gateway feeling "horrible" over a >100 ms link while VS Code Remote-SSH felt fine on the same link.
- `NOT VERIFIED`: Network.framework / QUIC / DeviceDiscoveryUI specifics for 2026 — Apple's documentation pages are JS-rendered and returned no body content. Do not design against remembered API details here; re-fetch the WWDC sessions.

#### Mac Virtual Display — the shortcut that already exists

Verified from Apple Support (<https://support.apple.com/en-us/118521> and the visionOS user guide):

- Mac and Vision Pro must be **within 10 metres (30 feet)**, both with Wi-Fi and Bluetooth on, and **"Neither device can be sharing its internet connection."** Same Apple ID with 2FA, iCloud Keychain and Handoff.
- Resolution on Apple-silicon Macs: standard up to **5120×2880**; **Wide 6720×2880 px**; **Ultrawide 10240×2880 px** (32:9, "equivalent to two 5K monitors side by side"), shipped in **visionOS 2.2, December 2024**.
- **Apple publishes no latency figure for Mac Virtual Display.** An independent first-person report (2024-02-11) says "no noticeable display latency" — qualitative only.
- `NOT VERIFIED`: whether visionOS 26 or 27 changed Mac Virtual Display. Apple's release-notes pages 404'd on fetch.

**The proximity requirement is the design constraint**: Mac Virtual Display is a same-room feature. Any remote/Tailscale story cannot use it and must be a native app.

#### Network reality

- Tailscale's own docs (<https://tailscale.com/docs/reference/connection-types>): "The primary difference between them is performance, not security." Direct WireGuard/UDP gives "the lowest latency and highest throughput"; DERP relay is "generally slower"; peer-relay is "usually faster than DERP" but still worse than direct. The docs' illustrative `tailscale ping` outputs show direct 35–130 ms, peer-relay 3–5 ms, DERP 50–282 ms — **these are documentation examples, not a benchmark.**
- Tailscale's own blog case study (<https://tailscale.com/blog/peer-relays-international-networks>): first ping via DERP in Chicago 452 ms, dropping to 298–306 ms once a peer-relay path establishes.
- `NOT VERIFIED`: Wi-Fi 6/6E/7 LAN RTT figures. I could not find a citable source in this pass.

**For Kevin's topology this is good news and it is already proven in his own environment**: the Mac↔Proxmox path is a direct Tailscale path on the same physical network (per the DNAT fix recorded in Throttle's memory), so it is a LAN hop, not a DERP hop. The headset↔Mac path is same-room. Neither is a 300 ms international relay.

#### Does anyone actually code in a Vision Pro?

The one substantive independent first-person report (vincelwt.com/visionpro, **2024-02-11**, M2 Vision Pro):

- Eye fatigue requiring breaks at **~30 minutes**; weight discomfort at **~45 minutes**; "very uncomfortable" with facial pressure marks by **~90 minutes**.
- Typing required dropping to **~50% passthrough** to see the physical keyboard; fully immersive mode caused typing errors.
- The author's stated *real* limitation is **text legibility**: eye strain reading code after 30 minutes despite adjusting distance, font size, anti-aliasing and contrast — "like the eyes are close from being able to focus on the text, but not quite all the way." Conclusion: resolution insufficient for extended coding.

**And the M5 Vision Pro has the same 23-million-pixel display** (Apple specs). The M5 refresh improved compute, refresh rate and battery — it did not change the constraint that governs coding comfort.

`NOT VERIFIED`: abandonment-rate data or negative developer reports at scale. Reddit is not fetchable and the search budget was exhausted. **Absence of retrieved evidence is not evidence of absence — do not claim developers have abandoned Vision Pro coding, and do not claim they haven't.**

---

## 3. Ranked engineering decisions for Throttle

Throttle already has the right skeleton. From this worktree: `DispatchAdvisor.swift` (advisory + `.abstain` verdict, pure, memory/budget injected), `LocalCandidateService.swift` (retro-attribution over `usage.db`, explicitly refusing the counterfactual claim), `RouterAdvisorService.swift`, `LocalDelegationService.swift`, `LocalWorkerRouter.swift`, `AppleIntelligenceProvider.swift` (conditional `canImport(FoundationModels)` + runtime `availability` check), `AIRoutingWindowController.swift`.

*Minor correction for the record:* the brief says "21 call sites of Apple's FoundationModels framework." I found **4 files** importing or referencing `FoundationModels` in this worktree (`AppleIntelligenceProvider`, `AppleIntelligenceTools`, `ClaudeAPIKeyProtocol`, `GlobalRAGOnboardingService`). 21 individual call sites across 4 files is plausible; 21 files is not what is here. Worth re-checking before it goes into any external claim.

---

### 1. Make the router cache-aware, and make it say the quiet part

**Do:** before `DispatchAdvisor` recommends "Local" for anything inside a live Claude Code session, compute and display the **stranded cache write** — the frontier-side cost of breaking a warm cache to take a local detour. Surface cache-read fraction as a first-class metric next to weighted tokens, mirroring what `/usage` already reports.

**Why:** this is the single highest-value, lowest-risk thing on the list. Anthropic's documented 0.1× read / 1.25×–2× write economics and model-scoped caches mean a naive local detour can be net-negative. Nobody else in this market shows the user that number. It converts Throttle's honesty doctrine into a feature competitors cannot copy without admitting their own routing is lossy.

**Cost:** small–medium. The data already exists in `usage.db`; the work is a cost model plus UI. Days, not weeks.

**Ageing risk: low.** Anthropic could change cache multipliers — the model must read them from config, not hard-code them. But the *mechanism* (caches are model-scoped; writes cost more than base) is structural and will outlive any specific price.

---

### 2. Route between sessions, never within one

**Do:** make session affinity an explicit, stated rule. `LocalCandidateService` already does the right thing by scoring *completed* sessions retrospectively; formalise it as policy — Throttle recommends "this *class of task* could have run locally next time," never "switch models now."

**Why:** the cache-affinity finding in Q5 makes mid-session switching structurally lossy, and Throttle's own memory already records that mid-session model switching is counter-productive because caches are per-model. This decision aligns the code, the doctrine and the 2026 literature.

**Cost:** near zero. It is a constraint, not a build.

**Ageing risk: very low.** If cross-model cache sharing ever ships, this becomes a limitation to relax rather than a bug to fix.

---

### 3. Keep advisory + abstention. Cite LLMRouterBench when challenged.

**Do:** do not build auto-routing, for any model, on any platform. Keep `.abstain` as a first-class verdict with confidence and reasons, as `DispatchAdvisor` already does.

**Why:** `LLMRouterBench` (Jan 2026) found commercial routers often fail to beat a simple baseline; arXiv 2605.07395 (2026) argues published routing savings are evaluation artifacts; AbstentionBench (NeurIPS 2025) suggests reasoning fine-tuning *degrades* self-knowledge; "Trust or Escalate" (ICLR 2025) shows external verification beats internal confidence. **The whole 2026 evidence base points at Throttle's existing design.**

**Cost:** zero. This is a decision not to build.

**Ageing risk: low, with one caveat.** If a routing method eventually does beat baselines convincingly, Throttle looks conservative. The mitigation is decision 5 — own a golden set so you can *tell* when that day arrives, rather than guessing.

---

### 4. Vision Pro app runs no models. Ever.

**Do:** the visionOS surface is a read-only mirror of Mac/LXC state plus a control surface. No `MLXLanguageModel`, no `CoreAILanguageModel`, no local inference in the headset — even though Apple lists both for visionOS.

**Why:** **5 GB per-app ceiling** on a 16 GB device (Apple engineer, Sept 2025), 2.5 h battery, a fanless thermal design with no published sustained-load data, and **zero** published inference benchmarks on Vision Pro. The one visionOS app claiming local models also ships a Mac-as-server mode and says why.

**Cost:** zero, and it *saves* build cost.

**Ageing risk: low–medium.** If a future Vision Pro ships more RAM and Apple raises the per-app cap, this ages. But the architecture (headset as client) survives that change unharmed — you would be adding an option, not rewriting.

---

### 5. Build a golden set before making any savings claim

**Do:** 200–400 real tasks per class drawn from Kevin's own `usage.db` profile (title, summary, extraction, commit message, quick question — the classes `LocalCandidateService` already isolates), with held-out evaluation. Measure **net cache-aware euro savings**, not token counts.

**Why:** every published number in Q4 and Q5 is contested, snippet-sourced, or benchmark-specific, and I could not verify a single dated evaluation of small models on summarisation or classification. Throttle cannot cite the literature honestly, so it must measure. This also closes the counterfactual `LocalCandidateService` explicitly refuses to claim (shadow replay).

**Cost:** medium. Corpus curation plus an evaluation harness. Apple's new **Evaluations** framework (WWDC26) may do part of this, though `NOT VERIFIED` whether it fits non-FoundationModels providers.

**Ageing risk: very low.** A golden set is the asset that keeps its value as models churn. It is the thing that will still be useful in 2028.

---

### 6. Add `MLXLanguageModel` behind the existing provider abstraction — Mac only, gated

**Do:** add an `AIProvider` implementation backed by `MLXLanguageModel(modelID:)`, gated to macOS 27+, alongside the existing Ollama-on-LXC path. Prefer the LXC path by default on a 16 GB Mac.

**Why:** `AppleIntelligenceProvider` already proves the conditional-import pattern. MLX gives access to `mlx-community` models with measured 20–40% faster decode than GGUF on Apple silicon, and Apple has endorsed MLX at two consecutive WWDCs. But Kevin's Mac is 16 GB with heavy swap — a resident local model on the Mac competes with the thing Throttle exists to protect. LXC 179 already runs `qwen3:4b` and costs the Mac nothing.

**Cost:** small–medium. One provider conforming to an existing protocol, plus model download/lifecycle UX (which is the real work: multi-GB downloads, disk budget — and Throttle already has a disk-full incident on record).

**Ageing risk: medium.** `MLXLanguageModel`'s module location is `NOT VERIFIED`, the API is one WWDC old, and Apple could fold it, rename it, or change its distribution model. Keep it behind `AIProvider` so it is one file, and ship it *after* macOS 27 is generally available, not during beta.

---

### 7. Terminal transport: buy latency with prediction, not with protocol shopping

**Do:** if the visionOS cockpit mirrors a terminal, implement **mosh-style local echo prediction** in the client rather than optimising the transport. Keep the existing ttyd/WebSocket path.

**Why:** mosh's measured result (median 503 ms → predicted-instant) came from prediction, not from a faster network. Terminal.app's own p50 is 6 ms and typical terminal tail latencies are already perceptible, so there is little headroom to win in the transport layer. Direct Tailscale on the same LAN is already the good case. And `NOT VERIFIED`: there are no published ttyd, WebRTC-vs-WebSocket, or Wi-Fi 6/7 RTT numbers to shop against.

**Cost:** medium. Prediction with correct rollback on server correction is genuinely fiddly, and wrong predictions are visible.

**Ageing risk: low.** The technique is 14 years old and still the best answer. But **defer this** — it only pays off if the headset turns out to be a place people type, which decision 8 says it is not.

---

### 8. Position the headset for supervision, not for typing

**Do:** design the visionOS cockpit around glanceable state — running sessions, budget headroom, cap forecast, waiting-on-you signals — not around an editor. Use Mac Virtual Display for anything that is genuinely text-editing, and accept its 10-metre same-room constraint.

**Why:** the only substantive independent report of coding in a Vision Pro identifies **text legibility**, not latency and not compute, as the limit — with eye fatigue at 30 minutes and a practical ceiling near 90. The M5 Vision Pro did not change the display. Meanwhile Ultrawide Mac Virtual Display (10240×2880 px, shipped Dec 2024) already solves "I want more screens" better than any app Throttle could write.

**Cost:** small — it is a scoping decision that removes work.

**Ageing risk: medium.** A higher-resolution headset would weaken the argument. But a supervision-first cockpit is *still* the right design on a better display, so this ages by becoming less necessary rather than by becoming wrong.

---

### 9. Do not build cross-network speculative decoding

**Do:** nothing. Explicitly record it as a non-goal.

**Why:** two separate 2026 papers exist specifically because edge-cloud speculative decoding does not work over high-latency, state-separated links — which is exactly the Mac↔LXC-over-Tailscale topology. **Cost:** zero. **Ageing risk: low** — if it is solved, adopting it later costs nothing that building it now would have saved.

---

### 10. Never promise AFM 3 Core Advanced

**Do:** no roadmap item, no marketing line, no cost model referencing the 20B model. If Kevin wants to settle it, the cheap experiment is to read `SystemLanguageModel.default.contextSize` and run a fixed prompt set on an 8 GB Mac and a 16 GB+ Mac on the same OS build, and see whether anything differs.

**Why:** Apple documents the model and documents no API to request it. `SystemLanguageModel` exposes no tier selector, and the only description of the developer-facing on-device model in 2026 coverage says "about 3B parameters."

**Cost:** zero to abstain; a few hours for the experiment. **Ageing risk: none** — this is a claim-hygiene rule, and if Apple later documents access, it becomes a feature you can add honestly.

---

## 4. What I could not verify

Listed so nothing here gets quietly promoted to fact later:

- Whether third-party apps can reach **AFM 3 Core Advanced**, and through which API. No Apple statement found either way.
- The **12 GB RAM floor** and device list for Core Advanced — reported by press and a leak account, never by Apple.
- Which **module** ships `MLXLanguageModel` and `CoreAILanguageModel`.
- The **visionOS 27 M5-exclusive feature list** (source returned HTTP 403).
- **Memory footprints** at 4-bit for 3B / 14B / 20B as a sourced table (only 8B and 32B figures found; the rest is arithmetic, and excludes KV cache).
- Any **measured local-LLM benchmark on Vision Pro hardware**.
- Dated 2026 evaluations of **small models on summarisation, classification, reranking, or log triage**.
- **Terminal-Bench** numbers for any small model; the "Qwen3.8" model family and its scores are contested and should not be cited.
- Full-text confirmation of the **SWE-Protégé / SWE-Dev / Seed-Coder** percentages (snippet-sourced).
- Quantified tables from **"Don't Break the Cache"** (arXiv 2601.06007) — read the PDF before quoting a number.
- **AbstentionBench**'s 24% figure — secondary-sourced; the NeurIPS paper was not fetched.
- **Wi-Fi 6/6E/7 RTT**, **ttyd benchmarks**, **WebRTC/gRPC/WebSocket per-keystroke overheads**, and **Network.framework/QUIC/DeviceDiscoveryUI 2026 specifics** (Apple docs are JS-rendered and returned no body).
- Whether **visionOS 26/27 changed Mac Virtual Display** (Apple release-notes pages 404'd).
- **Vision Pro abandonment data** among developers — no data retrieved, in either direction.
- Community-reported figures explicitly flagged and **not** to be quoted as fact: the "98.7% → 0.7%" cache-collapse figure, the "92% Claude Code cache hit rate," the "models say 95% sure while wrong 30% of the time" line, and the `llmcheck.net` tok/s table (self-labelled "Estimated," i.e. derived from bandwidth arithmetic rather than run).

Methodological caveat: the WebSearch budget for this session (200 calls) was exhausted partway through. Later gaps were left open rather than filled by guessing.
