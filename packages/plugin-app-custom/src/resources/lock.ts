import { tabNumber, type BrowseTab, type TabRef } from "./adapters/browse-relay.js"
import { sameNamespace } from "./adapters/chrome.js"
import type { Lock } from "./hub/hub.js"

const kindNames = {
  "ios-simulator": "o simulador iOS",
  "android-emulator": "o emulador Android",
  chrome: "o navegador",
} as const

/**
 * The locked resource a shell command would touch, if any. A command touches a resource when it names one of its
 * identifiers (UDID, simulator name, adb serial, AVD, `playwright-cli` session, CDP port: for a browse resource, the
 * relay's) or targets it implicitly: `simctl … booted`, `adb` without `-s`/`ANDROID_SERIAL`, or `playwright-cli` without
 * `-s` for the default session. A browse resource is also touched by a `browse` command (whose calls may use every
 * tab) that names one of its tabs, by integer or chosen id; only `browse` commands are matched on those.
 */
export function blocking(command: string, locks: readonly Lock[], workdir?: string) {
  return locks.find(
    (lock) =>
      tokens(lock).some((token) => mentions(command, token)) ||
      implicit(command, lock, workdir) ||
      (/(^|[\s;&|(])browse\s/.test(command) && browseTokens(lock).some((token) => mentions(command, token))),
  )
}

/**
 * Whether a browse call would act on a tab of a locked browse resource (rev. 2026-11-22: every session may use every
 * tab): one it names by integer or chosen id (`namedTabs`), or a group it closes whole.
 */
export function namesLockedTab(lock: Lock, refs: readonly TabRef[], group: string | undefined) {
  const tabs = lockedTabs(lock)
  return (
    refs.some((ref) => tabs.some((item) => (typeof ref === "number" ? item.tab === ref : item.id === ref))) ||
    (group !== undefined && tabs.some((item) => item.group === group))
  )
}

/**
 * The refusal of an agent's browse call while Alexandre controls a browse resource (`browse.ts`): its own session's
 * (`own`, which gets the hand-back notice), or another session's tab the call names.
 */
export function browseRefusal(whose: "own" | "other" = "own") {
  if (whose === "other")
    return [
      "Alexandre está controlando pelo app a aba do navegador que esta chamada do browse usaria (uma aba de outra sessão), então ela foi bloqueada.",
      "Use uma aba sua ou aguarde ele devolver o controle (até 2 minutos sem toque); esta sessão não recebe aviso.",
      "Não tente contornar a trava pelo shell ou pela CLI do browse.",
    ].join(" ")
  return [
    "Alexandre está controlando pelo app a aba do navegador que esta sessão usa pelo browse, então esta chamada do browse foi bloqueada.",
    "Aguarde ele devolver o controle (ou 2 minutos sem toque): você receberá um aviso.",
    "Não tente contornar a trava por outra aba, por outra sessão, pelo shell ou pela CLI do browse.",
  ].join(" ")
}

export function refusal(lock: Lock) {
  return `Alexandre está usando ${kindNames[lock.kind]} ${lock.label}; aguarde ele devolver o controle (ou 2 minutos sem toque) antes de usar esse recurso. Não tente contornar a trava com outro comando.`
}

export function returned(input: {
  readonly kind: Lock["kind"]
  readonly label: string
  readonly reason: "returned" | "expired"
}) {
  const how =
    input.reason === "expired" ? "e o controle voltou para você depois de 2 minutos sem toque" : "e devolveu o controle"
  return `Alexandre interagiu com ${kindNames[input.kind]} ${input.label} ${how}. Reavalie a tela (estado, foco e navegação podem ter mudado) antes de continuar.`
}

function tokens(lock: Lock) {
  const meta = lock.meta
  if (meta.kind === "ios-simulator") return [meta.udid, meta.name].filter(present)
  if (meta.kind === "android-emulator")
    return [meta.serial, meta.avd, meta.consolePort ? `localhost:${meta.consolePort}` : undefined].filter(present)
  const port = meta.cdp ? URL.parse(meta.cdp)?.port : undefined
  return [meta.session, port ? `:${port}` : undefined].filter(present)
}

/** A locked browse resource's tabs; a hub from before rev. 2026-11-22 names only the one it follows. */
function lockedTabs(lock: Lock): readonly BrowseTab[] {
  if (lock.meta.kind !== "chrome" || lock.meta.browse === undefined) return []
  const followed = tabNumber(lock.meta.targetID)
  const tabs = lock.tabs ?? []
  return followed === undefined || tabs.some((item) => item.tab === followed) ? tabs : [...tabs, { tab: followed }]
}

function browseTokens(lock: Lock) {
  return lockedTabs(lock).flatMap((item) => [String(item.tab), ...(item.id ? [item.id] : [])])
}

function implicit(command: string, lock: Lock, workdir: string | undefined) {
  if (lock.kind === "ios-simulator") return /\bsimctl\b/.test(command) && /(^|\s)booted(\s|$)/.test(command)
  if (lock.kind === "android-emulator")
    return (
      /(^|[\s;&|(])adb(\s|$)/.test(command) &&
      !/\badb\s+(-s\b|--serial\b)/.test(command) &&
      !/ANDROID_SERIAL=/.test(command)
    )
  // Text checks first: the namespace comparison probes directories, and runs before every shell command.
  return (
    lock.meta.kind === "chrome" &&
    lock.meta.browse === undefined &&
    (lock.meta.session ?? "default") === "default" &&
    /\bplaywright-cli\b/.test(command) &&
    !/(\s-s[= ]|\s--session[= ]|PLAYWRIGHT_CLI_SESSION=)/.test(command) &&
    sameNamespace(lock.meta.workspace, workdir)
  )
}

function mentions(command: string, token: string) {
  if (token.startsWith(":")) return new RegExp(`${escape(token)}(?![0-9])`).test(command)
  return new RegExp(`(^|[^A-Za-z0-9_.-])${escape(token)}($|[^A-Za-z0-9_.-])`).test(command)
}

function escape(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function present(value: string | undefined): value is string {
  return value !== undefined && value.length > 0
}
