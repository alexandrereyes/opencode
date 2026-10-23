# Agent selection on send

Verified against installed backend `1042585c285c25d4b5d4fd292d0b7eb5fb7c470e`.

- `Session.switchAgent` (`packages/core/src/session/session.ts`) always publishes
  `AgentSelected`, including unchanged selections. `message-updater.ts` projects it
  as `agent-switched` with `agent` and `previous`.
- `/prompt` has no top-level agent or model fields. Composer metadata records the
  selection for presentation; it does not select the execution agent.
- The custom web's `composer/submit.ts:applySelection` compares the current agent
  before calling `/agent`. It always calls `/model`; the server deduplicates that
  selection by provider, model ID, and variant (nil and `default` are equivalent).
- Native `PromptSubmission.applySelection` follows this contract for ordinary
  prompts and commands, fetching `/api/session/:id` immediately before comparison
  rather than trusting delayed SSE state. Queue submissions do not reconfigure
  execution. Child submissions retain their agent. New-session creation already
  supplies its initial selection without a separate switch.
- Historical no-op agent notices remain visible, matching the web's
  `session-timeline-row.tsx:notice`, which does not filter equal `previous` values.

## Verification

`swift test` in `OpenCodeKit`; warning-free simulator `build-for-testing`;
`python3 packages/ios-custom/script/test-agent-selection.py` using the dedicated
**OpenCode Agente** simulator and `ios-agente-derived` products.

The runner supplies explicit port-4177 credentials, creates and deletes only its
own sessions in the fake `abacato-v2` repository, and uses Luna 6/low. In both
themes, three unchanged sends produce zero agent/model switches; selecting the
sandbox's `utra` agent then sending produces exactly one `build → utra` switch
and zero model switches. Logs, server switch records, and screenshots are saved
under the temporary `opencode/ios-agente-prints` directory.
