import { Effect, Queue, Schedule } from "effect"
import { localCommand, machineParts, references, touches, type Reference } from "./discovery.js"
import type { HubEvent, Lock } from "./hub/hub.js"
import { blocking } from "./lock.js"
import { Resources } from "./rpc.js"
import { HubError, macHubSettings, makeHubClient, type HubClient } from "./supervisor.js"

/**
 * The hubs a server's plugin talks to (`resources.md`, "Mac hub"): its own (`local`) and, on a Linux server whose Mac
 * publishes a hub of its own (`OPENCODE_RESOURCES_HUB_MAC_SOCKET`), the Mac's, which holds simulators and emulators.
 * Without the Mac's hub everything goes to `local`, as before.
 */
export function makeHubs(local: HubClient, mac?: HubClient, options: { readonly listWait?: number } = {}) {
  const listWait = options.listWait ?? macListWait
  /** The hub that holds a resource: its kind says it (the Mac's hub keeps simulators and emulators only). */
  const owner = (id: string) => (mac && macKinds.some((kind) => id.startsWith(`${kind}:`)) ? mac : local)
  /**
   * The Mac's hub is shared with nobody, but its emulators are: an agent of the Mac's own server may be using one
   * that this server's hub sees as free. Only an emulator one of this server's agents started may be shut down here.
   */
  const shown = (resource: Resources.Resource): Resources.Resource => {
    if (!mac || owner(resource.id) !== mac || resource.startedBy || !resource.capabilities?.stop) return resource
    const { stop: _, ...rest } = resource.capabilities
    const { capabilities: __, ...without } = resource
    return Object.keys(rest).length > 0 ? { ...without, capabilities: rest } : without
  }
  return {
    local,
    mac,
    owner,
    of: (machine: Machine) => (machine === "mac" && mac ? mac : local),
    scopes: (command: string) => scopes(command, mac !== undefined),
    /**
     * Every resource, newest use first: the Mac's simulators and emulators and this machine's browsers. A Mac hub that
     * does not answer within `listWait` (asleep, tunnel down) leaves only this machine's; its request goes on, so its
     * backoff learns the hub is away. Each hub contributes only its kinds: this machine's hub keeps older simulator and
     * emulator entries for days. `probe` (a list the app asked for) tries the Mac's hub even in its backoff, within
     * the same `listWait`.
     */
    list: async (options: { readonly probe?: boolean } = {}) => {
      if (!mac) return local.list()
      const [here, there] = await Promise.allSettled([
        local.list(),
        within(mac.list(true, options.probe ?? false), listWait),
      ])
      if (here.status === "rejected" && there.status === "rejected") throw here.reason
      return {
        resources: [
          ...(here.status === "fulfilled" ? here.value.resources.filter((item) => !macKinds.includes(item.kind)) : []),
          ...(there.status === "fulfilled"
            ? there.value.resources.filter((item) => macKinds.includes(item.kind)).map(shown)
            : []),
        ].toSorted((a, b) => b.lastUsedAt - a.lastUsedAt),
      }
    },
    get: (id: string) => owner(id).get(id).then(shown),
    control: (id: string, action: "take" | "renew" | "release") =>
      owner(id)
        .control(id, action)
        .then((result) => ({ ...result, resource: shown(result.resource) })),
    /** A view or control ticket; the Mac's go through `/resources/mac/…`, which the server's proxy sends to its hub. */
    ticket: async (id: string, capability: Resources.Capability) => {
      const hub = owner(id)
      const onMac = hub === mac
      const [ticket, port] = await Promise.all([hub.ticket(id, capability), onMac ? undefined : hub.port()])
      return {
        ticket: ticket.ticket,
        expiresAt: ticket.expiresAt,
        path: `${onMac ? "/resources/mac" : "/resources"}/${encodeURIComponent(id)}`,
        // The Mac's hub has no port on this machine: clients always go through the proxy.
        loopbackPort: port ?? 0,
      }
    },
    stop: async (id: string) => {
      const hub = owner(id)
      if (hub === mac && !(await mac.get(id)).startedBy)
        throw new HubError("unsupported", "Only an emulator that an agent of this server started can be shut down here")
      await hub.stop(id)
    },
    /**
     * One long poll per hub, so a hub with nothing to say never delays the other's events. The Mac's hub found away or
     * back also changes the list (its resources leave or return), so each such change is a `changed` of its own.
     */
    relay: (handle: (event: HubEvent) => Effect.Effect<void>) =>
      Effect.gen(function* () {
        yield* Effect.forEach([local, ...(mac ? [mac] : [])], (hub) => relayEvents(hub, handle), { discard: true })
        if (!mac) return
        const turned = yield* Queue.sliding<void>(1)
        const stop = mac.listen(() => Queue.offerUnsafe(turned, undefined))
        yield* Effect.addFinalizer(() => Effect.sync(stop))
        yield* Queue.take(turned).pipe(
          Effect.andThen(handle({ type: "changed", ids: [] })),
          Effect.forever,
          Effect.forkScoped({ startImmediately: true }),
        )
      }),
  }
}

export type Hubs = ReturnType<typeof makeHubs>
export type Machine = "local" | "mac"

/** How long a list waits for the Mac's hub (about 25 ms when it answers) before showing this machine's alone. */
const macListWait = 1_000

const macKinds: readonly Resources.Kind[] = ["ios-simulator", "android-emulator"]
const allKinds: readonly Resources.Kind[] = ["ios-simulator", "android-emulator", "chrome"]

/**
 * A part of a shell command and the resource kinds it may name on one hub. Without the Mac's hub, one scope: what runs
 * here (`localCommand`), every kind, this hub. With it (`machineParts`): what runs here names this machine's browsers
 * (its `adb`/`emulator` reach the Android sidecar, outside Recursos); what runs through `mac` names the Mac's simulators
 * and emulators (its Chrome is not served here); and a simulator named here is the Mac's too, the only place one runs.
 * That last scope counts only what it names (`named`): a tool alone (`maestro`, `agent-device` for the sidecar) does
 * not make a command touch the Mac.
 */
interface Scope {
  readonly machine: Machine
  readonly command: string
  readonly kinds: readonly Resources.Kind[]
  readonly named?: boolean
}

export function scopes(command: string, mac: boolean): Scope[] {
  if (!mac) return [{ machine: "local", command: localCommand(command), kinds: allKinds }]
  const parts = machineParts(command)
  return [
    { machine: "local", command: parts.here, kinds: ["chrome"] },
    { machine: "mac", command: parts.mac, kinds: macKinds },
    { machine: "mac", command: parts.here, kinds: ["ios-simulator"], named: true },
  ]
}

/** What a scope names (`references`), only of its kinds. */
function scopeReferences(scope: Scope, output = "", workdir?: string): Reference[] {
  return references(scope.command, output, workdir).filter((reference) => scope.kinds.includes(reference.kind))
}

/**
 * What a command names per hub: the hub's machine, the part that runs there (what `usage` reads) and its references.
 * Only hubs it names something on.
 */
export function routes(all: readonly Scope[], output = "", workdir?: string) {
  return (["local", "mac"] as const).flatMap((machine) => {
    const own = all.filter((scope) => scope.machine === machine)
    const found = own.flatMap((scope) => scopeReferences(scope, output, workdir))
    if (found.length === 0) return []
    return [{ machine, command: own[0]!.command, references: found }]
  })
}

/** Whether a scope may touch a resource of its kinds, named or not (`touchesResources`). */
function scopeTouches(scope: Scope) {
  return scope.named ? scopeReferences(scope).length > 0 : touches(scope.command, scope.kinds)
}

/**
 * The lock a shell command would touch and whether some hub it touches could not say (`undefined` locks: the command
 * runs with a warning). This machine's hub is read for every command, as before; the Mac's only when the command may
 * touch the Mac, so a sleeping Mac never holds other commands.
 */
export async function commandLock(hubs: Pick<Hubs, "of">, all: readonly Scope[], workdir?: string) {
  const touched = (machine: Machine) => all.some((scope) => scope.machine === machine && scopeTouches(scope))
  const read = async (machine: Machine) =>
    machine === "local" || touched(machine) ? hubs.of(machine).locks() : ([] as Lock[])
  const [local, mac] = await Promise.all([read("local"), read("mac")])
  const locks = { local, mac }
  const lock = all
    .filter((scope) => !scope.named || scopeTouches(scope))
    .map((scope) =>
      blocking(
        scope.command,
        (locks[scope.machine] ?? []).filter((candidate) => scope.kinds.includes(candidate.kind)),
        workdir,
      ),
    )
    .find((found) => found !== undefined)
  return {
    lock,
    unchecked: (["local", "mac"] as const).some((machine) => locks[machine] === undefined && touched(machine)),
  }
}

/**
 * The Mac's hub of this server's environment, one per process: its backoff then covers every Location. `problem`
 * (a misconfiguration, without values) comes with the first call only, so it is logged once.
 */
export function sharedMacHub(): { readonly client?: HubClient; readonly problem?: string } {
  if (shared) return { ...(shared.client ? { client: shared.client } : {}) }
  const found = macHubSettings()
  shared = { ...(found.settings ? { client: makeHubClient(found.settings) } : {}) }
  return { ...shared, ...(found.problem ? { problem: found.problem } : {}) }
}
let shared: { readonly client?: HubClient } | undefined

/** Relays a hub's events; each event reaches exactly one plugin instance. Without a hub the poll returns at once. */
function relayEvents(hub: Pick<HubClient, "events">, handle: (event: HubEvent) => Effect.Effect<void>) {
  return Effect.promise(() => hub.events(25_000)).pipe(
    Effect.flatMap((events) => Effect.forEach(events, handle, { discard: true }).pipe(Effect.as(events.length))),
    Effect.flatMap((count) => (count === 0 ? Effect.sleep("2 seconds") : Effect.void)),
    Effect.repeat(Schedule.forever),
    Effect.forkScoped({ startImmediately: true }),
  )
}

function within<A>(promise: Promise<A>, ms: number) {
  return new Promise<A>((resolve, reject) => {
    const timer = setTimeout(() => reject(new HubError("hub", "The Mac's resources hub did not answer in time")), ms)
    promise.then(resolve, reject).finally(() => clearTimeout(timer))
  })
}
