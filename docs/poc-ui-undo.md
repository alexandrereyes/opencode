# Public-API undo orchestration POC

## Objective

Determine experimentally whether UI/plugin orchestration can replace all
undo-specific custom Core patches while preserving the behavior of custom
`9ebde0dc7`. OpenChamber's V1 cascade is implementation inspiration, not the
acceptance baseline: its best-effort timestamp heuristic is not strict parity.

The native upstream V2 per-session revert/snapshot implementation remains an
allowed dependency. "Zero Core" here means zero custom causal-undo machinery,
not eliminating OpenCode's native session engine.

## Isolation and candidate boundary

- Work in branch `poc-ui-undo`; do not replace the production plugin or register
  the experimental module in its default entrypoint.
- Put executable POC code and tests under an isolated package-local POC area.
- Candidate orchestration uses public HTTP/client/plugin interfaces and its own
  durable operation state. No Core/Server imports, direct reads of native
  database tables, monkeypatching, private service injection or hidden fallback
  to the custom causal planner/coordinator/guards.
- Test against an actual upstream V2 backend without the custom causal patches,
  or a separately verified stripped candidate. Merely disabling the planner on
  our custom backend is insufficient because its grouped-revert/job machinery
  would remain available and could mask gaps.
- The current custom implementation may serve as an oracle in separate tests.
  Identify the exact revisions and capabilities used by each target.

## Required behavior

1. Discover all relevant descendants through authoritative paginated APIs.
2. Preserve exact causal cuts, including reused children and independent child
   inputs; timestamp approximations do not establish parity. Match the oracle's
   existing suffix semantics: do not require selective preservation of inputs
   inside a suffix that the current implementation itself discards.
3. Preserve drafts, pending inputs and unrelated work.
4. Stop/invalidate affected foreground and background work, including shells,
   with no late notification or restart resurrection.
5. Preserve parent/child file restoration, including overlapping file edits and
   cross-Location history-only behavior.
6. Persist operation membership/boundaries for reload, redo and retry; preserve
   independent child reverts and family commit on new input.
7. Handle partial failures and concurrent input with the same observable
   guarantees as the current implementation.
8. Preserve behavior for existing histories, not only sessions created after
   the POC starts recording additional plugin-owned data. Investigate migration
   through the old custom backend's public APIs/event log before assuming its
   existing provenance is unavailable.

Use existing public capabilities seriously before declaring gaps: V2 exposes
message filtering/pagination, inbox cancellation, shell list/remove and shell
metadata, as well as per-session stage/clear/commit. Verify their real semantics.

## Evidence and decision

Implement an executable candidate and conformance tests. A happy path alone is
not sufficient. Include independent child inputs with ambiguous timestamps,
unloaded descendants, live background shell/subagent work, delayed completion,
partial failure, reload/redo, new prompt after undo and existing-history cases.

If a case cannot be implemented without a behavior change, capture a concrete
counterexample and the missing public information or operation. Classify such
cases as unsatisfied, even if the POC can refuse them safely. Do not silently
weaken assertions, swallow child errors or label partial functionality as full
parity. Additional backend capabilities, if necessary, must be presented as
residual requirements, not disguised as zero-Core success.

Conformance claims must compare with the actual custom oracle. A simulated
client fixture or a reduced projection of public messages cannot by itself
prove that the real public APIs lack information. Test durable operation state
by reopening actual persistent storage, not by sharing an in-memory Map across
two object instances. Keep unexecuted scenarios explicitly marked NOT TESTED.

The parent reviewer will inspect and iterate on the implementation/evidence,
then present feasibility to the user. No commit to `custom`, push, deployment,
production database access, global config change, live restart, sync, pending-
release writes or re-enabling automatic activation is authorized for this POC.
Preexisting upstream defects are outside scope.
