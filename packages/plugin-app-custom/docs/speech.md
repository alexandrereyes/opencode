# Speech (`custom.speech`)

Text-to-speech for the iOS app's Markdown viewer. The server holds the credential; the phone sends text and gets
compressed audio back.

- **Model:** `google/gemini-3.8-flash-lite-tts` through the Vercel AI Gateway (`defaults.model` in
  `src/speech/index.ts`; `OPENCODE_SPEECH_MODEL` overrides it, for example `google/gemini-3.8-flash-tts`). Voice
  `Kore`, with a short Brazilian Portuguese narration direction.
- **Credential:** the active `vercel` integration connection, resolved per call through
  `ctx.integration.connection`. Without a key the call fails with `unavailable`; a gateway 401/403 also maps to
  `unavailable`, other failures to `synthesis_failed`.
- **Protocol:** `POST https://ai-gateway.vercel.sh/v4/ai/speech-model` (the AI SDK speech-model protocol used by
  `@ai-sdk/gateway`, not OpenAI `/v1/audio/speech`), WAV out. `OPENCODE_SPEECH_GATEWAY_URL` points tests at a local
  server.
- **Cache:** `$XDG_CACHE_HOME/opencode/custom-speech/<sha256(model, voice, direction, text)>.m4a`. On macOS the WAV
  is converted with `/usr/bin/afconvert` to 48 kb/s AAC (about a tenth of the size); elsewhere the WAV is kept. A hit
  refreshes the file time; files unused for 30 days are removed at startup.
- **Methods:** `info` (model, voice, request limit, measured speaking rate and cost per audio second for estimates)
  and `synthesize({ text ≤ 2,000 characters, voice? })` → `{ audio (base64), mime, cached }`.
- **Cost:** Gemini audio output is 25 tokens per second at $6 per million, about $0.009 per minute of speech. The
  app generates only the pieces near the playhead and asks before starting a document over 30 minutes.

`test/speech.test.ts` runs against a local gateway; `OPENCODE_SPEECH_LIVE=1 AI_GATEWAY_API_KEY=…` adds one real,
fraction-of-a-cent request.
