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
 * `-s` for the default session. A browse resource is also touched by a `browse` command (whose calls see every tab)
 * that names its tab or its owner id; tab IDs are long numbers, but only `browse` commands are matched on them.
 */
export function blocking(command: string, locks: readonly Lock[], workdir?: string) {
  return locks.find(
    (lock) =>
      tokens(lock).some((token) => mentions(command, token)) ||
      implicit(command, lock, workdir) ||
      (lock.meta.kind === "chrome" &&
        lock.meta.browse !== undefined &&
        /(^|[\s;&|(])browse\s/.test(command) &&
        [lock.meta.browse, lock.meta.targetID].some((token) => token !== undefined && mentions(command, token))),
  )
}

/** The refusal of an agent's browse call while Alexandre controls its session's browser tab (`browse.ts`). */
export function browseRefusal() {
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
