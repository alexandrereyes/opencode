#!/usr/bin/env bun
// The Bancada's short acceptance (`docs/bancada.md`, "Acceptance"): a pair of sandbox servers on this computer (the
// installed release's binary, this branch's plugin bundle, folders, ports and password of their own; never
// production's), then the scenarios of that computer:
//
//   bun e2e-bancada.ts mac   --binary <opencode> --plugin <index.js> --scratch <folder> --example <bancada-exemplo>
//     real devices: a session of the hub asks android and ios, which run on the other server's real emulator and
//     simulator `bancada-test-…`, ready and given back; one notice.
//   bun e2e-bancada.ts linux --binary <opencode> --plugin <index.js> --scratch <folder> --example <bancada-exemplo>
//     host-6: android in a sibling container with an emulator in a container, with limits, everything removed;
//     the executor's server restarted mid-run: one result; the origin's process killed between the message and the
//     ack: one message.
//
// Exits 1 when a scenario fails. Always stops what it started and removes what it made, and lists what is left.
import fs from "node:fs/promises"
import path from "node:path"

const [pair] = process.argv.slice(2)
const option = (name: string) => {
  const index = process.argv.indexOf(`--${name}`)
  const value = index >= 0 ? process.argv[index + 1] : undefined
  if (!value) throw new Error(`--${name} is required`)
  return path.resolve(value)
}
if (pair !== "mac" && pair !== "linux")
  throw new Error("usage: e2e-bancada.ts mac|linux --binary … --plugin … --scratch … --example …")
const binary = option("binary")
const plugin = option("plugin")
const scratch = option("scratch")
const example = option("example")
const password = `bancada-test-${crypto.randomUUID()}`
const results: { scenario: string; ok: boolean; detail: string }[] = []
const servers = new Map<string, { process: Bun.Subprocess; port: number; base: string; state: string; root: string }>()
const log = (line: string) => console.log(`${new Date().toISOString().slice(11, 19)} ${line}`)

type Spec = { name: string; port: number; hub: boolean; machine: string }

/** One sandbox server: its own folders and machine file, production's nothing. */
async function start(spec: Spec, hubPort?: number) {
  const root = path.join(scratch, spec.name)
  const state = path.join(root, "state")
  for (const folder of ["tmp", "custom", "config", "data", "xdg/config", "xdg/state", "xdg/cache", "plugin"])
    await fs.mkdir(path.join(root, folder), { recursive: true })
  await Bun.write(path.join(root, "custom", "password"), password)
  await Bun.write(path.join(root, "bancada.toml"), spec.machine)
  await fs.copyFile(plugin, path.join(root, "plugin", "index.js"))
  const env: Record<string, string> = {
    HOME: process.env.HOME!,
    USER: process.env.USER ?? "",
    LOGNAME: process.env.LOGNAME ?? process.env.USER ?? "",
    SHELL: "/bin/bash",
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    LANG: "C.UTF-8",
    TMPDIR: path.join(root, "tmp"),
    OPENCODE_CONFIG_CONTENT: JSON.stringify({ update: "disable", plugins: [path.join(root, "plugin")] }),
    OPENCODE_PASSWORD: password,
    OPENCODE_CUSTOM_HOME: path.join(root, "custom"),
    OPENCODE_DB: path.join(root, "data", "opencode.db"),
    OPENCODE_CONFIG_DIR: path.join(root, "config"),
    XDG_DATA_HOME: path.join(root, "data"),
    XDG_CONFIG_HOME: path.join(root, "xdg/config"),
    XDG_STATE_HOME: path.join(root, "xdg/state"),
    XDG_CACHE_HOME: path.join(root, "xdg/cache"),
    OPENCODE_DISABLE_AUTOUPDATE: "1",
    OPENCODE_WATCH_GATEWAY_PORT: "0",
    OPENCODE_RESOURCES_HUB_INVENTORY: "0",
    OPENCODE_HOST_NAME: `bancada-test-${spec.name}`,
    OPENCODE_BANCADA: "1",
    OPENCODE_BANCADA_STATE: state,
    OPENCODE_BANCADA_CONFIG: path.join(root, "bancada.toml"),
    OPENCODE_BANCADA_SELF: `http://127.0.0.1:${spec.port}`,
    ...(spec.hub ? { OPENCODE_HUB: "1" } : {}),
    ...(hubPort
      ? { OPENCODE_SUMMARY_HUB: `http://127.0.0.1:${hubPort}`, OPENCODE_SUMMARY_HUB_PASSWORD: password }
      : {}),
  }
  const child = Bun.spawn([binary, "serve", "--hostname", "127.0.0.1", "--port", String(spec.port)], {
    cwd: root,
    env,
    stdout: Bun.file(path.join(root, "server.log")),
    stderr: Bun.file(path.join(root, "server.log")),
  })
  const base = `http://127.0.0.1:${spec.port}`
  servers.set(spec.name, { process: child, port: spec.port, base, state, root })
  await until(
    async () => (await rpcResponse(spec.name, "custom.bancada/wake", {}).catch(() => undefined))?.status === 200,
    90_000,
  )
  log(`${spec.name} up on ${spec.port}`)
}

const headers = { authorization: `Basic ${btoa(`opencode:${password}`)}`, "content-type": "application/json" }
function rpcResponse(name: string, route: string, input: unknown) {
  const server = servers.get(name)!
  const url = new URL(`/api/rpc/${route}`, server.base)
  url.searchParams.set("location[directory]", path.join(server.root, "repo"))
  return fetch(url, { method: "POST", headers, body: JSON.stringify({ input }), signal: AbortSignal.timeout(130_000) })
}
async function rpc<T>(name: string, route: string, input: unknown) {
  const response = await rpcResponse(name, route, input)
  const body = (await response.json()) as { output?: T; error?: unknown }
  if (!response.ok) throw new Error(`${route}: ${response.status} ${JSON.stringify(body)}`)
  return body.output as T
}

/** The example project, committed, as a session's repository on that server. */
async function repository(name: string, extra = "") {
  const repo = path.join(servers.get(name)!.root, "repo")
  await fs.rm(repo, { recursive: true, force: true })
  await fs.cp(example, repo, { recursive: true })
  if (extra) await fs.appendFile(path.join(repo, ".bancada.toml"), extra)
  for (const argv of [
    ["init", "-q"],
    ["add", "-A"],
    ["-c", "user.name=Bancada", "-c", "user.email=bancada@example.invalid", "commit", "-q", "-m", "exemplo"],
  ])
    Bun.spawnSync(["git", ...argv], { cwd: repo })
  return repo
}

async function session(name: string, title: string) {
  const server = servers.get(name)!
  const response = await fetch(new URL("/api/session", server.base), {
    method: "POST",
    headers,
    body: JSON.stringify({ title, location: { directory: path.join(server.root, "repo") } }),
  })
  return ((await response.json()) as { data: { id: string } }).data.id
}

async function synthetic(name: string, sessionID: string) {
  const server = servers.get(name)!
  const body = (await fetch(new URL(`/api/session/${sessionID}/message`, server.base), { headers }).then((response) =>
    response.json(),
  )) as { data: { type: string; text?: string }[] }
  return body.data.filter((message) => message.type === "synthetic" && message.text?.startsWith("[Bancada]"))
}

async function submit(name: string, sessionID: string, tests: string[], args: Record<string, string[]> = {}) {
  const submitted = await rpc<{ job: string }>(name, "custom.bancada/submit", {
    id: `j-${Array.from(crypto.getRandomValues(new Uint8Array(8)), (byte) => "0123456789abcdefghjkmnpqrstvwxyz"[byte % 32]).join("")}`,
    sessionID,
    diretorio: path.join(servers.get(name)!.root, "repo"),
    testes: tests.map((teste) => ({ teste, ...(args[teste] ? { args: args[teste] } : {}) })),
  })
  log(`${name}: ${submitted.job} asked (${tests.join(", ")})`)
  return submitted.job
}

/** Waits for the notice in the session; the text of every Bancada message in it. */
async function notice(name: string, sessionID: string, ms: number) {
  await until(async () => (await synthetic(name, sessionID)).length > 0, ms)
  // A second copy would come within a lease (30 s): wait for the request to be delivered, then a little more.
  await until(
    async () => (await rpc<{ jobs: unknown[] }>(name, "custom.bancada/status", { sessionID })).jobs.length === 0,
    120_000,
  )
  await Bun.sleep(5_000)
  return (await synthetic(name, sessionID)).map((message) => message.text!)
}

function record(scenario: string, ok: boolean, detail: string) {
  results.push({ scenario, ok, detail })
  log(`${ok ? "PASS" : "FAIL"} ${scenario}: ${detail}`)
}

async function until(condition: () => Promise<boolean>, ms: number) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (await condition().catch(() => false)) return
    await Bun.sleep(1_000)
  }
  throw new Error(`condition not met in ${Math.round(ms / 1000)} s`)
}

async function stop(name: string) {
  const server = servers.get(name)
  if (!server) return
  server.process.kill("SIGTERM")
  await server.process.exited
  // Its Bancada process leaves within 2 s of its server; anything later is killed by its pid.
  const info = (await Bun.file(path.join(server.state, "bancada.json"))
    .json()
    .catch(() => undefined)) as { pid?: number } | undefined
  await Bun.sleep(4_000)
  if (info?.pid) {
    try {
      process.kill(info.pid, "SIGKILL")
    } catch {
      // Gone already.
    }
  }
}

/** The Bancada's own processes of the pair (by their folder), and devices and containers with the test prefix. */
async function leftovers() {
  const ps = Bun.spawnSync(["ps", "-axo", "pid=,args="]).stdout.toString()
  const processes = ps.split("\n").filter((line) => line.includes(scratch) && !line.includes("e2e-bancada"))
  const found = [...processes.map((line) => `process: ${line.trim()}`)]
  if (pair === "mac") {
    const sdk = path.join(process.env.HOME!, "Library/Android/sdk")
    const avds = Bun.spawnSync([path.join(sdk, "emulator/emulator"), "-list-avds"]).stdout.toString()
    const sims = Bun.spawnSync(["/usr/bin/xcrun", "simctl", "list", "devices"]).stdout.toString()
    found.push(
      ...[...avds.split("\n"), ...sims.split("\n")]
        .filter((line) => line.includes("bancada-test-"))
        .map((line) => `device: ${line.trim()}`),
    )
    found.push(
      ...ps
        .split("\n")
        .filter((line) => /qemu-system.*-avd bancada-test-/.test(line))
        .map((line) => `emulator: ${line.trim()}`),
    )
  } else {
    const containers = Bun.spawnSync([
      "docker",
      "ps",
      "-a",
      "--filter",
      "label=purpose=bancada-test",
      "--format",
      "{{.Names}}",
    ]).stdout.toString()
    const volumes = Bun.spawnSync([
      "docker",
      "volume",
      "ls",
      "--filter",
      "label=purpose=bancada-test",
      "--format",
      "{{.Name}}",
    ]).stdout.toString()
    found.push(
      ...containers
        .split("\n")
        .filter(Boolean)
        .map((name) => `container: ${name}`),
    )
    found.push(
      ...volumes
        .split("\n")
        .filter(Boolean)
        .map((name) => `volume: ${name}`),
    )
  }
  return found
}

/** Deletes what the pair made: AVDs and simulators `bancada-test-…`, containers and volumes with the test label. */
async function clean() {
  if (pair === "mac") {
    const sdk = path.join(process.env.HOME!, "Library/Android/sdk")
    const avds = Bun.spawnSync([path.join(sdk, "emulator/emulator"), "-list-avds"]).stdout.toString()
    for (const avd of avds.split("\n").filter((line) => line.startsWith("bancada-test-")))
      Bun.spawnSync([path.join(sdk, "cmdline-tools/latest/bin/avdmanager"), "delete", "avd", "-n", avd], {
        env: {
          ...process.env,
          JAVA_HOME: "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
          ANDROID_SDK_ROOT: sdk,
        },
      })
    const listed = JSON.parse(
      Bun.spawnSync(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"]).stdout.toString(),
    ) as {
      devices: Record<string, { udid: string; name: string }[]>
    }
    for (const device of Object.values(listed.devices)
      .flat()
      .filter((item) => item.name.startsWith("bancada-test-"))) {
      Bun.spawnSync(["/usr/bin/xcrun", "simctl", "shutdown", device.udid])
      Bun.spawnSync(["/usr/bin/xcrun", "simctl", "delete", device.udid])
    }
  } else {
    const containers = Bun.spawnSync(["docker", "ps", "-aq", "--filter", "label=purpose=bancada-test"])
      .stdout.toString()
      .split("\n")
      .filter(Boolean)
    if (containers.length) Bun.spawnSync(["docker", "rm", "-f", ...containers])
    const volumes = Bun.spawnSync(["docker", "volume", "ls", "-q", "--filter", "label=purpose=bancada-test"])
      .stdout.toString()
      .split("\n")
      .filter(Boolean)
    if (volumes.length) Bun.spawnSync(["docker", "volume", "rm", "-f", ...volumes])
  }
}

const times = `[tempos]\nsilenciosa_s = 20\nincerto_s = 60\nperdido_s = 300\nmodo_local_s = 30\n`

async function mac() {
  await start({
    name: "mhub",
    port: 47_511,
    hub: true,
    machine: `versao = 1\nprefixo = "bancada-test-mhub-"\nnao_oferecer = ["android", "ios"]\n[orcamento]\nmemoria_gb = 8\ncpu = 4\n[portas]\nemulador = "5720-5739"\nprojeto = "48100-48199"\n${times}`,
  })
  await start(
    {
      name: "mmaq",
      port: 47_512,
      hub: false,
      machine: `versao = 1\nprefixo = "bancada-test-mmaq-"\n[orcamento]\nmemoria_gb = 24\ncpu = 8\nmax_android = 1\nmax_ios = 1\n[execucao]\nmodo = "processo"\n[portas]\nemulador = "5740-5759"\nprojeto = "48200-48299"\n${times}`,
    },
    47_511,
  )
  await repository("mhub")
  const sessionID = await session("mhub", "Bancada de verdade no Mac")
  // Discovery publishes android and ios a moment after the start.
  await until(async () => {
    const queue = await rpc<{ machines: { server: { name: string } }[] }>("mhub", "custom.bancada/queue", {})
    return queue.machines.length >= 2
  }, 120_000)
  await Bun.sleep(10_000)
  const job = await submit("mhub", sessionID, ["android", "ios"])
  const texts = await notice("mhub", sessionID, 40 * 60_000)
  const left = (await leftovers()).filter((item) => item.startsWith("emulator:"))
  record(
    "Mac de verdade",
    texts.length === 1 && texts[0]!.startsWith(`[Bancada] ${job} terminou: aprovado`) && left.length === 0,
    `${texts.length} aviso(s): ${texts.map((text) => text.split("\n").slice(0, 3).join(" / ")).join(" | ")}; emuladores ligados depois: ${left.length}`,
  )
}

async function linux() {
  await start({
    name: "lhub",
    port: 47_521,
    hub: true,
    machine: `versao = 1\nprefixo = "bancada-test-lhub-"\nrotulos = ["purpose=bancada-test"]\n[orcamento]\nmemoria_gb = 16\ncpu = 8\nmax_android = 1\n[execucao]\nmodo = "docker"\ncpus = 4\nmemoria_gb = 6\n[android.docker]\nimagem = "opencode-android:emu37.2.13-api36-google-r7"\nrede = "opencode-android-private"\ncpus_por_emulador = 4\nmemoria_por_emulador_gb = 6\n[portas]\nemulador = "5760-5779"\nprojeto = "48300-48399"\n${times}`,
  })
  await start(
    {
      name: "lmaq",
      port: 47_522,
      hub: false,
      machine: `versao = 1\nprefixo = "bancada-test-lmaq-"\netiquetas = ["so-na-maq"]\nnao_oferecer = ["android", "docker"]\n[orcamento]\nmemoria_gb = 8\ncpu = 4\n[execucao]\nmodo = "processo"\n[portas]\nemulador = "5780-5799"\nprojeto = "48400-48499"\n${times}`,
    },
    47_521,
  )
  const extra = `\n[teste.reinicio]\nherda = "simples"\nrotulo = "Reinício"\nprecisa = ["so-na-maq"]\nargs = ["--dorme", "40"]\n`
  await repository("lhub", extra)
  await repository("lmaq", extra)
  await until(async () => {
    const queue = await rpc<{ machines: unknown[] }>("lhub", "custom.bancada/queue", {})
    return queue.machines.length >= 2
  }, 120_000)
  await Bun.sleep(10_000)

  // host-6: android from the machine's session runs on the hub, in a sibling container, with an emulator container.
  {
    const sessionID = await session("lmaq", "Android em contêiner")
    const job = await submit("lmaq", sessionID, ["android"])
    const seen = { run: "", emulator: "" }
    const watcher = (async () => {
      for (const _ of Array.from({ length: 900 })) {
        const listed = Bun.spawnSync([
          "docker",
          "ps",
          "--filter",
          "label=purpose=bancada-test",
          "--format",
          "{{.Names}}",
        ]).stdout.toString()
        for (const name of listed.split("\n").filter(Boolean)) {
          const inspected = Bun.spawnSync([
            "docker",
            "inspect",
            name,
            "--format",
            "{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.PidsLimit}} {{json .Config.Labels}}",
          ])
            .stdout.toString()
            .trim()
          if (name.includes("-run-")) seen.run ||= `${name}: ${inspected}`
          if (name.includes("-emu-")) seen.emulator ||= `${name}: ${inspected}`
        }
        if (seen.run && seen.emulator) return
        await Bun.sleep(2_000)
      }
    })()
    const texts = await notice("lmaq", sessionID, 40 * 60_000)
    await watcher.catch(() => undefined)
    await Bun.sleep(20_000)
    const containers = (await leftovers()).filter((item) => item.startsWith("container:"))
    record(
      "host-6 de verdade",
      texts.length === 1 &&
        texts[0]!.startsWith(`[Bancada] ${job} terminou: aprovado`) &&
        seen.run.includes(" 4000000000 6442450944 2048 ") &&
        seen.emulator !== "" &&
        containers.length === 0,
      `${texts.length} aviso(s): ${texts.map((text) => text.split("\n").slice(0, 2).join(" / ")).join(" | ")}; execução: ${seen.run}; emulador: ${seen.emulator.split(" ")[0]}; contêineres depois: ${containers.length}`,
    )
  }

  // The executor's server restarted mid-run: the run goes on, one result.
  {
    const sessionID = await session("lhub", "Reinício no meio")
    const job = await submit("lhub", sessionID, ["reinicio"])
    await until(async () => {
      const status = await rpc<{ jobs: { parts: Record<string, { state: string }> }[] }>(
        "lhub",
        "custom.bancada/status",
        { job },
      )
      return status.jobs[0]?.parts.reinicio?.state === "rodando"
    }, 300_000)
    await Bun.sleep(5_000)
    const maq = servers.get("lmaq")!
    maq.process.kill("SIGKILL")
    await maq.process.exited
    log("lmaq's server killed mid-run")
    await Bun.sleep(8_000)
    servers.delete("lmaq")
    await start(
      {
        name: "lmaq",
        port: 47_522,
        hub: false,
        machine: await Bun.file(path.join(maq.root, "bancada.toml")).text(),
      },
      47_521,
    )
    const texts = await notice("lhub", sessionID, 10 * 60_000)
    record(
      "reinício no meio",
      texts.length === 1 && texts[0]!.startsWith(`[Bancada] ${job} terminou: aprovado`),
      `${texts.length} aviso(s): ${texts.map((text) => text.split("\n").slice(0, 2).join(" / ")).join(" | ")}`,
    )
  }

  // The origin's process dies between the session's message and its ack: one message.
  {
    const sessionID = await session("lmaq", "Aviso uma vez")
    await Bun.write(path.join(servers.get("lmaq")!.state, "teste-morre-no-ack"), "1")
    const job = await submit("lmaq", sessionID, ["simples"])
    const texts = await notice("lmaq", sessionID, 10 * 60_000)
    const died = (await Bun.file(path.join(servers.get("lmaq")!.state, "bancada.log")).text()).includes(
      `dying before the ack of ${job}`,
    )
    record(
      "aviso uma vez",
      died && texts.length === 1 && texts[0]!.startsWith(`[Bancada] ${job} terminou: aprovado`),
      `o processo morreu antes do ack: ${died}; ${texts.length} mensagem(ns)`,
    )
  }
}

try {
  await fs.mkdir(scratch, { recursive: true })
  await (pair === "mac" ? mac() : linux())
} catch (error) {
  record("execução", false, String(error))
} finally {
  for (const name of [...servers.keys()]) await stop(name)
  await clean()
  const left = await leftovers()
  log(left.length ? `LEFT BEHIND:\n${left.join("\n")}` : "nothing left behind")
  if (left.length) results.push({ scenario: "limpeza", ok: false, detail: left.join("; ") })
  console.log(JSON.stringify(results, null, 2))
  process.exit(results.every((item) => item.ok) ? 0 : 1)
}
