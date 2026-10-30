# Dictation review (`custom.dictation`)

A minimal revision of a dictated transcription before it enters a composer draft. The iPhone and Mac apps transcribe
on the device, then ask this server to fix spelling, punctuation and words speech recognition misheard. No Session is
created: the call is a stateless generation inside the plugin.

- **Method:** `review({ text, context? })` → `{ text, revised }`.
  - `text` (1–20,000 characters) is the transcription as recognized.
  - `context` (≤ 20,000 characters, optional) is what the composer already shows, sent as is: in a conversation the
    draft and the end of the latest messages; in Nova sessão the draft; in a comment the quoted passage and the draft;
    in Pergunta paralela whatever exists there. It only helps the model understand the subject; it is never revised or
    returned.
  - The method has no error cases. A failure, an idle stream or an empty reply returns `{ text: <transcription>,
    revised: false }`, so the app inserts the raw text without an error message.
- **Model:** `llm-proxy/gpt-6.1-terra-fast#low` (`defaults.model` in `src/dictation/index.ts`).
- **Timing:** the reply is consumed as a stream through `ctx.experimental.generate.textStream`. The limit is 5 s of
  inactivity: waiting for the first delta and between deltas. A reply that keeps streaming is never cut. The server
  returns the full text at the end; partial text is not sent to the app, so the draft changes once (raw → revised) and
  undo stays two steps. The app keeps its own ceiling (30 s) for a server that never answers.
- **Prompt:** `prompt(input)` in `src/dictation/index.ts`, in English and language neutral: revise in the language or
  languages it was spoken in, never translate, keep mixed speech mixed. It names no language, country, word or
  scenario; a test enforces that. The transcription goes in `<dictation>` and the optional context in `<context>`.
- **Older servers:** an app talking to a server without `custom.dictation` gets an RPC error and inserts the raw text.

## App behavior

- Every recording starts with review on (the sparkles button in the recording bar, orange when on, gray when off). The
  choice lasts only for that recording.
- While the server answers, the composer shows **Ajustando texto…** with **Usar original**, which inserts the raw text
  at once and ignores the late reply. Esc (and the trash button) cancels everything, inserting nothing.
- When the reply arrives the app inserts the raw text and replaces it with the revision as two undo steps: the first
  undo brings back the raw text, the second removes it.
- Details and tests: "AI review of the dictation" in `packages/ios-custom/README.md`.
