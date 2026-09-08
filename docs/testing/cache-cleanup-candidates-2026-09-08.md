# Cache cleanup candidates — read-only assessment

No deletion, process stop or configuration change was performed. This list is
not an execution authorization. Recheck usage immediately before any deletion.

## Safety observations

- Free space decreased from about 6.3 GiB to 4.3 GiB during inspection.
- Concurrent Claude/Codex sessions and an Xcode build were observed. Active
  project work includes Kernel, 404, ProofCheck, SiliconPass, Contract, Eclair,
  Health, iot-framework and Throttle. Protect their shared runtime/dependency
  caches and working directories; an idle descriptor list is not a future-use guarantee.
- The final `lsof` scan observed 1,024 user processes and zero open references
  under the three candidate roots below. A separate process-command scan emitted
  only matches for those roots (not private arguments) and found no references.
- All inspected targets are ordinary directories, not symlinks. They contain
  compiler modules/intermediates or an obsolete isolated test build cache.
- Removal would preserve source trees, `Build/Products`, installed apps, logs,
  xcresult bundles, receipts, project worktrees, credentials and model weights.
  Future builds can regenerate the removed files, at a recompilation cost.
- Sizes are measured allocated KiB from `du`, not a guaranteed free-space gain:
  APFS sharing and concurrent writes can change the actual amount recovered.

## Exact proposed targets, subject to explicit approval

| Target | Measured KiB |
|---|---:|
| `/private/tmp/velya-iot-ios-20260908/SDKExplicitPrecompiledModules` | 1186324 |
| `/private/tmp/velya-iot-ios-20260908/ModuleCache.noindex` | 181628 |
| `/private/tmp/velya-iot-ios-20260908/Build/Intermediates.noindex` | 580312 |
| `/private/tmp/velclar-iot-20260907/SDKExplicitPrecompiledModules` | 727876 |
| `/private/tmp/velclar-iot-20260907/ModuleCache.noindex` | 94664 |
| `/private/tmp/velclar-iot-20260907/Build/Intermediates.noindex` | 152228 |
| `/private/tmp/throttle-sota-core/throttle-core-evidence-bjqj9t88/package/.build` | 211020 |

Total: 3,134,052 KiB, approximately 2.99 GiB. The Velya group is approximately
1.86 GiB, Velclar 0.93 GiB, and our obsolete test cache 206 MiB.

The last target belongs to this conversation's earlier 60-case lightweight run.
Its receipt/log/reports and source copy live outside `.build` and would remain.
The current reusable lightweight cache is in `throttle-core-evidence-sxxgc7jc`;
keep it. Keep the full macOS replay cache in `throttle-macos-g3m_prz3/DerivedData`.

## Excluded despite size

- Shared Xcode DerivedData, SDK/module caches, SwiftPM and `.npm/_npx`: concurrent
  build/session dependencies; Xcode storage grew while being inspected.
- `.cache/uv`, Hugging Face models, Codex/Claude runtimes, state and histories:
  packages/models may be needed by live or resumed sessions.
- CloudKit cache: roughly 2.4 GiB, but this is a synchronization/data boundary,
  not a safe developer-cache cleanup target.
- `/private/tmp/claude-501`: active Claude session territory, not disposable by label.
- `/private/tmp/millrace-sota-20260907`: roughly 4 GiB but includes model weights,
  a Python environment and verification artifacts; do not delete the whole directory.
- Audit/release artifacts for other active projects and our `Tests.xcresult`:
  preserve evidence, application products and rollback material.

Only about 16 MiB were present in npm's download cache, 42 MiB across Homebrew's
cache (its downloads directory was empty), and 51 MiB of Cargo crate archives.
These small caches do not solve the space problem and were not selected. Gradle
has about 573 MiB but was not selected to avoid changing another workflow's
dependency availability without coordination.

## Expanded inspection — 2026-09-08

The broader inspection adds 28 exact compiler-cache directories, totalling
5,697,148 KiB (5.43 GiB). Combined with the initial seven candidates, the
proposal is 35 directories, 8,831,200 KiB (8.42 GiB). No deletion is authorized
or performed. Initial-lot measurements above are retained from the earlier scan.

| Additional group | Measured GiB |
|---|---:|
| Kernel compiler caches | 2.33 |
| Snapshot compiler caches | 1.47 |
| SiliconPass compiler caches | 1.05 |
| Contract compiler caches | 0.59 |

A scoped open-file scan observed 1,026 user processes and no references under
the nine selected additional roots. Sanitized process-command checks also found
no selected-root references. All 28 targets were verified as ordinary directories.
This is point-in-time evidence, not a guarantee that another session will not
resume a build there. Regeneration would cost compilation time.

The separate `/private/tmp/kernel-full-fix.Au33Ty` tree is excluded: `ibtoold`
still referenced its runtime. Preserve SiliconPass document-transfer/test data,
all application products, model weights, logs, receipts and xcresult bundles.
Free space fell further during inspection; the final `df` readback showed 1.8 GiB.

### Additional exact proposed targets

| Target | Measured KiB |
|---|---:|
| `/private/tmp/kernel-security-audit-derived-20260908/SDKExplicitPrecompiledModules` | 669800 |
| `/private/tmp/kernel-security-audit-derived-20260908/ModuleCache.noindex` | 196332 |
| `/private/tmp/kernel-security-audit-derived-20260908/Build/Intermediates.noindex` | 373512 |
| `/private/tmp/kernel-daybreak-20260908T161517Z-derived-r3/SDKExplicitPrecompiledModules` | 669716 |
| `/private/tmp/kernel-daybreak-20260908T161517Z-derived-r3/ModuleCache.noindex` | 176328 |
| `/private/tmp/kernel-daybreak-20260908T161517Z-derived-r3/Build/Intermediates.noindex` | 354740 |
| `/private/tmp/siliconpass-redteam-dd/SDKExplicitPrecompiledModules` | 539396 |
| `/private/tmp/contract-full-audit-20260908-33vfY7/AppDerivedData/SDKExplicitPrecompiledModules` | 276464 |
| `/private/tmp/contract-full-audit-20260908-33vfY7/AppDerivedData/ModuleCache.noindex` | 30308 |
| `/private/tmp/contract-full-audit-20260908-33vfY7/AppDerivedData/Build/Intermediates.noindex` | 19316 |
| `/private/tmp/contract-full-audit-20260908-33vfY7/OCRDerivedData/SDKExplicitPrecompiledModules` | 228128 |
| `/private/tmp/contract-full-audit-20260908-33vfY7/OCRDerivedData/ModuleCache.noindex` | 45236 |
| `/private/tmp/contract-full-audit-20260908-33vfY7/OCRDerivedData/Build/Intermediates.noindex` | 20808 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260906-12290-ka1w3p/SDKExplicitPrecompiledModules` | 219616 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260906-12290-ka1w3p/ModuleCache.noindex` | 47536 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260906-12290-ka1w3p/Build/Intermediates.noindex` | 128376 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260907-48671-n8vfe6/SDKExplicitPrecompiledModules` | 219616 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260907-48671-n8vfe6/ModuleCache.noindex` | 47536 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260907-48671-n8vfe6/Build/Intermediates.noindex` | 127072 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260906-77916-bphfl2/SDKExplicitPrecompiledModules` | 219616 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260906-77916-bphfl2/ModuleCache.noindex` | 47536 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260906-77916-bphfl2/Build/Intermediates.noindex` | 113220 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260906-91981-350pdv/SDKExplicitPrecompiledModules` | 219616 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260906-91981-350pdv/ModuleCache.noindex` | 47536 |
| `/private/var/folders/3w/fbl9wc1d3q7091lq5pj5sy0c0000gn/T/snapshot_derived20260906-91981-350pdv/Build/Intermediates.noindex` | 99828 |
| `/private/tmp/siliconpass-remediation-tests/out/SDKExplicitPrecompiledModules` | 99828 |
| `/private/tmp/siliconpass-remediation-tests/out/ModuleCache.noindex` | 196748 |
| `/private/tmp/siliconpass-remediation-tests/out/Intermediates.noindex` | 263384 |

## Before a subsequent authorized cleanup

Reconcile current processes/arguments/open files, exact directory identities and
fresh sizes again. Refuse any target that gained an active reference. Remove only
the explicitly approved subset of these 35 paths, never the enclosing temporary
roots or all DerivedData. Approval has not yet been given for any target.
Then verify each target's absence, preservation of products/reports, and actual
free space. Do not repeat deletion if concurrent builds immediately consume it.
