# Custom macOS runtime

## Manual releases

### Editable voice prompt

GPT Live's shared iPhone/Watch prompt is read from `voice.md` in the global config directory
(`OPENCODE_CONFIG_DIR`, otherwise `$XDG_CONFIG_HOME/opencode`, otherwise `~/.config/opencode`).
Start with `packages/plugin-app-custom/src/voice/voice.md`. The authenticated `custom.voice/instructions`
RPC rereads the complete file for every new call, so later edits require neither a server restart nor an app
update. Existing calls keep their instructions. An absent file uses the bundled default; an empty or unreadable
file fails explicitly. The initial migration requires a backend release and an iOS build with RPC loading.
The editable file lives outside immutable releases and is not overwritten by `custom:update`.

### Release commands

Run these commands from a clean, committed `custom` checkout on macOS (or Linux, see below):

```sh
bun run custom:prepare          # builds only; production keeps running
bun run custom:status
bun run custom:activate --dry-run
bun run custom:activate         # explicit interruption + backup + replacement

# Subsequent updates (does NOT fetch, pull, merge, commit or push Git):
bun run custom:update           # prepare, then activate without database backup

# Select an already-prepared release explicitly:
bun run custom:activate <full-40-character-sha>
```

`OPENCODE_CUSTOM_HOME` defaults to `~/.local/share/opencode-custom-v2`. Run the `custom:*`
commands with the Bun named by the root `packageManager` (currently 1.4.4): the release embeds
the Bun that runs preparation, the upstream build scripts refuse an older one, and preparation
stops before building when `bun --version` does not satisfy it. The first `bun` on the server's
`PATH` is the runtime's private `<runtime>/bin/bun`, so agent-run updates use that one. Preparation
uses `git archive HEAD`, installs frozen dependencies in the snapshot, typechecks
CLI/TUI, the upstream web app (`packages/app`) and plugin-app-custom, builds the plugin and
compiles the CLI with upstream's embedded web app, unchanged. CLI `--version` and `--help`
are checked with isolated XDG directories. Before publication, `custom-parser-smoke.ts` checks
the compiled binary's rejection of an inherited `--server` on unsupported commands, version
actions triggered by `--version=false` / `--no-version`, `--` operand handling, and help actions.
It also inspects help for the local/API routes and their ancestors, rejecting local flags or aliases
named `--help`, `-h`, `--version`, or `-v` that could shadow the global actions.
The harmless `debug paths home` handler is the execution sentinel. A changed parser contract
fails preparation rather than silently changing launcher safety. No server is started during prepare.

Each `releases/<sha>` contains:

- `OpenCode Custom.app`: signed bundle (`local.opencode.custom`) holding the compiled CLI/TUI
  with version `0.0.0-custom.<sha>`;
- `bin/opencode`: relative symlink to the bundle executable, used by launchers and hashed
  through the link;
- `plugin/index.js`: standalone custom plugin bundle, with Standard Schema RPC codec boundaries;
- `serve-sim/node_modules/`: Expo's `@expo/serve-sim` (with the repository's patch that stops it from opening a
  Device Hub window per simulator) and its `ws` dependency, copied from the plugin's installed dependencies on
  Apple silicon, which the resources hub runs to stream and drive iOS simulators
  (see `docs/resources-ios-simulator.md`). It is read-only like the rest of the release but outside the
  hashed artifacts;
- `server-config.json`: update disabled and the absolute release-owned plugin path;
- `manual-release.json`: format 2, commit, version, platform, architecture and SHA-256 artifact hashes.

Published directories are read-only and are never rebuilt in place.
The release config is loaded after discovered global, explicit, and project documents. User
plugins and MCP servers remain available, while the release-owned update policy wins if an
earlier document uses the same key. The release config defines no MCP servers, so removing one
from the user config removes it from the server. It does not edit `~/.config/opencode`.

MCP services are Location-scoped and connect eagerly, so each materialized Location retains one
process per local MCP server, for example `safaridriver --mcp` (about 3 MB) and
`codex-computer-use-mcp` (about 65 MB of Node). `LocationActivity` evicts a Location, stopping
those processes, after 60 minutes without session events and no active execution; the server log
records `location services evicted`. The `custom.worktrees` RPCs run in the server default
Location, so clients can resolve worktree roots and branch labels (`locate`), list a project's
worktree branches (`branches`) and confirm that a directory still exists before syncing its
catalogs (`available`) without booting each Location. The iOS and Mac apps use these three.
`check` is a read-only Git drift check that refreshes through the official `worktree.refresh`
endpoint only for missing directories, newly discovered directories, or linked worktrees whose
stored rows are still unowned; only core writes the inventory. When integrating upstream,
reconcile it with `Worktree.refresh`, its insert/conflict ownership rules, and the built-in Git
strategy; the custom plugin currently registers no worktree strategies.
Location keys compare directory strings exactly, so case variants of one directory on
the case-insensitive macOS filesystem (`~/Dev/x` and `~/dev/x`) become separate Locations with
duplicate processes. Initialization and tool discovery do not create Safari's automation window or consume its one
active WebDriver session. Once automation starts, Safari still permits only one active session
across Locations; a concurrent Location must report the conflict rather than fall back to the
user's ordinary Safari. The `@Safari DevTools` prompt context carries that instruction.
Staging remains writable until its atomic rename; read-only permissions are applied
at the published destination before selecting `prepared`. If preparation is interrupted
after rename, the next run verifies the existing hashes, normalizes permissions and
verifies again before selecting it. Corrupt artifacts are rejected without resealing.
Failed build directories are not reused or moved by subsequent preparations.

Source and installed
dependencies exist only under `builds/prepare-*` while building and are removed after
successful publication. Neither source nor node_modules ships in a release. Artifact
hashes are verified before activation and reuse. Failed build directories are retained
for diagnosis and can be removed manually. The binary serves its embedded web app
(upstream's `packages/app`) with `opencode serve`; there is no production source server or second Bun executable.
Its compiled version is the health version; no environment variable substitutes a commit.

### macOS privacy permissions

macOS attributes privacy grants such as Accessibility or Screen Recording, requested by child
tools like Computer Use MCP servers, to the launchd-owned server. Unbundled executables are
identified by path and ad-hoc signatures by cdhash, so each release previously appeared as a
new `opencode` entry and asked again. Prepare now places the binary in `OpenCode Custom.app`
with the fixed bundle identifier `local.opencode.custom` and signs it with a persistent local
certificate, giving every release the same designated requirement:
`identifier "local.opencode.custom" and certificate leaf = H"<certificate sha1>"`.

The first prepare creates `signing/signing.keychain-db` (directory 0700, file 0600) with a
self-signed "OpenCode Custom Local Signing" certificate. The keychain is not added to the
user search list; prepare unlocks it with an empty password and passes it to `codesign`
explicitly, so updates never show Keychain prompts. Keep this directory: deleting it creates a
new certificate and macOS asks for the grants once more. Releases prepared before this
change keep their old identity; rolling back to one asks again.

#### Granting permissions once

A background server whose identity lacks a grant often gets no prompt: Computer Use fails with
`bootstrapTimedOut` instead. This happened on every release before the stable identity; audit
records in `~/.direct-computer-use/audit/direct-computer-use.jsonl` show the first
`official_error` right after the activation that changed the identity. To grant the identity:

1. In System Settings → Privacy & Security, add
   `~/.local/share/opencode-custom-v2/current/OpenCode Custom.app` with **+** (use ⌘⇧G for the
   hidden path) or by dragging it from Finder, and enable it in:
   - Accessibility (listed as "Controle do Dispositivo e Acesso a Dados" in pt-BR);
   - Screen & System Audio Recording;
   - App Management, when requested.
2. Remove the obsolete `opencode` entries with the `exec` icon; they belong to old cdhashes.
3. Restart the server once so the running process picks up the grants, for example from a
   detached `tmux` session when it hosts the current conversation:
   `launchctl kickstart -k gui/$(id -u)/local.opencode.custom-manual`. This is the only
   lifecycle action outside `custom:*`; it keeps the current release and does not change pointers.
4. Verify with the Computer Use `list_apps` and `get_app_state` tools (the latter needs Screen
   Recording for its screenshot).

To tell a missing grant from a Computer Use regression, run the official client
(`~/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient mcp`)
from Terminal.app. It gets past bootstrap and reports `Sender process is not authenticated`,
because only an OpenAI-signed Codex parent is accepted. `bootstrapTimedOut` only from the
server context points to the server identity's grants.

#### Calendar, Reminders and Contacts

The server holds no Calendar, Reminders or Contacts grant. The `mac_query` tool
(`packages/plugin-app-custom/src/mac-data`), available to every agent, asks the OpenCode app on the Mac
(`packages/ios-custom`, target `OpenCodeMac`), which reads them under its own grants and answers through the
`custom.mac` RPC, the same way the iPhone answers `iphone_query` (see
`packages/plugin-app-custom/docs/mac-data.md`). The app must be open; otherwise the tool fails at once with
`offline`.

Releases up to `a012b361ad` nested a Swift helper, `OpenCode Mac Data.app`, in
`OpenCode Custom.app/Contents/Helpers`. Although it disclaimed responsibility, `tccd` attributed its requests to
the enclosing bundle (`AUTHREQ_SUBJECT: subject=local.opencode.custom`) and refused to prompt, because
`OpenCode Custom.app` has no usage descriptions (`usage description: (null)` … `Refusing authorization request`).
The grant shown under "OpenCode Mac Data" in System Settings therefore never applied; remove it there or with
`tccutil reset Calendar local.opencode.custom.macdata` (likewise `Reminders` and `AddressBook`).

Manual retention is explicit:

```sh
bun run custom:prune --dry-run --keep=3
bun run custom:prune --keep=3
```

Pruning protects current/previous/prepared, the responding server version and the newest
N manifests. It only prunes verified compact releases. It never runs during activation.

`prepared`, `current` and `previous` are atomic symlinks. A `.manual-lock` directory
serializes mutating manual commands; after a killed command, remove a stale lock only
after confirming that no manual operation is running. `--dry-run` writes nothing,
does not build and never changes launchd; migration may read `launchctl print` to
validate the incumbent. A prepare/update dry-run still requires a
clean `custom` checkout. Status performs only authenticated health reads and reports
prepared/current/previous commits plus the live server version; it never prints the password.

### Activation and persistence

Existing `password`, database and configuration are required. Optional
`<runtime>/manual.json` selects existing paths and service environment:

```json
{
  "port": 4178,
  "database": "/Users/you/.local/share/opencode-custom-v2/data/opencode/custom.db",
  "config": "/Users/you/.local/share/opencode-custom-v2/config/opencode",
  "environment": {
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  }
}
```

The defaults for a separately initialized runtime are port **4178**,
`<runtime>/data/opencode/custom.db` and `<runtime>/config/opencode`. Migration instead
copies the actual paths and environment from `environment.sh`. In the current installation
these are `~/.local/share/opencode/opencode.db` and `~/.config/opencode`.
The server launcher preserves explicit XDG roots, falling back to runtime-specific roots for
separately initialized runtimes. Identity/path variables override `environment`. Protect this file
if it contains credentials. Both generated launchers, `bin/serve` and `bin/opencode2`, also contain
these environment values and are private (mode 0700). Never configure
a second global or project-local copy of the custom plugin; every Location loads the
release-owned plugin build through normal plugin configuration.

For the primary installation, set `environment.XDG_CONFIG_HOME` in `manual.json` to the user's
normal config root (`/Users/you/.config`). `OPENCODE_CONFIG_DIR` selects OpenCode configuration;
it does not override XDG for child tools such as `gh`, Homebrew, Stripe, or SwiftPM. Without this
explicit setting, those tools inherit `<runtime>/config` and may use a different login/configuration
from the user's terminal. Check their existing logins before changing it. This setting takes effect
on the next activation that actually starts the service, for example when selecting a different
release. Selecting an already healthy current release returns without rewriting either launcher
or restarting the service, so that no-op does not apply changes to `manual.json`.
Editing the file does not change the running server's environment. Keep `<runtime>/config`:
the 4096 proxy reads `<runtime>/config/opencode/service-custom.json` by its fixed path, independent
of XDG. The default remains isolated for development/test runtimes.

Routine `custom:update` skips the database backup and does not require `sqlite3`.
It still requires the existing database and password and verifies the authenticated
health response and exact running version after activation.

Explicit `custom:activate`, rollback and one-time migration retain the backup step.
Activation controls only `local.opencode.custom-manual`. It first seeds or verifies the
managed-service password (see "Managed-service mode under launchd"), then unloads that job, waits
up to 65 seconds for launchd registration removal and the previous PID to exit, then
up to 65 port checks for the port to close, takes a consistent SQLite `.backup` using the system `sqlite3`
and checks it with `PRAGMA quick_check`. Missing database, password or sqlite3 aborts
the operation. Backups live under `backups/<timestamp>-<uuid>/database.sqlite` with an
`activation.json` identifying the previous/target release and database path. These
are database backups, not backups of config, credentials, external files or services.

The job plist sets `ProcessType` to `Interactive`. Without it, launchd applies light CPU and
I/O throttling to agents, which makes the server lose scheduling priority under load.

Then activation writes runtime-owned launchers and the job plist, switches `current`, bootstraps the
job and waits up to 90 checks for **authenticated HTTP 200 with the exact target
version**. Before declaring success, the responding PID must match the PID reported by
`launchctl print` for the runtime-owned job. This check also applies to the already-active
shortcut: another process running the same binary/version is not proof of successful activation.
A missing or different PID fails verification; cleanup only unloads the owned job, never the
other listener. It preserves the password, database and config paths. This is an explicit
service interruption; schedule it between active work where possible. Existing TUI
processes keep their already-loaded version: reopen them with `opencode2` afterward.

Bootstrap reconciles an already registered, runtime-owned job through the same health
check. An explicit `Operation already in progress` response may be retried at most
three times for the same release, with registration queried before every attempt.
Generic input/output error 5 alone is not treated as transient. Query permission/domain
errors abort rather than masquerading as a missing job. Ownership is checked on every
successful query; an unexpected owner is never unloaded.

Manual operations retain private timestamped JSON results under
`<runtime>/logs/operations/`, including phases, times, outcome and original failure.
These remain after subsequent recovery. The detached skill runner additionally prints
a unique `$TMPDIR/opencode/opencode-custom-update.*/` directory containing `output.log`
and `result.txt`, including pull/build failures. Inspect those files after tmux closes;
successful activation and completion-notification delivery have separate outcomes.
Progress and result writes are best-effort: a write failure emits a diagnostic on
stderr but never interrupts activation or triggers service cleanup. If storage is
unavailable, the JSON result may be absent or stale; consult the command output.

If startup fails, the attempted service is unloaded, `current` remains on the failed
release, and `previous` plus any backup created are retained. There is deliberately **no
automatic downgrade**: startup may already have migrated the database. Inspect
`<runtime>/logs/server.log`, fix forward, or review the migrations before rollback:

```sh
bun run custom:rollback --database-compatible
# or choose a specific retained release:
bun run custom:rollback <full-sha> --database-compatible
```

`--database-compatible` is the operator's assertion, not an automatic schema
compatibility proof. Rollback backs up the current database and reuses it; it never
silently restores an old snapshot. If a previous schema is required, stop all writers,
retain the current database **and its WAL/SHM sidecars**, restore the selected consistent
backup at the configured database path without stale WAL/SHM files, then run the
explicit rollback. Restoring a snapshot discards later writes. A failure before the
pointer switch leaves the old pointer intact, possibly with the service stopped;
correct the reported problem and rerun activation.

### 4096 proxy and session resources hub

The loopback proxy on 4096 (`com.alexandrem.opencode2-ui`, Homebrew Node, `<runtime>/bin/proxy.mjs`) is the
entry point of the Cloudflare One route (`10.203.96.2:80` → nginx → 4096) and of local browsers. Its source is
`packages/cli/script/custom-proxy.mjs`. It injects the server credentials for every route except `/resources/*`,
which it forwards, without any `authorization` header, to the session resources hub on `127.0.0.1:4179`
(WebSocket upgrades included); the hub authorizes each request with its own short tickets
(`packages/plugin-app-custom/docs/resources.md`).

After a successful activation (`custom:activate`, `custom:update`, rollback), activation installs that file as
`<runtime>/bin/proxy.mjs` and restarts the proxy job with `launchctl kickstart -k`, but only when the installed job
runs this runtime's `bin/proxy.mjs` and the content changed; other runtimes and unchanged proxies are left alone.
A proxy failure is reported after the server is already healthy and does not undo the activation. The
already-active shortcut does not touch the proxy.

The server launcher exports `OPENCODE_RESOURCES_HUB_PORT=4179` (override it in `manual.json` `environment` only
together with the proxy). The custom plugin starts the hub on demand as a separate process of the release binary
(`BUN_BE_BUN=1 opencode plugin/index.js --opencode-resources-hub`), with the server as its parent: it exits with the
server, and a hub crash never takes the server down. Its state lives in `$XDG_STATE_HOME/opencode/resources-hub`
(`hub.json` with its secret, `resources.json`, `hub.log`). Sandboxes leave the port unset, so their hub binds a free
loopback port and clients on the Mac connect to it directly.

The hub can also run on its own, with no server as its parent (the Mac LaunchAgent that serves the Linux runtime,
below): `OPENCODE_RESOURCES_HUB_STATE=<dir> OPENCODE_RESOURCES_HUB_PORT=4179 bun <release>/plugin/index.js
--opencode-resources-hub`. Without `OPENCODE_RESOURCES_HUB_PARENT` it only exits on `SIGTERM`. Besides `hub.json`
it writes `<dir>/playwright-cli.json` (adds `--remote-debugging-port=0`), the file Mac shells must point
`PLAYWRIGHT_MCP_CONFIG` to so the hub can mirror `playwright-cli` browsers.

### One-time migration from the old installation

Preparation is safe while the old service runs. Run the explicit migration in a
maintenance window after reviewing its dry-run:

```sh
bun run custom:migrate --dry-run
bun run custom:migrate --replace-launcher --stop-beta
```

It validates the legacy label, plist and loaded command against the known runtime's
`bin/serve.sh`; parses the generated `environment.sh` without executing shell code;
uses its actual `OPENCODE_DB`/`OPENCODE_CONFIG_DIR`; reads the existing credential from
`config/opencode/service-custom.json`; and creates `password`/`manual.json` with mode 0600.
It retires the known old LaunchAgent, preserves its plist and legacy pointer, activates
the prepared release, and installs the stable launcher and login plist links. Existing
launcher files are preserved in unique `.pre-custom-*` backups before atomic replacement.
The 4096 proxy is untouched.
The optional beta stop only accepts the exact `~/.opencode/bin/opencode2 serve --service`
process listening on 4097; any unknown listener aborts migration. A retry reuses the
same persistence and password and does not restart an already healthy target release.

#### Managed-service mode under launchd

`bin/serve` runs `serve --service` in the foreground, and launchd supervises it: the job starts it at
login and restarts it when it exits. Only service mode starts upstream's scheduled-task loop and its
restart continuity, which resumes Sessions, subagents and background jobs interrupted by a restart or
crash. Plain `serve` starts neither: a schedule created there is stored but never fires. Enable
`/schedule` with `"experimental": { "schedules": true }` in the user config once a release with this
launcher is active.

In service mode the server:

- answers with the `password` of the managed-service config, `$OPENCODE_CONFIG_DIR/service-custom.json`,
  and ignores `OPENCODE_PASSWORD`; when the key is missing it generates and saves a new one. Activation
  therefore seeds the key from `<runtime>/password` when it is missing and aborts, before stopping
  anything, when it differs. The launchers and the healthcheck read `<runtime>/password` and the 4096
  proxy `<runtime>/config/opencode/service-custom.json`; keep the three equal;
- takes `hostname` and `port` from the launcher flags. `cors`, `env` and `remote` in that config file
  still apply, so leave them unset: `remote` would open upstream's public remote-access tunnel;
- registers itself in `$XDG_STATE_HOME/opencode/service-custom.json` and rechecks that file every
  5 seconds. If it is deleted or replaced, the server shuts down and launchd restarts it. A stale
  registration left by a crash does not block the next start, and a graceful stop removes it;
- changes its working directory to the home directory.

The launcher keeps rejecting `serve` and the mutating `service` commands, so no other process of the
custom channel contends for the port or replaces the registration.

Releases activated before this change ran plain `serve`, which kept the server out of the
managed-service registration and election of the beta service that then shared the configuration
directory on 4097. Migration stops that service.

Plain `serve` also never reconciled restart recovery: each restart left the interrupted executions
claimed (`session_v2.time_suspended`) and their background jobs listed (`job.background/*` in `kv`).
On 2026-10-30 that was 161 job entries since 2026-09-14, including 14 running subagents, and two
claimed archived Sessions. The first managed-service boot would resume all of them and wake their
parents. Activation therefore discards those markers, in one transaction and before stopping
anything, whenever the installed `bin/serve` does not yet run `serve --service`; from then on restart
continuity owns them. Executions interrupted by that one switching restart are not resumed, as before.

The stable launcher resolves `current` once and disables automatic CLI updates. For the TUI,
`run`, `mini`, `api`, `models`, `stats`, `reload`, and the supported `auth`/`session` subcommands,
it reads the existing password into `OPENCODE_PASSWORD` and injects `--server` with the configured
runtime URL (normally `http://127.0.0.1:4178`). It inserts the flag immediately after the command
path, before operands or `--`, preserving the working directory and argument boundaries.
For example, `opencode run -- service` sends the word `service`; it is not a lifecycle request.
Known global flags such as `--print-logs` and `--log-level debug` can precede command names.

The launcher provides read-only service adapters without native service discovery:

- `service status`: authenticated health check; prints the configured URL when ready, otherwise
  `stopped`. Both states exit successfully, matching the native status command. Credentials go to
  curl through stdin, not its command arguments. No service is started.
- `service get password`: prints the existing runtime password; never generates one.
- `service get port` / `service get hostname`: prints the configured port / `127.0.0.1`.
- `service get`: prints hostname and port as JSON, omitting the password and environment.

These adapters support `bun run dev:live` and `bun run dev:vite:live`. launchd, not native service
discovery, starts and supervises the server; the adapters do not read its registration.

`mcp add`, `plugin add`, `plugin remove`, and `debug paths` use only local configuration/files and
pass through without `--server`, using the runtime's configured environment and persistence paths.
`mcp add example -- command args` retains the native `--` behavior. Commands whose native handlers
would discover/start a server are rejected with a specific alternative:

| Native command            | Custom-server alternative                                                                          |
| ------------------------- | -------------------------------------------------------------------------------------------------- |
| `mcp list`                | `opencode api mcp.list --param "location[directory]=$PWD"`                                         |
| `mcp auth` / `mcp logout` | `/mcps` in the TUI or `opencode auth login` / `opencode auth logout`                               |
| `plugin list`             | `opencode api plugin.list --param "location[directory]=$PWD"` (server plugins)                     |
| `plugin check`            | `opencode api plugin.check --param "location[directory]=$PWD" --data '{}'`                         |
| `plugin update`           | `opencode api plugin.update --param "location[directory]=$PWD" --data '{"targets":["<package>"]}'` |
| `debug agents`            | `opencode api agent.list --param "location[directory]=$PWD"`                                       |
| `debug config`            | `opencode api config.get --param "location[directory]=$PWD"`                                       |
| `pair`                    | `opencode api server.pair`, then open `/auth/connect/<code>` on the custom server                  |

`--help` or `-h` before `--` passes through to native help without a server flag only for the
audited local/API routes, including `mcp list --help` and `pair --help`. Normal client commands
such as `run` retain their explicit server flag on help requests. Lifecycle commands, including
`serve`, `upgrade`/`update`, `uninstall`, mutating `service` commands and `acp`, remain blocked
even with help. The compiled-binary parser smoke verifies global action handling and rejects
shadowing local help/version aliases on the pass-through routes. It requests help before the
command path so that inspecting a newly shadowing alias does not execute that command.
Server/password/standalone overrides remain blocked even on help requests. A literal `--help`
after `--` remains an operand.

Use `custom:*` for lifecycle. The launcher rejects top-level `serve`, `upgrade`/`update`,
`uninstall`, and `service start/stop/restart/set/unset`. It also rejects `acp`, which creates a
private server. User-supplied `--standalone*`, `--server*`, and `--password*` are rejected anywhere,
including after `--`. Native wizard mode is unavailable because it can generate and execute a
different command without passing through the launcher again. Ordinary prompt words such as
`update`, `service`, and `serve` are not blocked. As in the native CLI, use `./service` for a
project named `service`. For non-default runtimes, adjust the paths above consistently.

Migration installs `~/.opencode/bin/opencode2`; an existing `opencode` alias/symlink to it continues
to resolve the updated launcher. Migration and activation do not create that extra alias.

The retired periodic updater, maintenance API, admission barrier, controller and
updater LaunchAgent are not part of this flow. Nothing polls Git or schedules updates.

### Linux runtime (systemd)

The same `custom:prepare|update|activate|rollback|status|prune` commands run on Linux (the
OrbStack machine `dev`, Ubuntu arm64; setup in `core-infra/opencode-mac`). Differences:

- The release is the plain `bin/opencode` executable for the host (`cli-linux-arm64`, glibc), with no
  `OpenCode Custom.app` or signing. It still carries `serve-sim/` (Mach-O files, never run on Linux) for the Mac's
  hub.
- The service is the systemd **user** unit `~/.config/systemd/user/local.opencode.custom-manual.service`
  (first line `# Runtime <home>`, which owns it), started with the login environment (`/etc/profile`),
  `Restart=always`, log in `<home>/logs/server.log`. It needs lingering (`loginctl enable-linger`).
  Inspect with `systemctl --user status local.opencode.custom-manual`.
- `KillMode=process`: a stop signals only the server, as launchd does on the Mac. Everything agents start from their
  shells lives in the unit's cgroup (`custom:update` itself, tmux sessions, `nohup`/`setsid` processes, `mac` clients,
  whose death ends their process on the Mac); with `mixed` or `control-group` the stop of an activation would kill
  them, leaving the server stopped and `.manual-lock` behind. systemd logs "left-over process" for them at the next
  start; that is expected. A stop first rewrites an outdated unit and runs `daemon-reload`, so the new `KillMode`
  already applies to the stop that replaces an older unit.
- The 4096 proxy stays on the Mac and reaches the server through OrbStack, which forwards the machine's
  `127.0.0.1:4178` to the Mac's loopback; its `/resources/*` go to the Mac's hub on `127.0.0.1:4179` (below), not to
  Linux. After a successful activation, `installMacProxy` does what `installProxy` does on macOS through the mounted
  `/Users`: only when `~/Library/LaunchAgents/com.alexandrem.opencode2-ui.plist` exists and its `ProgramArguments`
  (read with `mac plutil`) run the Mac runtime's `~/.local/share/opencode-custom-v2/bin/proxy.mjs`, and only when the
  content changed, it replaces that file and restarts the job with
  `mac launchctl kickstart -k gui/$(mac id -u)/com.alexandrem.opencode2-ui`. A failure is reported without undoing the
  activation.
- `custom:migrate` is macOS-only. Moving the runtime from the Mac: `core-infra/opencode-mac/opencode-migrate.sh`.

#### Resources hub on the Mac

Simulators, emulators and Chrome stay on the Mac, so the hub does too, as the LaunchAgent
`local.opencode.resources-hub` (no parent, always running), and the Linux plugin runs in remote mode
(`packages/plugin-app-custom/docs/resources.md`, "Remote hub"). Layout on the Mac, under
`~/.local/share/opencode-resources-hub`: `releases/<commit>/{plugin,serve-sim}`, `current` (symlink), `state/`
(`hub.json`, `resources.json`, `playwright-cli.json`) and `hub.log`.

- **LaunchAgent.** `bun run custom:hub-plist` (or `resourcesHubPlist(macHome)` in `custom-release.ts`) prints it:
  the Mac's `~/.local/share/opencode-custom-v2/bin/bun` runs `current/plugin/index.js --opencode-resources-hub`
  with `OPENCODE_RESOURCES_HUB_STATE=<hub>/state`, `OPENCODE_RESOURCES_HUB_PORT=4179`,
  `OPENCODE_SERVE_SIM=<hub>/current/serve-sim/…/serve-sim.js` and a Homebrew `PATH`; `RunAtLoad`, `KeepAlive`, log in
  `<hub>/hub.log`. `core-infra/opencode-mac` installs it in `~/Library/LaunchAgents` (create `<hub>` first: launchd
  does not create the log's directory).
- **Publication.** After a successful Linux activation, if that plist exists (read through the mounted `/Users`),
  activation copies the release's `plugin/` and `serve-sim/` to `<hub>/releases/<commit>`, points `current` at it
  atomically, restarts the job with `mac launchctl kickstart -k gui/$(mac id -u)/local.opencode.resources-hub` and
  keeps the three newest other copies. A failure is reported without undoing the activation; the already-active
  shortcut does not publish.
- **Server environment** (`manual.json` `environment` on Linux):
  `OPENCODE_RESOURCES_HUB_REMOTE_INFO=/Users/<user>/.local/share/opencode-resources-hub/state/hub.json`,
  `OPENCODE_RESOURCES_HUB_REMOTE_HOST=host.orb.internal`,
  `OPENCODE_RESOURCES_HUB_PATH_MAP=/home/<user>/=/Users/<user>/OrbStack/dev/home/<user>/`.
- **Mac shells.** `mac` does not pass Linux variables, so `~/.zshenv` on the Mac exports
  `PLAYWRIGHT_MCP_CONFIG=~/.local/share/opencode-resources-hub/state/playwright-cli.json` for
  `mac playwright-cli …`.

### Isolated source development

Compact artifact verification is available from `packages/cli`:

```sh
bun script/custom-smoke.ts /absolute/path/to/compiled/custom/opencode
```

It bundles the real plugin, seals/verifies the four-file release, asserts the release-owned
Safari MCP command, starts only a temporary server with a fresh database and random port, checks matching CLI/server versions,
embedded web, plugin RPC save/list and invalid-input rejection, then stops its own process.
The measured macOS arm64 fixture was **184,056,606 bytes (175.53 MiB)**, including the
201.64 KB plugin. Builds from a dirty development checkout are fixture evidence only;
production preparation always archives the committed SHA.

For a reusable isolated instance from the current worktree, run from the repository root:

```sh
bun packages/cli/script/custom-sandbox.ts up
bun packages/cli/script/custom-sandbox.ts status
bun packages/cli/script/custom-sandbox.ts down
```

The default is `http://127.0.0.1:4177`, tmux session `custom-sandbox-4177`, and
`<os.tmpdir()>/opencode/custom-sandbox-4177` (canonicalized on macOS). Override with
`--port` and `--home`; ports 4096 and 4178 are always refused. The sandbox's watch gateway listens on
`--watch-port` (default `0`, any free port, logged as `Watch gateway listening`); 4192, production's, is refused. Dependencies must already
be installed. `up` builds the plugin and upstream's web app (`packages/app`), removes `dist/sw.js`
so the sandbox origin installs no service worker (upstream always registers `/sw.js` in production
builds, so the console reports the failed registration), starts `custom-server.ts`, and waits for authenticated `/api/info`. An already
healthy owned sandbox is left untouched; use `down` then `up` to rebuild changed source.

The sandbox loads the plugin's `tsc` output (`packages/plugin-app-custom/dist`), unlike the release,
which bundles `src` with Bun through `custom-plugin.ts` and embeds text imports. The package `build`
therefore copies every non-TypeScript file under `src` beside the compiled modules
(`script/copy-assets.ts`): `voice/voice.md`, imported `with { type: "text" }`, is the only one today,
and new ones are covered without listing them. The sandbox keeps loading `dist` rather than a bundle
because the resources hub then runs `hub/bin.js` and resolves `@expo/serve-sim` from the plugin's own
dependencies; a bundle outside the release layout would need a copied serve-sim.

A server whose plugin fails to load stays healthy with no custom RPC, tool or route. `up` therefore
also waits up to 60 s for `custom.preferences/get` to answer, also on an already healthy sandbox.
When the plugin is listed as failed or never answers, it stops the sandbox and exits with an error
pointing to `failed to load plugin` in the private `server.log`, so no test runs against a sandbox
without the custom functions.

The script discovers configuration/database paths through the installed `manual.json`,
loads `environment.sh` privately, copies configuration without backups or service credentials,
and redirects config, database, data, state and cache to the sandbox. Its first startup runs
the real migrations; while that sandbox is stopped, a read-only SQLite attachment copies
**only `credential`**, in one transaction. No production history is copied. Existing sandbox
credentials are not overwritten on subsequent startups. The home is private (0700), and
configuration, environment and password files are 0600. The script prints the password
**path**, never its contents. It stops only the tmux session carrying its ownership token.

Copying files is not proof of working integrations: verify the custom RPCs, models and quota
response against the sandbox before handing it over. Logs and `environment.json` can contain
private information and must remain outside Git. Never reuse production persistence or stop
the production backend/proxy. The underlying `custom-server.ts` remains available for smoke
supervisors; `OPENCODE_CUSTOM_LAUNCHD=1` keeps it running without stdin. It uses the same
release config generator as production, but is not a production release.

## Web app

The custom clients are the native iOS and Mac apps (`packages/ios-custom`). The release embeds
upstream's web app (`packages/app`) unchanged, so the browser at `http://127.0.0.1:4096` and
`https://mac.alexandrem.com.br` shows the standard OpenCode web UI against the custom backend. It is
kept for occasional browser access and has none of the custom client features (archive, snippets,
chat quotes, Sessão mestra, LLM proxy panels, custom themes and so on); those live in the native apps.

The custom web app (`packages/app-custom`, `packages/ui-custom`, `packages/session-ui-custom`) was
removed on 2026-10-29. It remains in Git history at the tag `web-custom-final`, which the native apps'
documentation cites as their former behavior reference. A browser that used the custom web app keeps
its service worker and local storage for that origin until upstream's service worker replaces it; if
the first visit after the switch looks stale or broken, clear the site data for that origin only.

## Lean transcript

Tool results keep their media inline: every `read` of an image stores the whole file as a base64
`data:` URI in the assistant message, because the model replays it from history. A session that read
410 large PNGs reached 1.16 GB of messages, so a client reading the plain endpoint downloads payloads
that no transcript view displays.

The custom plugin exposes `custom.transcript/list`, the same page as
`GET /api/session/:sessionID/message` (same cursors, limits and order) with every inline tool-result
payload emptied to `data:<mime>;base64,`. Stored messages, model history, export, the TUI and the
standard web app still receive the originals. User attachments keep their inline data for thumbnails.
A server without the plugin, or any failed RPC read, should fall back to the endpoint, which also
reports its canonical errors (missing session, invalid cursor).

`custom.transcript/skills` returns only `{ id, name }` for the skills a session loaded, deduplicated
in first-load order: direct activations (`skill` messages), skills attached to prompts and completed
`skill` tool calls. The plugin pages the type-filtered messages in-process, so the iOS details sheet
never downloads a transcript to find them. A server without this method shows the section as
unavailable.

Measured on the isolated 4177 runtime with a synthetic 32-message session holding 90 image reads
(325 MB stored): the endpoint served 214.6 MB for 20 messages while the RPC served 41 KB.

## Prompt snippets

`custom.snippets` stores reusable text with a name, description, comma-separated search aliases, and
content in the OpenCode server database, globally or scoped to a project. All clients of a server share
the same catalog and receive live updates. Project snippets override global snippets with the same name.
Snippets do not require server config files.

## Project directories

`custom.directories` creates only the final folder of a path, so a missing parent fails instead of
creating a tree, and reports the server home directory, which V2 sync does not publish. The native
apps' project explorer uses it for **Criar e adicionar**.

## Session references

The `tools.sessions.read` tool (formerly `opencode.session_read`; see
`packages/plugin-app-custom/docs/sessions.md`) retrieves another session's text on demand in newest-first pages:
20 messages by default, up to 50, with a 20,000-character message-text budget. Tool payloads and
reasoning are omitted; truncated messages are marked.

## LLM proxy subscriptions

Set `OPENCODE_LLM_PROXY_URL` on the backend to the internal proxy base URL. The `custom.subscriptions`
RPC reads `/_admin/status` server-side and returns only quota metadata: weekly percentages as remaining
quota, and dates as quota resets, not subscription or OAuth expirations. Missing or stale usage is marked
explicitly. It also reads the separate Anthropic pool from `/_admin/anthropic/status`, normalizing
`*_max_20x`/`*_max_5x` tiers to Max 20x/Max 5x and counting banked resets from unpaused Anthropic
grants. A 404 or 503 means the proxy has no enabled Anthropic pool, so the pool is omitted instead of
reported as a failure. The two pools are never combined, matching the proxy's lack of cross-provider
failover.

## Codex web search

When `OPENCODE_LLM_PROXY_URL` is set on the backend (the same root URL used by the
subscriptions RPC), the custom plugin registers **Codex Search** with provider ID
`codex`. It uses `POST /backend-api/codex/alpha/search` through the proxy, not a Codex
CLI subprocess. No provider or default is added when the URL is unset.

Select it through the existing web search provider picker, or add this to the
existing `opencode.json` configuration after installing a release containing the plugin:

```json
{
  "websearch": { "provider": "codex" }
}
```

The registration does not override an existing provider choice or disabled web search.
All conversation models can use it. Each search sends only its query, a fresh request
ID, and live-web access settings; no conversation history, account credentials, or
encrypted search output is exposed. The request model defaults to `gpt-6-astra` and
can be changed with `OPENCODE_CODEX_SEARCH_MODEL`, independently of the conversation model.

The adapter preserves the complete text/citations once and includes source URLs from
both structured results and Codex's text-only source headers. It rejects malformed
responses and content without usable sources instead of reporting them as empty results.
HTTP failures retain their status and `Retry-After` for native rate-limit handling;
the adapter does not retry or silently switch providers. Requests time out after 30
seconds, and cancelling the tool aborts HTTP work.

This is an internal Codex endpoint, not a stable public API. `open`, `click`, and
`find` are not exposed here: retaining account-scoped references across proxy calls
would need a separate integration. No proxy-side account-affinity or retry policy is changed.

## Native app themes

The iOS and Mac themes are generated from the theme JSON files in `packages/ios-custom/script/theme/themes`,
including **OpenChamber** (warm ink neutrals, orange accent, Vitesse-style syntax, teal links, green inline
code and a tinted user-message bubble). Run `bun packages/ios-custom/script/generate-themes.ts`; the resolver
in `packages/ios-custom/script/theme` came from the former custom web UI. Two optional pairs of theme
variables apply to every theme that defines them: `v2-user-message-background`/`v2-user-message-text` (user
bubble) and `v2-inline-code-background`/`v2-inline-code-text` (Markdown inline code and paths, which otherwise
follow `syntax-string`).

## Model preferences

Favorite models, provider order and the default model with its thinking level live in the server-side
preferences profile (`plugin-app-custom` `custom.preferences`), so every client of the server shares them.
The default applies to new sessions only and never changes existing sessions, the TUI or the config file.
