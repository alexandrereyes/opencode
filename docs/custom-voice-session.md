# Voice memory: plugin KV record

Voice memory now uses one versioned record at `voice/transcript/global` in the
custom plugin's SQLite-backed KV namespace. It does **not** create an OpenCode
Session or register a provider, model or agent. The discarded echo implementation,
its preference pointer and custom-web picker filter have been removed.

Version 2 `custom.voice` RPCs provide `info`, atomic idempotent `append`, bounded
`context` and `end` (compaction check). Older/unsupported servers remain usable
without memory. History is supplied to GPT Live as `session.initial_items` with
both roles; instructions stay short and behavior-only.

Compaction starts above ~7,000 estimated tokens or 120 turns, using
`llm-proxy/gpt-6.1-sol-ultrafast`, with a deterministic fallback. It overwrites
older turns with a summary and the last up to ten whole turns, targeting ~4,500
tokens. Context is always capped at 128 items / 8,192 estimated tokens.
There is no TTL or delete action; this is rolling memory, not a verbatim archive.

See [the plugin contract, measurements and Phase 3 handoff](../packages/plugin-app-custom/docs/voice-session.md).
iOS still needs durable local buffering/replay, context → `initial_items`, the
end check and read-only **Ver transcrição**. The master does not receive voice
turns. No Core or public API extension was required.
