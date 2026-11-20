export * as BancadaMachineConfig from "./machine-config.js"

import { isTable, list, table, text1, toml, unknownKeys, type Raw } from "./toml.js"

/**
 * The machine's `bancada.toml` (`docs/bancada.md`, "Machine file"): what this machine offers and how much of it. Keys
 * are in Portuguese, as the owner writes them; the resolved file uses this package's names and units (MB, thousandths
 * of a core, milliseconds). Absent, every value is a default taken from the machine itself. Invalid, every problem is
 * listed at once and the machine offers nothing.
 */

/** A range of ports, both ends included. */
export type Range = { readonly start: number; readonly end: number }

/** A phone of the catalog (`[[fisico]]`). */
export type Phone = {
  readonly alias: string
  readonly name: string
  readonly id: string
  readonly platform: "android" | "ios"
  readonly transport: "usb" | "wifi"
  readonly tags: ReadonlyArray<string>
  readonly realAccounts: boolean
  readonly policy: "reservavel" | "negar"
  /** Until when it stays with someone, whatever the expiry rules say (D8). */
  readonly reserved?: { readonly until: number; readonly for: string }
}

export type MachineConfig = {
  readonly speed: "normal" | "lento"
  /** Capabilities found here that this machine does not offer. */
  readonly withheld: ReadonlyArray<string>
  readonly tags: ReadonlyArray<string>
  /** The name of everything the Bancada creates here. */
  readonly prefix: string
  readonly labels: ReadonlyArray<string>
  /** MyCredentials policies `mycred run` resolves here: a part with `segredos` runs only where its policy is listed. */
  readonly secrets: ReadonlyArray<string>
  readonly budget: {
    readonly memMb: number
    readonly cpuMilli: number
    readonly builds: number
    readonly maxAndroid: number
    readonly maxIos: number
    /** While the owner used the Mac in the last `idleMs`, new admissions get `factor` of the budget. */
    readonly presence: { readonly idleMs: number; readonly factor: number }
  }
  readonly brake: BrakeConfig
  readonly execution: {
    readonly mode: "processo" | "docker"
    readonly lowPriority: boolean
    readonly cpus: number
    readonly memMb: number
    readonly pids: number
  }
  readonly link: { readonly waitMs: number; readonly blockBytes: number }
  readonly android: {
    readonly sdk?: string
    readonly javaHome?: string
    readonly docker?: {
      readonly image: string
      readonly network: string
      readonly cpusPerEmulator: number
      readonly memMbPerEmulator: number
      readonly warmMs: number
    }
  }
  readonly ports: { readonly emulator: Range; readonly project: Range }
  readonly times: Times
  readonly phones: ReadonlyArray<Phone>
}

export type BrakeConfig = {
  readonly memFreeMinPct: number
  readonly swapGrowthMb: number
  readonly loadPerCoreMax: number
  readonly cpuIdleMinPct: number
  readonly samplesToReopen: number
}

export type Times = {
  readonly silentMs: number
  readonly uncertainMs: number
  readonly lostMs: number
  readonly localModeMs: number
  /** A notice a plugin instance took and did not acknowledge in this long goes to another. */
  readonly noticeLeaseMs: number
  readonly holdIdleQueuedMs: number
  readonly holdIdleMs: number
  readonly holdTotalQueuedMs: number
  readonly queuePlaceMs: number
  readonly prepareMs: number
  readonly buildMs: number
  readonly runMs: number
}

/** What the machine itself says, for the defaults: its memory, its cores, and whether this runs in a container with Docker. */
export type Host = { readonly memMb: number; readonly cores: number; readonly inDocker: boolean }

export type Parsed =
  | { readonly ok: true; readonly config: MachineConfig }
  | { readonly ok: false; readonly problems: string[] }

const minute = 60_000
const gb = 1024

/** The defaults that do not depend on the machine (the rest come from its memory and cores). */
export const defaults = {
  presence: { idleMs: 5 * minute, factor: 0.6 },
  brake: {
    memFreeMinPct: 20,
    swapGrowthMb: 256,
    loadPerCoreMax: 3,
    cpuIdleMinPct: 5,
    samplesToReopen: 6,
  } satisfies BrakeConfig,
  ports: { emulator: { start: 5_700, end: 5_799 }, project: { start: 48_000, end: 49_999 } },
}

/** `[tempos]`: the key, its unit and its default (section "State machine" and "Holds"). */
const timeKeys = {
  silenciosa_s: ["silentMs", 1_000, 45],
  incerto_s: ["uncertainMs", 1_000, 180],
  perdido_s: ["lostMs", 1_000, 900],
  modo_local_s: ["localModeMs", 1_000, 45],
  aviso_s: ["noticeLeaseMs", 1_000, 30],
  vaga_parada_com_fila_min: ["holdIdleQueuedMs", minute, 10],
  vaga_parada_sem_fila_min: ["holdIdleMs", minute, 60],
  vaga_total_com_fila_min: ["holdTotalQueuedMs", minute, 30],
  lugar_na_fila_min: ["queuePlaceMs", minute, 15],
  preparo_min: ["prepareMs", minute, 10],
  build_min: ["buildMs", minute, 30],
  run_min_padrao: ["runMs", minute, 60],
} as const satisfies Record<string, readonly [keyof Times, number, number]>

const topKeys = new Set([
  "versao",
  "velocidade",
  "nao_oferecer",
  "etiquetas",
  "prefixo",
  "rotulos",
  "segredos",
  "orcamento",
  "freio",
  "execucao",
  "link",
  "android",
  "portas",
  "tempos",
  "fisico",
])
const capability = /^[a-z0-9:-]+$/
const policy = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
const alias = /^[a-z0-9-]{1,40}$/

/** Reads the machine file; `text` undefined (no file) is every default. */
export function parseMachineConfig(text: string | undefined, host: Host): Parsed {
  const raw = text === undefined ? { versao: 1 } : toml(text)
  if (typeof raw === "string") return { ok: false, problems: [`bancada.toml não é TOML válido: ${raw}`] }
  const problems: string[] = []
  const read = reader(problems)
  unknownKeys(raw, topKeys, "", problems)
  if (raw.versao !== 1) problems.push("versao: precisa ser 1")
  const speed = read.choice(raw.velocidade, "velocidade", ["normal", "lento"], "normal")
  const names = (value: unknown, at: string) => {
    const items = list(value, at, problems)
    items
      .filter((item) => !capability.test(item))
      .forEach((item) => problems.push(`${at}: "${item}" precisa casar com [a-z0-9:-]+`))
    return items
  }
  const withheld = names(raw.nao_oferecer, "nao_oferecer")
  const tags = names(raw.etiquetas, "etiquetas")
  const prefix = raw.prefixo === undefined ? "bancada-" : text1(raw.prefixo, "prefixo", problems)
  if (prefix !== undefined && !/^[a-z][a-z0-9-]*-$/.test(prefix))
    problems.push('prefixo: letras minúsculas, números e hífens, terminando em "-" (por exemplo "bancada-")')
  const labels = list(raw.rotulos, "rotulos", problems)
  labels
    .filter((label) => !/^[A-Za-z0-9._/-]+=\S*$/.test(label))
    .forEach((label) => problems.push(`rotulos: "${label}" precisa ser chave=valor`))
  const secrets = list(raw.segredos, "segredos", problems)
  secrets
    .filter((name) => !policy.test(name))
    .forEach((name) => problems.push(`segredos: "${name}" não é um nome de policy (letra ou número, depois . _ -)`))

  const budgetRaw = section(
    raw,
    "orcamento",
    ["memoria_gb", "cpu", "compilacoes", "max_android", "max_ios", "presenca"],
    problems,
  )
  const presenceRaw = section(budgetRaw, "presenca", ["ocioso_min", "fator"], problems, "orcamento.")
  const budget = {
    memMb: Math.round(
      read.number(budgetRaw.memoria_gb, "orcamento.memoria_gb", { above: 0 }, (host.memMb * 0.75) / gb) * gb,
    ),
    cpuMilli: Math.round(read.number(budgetRaw.cpu, "orcamento.cpu", { above: 0 }, host.cores * 0.8) * 1_000),
    builds: read.number(budgetRaw.compilacoes, "orcamento.compilacoes", { min: 0, integer: true }, 1),
    maxAndroid: read.number(
      budgetRaw.max_android,
      "orcamento.max_android",
      { min: 0, integer: true },
      Math.floor(host.cores / 2),
    ),
    maxIos: read.number(
      budgetRaw.max_ios,
      "orcamento.max_ios",
      { min: 0, integer: true },
      Math.floor(host.cores * 0.4),
    ),
    presence: {
      idleMs:
        read.number(
          presenceRaw.ocioso_min,
          "orcamento.presenca.ocioso_min",
          { min: 0 },
          defaults.presence.idleMs / minute,
        ) * minute,
      factor: read.number(presenceRaw.fator, "orcamento.presenca.fator", { min: 0, max: 1 }, defaults.presence.factor),
    },
  }

  const brakeRaw = section(
    raw,
    "freio",
    [
      "memoria_livre_min_pct",
      "swap_crescendo_mb",
      "carga_por_nucleo_max",
      "cpu_ociosa_min_pct",
      "amostras_para_reabrir",
    ],
    problems,
  )
  const fallback = defaults.brake
  const brake = {
    memFreeMinPct: read.number(
      brakeRaw.memoria_livre_min_pct,
      "freio.memoria_livre_min_pct",
      { min: 0, max: 100 },
      fallback.memFreeMinPct,
    ),
    swapGrowthMb: read.number(brakeRaw.swap_crescendo_mb, "freio.swap_crescendo_mb", { min: 0 }, fallback.swapGrowthMb),
    loadPerCoreMax: read.number(
      brakeRaw.carga_por_nucleo_max,
      "freio.carga_por_nucleo_max",
      { above: 0 },
      fallback.loadPerCoreMax,
    ),
    cpuIdleMinPct: read.number(
      brakeRaw.cpu_ociosa_min_pct,
      "freio.cpu_ociosa_min_pct",
      { min: 0, max: 100 },
      fallback.cpuIdleMinPct,
    ),
    samplesToReopen: read.number(
      brakeRaw.amostras_para_reabrir,
      "freio.amostras_para_reabrir",
      { min: 1, integer: true },
      fallback.samplesToReopen,
    ),
  }

  const executionRaw = section(raw, "execucao", ["modo", "prioridade", "cpus", "memoria_gb", "processos"], problems)
  const execution = {
    mode: read.choice(
      executionRaw.modo,
      "execucao.modo",
      ["processo", "docker"],
      host.inDocker ? "docker" : "processo",
    ),
    lowPriority: read.choice(executionRaw.prioridade, "execucao.prioridade", ["normal", "baixa"], "normal") === "baixa",
    cpus: read.number(executionRaw.cpus, "execucao.cpus", { above: 0 }, Math.min(8, host.cores)),
    memMb: Math.round(read.number(executionRaw.memoria_gb, "execucao.memoria_gb", { above: 0 }, 16) * gb),
    pids: read.number(executionRaw.processos, "execucao.processos", { min: 1, integer: true }, 2048),
  }

  const linkRaw = section(raw, "link", ["espera_s", "bloco_kib"], problems)
  const link = {
    waitMs: read.number(linkRaw.espera_s, "link.espera_s", { min: 0, max: 25 }, 25) * 1_000,
    blockBytes:
      read.number(linkRaw.bloco_kib, "link.bloco_kib", { min: 64, max: 32_768, integer: true }, 1_024) * 1_024,
  }

  const androidRaw = section(raw, "android", ["sdk", "java_home", "docker"], problems)
  const dockerRaw =
    androidRaw.docker === undefined
      ? undefined
      : section(
          androidRaw,
          "docker",
          ["imagem", "rede", "cpus_por_emulador", "memoria_por_emulador_gb", "aquecido_min"],
          problems,
          "android.",
        )
  const absolute = (value: unknown, at: string) => {
    if (value === undefined) return undefined
    const path = text1(value, at, problems)
    if (path !== undefined && !path.startsWith("/")) problems.push(`${at}: precisa ser um caminho absoluto`)
    return path
  }
  const sdk = absolute(androidRaw.sdk, "android.sdk")
  const javaHome = absolute(androidRaw.java_home, "android.java_home")
  const required = (value: unknown, at: string) => {
    if (value === undefined) problems.push(`${at}: obrigatório`)
    return value === undefined ? undefined : text1(value, at, problems)
  }
  const docker = dockerRaw && {
    image: required(dockerRaw.imagem, "android.docker.imagem") ?? "",
    network: required(dockerRaw.rede, "android.docker.rede") ?? "",
    cpusPerEmulator: read.number(dockerRaw.cpus_por_emulador, "android.docker.cpus_por_emulador", { above: 0 }, 4),
    memMbPerEmulator: Math.round(
      read.number(dockerRaw.memoria_por_emulador_gb, "android.docker.memoria_por_emulador_gb", { above: 0 }, 8) * gb,
    ),
    warmMs: read.number(dockerRaw.aquecido_min, "android.docker.aquecido_min", { min: 0 }, 15) * minute,
  }

  const portsRaw = section(raw, "portas", ["emulador", "projeto"], problems)
  const emulator = read.range(portsRaw.emulador, "portas.emulador", 2, defaults.ports.emulator)
  const project = read.range(portsRaw.projeto, "portas.projeto", 20, defaults.ports.project)
  if (emulator.start <= project.end && project.start <= emulator.end)
    problems.push("portas: as faixas emulador e projeto não podem se sobrepor")

  const timesRaw = section(raw, "tempos", Object.keys(timeKeys), problems)
  const times = Object.fromEntries(
    Object.entries(timeKeys).map(([key, [name, unit, fallback]]) => [
      name,
      read.number(timesRaw[key], `tempos.${key}`, { above: 0 }, fallback) * unit,
    ]),
  ) as Times

  const phones = phonesOf(raw.fisico, problems)

  if (problems.length > 0) return { ok: false, problems: [...new Set(problems)] }
  return {
    ok: true,
    config: {
      speed,
      withheld,
      tags,
      prefix: prefix!,
      labels,
      secrets,
      budget,
      brake,
      execution,
      link,
      android: {
        ...(sdk ? { sdk } : {}),
        ...(javaHome ? { javaHome } : {}),
        ...(docker ? { docker } : {}),
      },
      ports: { emulator, project },
      times,
      phones,
    },
  }
}

/**
 * What this machine publishes to the hub: what it found, its free tags and, outside the Docker mode (where an
 * execution has no `mycred`), `segredos:<policy>` for each policy it resolves; minus what the owner withholds.
 */
export function offered(config: MachineConfig, found: Readonly<Record<string, unknown>>): Record<string, unknown> {
  const secrets = config.execution.mode === "docker" ? [] : config.secrets.map((name) => `segredos:${name}`)
  return Object.fromEntries(
    [...Object.entries(found), ...[...config.tags, ...secrets].map((name) => [name, {}] as const)].filter(
      ([name]) => !config.withheld.includes(name),
    ),
  )
}

const phoneKeys = new Set([
  "apelido",
  "nome",
  "id",
  "plataforma",
  "transporte",
  "etiquetas",
  "contas_reais",
  "politica",
  "reservado",
])

function phonesOf(value: unknown, problems: string[]): Phone[] {
  if (value === undefined) return []
  if (!Array.isArray(value)) {
    problems.push("fisico: use [[fisico]], uma tabela por celular")
    return []
  }
  const read = reader(problems)
  const phones = value.flatMap((item, index): Phone[] => {
    const at = `fisico[${index + 1}]`
    if (!isTable(item)) {
      problems.push(`${at}: precisa ser uma tabela`)
      return []
    }
    unknownKeys(item, phoneKeys, at, problems)
    const name = (key: string) => {
      if (item[key] !== undefined) return text1(item[key], `${at}.${key}`, problems)
      problems.push(`${at}.${key}: obrigatório`)
      return undefined
    }
    const nickname = name("apelido")
    if (nickname !== undefined && !alias.test(nickname))
      problems.push(`${at}.apelido: precisa casar com [a-z0-9-]{1,40}`)
    const shown = name("nome")
    if (shown !== undefined && (shown.length < 1 || shown.length > 40))
      problems.push(`${at}.nome: de 1 a 40 caracteres`)
    const id = name("id")
    if (id === "") problems.push(`${at}.id: não pode ser vazio`)
    if (item.plataforma === undefined) problems.push(`${at}.plataforma: obrigatório`)
    const platform = read.choice(item.plataforma, `${at}.plataforma`, ["android", "ios"], "android")
    const contas = item.contas_reais
    if (contas !== undefined && typeof contas !== "boolean") problems.push(`${at}.contas_reais: true ou false`)
    const reservedRaw = table(item.reservado, `${at}.reservado`, problems)
    if (reservedRaw) unknownKeys(reservedRaw, new Set(["ate", "para"]), `${at}.reservado`, problems)
    const until = reservedRaw ? Date.parse(String(reservedRaw.ate ?? "")) : undefined
    if (reservedRaw && !Number.isFinite(until))
      problems.push(`${at}.reservado.ate: uma data e hora (2026-11-21T06:00:00Z)`)
    const reservedFor = reservedRaw ? text1(reservedRaw.para ?? "", `${at}.reservado.para`, problems) : undefined
    if (nickname === undefined || shown === undefined || !id) return []
    return [
      {
        alias: nickname,
        name: shown,
        id,
        platform,
        transport: read.choice(item.transporte, `${at}.transporte`, ["usb", "wifi"], "usb"),
        tags: list(item.etiquetas, `${at}.etiquetas`, problems),
        realAccounts: contas === true,
        policy: read.choice(item.politica, `${at}.politica`, ["reservavel", "negar"], "reservavel"),
        ...(until !== undefined && Number.isFinite(until) ? { reserved: { until, for: reservedFor ?? "" } } : {}),
      },
    ]
  })
  const repeated = (key: "alias" | "id", label: string) =>
    [...new Set(phones.map((phone) => phone[key]))]
      .filter((value) => phones.filter((phone) => phone[key] === value).length > 1)
      .forEach((value) => problems.push(`fisico: ${label} "${value}" aparece em mais de um celular`))
  repeated("alias", "o apelido")
  repeated("id", "o id")
  return phones
}

/** A table of the file (`{}` when absent), its unknown keys reported. */
function section(parent: Raw, key: string, keys: ReadonlyArray<string>, problems: string[], prefix = "") {
  const found = table(parent[key], `${prefix}${key}`, problems)
  if (found) unknownKeys(found, new Set(keys), `${prefix}${key}`, problems)
  return found ?? {}
}

function reader(problems: string[]) {
  return {
    number: (
      value: unknown,
      at: string,
      bounds: { readonly min?: number; readonly above?: number; readonly max?: number; readonly integer?: boolean },
      fallback: number,
    ) => {
      if (value === undefined) return fallback
      const valid =
        typeof value === "number" &&
        Number.isFinite(value) &&
        (bounds.min === undefined || value >= bounds.min) &&
        (bounds.above === undefined || value > bounds.above) &&
        (bounds.max === undefined || value <= bounds.max) &&
        (!bounds.integer || Number.isInteger(value))
      if (valid) return value
      const limits = [
        bounds.integer ? "um número inteiro" : "um número",
        bounds.min === undefined ? undefined : `≥ ${bounds.min}`,
        bounds.above === undefined ? undefined : `> ${bounds.above}`,
        bounds.max === undefined ? undefined : `≤ ${bounds.max}`,
      ].filter(Boolean)
      problems.push(`${at}: precisa ser ${limits.join(", ")}`)
      return fallback
    },
    choice: <const T extends string>(value: unknown, at: string, options: ReadonlyArray<T>, fallback: T): T => {
      if (value === undefined) return fallback
      if (typeof value === "string" && (options as ReadonlyArray<string>).includes(value)) return value as T
      problems.push(`${at}: ${options.map((option) => `"${option}"`).join(" ou ")}`)
      return fallback
    },
    range: (value: unknown, at: string, size: number, fallback: Range): Range => {
      if (value === undefined) return fallback
      const match = typeof value === "string" ? /^(\d+)-(\d+)$/.exec(value) : null
      const start = Number(match?.[1])
      const end = Number(match?.[2])
      if (match && start >= 1_024 && end <= 65_535 && end - start + 1 >= size) return { start, end }
      problems.push(`${at}: use "início-fim" entre 1024 e 65535, com pelo menos ${size} portas`)
      return fallback
    },
  }
}
