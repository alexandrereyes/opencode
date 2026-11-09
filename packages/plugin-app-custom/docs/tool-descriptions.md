# Descriptions the agent writes for its calls

Rev. 2026-11-09, prototype (branch `descricao-nativa`, not merged). The apps' activity rows show a raw command for each
`shell`, `grep` and Code Mode `execute` call, which says nothing about why it runs. The model already knows why: the
plugin (`src/tool-descriptions/index.ts`) asks it to say so in a `description` argument of those three tools.

## How

- The field goes into the **JSON schema the model receives**, after the tool's main argument (`command`, `pattern`,
  `code`), optional, through the session hooks `context`, `compaction` and `generate` (the same request hooks the core's
  shell uses for its description). `compaction` and `generate` get it too so their tool list keeps the prompt cache's
  prefix. A schema that already has a `description` property (a future upstream field) is left alone.
- **Nothing in the core changes.** `ctx.tool.transform` cannot reach `execute`: Code Mode builds that tool for each
  request snapshot instead of registering it in the editor. The request hook reaches all three.
- **Validation:** the tools decode their input with their own Effect schemas, which drop unknown keys (Effect's default),
  so the call runs exactly as before.
- **Storage:** the part's `state.input` is what the model sent (`session.tool.called` copies the provider's arguments),
  description included. The apps read `input.description`; old calls simply lack it.

## Text

Portuguese, gerund, 2 to 6 words (about 38 characters), the intent in the task rather than the mechanics, the target by
its short name, with good and bad examples per tool (`fields` in the module). Based on Claude Code's and OpenCode V1's
"Clear, concise description of what this command does", turned toward the why.

## Prompt cache

The schema is the same bytes on every request and across restarts and plugin reloads, so it costs one cache miss when
it first appears (or changes) and none after (about 600 more tokens in the cached prefix). The measurements are in the
results of the 2026-11-09 test (`descricao-nativa/results.md`).
