# Bancada — device test bench, contract v1

The Bancada runs a project's device tests (Android emulator, iOS simulator, tests without devices) on whichever of the
owner's machines can run them, prepares and gives back the devices, and puts the result in the session that asked, as
one message. One process per machine (`src/bancada/daemon/`) owns that machine's devices and executions; the hub's
also keeps the queue of every machine. `custom.bancada` is how tools, apps and other servers reach it; every handler
only relays to this machine's process.

It is on only with `OPENCODE_BANCADA=1` (the installed servers' launchers set it); off, every call answers
`unavailable { reason: "off" }` and nothing starts.

## For agents

Tools (`src/bancada/tools.ts`): `bancada_run` (the tests named in the repository's `.bancada.toml`; without `commit`,
the working tree as it is; in a subagent the call waits for the result, delivered once the call completed: a call
that fails after the wait leaves the notice to come as a message a minute later), `bancada_status`, `bancada_cancel`,
`bancada_hold` and `bancada_release` (a catalog phone, or room for an emulator or simulator the agent starts itself).
The hook on shell commands refuses what the repository reserves to the Bancada (`fora`), a catalog phone without the
family's hold, another family's device or a test's device, and asks for a slot when a command starts an emulator or a
simulator.

## Project contract

`.bancada.toml` at the repository root: `[teste.<name>]` with `precisa`, `aparelho`, `aparelhos`, `celular`, `build`,
`plan`, `run`, `args`; `caches`; `fora`. The commands get `BANCADA_JOB`, `BANCADA_TESTE`, `BANCADA_TENTATIVA`,
`BANCADA_COMMIT`, `BANCADA_OUT`, and the `run` gets `BANCADA_DEVICES` (the `devices.json`, one device per line) and,
on a new attempt, `BANCADA_APENAS`; every command gets `BANCADA_DOCKER_LABEL`, which what it starts in Docker carries
(the Bancada removes those containers, networks and volumes once the attempt's commands ended). The `run` writes `planned.json` before touching a device and `summary.json` at the
end; nothing is approved without both. The example project (`test/fixture/bancada-exemplo/`) is the reference: its
`run` proves each device arrived ready.

## Execution

Every attempt runs as a detached process of the machine, with the environment of the server's agents there (on the
Mac, the custom service's; on host-6, the server's own container `opencode_opencode-svc`: the `dotnet` wrapper with
GitHub Packages, `mycred`, the SDKs, the NuGet cache, the Docker socket, so `docker` is offered). Its folder lives in
the state folder (on host-6 in the `/workspace` volume): a redeploy kills the runner with the server, and back the
process finds the runner dead there (infrastructure: the part runs once more, on any machine).

## Devices

- **Mac** (`devices/android-local.ts`, `devices/ios.ts`): AVDs `<prefixo>a<api>-<tag>-<abi>-<perfil>-<n>` made with
  the SDK's `avdmanager`, booted detached from their clean snapshot (made on the first boot, after trimming), Wi-Fi
  off and the Mac reached by `eth0` at `10.0.2.2`, stopped after proving the serial runs that AVD. Simulators
  `<prefixo><modelo>-<n>`, booted trimmed by `simslim`, given back shut down and erased.
- **host-6** (`devices/android-docker.ts`, `[android.docker]`): each emulator in its own container (`<prefixo>emu-<n>`,
  KVM, the emulators' network, which the server's container is on too; Wi-Fi stays on, it is its only network, the
  device's `host` is the server container's address there and the device is delivered once it routes to it), given
  back with third-party packages
  uninstalled and kept running for `aquecido_min` (`[android.docker]`), for the next part, which gets it without
  booting; it counts in the budget, so the oldest stops first when what is reserved needs the room. Then the
  container is removed; the AVD volume stays.
- A part with a `plan` is accepted reserving its build and its minimum of devices (at least one), which start while it
  builds. Once `planned.json` says how many it can use (`aparelhos`, else one per scenario), it asks for the ones it
  lacks: the executor grants as many as fit in the budget then (memory, CPU, what the test takes beside each device,
  ceilings, ports; none with the brake closed), up to what the hub proposed for it, and the part goes on with what it
  got. Beyond what it can use goes back unstarted, so two scenarios never get four emulators. Without a plan, every
  device granted at admission starts. Each device, and a phone, takes its block of ports as it starts.
- Only devices of the `device` table, named with the machine's prefix, are ever stopped. A device dead, or mute for
  60 s, during a run fell: the scenarios it lost run again once elsewhere; two falls in a row put it 30 min aside.
  Emulators starting together get their console ports one at a time, each held in its row from the start, and one
  whose port answers another AVD after the boot is ended by its own pid. One that cannot be given back is set apart
  (`isolado`, its port still held, tried again every round): its attempt's reservation and folder go back meanwhile.
- **Code on another machine:** a working folder takes the commit from the machine's other folders of the project
  first (no transfer), and borrows from them what a bundle needs; a bundle that still does not apply is
  infrastructure, asked again whole. Code asked through the hub that does not come in 30 min ends its attempts with
  the reason (the part runs once more), instead of holding the machine.

## Phones

- **Catalog:** the machine file's `[[fisico]]`: `apelido`, `nome`, `id` (serial or UDID), `plataforma`, `transporte`
  (`usb` or `wifi`), `etiquetas`, `contas_reais`, `politica` (`negar`: nobody uses it, the hook refuses any command
  citing it), `reservado = { ate, para }` (kept for someone until then: its first hold never expires, no test gets
  it).
- **Connection** (`devices/physical.ts`, every 30 s and on each hold of the machine's own phones): by USB the id is
  the serial; by Wi-Fi the phone is whatever `ip:porta` answers its `ro.serialno`, reconnected through its
  `_adb-tls-connect` mDNS announcement when held and gone; an iPhone is its UDID in `xcrun devicectl list devices`.
  The serials go to the hub in the hello, so the hook on any machine knows a phone by its id, serial or `ip:porta`,
  also behind `mac`.
- **Tests:** a part with `precisa = ["android-fisico"]` (or `ios-fisico`) and `aparelho.etiquetas` goes to a machine
  with such a phone, takes it before anything else (a free, connected, reservable phone with the tags, not kept for
  someone) and none of the emulator budget; its `devices.json` has the phone (`serial`, `adb`, `contasReais`). A test
  that needs emulators (or simulators) and a phone asks for both: `precisa = ["android"]`, `aparelho`, `aparelhos` for
  the emulators and `celular = { etiquetas = [...] }`; the phone is taken first, the emulators come from the budget,
  and `devices.json` lists the emulators, then the phone. While the test runs no session's command may use it. The Bancada never clears, uninstalls, restarts, stops or sends
  anything on a phone; at the end only the hold ends.

## App surface

Two calls and two events, all optional for older apps. Normative fixtures in [`bancada/`](bancada/), produced by
`test/bancada-app.test.ts` from one simulated instant (`now` = `1795092060000`): `session-a1-b1.json`,
`queue-c2-d1-f3.json` (the hub) and `queue-local.json` (the Mac with the hub out).

### `custom.bancada/session { sessionID }`

Asked on the session's server, for the root or a subagent; the answer covers the family.

```ts
SessionResources {
  version: 1; now: number; hub: "ok" | "unavailable" | "incompatible" | "none"
  counts: { using: number; waiting: number }
  using: Using[]      // devices of tests first, then holds; the most recent use first
  waiting: Waiting[]  // the oldest first
  members: Member[]   // the root first, then by sessionID
}
Using {
  key: string
  kind: "android-emulator" | "ios-simulator" | "android-device" | "ios-device"
  kindLabel: string                    // "Emulador Android", "Simulador iOS", "Celular físico"
  name?: string                        // only a phone's or a slot's own name; a device the Bancada made has none
  resourceID?: string                  // equal to the resources hub's Resource.id
  machine: Server                      // { instanceID, name, short }
  viewer?: { instanceID: string; resourceID: string }
  by: By                               // { sessionID, title?, root, agent? } (title and agent read when asked)
  use: { type: "job"; job; teste; partLabel; state: "preparando" | "compilando" | "rodando"; since }
     | { type: "hold"; hold; since; expiresAt? }
}
Waiting {
  key: string
  what: { kind: Using["kind"] | "none"; count: { min; max }; label: string }   // "2 emuladores Android"
  by: By
  for: { type: "job"; job; teste; partLabel } | { type: "hold"; hold }
  queue?: { job: string }              // tests only: the group to open in `queue`
  position?: number; etaMs?: number; reason: Reason; since: number
}
Member { sessionID; title?; root; using: number; waiting?: { count; position?; etaMs?; reason } }
```

### `custom.bancada/queue {}`

On the hub, the whole queue (`scope: "all"`); elsewhere, this server's own requests (`scope: "local"`, waits with
`aguardando_hub` and no place when the hub is out).

```ts
Queue {
  version: 1; now: number; scope: "all" | "local"; hub: "ok" | "unavailable" | "incompatible" | "none"
  counts: { running: number; waiting: number }               // parts, not groups
  running: Group<RunningPart>[]   // the group whose first part was accepted last first; ties by job
  waiting: Group<WaitingPart>[]   // arrival order; ties by job (the place never orders the list)
  machines: { server: Server; state: "ok" | "reconciling" | "silent" | "away" | "incompatible"; running: number }[]
  alerts: { id; at; kind; text }[]
}
Group<P> { job; since; session: { server: Server; sessionID; rootSessionID; title?; by? }; parts: P[] }
RunningPart { teste; label; platform; machine: Server; state: "preparando" | "compilando" | "rodando" | "incerto"; devices; since }
WaitingPart { teste; label; platform; position?; etaMs?; reason: Reason; since }
```

`Reason { code, detail?, text }`: `text` is the full sentence in Portuguese and is shown as it comes; `code` and
`detail` are for icon and color. Position and reason on one line: "`<n>`º na fila" when `code` is `fila`,
"`<n>`º · `<text>`" otherwise, `text` alone without a position.

### Events

- `rpc.custom.bancada.changed { sessions: string[]; queue: boolean }`: the roots whose `session` changed and whether
  `queue` did; at most one a second, never for an estimate alone, no counts (reload what it names).
- `rpc.custom.bancada.alert { id, kind, text }`: a new exception (also listed in `queue.alerts`).

## Acceptance

`script/e2e-bancada.ts` runs pairs of sandbox servers (release binary, this branch's plugin bundle, folders, ports
and passwords of their own) through four scenarios: real devices on the Mac, on host-6 an execution with Docker (what
its run leaves with its label removed) and an emulator in a container, the executor's server restarted mid-run, and the origin's process killed between the session's
message and its acknowledgement (the file `teste-morre-no-ack` in the process folder triggers that, once). It cleans
up and checks nothing is left.

## Adoption

- **AbacatoV3:** `.bancada.toml` with `caches = ["**/bin/", "**/obj/"]` and `fora = ["scripts/e2e", "scripts/e2e-run",
".agents/skills/e2e/scripts/linux/"]`; `scripts/e2e` splits into `e2e-build`, `e2e-plan`, `e2e-run`. Leave the
  project: copying to the Mac, device pools and locks, creating and booting emulators and simulators, Wi-Fi and relay
  cleanup (the Bancada does them). Stay: building, listing and sharing scenarios, `adb install`, the fake WhatsApp and
  its relay to the granted port, fixtures, Appium, converting xUnit's XML into `summary.json`. `AGENTS.md` and the
  `e2e` skill say `bancada_run`; the phone tests ask for `android-fisico` with their tags.
- **Phones:** in the Bancada (catalog in the Mac's machine file, migrated from `device-lease`'s `devices.json`). The
  global skills `aparelhos-fisicos` and `emuladores-android` and the `device-lease` script are retired with nothing
  in their place: the tools' descriptions and answers are the only explanation. A long run already on a phone becomes
  its `reservado`.
- **Deploy order:** the machine file (`~/.config/opencode/bancada.toml`) on host-6 (`[android.docker]`; `execucao` only
  takes `modo = "processo"` and `prioridade`: a file with the old `modo = "docker"`, `cpus`, `memoria_gb` or
  `processos` is invalid and the machine offers nothing) and on the Mac; the Linux image first, then `custom:update` on the Mac. In core-infra's compose:
  `OPENCODE_BANCADA=1` and `OPENCODE_BANCADA_SELF`; host-6's server gets its own password from the private environment
  (`OPENCODE_SERVER_PASSWORD` in `private-env-linux`), the Mac's from `service-custom.json`. The schema's first step
  freezes at the first deploy.
- **Turning it off:** `OPENCODE_BANCADA=0` (the Mac's `manual.json`, the Linux compose) and a server restart: the
  tools, the hook and the process go; devices the Bancada made can be removed by their prefix (`bancada-`).
