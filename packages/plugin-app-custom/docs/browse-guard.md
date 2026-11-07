# browse credential guard

Rev. 2026-11-07. Rule: [browse](https://github.com/anomalyco/browse) must not store credentials on disk on this
machine. Everything else in browse stays available: `execute`, sessions, tabs, recording, `flight_recorder`,
`demonstrate`, and network capture without credentials. Code: `src/browse-guard/index.ts`. Public plugin APIs only;
no core change.

## Where browse writes credentials

| Writer                                                          | File                                                                | Who can call it                    |
| --------------------------------------------------------------- | ------------------------------------------------------------------- | ---------------------------------- |
| `network` with `secrets` (MCP), `browse network stop --secrets` | `~/.local/share/browse/secrets/<profile>.json`                      | an agent, through MCP or the shell |
| `secrets_refresh` (MCP), `browse secrets refresh`               | the same profile, updated                                           | an agent, through MCP or the shell |
| `browse secrets add`                                            | `~/.local/share/browse/site-secrets/<name>.json` (plain text value) | the shell only                     |

`secrets_run`, `secrets_list` and `secrets_status` only read. browse itself has no setting to turn the writers off.

## The module

MCP permission rules see only the tool name (`browse_network`; the resource is always `*`), so a rule can deny the
whole tool but not one input. The module checks the input instead:

- `ctx.permission.hook("evaluate")` denies the action `browse_network` whenever the call carries `secrets` (any
  action, any value but `undefined`). This holds on every path that asks permission for the tool, whatever the
  configured or saved rules allow.
- `ctx.tool.hook("execute.before")` refuses the same call (`browse_network` or `browse.network`, direct or inside
  Code Mode) with a `Tool.Error`, so the agent reads the reason:

  > O browse não pode gravar credenciais em disco nesta máquina: `network` com `secrets` está bloqueado. Para guardar
  > a captura, chame `network` de novo sem `secrets`, com `outputPath` (HAR com as credenciais redigidas).

  The permission denial alone would reach the agent only as "Unable to execute browse_network": core's MCP tool
  wrapper (`packages/core/src/tool/mcp.ts`) replaces every error that is not a tool failure, the permission's
  message included.

`network` start, status, cancel and `stop` with only `outputPath` pass untouched.

## Rules in `~/.config/opencode/opencode.json`

The other writers are whole tools or shell commands, so global permission rules cover them (applied on 2026-11-07,
after `subagent`; the file reloads without a restart):

```json
{ "action": "browse_secrets_refresh", "resource": "*", "effect": "deny" },
{ "action": "shell", "resource": "*browse* secrets add*", "effect": "deny" },
{ "action": "shell", "resource": "*browse* secrets refresh*", "effect": "deny" },
{ "action": "shell", "resource": "*browse* network stop*--secrets*", "effect": "deny" },
{ "action": "edit", "resource": "*.local/share/browse/secrets/*", "effect": "deny" },
{ "action": "edit", "resource": "*.local/share/browse/site-secrets/*", "effect": "deny" }
```

A wholly denied MCP tool leaves the Code Mode catalog, so `secrets_refresh` disappears. The `edit` rules cover the
write, edit and patch tools, with absolute paths and paths relative to the session directory.

## What remains possible

The guard closes browse's own credential stores. An agent that means to keep credentials can still:

- save cookies from `execute` code (`context.storageState({ path })`, `files.write` of `context.cookies()`) into the
  browse session's artifacts;
- write the profile or site-secret JSON from the shell in a way the patterns do not see (`echo … > file`, an alias,
  a script), or call the relay's HTTP API (`/auth/*`) directly;
- run `secrets_run` with a profile stored before the guard (none existed on 2026-11-07).

## Tests

- `test/browse-guard.test.ts`: which inputs are denied and refused, and that everything else passes.
- `script/e2e-browse-guard.ts`: against an owned sandbox, a real model calls a fake browse
  (`test/fixture/browse-mcp.ts`) through Code Mode. Capture and a redacted HAR reach browse, `secrets` never does,
  and the agent reads the reason.
