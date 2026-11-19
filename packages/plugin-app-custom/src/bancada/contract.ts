export * as BancadaContract from "./contract.js"

import type { BancadaProtocol } from "./protocol.js"

/**
 * The project's `.bancada.toml` (`docs/bancada.md`, "Project contract"): what each test needs and how it builds,
 * plans and runs, never where it runs or how devices start. Keys are in Portuguese, as the project writes them; the
 * resolved contract uses this package's names. A contract is read from the commit that runs, and every problem is
 * listed at once, for the agent that wrote it.
 */

/** A command without a shell: a path relative to the repository's root, then its arguments. */
export type Command = readonly string[]

export type Test = {
  readonly name: string
  readonly label: string
  readonly needs: ReadonlyArray<string>
  readonly device: BancadaProtocol.DeviceSpec
  readonly devices: { readonly min: number; readonly max: number }
  readonly build?: Command
  readonly plan?: Command
  readonly run: Command
  readonly args: ReadonlyArray<string>
  readonly deadlineMin?: number
  readonly exclusive: ReadonlyArray<string>
  readonly secrets?: string
}

export type Contract = {
  readonly version: 1
  readonly project: string
  readonly caches: ReadonlyArray<string>
  /** Commands that, in this repository, only the Bancada runs (the hook refuses them elsewhere). */
  readonly outside: ReadonlyArray<string>
  readonly tests: Readonly<Record<string, Test>>
}

export type Parsed =
  | { readonly ok: true; readonly contract: Contract }
  | { readonly ok: false; readonly problems: string[] }

export const limits = { inheritance: 5, devices: 16, label: 40 }

const testName = /^[a-z0-9-]{1,40}$/
const capability = /^[a-z0-9:-]+$/
const policy = /^[A-Za-z0-9._-]+$/
const physical = ["android-fisico", "ios-fisico"]
const topKeys = new Set(["versao", "projeto", "caches", "fora", "teste"])
const testKeys = new Set([
  "herda",
  "rotulo",
  "precisa",
  "aparelho",
  "aparelhos",
  "build",
  "plan",
  "run",
  "args",
  "prazo_min",
  "exclusivo",
  "segredos",
])
const deviceKeys = new Set(["api", "ios", "modelo", "google_play", "enxuto", "etiquetas"])

/**
 * Reads a `.bancada.toml`. `project` is the name to use when the file names none (the normalized remote, or the
 * folder's name); `exists` says whether a path exists in the commit being read (commands must).
 */
export function parseContract(
  text: string,
  options: { readonly project: string; readonly exists?: (path: string) => boolean },
): Parsed {
  const raw = toml(text)
  if (typeof raw === "string") return { ok: false, problems: [`.bancada.toml não é TOML válido: ${raw}`] }
  const problems: string[] = []
  unknownKeys(raw, topKeys, "", problems)
  if (raw.versao !== 1) problems.push("versao: precisa ser 1")
  const project = raw.projeto === undefined ? options.project : text1(raw.projeto, "projeto", problems)
  const caches = list(raw.caches, "caches", problems).filter((item) => relative(item, "caches", problems))
  const outside = list(raw.fora, "fora", problems).filter((item) => relative(item, "fora", problems))
  const declared = table(raw.teste, "teste", problems) ?? {}
  const names = Object.keys(declared)
  if (names.length === 0) problems.push("teste: declare pelo menos um teste ([teste.<nome>])")
  const tests = Object.fromEntries(
    names.flatMap((name) => {
      if (!testName.test(name)) {
        problems.push(`teste.${name}: o nome precisa casar com [a-z0-9-]{1,40}`)
        return []
      }
      const merged = inherit(name, declared, problems)
      if (!merged) return []
      const test = resolve(name, merged, options.exists, problems)
      return test ? [[name, test] as const] : []
    }),
  )
  if (problems.length) return { ok: false, problems: [...new Set(problems)] }
  return { ok: true, contract: { version: 1, project: project ?? options.project, caches, outside, tests } }
}

/** The part the hub schedules for a test of the contract, with the request's arguments after the test's own. */
export function partSpec(test: Test, args: ReadonlyArray<string> = []): BancadaProtocol.PartSpec {
  return {
    part: test.name,
    label: test.label,
    platform: platform(test),
    needs: [...test.needs],
    device: test.device,
    devices: test.devices,
    exclusive: [...test.exclusive],
    ...(test.secrets ? { secrets: test.secrets } : {}),
    // A physical device, an exclusive lock or secrets: never run again without a confirmed end (`docs/bancada.md`).
    unsafe: test.needs.some((need) => physical.includes(need)) || test.exclusive.length > 0 || Boolean(test.secrets),
    args: [...test.args, ...args],
  }
}

/** The kind of device a test asks for, from what it needs; a test without devices is `none`. */
export function platform(test: Pick<Test, "needs" | "devices">): BancadaProtocol.Platform {
  if (test.devices.max === 0) return "none"
  if (test.needs.some((need) => need === "ios" || need === "ios-fisico")) return "ios"
  if (test.needs.some((need) => need === "android" || need === "android-fisico")) return "android"
  return "none"
}

/**
 * A remote's URL as a project name, without scheme, user, credentials or `.git`: `git@github.com:dono/repo.git` and
 * `https://user:token@github.com/dono/repo` are both `github.com/dono/repo`. Undefined for a local path.
 */
export function normalizeRemote(url: string) {
  const parsed = scpLike(url) ?? urlLike(url)
  if (!parsed) return undefined
  const path = parsed.path
    .replace(/\/+$/, "")
    .replace(/\.git$/, "")
    .replace(/^\/+/, "")
  return path ? `${parsed.host.toLowerCase()}/${path}` : undefined
}

/** `git@github.com:dono/repo.git` */
function scpLike(url: string) {
  const match = /^[^/@:]+@([^:/]+):(.+)$/.exec(url)
  return match ? { host: match[1]!, path: match[2]! } : undefined
}

/** `https://user:token@github.com:443/dono/repo`, `ssh://git@host/dono/repo`; `file://` has no host and is local. */
function urlLike(url: string) {
  const match = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@/]*@)?([^/:]+)(?::\d+)?\/(.+)$/i.exec(url)
  return match ? { host: match[1]!, path: match[2]! } : undefined
}

type Raw = Record<string, unknown>

function toml(text: string): Raw | string {
  try {
    const value: unknown = Bun.TOML.parse(text)
    return isTable(value) ? value : "o arquivo não é uma tabela"
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
}

/** The test's own keys over its ancestors' (a key it defines replaces the parent's whole value: lists never add up). */
function inherit(name: string, declared: Raw, problems: string[]): Raw | undefined {
  const chain: Raw[] = []
  const seen: string[] = []
  for (let current: string | undefined = name; current !== undefined; ) {
    if (seen.includes(current)) {
      problems.push(`teste.${name}: herda forma um ciclo (${[...seen, current].join(" → ")})`)
      return undefined
    }
    seen.push(current)
    const own = declared[current]
    if (!isTable(own)) {
      problems.push(
        current === name
          ? `teste.${name}: precisa ser uma tabela`
          : `teste.${name}: herda "${current}", que não existe`,
      )
      return undefined
    }
    chain.push(own)
    if (chain.length > limits.inheritance + 1) {
      problems.push(`teste.${name}: herda passa de ${limits.inheritance} níveis`)
      return undefined
    }
    const parent: unknown = own.herda
    if (parent !== undefined && typeof parent !== "string") {
      problems.push(`teste.${current}.herda: precisa ser o nome de outro teste`)
      return undefined
    }
    current = parent
  }
  return Object.assign({}, ...chain.toReversed())
}

function resolve(name: string, raw: Raw, exists: ((path: string) => boolean) | undefined, problems: string[]) {
  const at = `teste.${name}`
  const before = problems.length
  unknownKeys(raw, testKeys, at, problems)
  const label = raw.rotulo === undefined ? name : text1(raw.rotulo, `${at}.rotulo`, problems)
  if (label !== undefined && (label.length < 1 || label.length > limits.label || /[\r\n]/.test(label)))
    problems.push(`${at}.rotulo: de 1 a ${limits.label} caracteres, numa linha só`)
  const needs = list(raw.precisa, `${at}.precisa`, problems)
  needs
    .filter((need) => !capability.test(need))
    .forEach((need) => problems.push(`${at}.precisa: "${need}" precisa casar com [a-z0-9:-]+`))
  const devices = count(raw.aparelhos, `${at}.aparelhos`, problems)
  const isPhysical = needs.some((need) => physical.includes(need))
  if (devices.max > 0 && needs.length === 0)
    problems.push(`${at}.precisa: diga do que o teste precisa (por exemplo "android")`)
  if (isPhysical && devices.max > 1) problems.push(`${at}.aparelhos: um teste com celular usa no máximo 1 aparelho`)
  const device = deviceSpec(raw.aparelho, `${at}.aparelho`, isPhysical, problems)
  const build = raw.build === undefined ? undefined : command(raw.build, `${at}.build`, exists, problems)
  const plan = raw.plan === undefined ? undefined : command(raw.plan, `${at}.plan`, exists, problems)
  const run = raw.run === undefined ? undefined : command(raw.run, `${at}.run`, exists, problems)
  if (raw.run === undefined) problems.push(`${at}.run: obrigatório`)
  const args = list(raw.args, `${at}.args`, problems)
  const deadline = raw.prazo_min
  if (deadline !== undefined && (typeof deadline !== "number" || !(deadline > 0)))
    problems.push(`${at}.prazo_min: precisa ser um número de minutos maior que zero`)
  const exclusive = list(raw.exclusivo, `${at}.exclusivo`, problems)
  exclusive
    .filter((lock) => !capability.test(lock))
    .forEach((lock) => problems.push(`${at}.exclusivo: "${lock}" precisa casar com [a-z0-9:-]+`))
  const secrets = raw.segredos === undefined ? undefined : text1(raw.segredos, `${at}.segredos`, problems)
  if (secrets !== undefined && !policy.test(secrets)) problems.push(`${at}.segredos: nome de policy inválido`)
  if (problems.length > before || !run || label === undefined) return undefined
  return {
    name,
    label,
    needs,
    device,
    devices,
    ...(build ? { build } : {}),
    ...(plan ? { plan } : {}),
    run,
    args,
    ...(typeof deadline === "number" ? { deadlineMin: deadline } : {}),
    exclusive,
    ...(secrets ? { secrets } : {}),
  } satisfies Test
}

function deviceSpec(value: unknown, at: string, isPhysical: boolean, problems: string[]): BancadaProtocol.DeviceSpec {
  if (value === undefined) return {}
  if (!isTable(value)) {
    problems.push(`${at}: precisa ser uma tabela ({ api = ">=36" }, por exemplo)`)
    return {}
  }
  unknownKeys(value, deviceKeys, at, problems)
  const version = (key: string, pattern: RegExp, example: string) => {
    const item = value[key]
    if (item === undefined) return undefined
    if (typeof item === "string" && pattern.test(item)) return item
    problems.push(`${at}.${key}: use "${example}" ou "${example.replace(">=", "")}"`)
    return undefined
  }
  const api = version("api", /^(>=)?\d+$/, ">=36")
  const ios = version("ios", /^(>=)?\d+(\.\d+)*$/, ">=27.0")
  const model = value.modelo === undefined ? undefined : text1(value.modelo, `${at}.modelo`, problems)
  const googlePlay = value.google_play
  if (googlePlay !== undefined && typeof googlePlay !== "boolean") problems.push(`${at}.google_play: true ou false`)
  const slim = value.enxuto
  if (slim !== undefined && slim !== "aceita" && slim !== "exige" && slim !== "recusa")
    problems.push(`${at}.enxuto: "aceita", "exige" ou "recusa"`)
  const tags = value.etiquetas === undefined ? undefined : list(value.etiquetas, `${at}.etiquetas`, problems)
  if (tags && !isPhysical)
    problems.push(`${at}.etiquetas: só vale para celular (precisa de android-fisico ou ios-fisico)`)
  return {
    ...(api ? { api } : {}),
    ...(ios ? { ios } : {}),
    ...(model ? { model } : {}),
    ...(typeof googlePlay === "boolean" ? { googlePlay } : {}),
    slim: slim === "exige" || slim === "recusa" ? slim : "aceita",
    ...(tags ? { tags } : {}),
  }
}

function count(value: unknown, at: string, problems: string[]) {
  if (value === undefined) return { min: 1, max: 1 }
  const min = isTable(value) ? value.min : undefined
  const max = isTable(value) ? value.max : undefined
  if (isTable(value)) unknownKeys(value, new Set(["min", "max"]), at, problems)
  if (
    !Number.isInteger(min) ||
    !Number.isInteger(max) ||
    (min as number) < 0 ||
    (min as number) > (max as number) ||
    (max as number) > limits.devices
  ) {
    problems.push(`${at}: use { min, max } inteiros com 0 ≤ min ≤ max ≤ ${limits.devices}`)
    return { min: 1, max: 1 }
  }
  return { min: min as number, max: max as number }
}

function command(value: unknown, at: string, exists: ((path: string) => boolean) | undefined, problems: string[]) {
  const argv = typeof value === "string" ? [value] : Array.isArray(value) ? value : undefined
  if (!argv || argv.length === 0 || argv.some((item) => typeof item !== "string" || item.length === 0)) {
    problems.push(`${at}: um caminho, ou uma lista [caminho, argumento…]`)
    return undefined
  }
  const [file] = argv as string[]
  if (!relative(file!, at, problems)) return undefined
  if (exists && !exists(file!)) {
    problems.push(`${at}: "${file}" não existe neste commit`)
    return undefined
  }
  return argv as string[]
}

/** A path inside the repository: relative, without `..`. */
function relative(value: string, at: string, problems: string[]) {
  if (value.startsWith("/") || value.split(/[\\/]/).includes("..") || value.length === 0) {
    problems.push(`${at}: "${value}" precisa ser um caminho relativo à raiz do repositório, sem ".."`)
    return false
  }
  return true
}

function list(value: unknown, at: string, problems: string[]): string[] {
  if (value === undefined) return []
  if (Array.isArray(value) && value.every((item) => typeof item === "string")) return value
  problems.push(`${at}: precisa ser uma lista de textos`)
  return []
}

function text1(value: unknown, at: string, problems: string[]) {
  if (typeof value === "string") return value
  problems.push(`${at}: precisa ser um texto`)
  return undefined
}

function table(value: unknown, at: string, problems: string[]) {
  if (value === undefined) return undefined
  if (isTable(value)) return value
  problems.push(`${at}: precisa ser uma tabela`)
  return undefined
}

function unknownKeys(value: Raw, known: ReadonlySet<string>, at: string, problems: string[]) {
  Object.keys(value)
    .filter((key) => !known.has(key))
    .forEach((key) => problems.push(`${at ? `${at}.` : ""}${key}: chave desconhecida`))
}

function isTable(value: unknown): value is Raw {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
