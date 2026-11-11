import { identity } from "./adapters/android-emulator.js"
import { onlyAsksAndroid, references } from "./discovery.js"
import type { Upsert } from "./hub/hub.js"
import type { Resources } from "./rpc.js"

/** The session a shell call ran in: its own ID, agent and title, and its family's root and title. */
export interface Caller {
  readonly sessionID: string
  readonly rootSessionID: string
  readonly agent?: string
  readonly title?: string
  readonly rootTitle?: string
}

/**
 * What registering `meta` for `command` adds (`docs/resources.md`, "Activity"), or `undefined` when the command must not
 * register it at all: a command that only asks about Android emulators (`onlyAsksAndroid`) neither uses one nor makes
 * its session the owner. A completed command that started the AVD (`emulator -avd`, `android-emulator --detach -avd`)
 * records who started it.
 */
export function usage(
  command: string,
  meta: Resources.Meta,
  caller: Caller,
  at: number,
  completed: boolean,
): Pick<Upsert, "owner" | "startedBy"> | undefined {
  if (meta.kind === "android-emulator" && onlyAsksAndroid(command)) return undefined
  const owner = { sessionID: caller.sessionID, rootSessionID: caller.rootSessionID, agent: caller.agent }
  const started =
    completed && meta.kind === "android-emulator" && meta.avd !== undefined && startedAVDs(command).includes(meta.avd)
  return {
    owner: clean(owner),
    ...(started ? { startedBy: clean({ ...caller, at }) } : {}),
  }
}

/** AVDs a command starts: discovery names an AVD only after `emulator`/`android-emulator` `-avd NAME` or `@NAME`. */
export function startedAVDs(command: string) {
  return references(command).flatMap((reference) =>
    reference.kind === "android-emulator" && reference.avd !== undefined ? [reference.avd] : [],
  )
}

/**
 * The resource `resource_label` names with `ref`, or why it refuses. An adb serial is only a console port of this Mac
 * that the next AVD to start takes over, so a label given by serial goes to an entry known only by that serial, and only
 * while an emulator answers there. When an AVD with its own entry runs on that serial now, the label is refused rather
 * than moved to it: the agent may mean another machine's emulator with the same serial (a container reached by `ssh` or
 * `docker exec`) or one that held the port before, and silently renaming someone else's emulator is worse than asking
 * for the AVD name.
 */
export function labelTarget(
  resources: readonly Resources.Resource[],
  ref: string,
): { readonly resource: Resources.Resource; readonly bare: boolean } | { readonly refusal: string } {
  const named = resources.filter((resource) => names(resource.meta).includes(ref))
  if (!/^emulator-\d+$/.test(ref)) {
    const resource = named[0]
    return resource
      ? { resource, bare: false }
      : { refusal: `No known resource is called ${ref}; use it in a shell command first.` }
  }
  const live = (resource: Resources.Resource) => resource.state !== "stopped" && resource.state !== "gone"
  const holder = resources.find(
    (resource) =>
      resource.meta.kind === "android-emulator" && resource.meta.serial === ref && identity(resource) && live(resource),
  )
  if (holder)
    return {
      refusal: `${ref} is the AVD ${identity(holder)} on this Mac now, already its own resource ("${holder.label}"): name it with ref ${identity(holder)}. An emulator on another machine (reached by ssh or docker exec) is not a resource of this Mac.`,
    }
  const bare = named.find((resource) => resource.meta.kind === "android-emulator" && identity(resource) === undefined)
  if (!bare || !live(bare))
    return {
      refusal: `No emulator answers at ${ref} on this Mac. An emulator on another machine (reached by ssh or docker exec) is not a resource of this Mac.`,
    }
  return { resource: bare, bare: true }
}

function names(meta: Resources.Meta) {
  if (meta.kind === "ios-simulator") return [meta.udid, meta.name]
  if (meta.kind === "android-emulator") return [meta.serial, meta.avd]
  return [meta.session, meta.cdp]
}

function clean<T extends object>(value: T) {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as T
}
