# Continuous voice conversation memory

The custom plugin records voice in one real, top-level **Conversa por voz**
Session per server. It lives directly in the managed chats root, uses the hidden
`voz` agent, and is not a child of the master. Transcripts have no retention limit
or feature-specific delete action. Native compaction does not delete the timeline.

## Local echo provider

`voz-eco/transcricao` declares a 48,000-token context and zero-cost usage. Its
`LanguageModelV3` streams already-spoken text, reports zero tokens and `stop`, and
never invokes inference or a tool. The agent is hidden, primary, has `steps: 1`
and deny-all permissions; the context hook also removes tools.

The provider declares `aisdk:@ai-sdk/perplexity` **only as a shipped SDK factory**.
Core's built-in Perplexity hook constructs the SDK before its dynamic npm
fallback; the custom provider-scoped `aisdk.hook("sdk")` then unconditionally
replaces it with the in-process echo SDK. No Perplexity credential or HTTP method
is used. The package remains on the AISDK path instead of native canonicalization.
Core already depends on and bundles its literal dynamic import in the compiled
CLI. No new runtime dependency, sidecar file, listening port, Core change or
plugin extension point is needed.

An invented package initially failed: Core's dynamic SDK hook tried installing
it before the external plugin hook ran. `@ai-sdk/openai-compatible` worked in the
source sandbox, but was not chosen because a cached dynamic installation would
not prove release compatibility. The shipped Perplexity factory resolves that
problem without changing hook ordering.

## RPC version 1

All methods use the normal authenticated, location-scoped plugin RPC transport:
`POST /api/rpc/custom.voice/<method>?location[directory]=...`, body `{ "input": ... }`.
The contract is exported as `@opencode/plugin-app-custom/voice/rpc`.

- **`info({})`** returns `{version:1, agent:"voz", provider:"voz-eco", model:"transcricao"}`.
  It does not create a Session. An app must probe support and fall back to voice
  without memory on older servers (`rpc.unavailable`/`rpc.method_not_found`).
- **`context({version:1})`** creates/adopts the recorder and returns
  `{version:1, sessionID, text}`. The text contains the native summary, recent
  exchanges and the master's current running/idle state plus at most its latest
  500 text characters. It excludes reasoning and tools, is bounded to **16 KiB
  UTF-8**, and explicitly marks historical content as untrusted data, not current
  instructions or authorization. Literal `<` in data is escaped. No master
  prompt, delegation or model call is made by this read.
- **`turn(...)`** durably admits one finalized exchange or one master notice,
  returning `{version:1, sessionID, messageID}`. This is admission, not completion.
  Call/turn/item identifiers are nonempty, at most 200 characters; each speech
  text is at most 64,000 characters.
- **`end({version:1, callID})`** queues native compaction **after** already-admitted
  exchanges, then returns `{version:1, sessionID}`. It does not wait for summary
  completion. Repeated calls after admission are ignored; no known turns means
  no compaction. Like normal Session operations, crash recovery is not an
  exactly-once guarantee for inference.

Example finalized exchange:

```json
{
  "version": 1,
  "callID": "call-uuid",
  "turnID": "exchange-id",
  "type": "exchange",
  "user": { "itemID": "input-item", "text": "Prefiro respostas curtas." },
  "assistant": {
    "itemID": "output-item",
    "text": "Vou lembrar, Alexandre.",
    "interrupted": false
  }
}
```

Either `user` or `assistant` may be omitted, but not both. Assistant-only speech
uses an undescribed synthetic input so no fictitious user bubble is shown.
User-only speech gets an empty echo, not the typed-text warning. Interrupted
speech preserves the original text in metadata and adds an explicit visible
marker that its ending may not have been heard.

A master return is a notice, not a user utterance:

```json
{
  "version": 1,
  "callID": "call-uuid",
  "turnID": "notice-id",
  "type": "notice",
  "itemID": "master-result-id",
  "text": "A mestra concluiu a consulta."
}
```

Its synthetic description is **Atualização da Sessão mestra**, its model-facing
text identifies the master as the source, and its echo is empty. Recent voice
turns are **never sent to the master**.

## Durability and preferences

The plugin atomically reserves one Session ID in its own KV storage, then uses
idempotent `session.create({id,...})`. The shared preferences pointer is
`custom.preferences.data.voiceSessions.local`; `voice.set` is an additive intent.
Old profiles need no migration, and unrelated preference mutations preserve the
new optional field. The plugin's reservation is server-global across Locations.
Voice and preferences handlers share an in-plugin preferences service, including
its update event. They do not send bundled Effect codecs through a host-side
internal RPC client; that boundary is incompatible with the minified release.

A per-call index stores turn/item aliases and their native message IDs, **not
another transcript copy**. Retries by either turn or item ID reuse the admission
ID, including after restart. Core's first-admission-wins contract ignores changed
retry payloads. Cross-type reuse fails instead of changing message types.

Each admission uses `delivery:"queue"`: one promoted input produces one echo
assistant. The completed reply and canonical IDs are in the input's
`metadata["custom.voice"]`, so restart does not depend on a process-local map.
Immediately before dispatch, the plugin reads the latest promoted user/synthetic
message and passes its reply through the internal `x-voz-reply` request header.
That header is consumed by the local model; it is never sent over HTTP.

Typed text gets this fixed local response:

> Esta sessão registra conversas por voz. Para pedir algo, use a Sessão mestra.

A prompt-admission hook restores the recorder's agent and model before waking
execution. This also handles custom-web picker fallbacks that commit a normal
agent/model before submission. Voice RPCs restore them too. An archived recorder
must be unarchived; the plugin does not silently replace or delete its memory.

## Summary

The compaction hook filters by **agent `voz`**, not provider: a configured
compaction-agent model may differ from the Session model. It supplies
`event.result.summary`, so Core makes no compaction call to the eco model or the
configured compaction model. The plugin uses exactly one explicit
`ctx.generate.text` request to **`llm-proxy/gpt-6.1-sol-ultrafast`** with a
voice-specific factual-memory prompt in Portuguese. It bounds source text to
96 KB and saved summary to 6 KB. On failure/empty output it preserves bounded
prior and recent source text deterministically. This is not a second master
conversation. The native compaction marker's usage does not account for the
separate `generate.text` call, whose API returns text only.

Call end requests compaction; global automatic compaction remains unchanged as a
safety net. No global `keep`, buffer or model settings are changed. Full turns
remain available in native message pagination even when active context shrinks.

## Picker policy and Phase 3

The custom web provider facade excludes `voz-eco` from connected/paid choices,
while retaining historical metadata in the full catalog. Existing hidden-agent
filtering excludes `voz`. Saved defaults, visibility and recents cannot bring the
model back. The voice transcript remains a normal navigable web Session. The
upstream TUI may list the internal agent/model; typing still gets the fixed
notice. Upstream-owned UI trees are unchanged.

iOS integration is deliberately **not included yet**. The app needs to:

1. Probe `info`, fetch `context` at call start and append it as data to GPT Live
   instructions; failure must not prevent a call without memory.
2. Retain canonical `turn.done` text and item IDs; serialize finalized exchange
   admissions before `end`. Buffer the user's completed input until the matching
   assistant turn ends, flushing user-only speech on interruption/call end. Send
   assistant-only greetings separately. Never reuse an assistant item as both
   an early partial reply and a later finalized exchange.
3. Send narrated master returns as notices and preserve interruption flags.
4. Hide/mute the recorder in Sessões and counts using the pointer/`voz` agent;
   exclude its provider/agent from pickers. **Ver transcrição** opens it read-only
   from the expanded voice bar. No retention/delete feature is requested.

## Verification evidence (2026-10-23)

Only sandbox **4180** was used. No production/other sandbox service, physical
device or GPT Live call was touched. The second spike completed well within its
two-hour limit. Local evidence scripts/logs are in `.agent-artifacts/voz-sessao/`.

| Required mechanism          | Observed result                                                                                                                                                                                           |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Provider accepted and local | Enabled catalog model; three verbatim Unicode replies, `stop`, zero cost/tokens.                                                                                                                          |
| Reply transport             | Different stored replies reached `doStream` through the internal header, in FIFO order.                                                                                                                   |
| Manual/automatic compaction | Both completed for `voz`; each summary increased the plugin generation counter once, with **no additional eco stream**. Release auto fixture: two replies, one completed `reason:"auto"` checkpoint.      |
| Queue and restart           | Three initial replies; parked a durable fourth input, restarted, retried old IDs and woke with a fifth input. Exactly five total assistants; restarted plugin counter was **two** streams, no duplicates. |

The release-like proof ran the **compiled custom CLI + minified
`custom-plugin.ts` bundle** outside the checkout, with **no `node_modules` and a
fresh, still-empty dependency cache**. It used the same compiled-provider path
as `custom-release.ts`, not merely the source sandbox's generated plugin JS.
This was a dirty development fixture, not a signed/published production release.
Its manual/automatic checkpoints used tiny bounded summary prompts. No runtime
npm installation or Perplexity request was needed.
The final bundled product RPCs also passed against a fresh database without
copied credentials: first-use Session/pointer creation and Unicode echo completed
with zero tokens. Against the persisted sandbox database, retrying after restart
kept the same Session/admission IDs and did not duplicate a reply or summary.

Product RPC smoke evidence additionally covers concurrent duplicate requests,
assistant-only speech, user-only speech, master notices, one continuous root
Session, bounded context, and restoration from a deliberately invalid changed
model/agent before a typed prompt: **five assistants, zero eco tokens/cost, fixed
notice**. Unit tests cover schema limits, durable mapping, aliases, preference
compatibility, summary/fallback and adversarial Unicode/escaped context budgets.
The custom web model-selection fixture and headless Chrome picker check verify
the internal model cannot be selected; no application service worker controls
the sandbox page.
