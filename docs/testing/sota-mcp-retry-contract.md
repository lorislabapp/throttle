# Plan MCP retry contract

The `throttle_task_claim`, `throttle_task_event` and `throttle_task_verdict`
schemas now expose `event_id` and `expected_seq`. The live adapter delegates to
the same argument router exercised by isolated tests. This is a persistence and
concurrency contract, not caller authentication or a release qualification.

## Client workflow

1. Read `throttle_plan_read`. Each task line includes its last recorded `seq=N`.
2. For a new mutation, create a fresh UUID and send both metadata fields with the
   intended payload. `expected_seq` is the task sequence just observed.
3. If the response is lost, resend the identical task/project/author/payload and
   the same UUID/sequence pair. Do not generate a new UUID for a network retry.
4. An `Already recorded ...` reply acknowledges a historical event, not current
   ownership or permission to continue. Read the plan again before acting.
5. After a stale-state refusal, read the plan and reconsider the intent. A new
   valid intent uses a fresh UUID and the newly observed sequence; do not blindly
   rewrite metadata to force an old action through.

Synthetic first-claim arguments:

```json
{
  "project": "/path/to/your/project",
  "task_id": "task",
  "by": "codex:example-session",
  "event_id": "939f6d85-ce59-4f9e-a6d3-0e9aabb38c29",
  "expected_seq": 0
}
```

This example is documentation, not an instruction to mutate a project.

## Refusals and replay behavior

- Metadata is either absent as a pair (legacy behavior) or present as a pair.
  Partial/null/malformed metadata yields invalid parameters (`-32602`) before
  opening a mutation transaction. Sequence values must be nonnegative integral
  JSON numbers no larger than 9007199254740991; booleans and strings are refused.
- Read, retry comparison, state/ownership checks and append share one cooperative
  project lock. A fresh operation with a stale sequence does not write anything.
- Reusing an event UUID with a changed payload, author or original sequence is
  refused. The server timestamp is reused only when checking an existing UUID;
  every remaining event field is compared by the existing store encoder.
- An identical retry writes nothing even after release, rejection or reassignment.
  It cannot take ownership back or increment a rejection counter again.
- Stale/conflicting mutations use the existing textual `Refused:` result. A
  transport-level success alone must not be interpreted as an accepted mutation.

## Boundaries still open

Legacy callers without metadata retain their old behavior and do not gain the
new stale-generation protection. The `by` field is still client supplied; UUIDs,
sequences, locks and hash chains do not authenticate it. A locally rewritten log
is not cryptographically authenticated. The result does not prove a complete
signed app, live MCP transport, crash recovery, physical acceptance or a safe
downstream merge. These remain separate integration gates.
