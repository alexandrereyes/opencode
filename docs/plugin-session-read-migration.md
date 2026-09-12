# Session reading plugin migration

Base: `origin/custom` at `a289af884`.

## Preserved feature contract

Move only `opencode.session_read` from the built-in OpenCode tools to a
`session-read` module in the existing custom plugin. Keep its effective tool
name, Code Mode exposure, descriptions, input and output compatible.

- Input: `sessionID`, optional `limit` (default 20, maximum 50), optional
  `cursor` as an existing message ID.
- Output: `session: { id, title?, directory }`, `messages: [{ id, type, text,
truncated? }]`, optional `next` as a message ID.
- Preserve newest-first order, the 20,000-character returned-text budget,
  message formatting/filtering, and continuation after the last consumed
  message. Do not include reasoning, tool payloads or attachments.
- Preserve reads across projects on the same server, errors for unknown
  sessions/cursors, and the behavior for untitled/empty sessions.
- Rename/move tools and the existing session-mention UI remain intact.

## Generic plugin capability

Expose `ctx.message.list` in both Effect and Promise contexts by extending the
existing corresponding `MessageApi` client interface. Reuse its input/output
contract and pagination behavior rather than creating a feature-specific read
endpoint. Host wiring may access native services; the custom plugin may not
import Core or Server.

The public HTTP message API uses opaque cursors while this existing tool uses
message IDs. Preserve both. Extract the existing cursor codec from the Server
handler into a small browser-safe canonical Schema module, shared by the
handler and plugin host. Expose a public cursor constructor through the plugin
surface so the custom tool can request a page from a known message boundary
without encoding an internal cursor format itself or scanning all history.
Keep the wire cursor encoding compatible; do not add a new HTTP endpoint.

The proposed canonical helper namespace is `MessagePage` in
`@opencode/schema/session-message-page`, re-exported by `@opencode/plugin/message`.
Its cursor constructor accepts `{ id, order, direction }` and returns the
opaque string accepted by `ctx.message.list`. Codec errors must remain normal
typed failures, and the existing invalid cursor/order checks must be preserved.
If inspection reveals a smaller existing public capability covering this,
report the alternative for review before changing this part of the contract.

## Validation and delivery

Exercise the real custom plugin through the normal tool registry/Code Mode
with durable sessions and messages, including cross-project reads, pagination,
character limits and redaction. Verify the built-in registration is gone,
rename/move remain available, and the three existing plugin features still
register. Cover Effect/Promise message APIs and HTTP cursor compatibility with
the shared helper. Avoid mocks when the existing fixtures provide the runtime.

No UI rewrite is expected. Run package checks and focused tests appropriate to
changed contracts; regenerate clients only through the generator if public
Protocol/HttpApi changes. No upstream bug fixes. Submit to reviewer before Git
finalization, then squash/push only to `custom` on approval. Automatic activation
remains disabled: no sync, pending-release writes, MyEnv/config changes or
production restarts.

## Migration result

- `opencode.session_read` now registers from the custom plugin's `session-read`
  module; the built-in OpenCode plugin retains only `session_rename` and
  `session_move`.
- Effect and Promise plugin contexts expose the existing `message.list` client
  contract. The Core host adapter delegates to `Session.Service`.
- `@opencode/schema/session-message-page` owns the browser-safe opaque cursor
  codec, and `@opencode/plugin/message` re-exports its `MessagePage` namespace.
  The JSON/base64url wire representation remains unchanged.
- Focused coverage exercises normal custom-plugin loading and unloading,
  Code Mode execution, cross-project durable history, pagination, the 20-message
  default and 20,000-character budget, payload filtering, Effect/Promise API
  parity, HTTP's 50-message default, and valid, malformed, mismatched-order, and
  missing-boundary cursor behavior.
- The existing app mentions, native apps, and subscriptions RPC smoke test
  continues to pass. No UI or HTTP endpoint changed, so client regeneration and
  UI benchmarking were not required.
