# Local delegation bench

A deterministic golden set for the worker behind `LocalDelegationService`.

Until 2026-08-21 every claim Throttle made about local delegation — that it is
reliable, that it saves context without losing fidelity — was an assertion. This
is the smallest instrument that can contradict one.

## Run

```sh
./bench.py                              # shipped prompt, 5 runs per case
./bench.py --variant all --runs 5       # shipped prompt vs the pre-2026-08-21 one
./bench.py --url http://127.0.0.1:11434 --model qwen3.5:4b
```

Exits non-zero when the shipped prompt scores below perfect, so it can gate a
build. Endpoint and model also read `THROTTLE_BENCH_URL` / `THROTTLE_BENCH_MODEL`.

## What it scores

| metric | meaning |
| --- | --- |
| `json_ok` | the worker returned parseable JSON |
| `quotes_ok` | every evidence string appears **byte-for-byte** in the source |
| `conf_ok` | confidence is one of `high` / `medium` / `low` |
| `facts` | the required facts appear in `result` or `evidence` |

No LLM judges the output. A judge would import position, verbosity and authority
bias into the one number that has to stay reproducible across builds. Byte-exact
quoting proves **provenance**, not truth — a quote can be authentic and still
support a wrong claim, which is why `facts` is measured separately.

## What it caught

Measured on `throttle-worker` (qwen3:4b), 4 cases × 5 runs:

| prompt | facts | byte-exact quotes |
| --- | --- | --- |
| pre-2026-08-21 (prose, no examples) | 75% | 20/20 |
| fixed pair of extraction examples | 95% | 19/20 |
| **examples per task kind (shipped)** | **100%** | **20/20** |

The middle row is the interesting one. Showing two *extraction* examples to every
task kind lifted extraction from 50% to 100% and dropped normalisation from 100%
to 80%: the model had learned to quote the input instead of converting it. Small
models inherit the bias of whatever example they are shown, so each kind gets its
own.

Building this bench also surfaced a live regression: with a schema attached,
`think: true` sends the entire generation to `thinking` and leaves `response`
empty, so delegation failed silently and fell back to the embedded model. The
matrix is in `LocalWorkerRouter.ollamaGenerate`.

## Extending it

Four cases is a seed, not a golden set — sized to catch a prompt regression, far
too small to bound a failure rate. Add cases to `cases.json`; keep `must_contain`
to facts a machine can check literally. When
`LocalDelegationService.examples(for:)` changes, update `EXAMPLES` in `bench.py`
to match: a bench measuring a prompt the app no longer sends reports confidence
in the wrong thing.
