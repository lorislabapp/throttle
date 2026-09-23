# Next steps — source validation

The former v3.0 checklist is superseded. This checkout is not proven ship-ready
by a build or three smoke tests. Use [the work ledger](docs/TODO.md) and the
[T1.2 gap inventory](audit-output/T1.2-gaps.md) for scoped evidence and open gates.

- Generate the Xcode project from `project.yml`; its `Throttle` source directory
  already includes `AssistantPane.swift` and `CcusageImporter.swift`. Do not add
  them manually to the generated project.
- Use the [README build commands](README.md#build) and
  [validation workflow](docs/testing/workflow.md). Record the source commit,
  completed cases, failures and skipped checks.
- Test missing session directories with disposable fixtures or an isolated test
  account. Never delete the user's live `~/.claude/projects` to run a smoke test.
- Full app/UI, physical-device, signed-bundle and release checks remain separate
  from the isolated validator suite. Old release results do not validate new bytes.

The old `audit-output/PHASE-1-5-TEST-CHECKLIST.md` and deep-dive reports referenced
here are absent from this checkout. The previous instructions and readiness
claims remain available in Git history; they are not release authorization.
