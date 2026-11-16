# browse credential guard (retired)

Rev. 2026-11-16: retired with browse 0.1.0. Earlier: rev. 2026-11-07.

The rule stays: [browse](https://github.com/anomalyco/browse) must not store credentials on disk on this machine. Since
browse 0.0.17 it cannot: site secrets, secret profiles, `network` with `secrets`, `secrets_refresh` and the `browse
secrets` commands are gone, and browse 0.1.0's relay deletes the folders older versions wrote (`site-secrets/` and
`secrets/` in its data directory) every time it starts. Its `network` capture has no `secrets` and no `outputPath`: it
returns the exchanges inline, with authorization headers, cookie values, secret-named fields and token-like values
replaced by `[redacted]`. So the module had nothing left to check, and it was removed with its test and its end to
end script (`src/browse-guard/`, `test/browse-guard.test.ts`, `script/e2e-browse-guard.ts`).

## What changed for the agents

Nothing they could still call is refused. The plugin's other browse rules stay: while Alexandre controls a session's
browse tab, its browse calls and the `browse` commands that name the tab are refused (`browse-handoff-remoto.md`,
section 0).

## Rules in `~/.config/opencode/opencode.json`

The global permission rules added on 2026-11-07 (`browse_secrets_refresh`, the `browse secrets …` and `browse network
stop … --secrets` shell patterns, and the `edit` rules on `~/.local/share/browse/secrets/*` and `site-secrets/*`) now
match nothing browse offers. They are harmless and can be removed at any time; the plugin does not depend on them.

## What remains possible

As before, an agent that means to keep credentials can write them itself (page values read with `eval`, files written
from the shell). The guard never covered that.
