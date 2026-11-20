import { describe, expect, test } from "bun:test"
import { offered, parseMachineConfig, type Host, type MachineConfig } from "../src/bancada/machine-config"

const mac: Host = { memMb: 131_072, cores: 16, inDocker: false, platform: "darwin" }
const valid = (text: string | undefined, host = mac): MachineConfig => {
  const parsed = parseMachineConfig(text, host)
  if (!parsed.ok) throw new Error(parsed.problems.join("\n"))
  return parsed.config
}
const problems = (text: string) => {
  const parsed = parseMachineConfig(text, mac)
  return parsed.ok ? [] : parsed.problems
}

describe("machine file", () => {
  test("absent, every value comes from the machine itself or the documented defaults", () => {
    expect(valid(undefined)).toEqual({
      speed: "normal",
      withheld: [],
      tags: [],
      prefix: "bancada-",
      labels: [],
      secrets: [],
      budget: {
        memMb: 98_304,
        cpuMilli: 12_800,
        builds: 1,
        // Measured: past 6 emulators the suite stops getting shorter (AbacatoV3).
        maxAndroid: 6,
        maxIos: 6,
        presence: { idleMs: 300_000, factor: 0.6 },
      },
      brake: { memFreeMinPct: 20, swapGrowthMb: 256, loadPerCoreMax: 3, cpuIdleMinPct: 5, samplesToReopen: 6 },
      execution: { mode: "processo", lowPriority: false, cpus: 8, memMb: 16_384, pids: 2_048 },
      link: { waitMs: 25_000, blockBytes: 1_048_576 },
      android: {},
      ports: { emulator: { start: 5_700, end: 5_799 }, project: { start: 48_000, end: 49_999 } },
      times: {
        silentMs: 45_000,
        uncertainMs: 180_000,
        lostMs: 900_000,
        localModeMs: 45_000,
        noticeLeaseMs: 30_000,
        holdIdleQueuedMs: 600_000,
        holdIdleMs: 3_600_000,
        holdTotalQueuedMs: 1_800_000,
        queuePlaceMs: 900_000,
        prepareMs: 600_000,
        buildMs: 1_800_000,
        runMs: 3_600_000,
      },
      phones: [],
      // A Mac identifies itself with ioreg; the machine behind the mac bridge, with ioreg through it.
      bridges: {
        mac: ["mac", "/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
        own: ["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
      },
    })
    // In a container with Docker's socket, executions run in sibling containers by default.
    expect(valid(undefined, { ...mac, inDocker: true })).toMatchObject({
      execution: { mode: "docker" },
      // In containers on host-6, 4 emulators at once (6 failed a scenario by accessibility timeouts).
      budget: { maxAndroid: 4 },
    })
    // Elsewhere nothing identifies the machine unless [pontes] says how.
    expect(valid(undefined, { ...mac, platform: "linux" }).bridges).toEqual({
      mac: ["mac", "/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
    })
    expect(
      valid(`versao = 1\n[pontes]\nmac = ["mac", "cat", "/tmp/uuid"]\npropria = ["cat", "/tmp/uuid"]`, {
        ...mac,
        platform: "linux",
      }).bridges,
    ).toEqual({ mac: ["mac", "cat", "/tmp/uuid"], own: ["cat", "/tmp/uuid"] })
    expect(problems(`versao = 1\n[pontes]\nmac = []\nponte = "x"`)).toEqual([
      expect.stringContaining("ponte"),
      "pontes.mac: precisa de pelo menos o programa",
    ])
  })

  test("the documented example reads as written", () => {
    const config = valid(`
versao = 1
velocidade   = "lento"
nao_oferecer = ["ios"]
etiquetas    = ["gpu"]
prefixo      = "bancada-test-"
rotulos      = ["purpose=bancada-test"]
segredos     = ["opencode-skills"]

[orcamento]
memoria_gb  = 96
cpu         = 13
compilacoes = 1
max_android = 8
max_ios     = 6
presenca    = { ocioso_min = 5, fator = 0.6 }

[freio]
memoria_livre_min_pct = 20
swap_crescendo_mb     = 256
carga_por_nucleo_max  = 3.0
cpu_ociosa_min_pct    = 5
amostras_para_reabrir = 6

[execucao]
modo       = "docker"
prioridade = "baixa"
cpus       = 8
memoria_gb = 16
processos  = 2048

[link]
espera_s  = 10
bloco_kib = 512

[android]
sdk       = "/Users/u/Library/Android/sdk"
java_home = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"

[android.docker]
imagem                  = "opencode-android:emu37.2.13-api36-google-r7"
rede                    = "opencode-android-private"
cpus_por_emulador       = 4
memoria_por_emulador_gb = 8
aquecido_min            = 15

[portas]
emulador = "5700-5799"
projeto  = "48000-49999"

[tempos]
silenciosa_s = 5
build_min    = 2

[[fisico]]
apelido      = "poco"
nome         = "POCO X7"
id           = "IBHUYT85ZTYH5XDM"
plataforma   = "android"
transporte   = "usb"
etiquetas    = ["whatsapp-business"]
contas_reais = true
politica     = "reservavel"
reservado    = { ate = 2026-11-21T06:00:00Z, para = "ensaio do Abacato" }

[[fisico]]
apelido    = "redmi"
nome       = "Redmi Note 11"
id         = "d8cf6fc2"
plataforma = "android"
transporte = "wifi"
politica   = "negar"
`)
    expect(config).toMatchObject({
      speed: "lento",
      withheld: ["ios"],
      prefix: "bancada-test-",
      labels: ["purpose=bancada-test"],
      secrets: ["opencode-skills"],
      budget: { memMb: 98_304, cpuMilli: 13_000, builds: 1, maxAndroid: 8, maxIos: 6 },
      execution: { mode: "docker", lowPriority: true, memMb: 16_384 },
      link: { waitMs: 10_000, blockBytes: 524_288 },
      android: {
        sdk: "/Users/u/Library/Android/sdk",
        docker: { image: "opencode-android:emu37.2.13-api36-google-r7", memMbPerEmulator: 8_192, warmMs: 900_000 },
      },
      times: { silentMs: 5_000, buildMs: 120_000, runMs: 3_600_000 },
    })
    expect(config.phones).toEqual([
      {
        alias: "poco",
        name: "POCO X7",
        id: "IBHUYT85ZTYH5XDM",
        platform: "android",
        transport: "usb",
        tags: ["whatsapp-business"],
        realAccounts: true,
        policy: "reservavel",
        reserved: { until: Date.parse("2026-11-21T06:00:00Z"), for: "ensaio do Abacato" },
      },
      {
        alias: "redmi",
        name: "Redmi Note 11",
        id: "d8cf6fc2",
        platform: "android",
        transport: "wifi",
        tags: [],
        realAccounts: false,
        policy: "negar",
      },
    ])
  })

  test("every problem is listed at once", () => {
    expect(
      problems(`
versao = 2
cor = "azul"
velocidade = "rapido"
prefixo = "Bancada"
rotulos = ["sem valor"]
segredos = ["-x"]
[orcamento]
memoria_gb = 0
max_android = 1.5
presenca = { fator = 2 }
[freio]
amostras_para_reabrir = 0
[execucao]
modo = "launchd"
[link]
espera_s = 60
[android]
sdk = "Library/Android/sdk"
[android.docker]
cpus_por_emulador = 4
[portas]
emulador = "48000-48010"
projeto = "48000-48010"
[tempos]
silenciosa_s = 0
lento_min = 1
`),
    ).toEqual([
      "cor: chave desconhecida",
      "versao: precisa ser 1",
      'velocidade: "normal" ou "lento"',
      'prefixo: letras minúsculas, números e hífens, terminando em "-" (por exemplo "bancada-")',
      'rotulos: "sem valor" precisa ser chave=valor',
      'segredos: "-x" não é um nome de policy (letra ou número, depois . _ -)',
      'execucao.modo: "processo" ou "docker"',
      "orcamento.memoria_gb: precisa ser um número, > 0",
      "orcamento.max_android: precisa ser um número inteiro, ≥ 0",
      "orcamento.presenca.fator: precisa ser um número, ≥ 0, ≤ 1",
      "freio.amostras_para_reabrir: precisa ser um número inteiro, ≥ 1",
      "link.espera_s: precisa ser um número, ≥ 0, ≤ 25",
      "android.sdk: precisa ser um caminho absoluto",
      "android.docker.imagem: obrigatório",
      "android.docker.rede: obrigatório",
      'portas.projeto: use "início-fim" entre 1024 e 65535, com pelo menos 20 portas',
      "portas: as faixas emulador e projeto não podem se sobrepor",
      "tempos.lento_min: chave desconhecida",
      "tempos.silenciosa_s: precisa ser um número, > 0",
    ])
    expect(problems("versao = = 1")).toEqual([expect.stringContaining("bancada.toml não é TOML válido")])
  })

  test("the phone catalog refuses what would make a phone ambiguous or unreadable", () => {
    expect(
      problems(`
versao = 1
[[fisico]]
apelido = "poco"
nome = "POCO X7"
id = "A1"
plataforma = "android"
politica = "talvez"
reservado = { ate = "amanhã", para = "x" }
[[fisico]]
apelido = "poco"
nome = "Outro"
id = "A1"
plataforma = "ios"
[[fisico]]
apelido = "Sem Nome"
plataforma = "windows"
`),
    ).toEqual([
      "fisico[1].reservado.ate: uma data e hora (2026-11-21T06:00:00Z)",
      'fisico[1].politica: "reservavel" ou "negar"',
      "fisico[3].apelido: precisa casar com [a-z0-9-]{1,40}",
      "fisico[3].nome: obrigatório",
      "fisico[3].id: obrigatório",
      'fisico[3].plataforma: "android" ou "ios"',
      'fisico: o apelido "poco" aparece em mais de um celular',
      'fisico: o id "A1" aparece em mais de um celular',
    ])
  })

  test("a machine publishes what it found, its tags and the policies it resolves, minus what it withholds", () => {
    const config = valid(`versao = 1\netiquetas = ["gpu"]\nsegredos = ["opencode-skills"]\nnao_oferecer = ["ios"]`)
    expect(offered(config, { android: { abi: "arm64-v8a" }, ios: {} })).toEqual({
      android: { abi: "arm64-v8a" },
      gpu: {},
      "segredos:opencode-skills": {},
    })
    // An execution in a container has no mycred: no policy is resolved there.
    const docker = valid(`versao = 1\nsegredos = ["opencode-skills"]\n[execucao]\nmodo = "docker"`)
    expect(offered(docker, {})).toEqual({})
  })
})
