# Descriptions the agent writes for its calls (`input.description`)

Rev. 2026-11-09. The apps' activity rows showed a raw command for each `shell`, `grep` and Code Mode `execute` call,
which says nothing about why it runs. The model already knows why: the plugin (`src/tool-descriptions/index.ts`) asks
it to say so in a `description` argument of those three tools. Alexandre chose this over inferring descriptions with
another model (instant, it carries the intent, and nothing more leaves the server).

## Contract

- **Where:** the `input` of a tool part (`state.input`, and `session.tool.called`'s `data.input`) of `shell`, `grep`
  and `execute`, as `description: string`. No other tool has it. Text written by the agent: plain text, to be shown,
  never interpreted.
- **What:** Portuguese, a verb in the gerund first, 2 to 6 words (about 38 characters): the intent in the task, with the
  target by its short name (`Reproduzindo falhas dos testes`, `Localizando os TODOs do repositório`, `Somando os
pedidos por cliente`). Clients collapse whitespace and trim it.
- **May be absent:** calls from before rev. 2026-11-09, models that leave it out (required of the model, not of the
  call: the tool still runs), and while the input streams (it comes after `command`, `pattern` or `code`, so it may
  arrive last). Without it a client shows what it showed before.
- **Who uses it** (each one falls back to its previous text when it is absent):
  - the apps' activity rows (the description on top, the command, pattern or Code Mode label below; a short simple
    command, which already says it all, stays on one line without it);
  - Sessões' status line and the master's voice (`trabalhando · reproduzindo falhas dos testes`), in the apps;
  - the Live Activity's `activity` (`describe()` in `src/live-activity/tracker.ts`, [live-activity.md](live-activity.md)).

## How

- The field goes into the **JSON schema the model receives**, after the tool's main argument, **required**, through the
  session hooks `context`, `compaction` and `generate` (the same request hooks the core's shell uses for its
  description). `compaction` and `generate` get it too so their tool list keeps the prompt cache's prefix. A schema
  that already has a `description` property (a future upstream field) is left alone.
- **Nothing in the core changes.** `ctx.tool.transform` cannot reach `execute`: Code Mode builds that tool for each
  request snapshot instead of registering it in the editor. The request hook reaches all three.
- **Validation:** the tools decode their input with their own Effect schemas, which drop unknown keys (Effect's default),
  so a call runs exactly as before, with or without the field.
- **Storage:** the part's `state.input` is what the model sent (`session.tool.called` copies the provider's arguments),
  description included.

## Text

Per tool (`fields` in the module), based on Claude Code's and OpenCode V1's "Clear, concise description of what this
command does", turned toward the why, with good and bad examples. The shell's: "Para quem acompanha pelo app: por que
este comando roda, de 2 a 6 palavras (até uns 38 caracteres), em português, começando com um verbo no gerúndio. Diga a
intenção na tarefa, não a mecânica, e cite o alvo pelo nome curto, sem caminhos, flags ou código."

## Measured (2026-11-09, sandbox)

Nine models (Opus 5.5, Sonnet 5.5, Terra 6.1, Sol 6.1, Luna 6, DeepSeek V4.1 Flash, GLM 5.3, Kimi K3.1 Pro, Grok 4.7)
on four short tasks, three rounds: filled in 84 to 100% of the calls as an optional field (100% of shell and execute;
grep was the gap) and in all of them once required; Portuguese throughout; rated above another model's description
of the same call when the judges saw the agent's context (4.0 against 3.9; intent 4.1 against 3.2). Tasks solved,
calls, errors and time were the same with and without the field.

## Prompt cache

The schema is the same bytes on every request and across restarts and plugin reloads, so it costs one cache miss when
it first appears (or changes) and none after (about 600 more tokens in the cached prefix).
