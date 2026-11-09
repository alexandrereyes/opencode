# Browser handoffs

Rev. 2026-11-07. When an agent drives Alexandre's Chrome through [browse](https://github.com/anomalyco/browse) and
calls `handoff("…")` (login, 2FA, captcha, payment), browse's `execute` tool blocks until he clicks **Continue** in the
tab, for up to 10 minutes. browse reports nothing over MCP meanwhile (no progress, no elicitation), and core drops MCP
progress anyway, so without this module the session only looks like it is working. This module makes such a call
attention of kind `browser`: "Precisa de você" in the apps, the Live Activity, the watch and one push. It uses public
plugin APIs only; no core change.

## Detection

- `ctx.tool.hook("execute.before")` and `"execute.after"` fire for every tool call of the plugin's Location,
  including the calls inside Code Mode's `execute` (core runs `beforeExecute`/`executeTool` for each inner call).
  Their `id` is the tool part of the transcript: Code Mode's `execute`, or browse's own call when it is a direct tool.
- A call counts when its tool is `browse_execute` (or `browse.execute`) and its `code` calls `handoff(` or
  `demonstrate(` outside comments (`detect.ts`). The message is that call's first string literal argument (a
  template's `${…}` reads as `…`), clipped to 120 characters; without one, `Conclua a etapa no navegador e clique em
  Continue` (`Demonstre o fluxo…` for `demonstrate`).
- It **waits** once it has run for 3 s (`limits.graceMs`, the permission alert delay), unless it ended before.
- It **ends** on `execute.after` (same input object, or the same code in the same tool part when a hook replaced it),
  on `session.tool.success`/`failed` of its tool part (Code Mode interrupts pending inner calls when its program
  returns), on `session.execution.succeeded`/`failed`/`interrupted` of its session (an interruption skips the hook),
  on `session.archived`/`deleted`, and when its Location unloads. A server restart forgets everything, as the call
  is gone too.
- The registry is process-wide (`globalThis.opencodeCustomBrowserHandoffs`): a call fires the hooks of its own
  Location only, while Sessões, the family and the hub read across Locations. Only the instance that saw a call start
  settles it and announces it, so each change is announced once.

### False positives and misses

It is a heuristic. A `handoff(` behind an `if` that does not run, or code that waits more than 3 s for something else
before or after a handoff it never reaches, shows as waiting for as long as the call runs. A handoff passed through a
variable (`const h = handoff; await h(…)`) or built with `eval` is missed. browse's other tools (`secrets_refresh`
with an auth failure) can hand off too and are not detected.

## RPC `custom.browser-handoffs`

`POST /api/rpc/custom.browser-handoffs/list` with `{"input":{"sessionID"?: string}}` returns `{ data: Handoff[] }`,
the waiting calls (oldest first), all sessions or one:

```ts
Handoff {
  id: string          // "brw_…", the call's own ID
  sessionID: string   // the session that runs it: top-level or a subagent
  callID: string      // the waiting tool part (Code Mode's execute, or browse's call)
  messageID: string
  message: string     // ≤ 120 characters
  since: number       // epoch ms the call started
}
```

Event `rpc.custom.browser-handoffs.changed` `{ sessionID }`: a call of that session started waiting or ended. The apps
reload on any `rpc.*` event, so the fields below follow without a read of their own.

## Where it shows

| Surface | Field |
| --- | --- |
| Sessões (`custom.navigation`) | `browserAt` (newest start), `browserCount`, `browserText` (newest message) per Session; the app rolls them up to the root like `questionAt` |
| Session family (`custom.session-family` `snapshot`) | `browser: Handoff[]`, root first then descendants, oldest first; the conversation names the waiting tool part |
| Live Activity (`live-activity.md`) | `counts.browser` (only when > 0), `attention`/`sessions`/`needs` of kind or status `browser`, after permissions; part of `activeTotal` and `attentionTotal` |
| Watch (`watch.md`) | the same state; no `requestID` (nothing to answer on the wrist); the complication key gains `browser` |
| Push (`session-notifications.md`) | `Navegador: <message>`, `attention: "browser"`, no `requestID`, `apns-collapse-id: attention:<sessionID>`, once per call, through the Live Activity when there is one |

Precedence everywhere: question > permission > browser > failed > working > unread.

## Finishing it from the apps

Rev. 2026-11-07: a handoff whose call names its browse `session` also gets a `resourceID`, the resource that shows its
tab in the viewer; see `browse-handoff-remoto.md`. Rev. 2026-11-08: so does a call that names none, when the plugin can
tell the agent's current browse session for sure (`browse-handoff-remoto.md`, "Sessão do browse").

## Compatibility

- **Old app, new server:** unknown fields are ignored; the Live Activity decodes kind and status `browser` as unknown,
  the push shows as a plain notification. `counts.browser` is absent while nothing waits.
- **New app, old server:** no `browser*` field, no `browser` list, no event: nothing changes.

## Tests

`docs/live-activity/state-browser.json` is the normative Live Activity state with a handoff, shared with the
apps' tests. `test/browser-handoff.test.ts` (detection, grace period, every way a call ends, two Locations, the tracker, the
notifier, Sessões and the family). `script/e2e-browser-handoff.ts` runs real Luna 6 / low prompts on an owned
sandbox against `test/fixture/browse-mcp.ts`, a fake browse whose `execute` blocks while its code hands off: no relay,
no Chrome. It checks every surface above, the clear on Continue and on interruption, and that code without a handoff
never shows; `--keep-waiting` leaves one session waiting for app captures.
