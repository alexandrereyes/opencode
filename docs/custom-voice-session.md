# Voice conversation memory

The custom plugin now provides a continuous **Conversa por voz** Session using a
zero-inference local echo model, with native compaction and an explicit
`llm-proxy/gpt-6.1-sol-ultrafast` memory summary at call end. Versioned
`custom.voice` RPCs expose recording, bounded startup context and call end.
No Core or public API changes are needed; older clients keep their current
behavior without memory.

The plugin-only echo path passed isolated source and compiled-release-bundle
proofs on port 4180; the earlier imaginary-package SDK-loader blocker is resolved
by using a shipped factory before replacing its SDK locally.

See [the plugin contract and evidence](../packages/plugin-app-custom/docs/voice-session.md).
iOS integration remains a separate Phase 3: canonical turn/item IDs, memory
instructions, call-end summary, hidden/muted recorder and read-only transcript
access from the voice bar. Transcripts have no retention limit or delete action;
the master does not receive recent voice turns with delegations.
