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
- **Methods:** `info` (model, voice, request limit, learned speaking rate and cost per audio second for estimates),
  `synthesize({ text ≤ 2,000 characters, voice? })` → `{ audio (base64), mime, cached }`, and the reading-position
  methods below.
- **Early stops:** Gemini TTS sometimes stops partway through a long piece (it happened most on text that repeats
  itself). A piece of 300 characters or more whose audio is under 60% of the length the learned rate predicts is
  generated once more and the longer audio is kept; a cached piece that short (checked with `afinfo` on macOS) is
  generated again. A piece still short after the retry is kept, logged and not learned from.
- **Learned speaking rate:** each newly generated, plausible piece adds its characters and audio seconds to
  `speech:rate:<model>:<voice>` in the plugin storage (cache hits add nothing). `info.charactersPerSecond` is
  `(2,000 + characters) / (2,000 / 14 + seconds)`: 14 per second until audio exists, then the weighted rate of the
  server's own audio. Past 200,000 characters both sums halve, so the rate follows recent audio. Audio cached before
  this was added carries no text length and teaches nothing.
- **Reading positions:** `getPosition({ path })` → `{ position | null }`, `setPosition({ path, hash, offset,
  characters, sentence, seconds? })` and `clearPosition({ path })`, in `speech:positions`. The plugin is per server, so
  the key (still named `path` for older apps) is a file's absolute path or, for a chat answer,
  `message:<sessionID>/<messageID>` with the answer's last message (`Speech.messageKey`). `offset` counts characters of the speakable text (the app's pieces joined),
  `hash` is that text's SHA-256, `sentence` (≤ 200 characters) the sentence being read and `seconds` the elapsed audio
  at 1×. Saving moves the key to the front; the 200 most recently saved files and, separately, the 200 most recent
  answers are kept, so listened answers never push out a file's place. The app saves on pause,
  stop, closing or leaving the file, going to the background and every 8 s while playing (only after the reading
  moved in that opening, and failures are ignored); it clears the place when the document ends or on **Recomeçar do
  início**. When the hash differs, the app looks for the saved sentence (nearest the old offset), then the sentence
  start nearest the old offset, and starts from the top if the text got shorter than the saved place.
- **Cost:** Gemini audio output is 25 tokens per second at $6 per million, about $0.009 per minute of speech. The
  app generates only the pieces near the playhead and asks before starting a document over 30 minutes.

`test/speech.test.ts` runs against a local gateway; `OPENCODE_SPEECH_LIVE=1 AI_GATEWAY_API_KEY=…` adds one real,
fraction-of-a-cent request.
