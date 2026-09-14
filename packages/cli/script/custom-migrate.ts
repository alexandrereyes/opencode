import { chmod, copyFile, lstat, mkdir, readlink, rename, rm, symlink } from "node:fs/promises"
import { randomUUID } from "node:crypto"
import path from "node:path"
import os from "node:os"
import { activate, command, label, manifest, pointer, portFree, quote } from "./custom-release"

const oldLabel = "local.opencode.custom-service"

export type MigrationHost = {
  validateOld: (file: string, launcher: string) => Promise<void>
  stopOld: () => Promise<void>
  beta: (binary: string) => Promise<number | undefined>
  stopBeta: (pid: number) => Promise<void>
  activate: (commit: string) => Promise<void>
}

export async function migrate(
  home: string,
  user: string,
  options: { dryRun?: boolean; replaceLauncher?: boolean; stopBeta?: boolean },
  host = nativeHost(home),
) {
  const commit = await pointer(home, "prepared")
  if (!commit) throw new Error("Prepare a compact release before migration")
  await manifest(home, commit)
  const oldPlist = `${user}/Library/LaunchAgents/${oldLabel}.plist`
  const exists = await lstat(oldPlist)
    .then(() => true)
    .catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return false
      throw error
    })
  if (exists) await host.validateOld(oldPlist, `${home}/bin/serve.sh`)
  const environment = Object.fromEntries(
    (await Bun.file(`${home}/environment.sh`).text())
      .trim()
      .split("\n")
      .map((line) => {
        const match = /^export ([A-Z_][A-Z0-9_]*)=(.*)$/.exec(line)
        if (!match) throw new Error("Unrecognized legacy environment syntax; refusing to execute it")
        const value = match[2].slice(1, -1).replaceAll("'\\''", "'")
        if (quote(value) !== match[2]) throw new Error("Unsupported legacy shell expression")
        return [match[1], value]
      }),
  )
  const database = environment.OPENCODE_DB
  const config = environment.OPENCODE_CONFIG_DIR
  if (!database || !path.isAbsolute(database) || !config || !path.isAbsolute(config))
    throw new Error("Legacy database/config paths must be absolute")
  if (!(await Bun.file(database).exists())) throw new Error("Legacy database is missing")
  const service: unknown = await Bun.file(`${home}/config/opencode/service-custom.json`).json()
  if (
    typeof service !== "object" ||
    service === null ||
    !("password" in service) ||
    typeof service.password !== "string" ||
    !service.password ||
    !("port" in service) ||
    service.port !== 4178
  )
    throw new Error("Unexpected legacy credential/port configuration")
  const launcher = `${user}/.opencode/bin/opencode2`
  const beta = await host.beta(launcher)
  if (options.dryRun) {
    console.log(
      JSON.stringify(
        {
          action: "migrate",
          commit,
          oldLabel: exists ? oldLabel : "already retired",
          database,
          config,
          proxy: "4096 unchanged",
          beta: beta ? "4097 requires --stop-beta" : "absent",
          launcher,
          requires: "--replace-launcher",
        },
        null,
        2,
      ),
    )
    return
  }
  if (!options.replaceLauncher) throw new Error("Migration requires --replace-launcher")
  if (beta && !options.stopBeta) throw new Error("Known beta on 4097 requires --stop-beta")
  const password = Bun.file(`${home}/password`)
  if ((await password.exists()) && (await password.text()).trim() !== service.password)
    throw new Error("Existing runtime password differs; refusing to replace it")
  if (!(await password.exists())) await Bun.write(password, service.password, { mode: 0o600 })
  await chmod(password.name!, 0o600)
  const desired = {
    port: 4178,
    database,
    config,
    environment: Object.fromEntries(
      Object.entries(environment).filter(
        ([key]) => !["OPENCODE_BUILD_BUN", "OPENCODE_DISTRIBUTION_HOME", "OPENCODE_TUI_UPDATER"].includes(key),
      ),
    ),
  }
  const manual = Bun.file(`${home}/manual.json`)
  if (await manual.exists()) {
    const previous: unknown = await manual.json()
    if (
      typeof previous !== "object" ||
      previous === null ||
      !("database" in previous) ||
      previous.database !== database ||
      !("config" in previous) ||
      previous.config !== config ||
      !("port" in previous) ||
      previous.port !== 4178
    )
      throw new Error("manual.json differs from legacy persistence; refusing to overwrite")
  }
  if (!(await manual.exists())) await Bun.write(manual, JSON.stringify(desired, null, 2), { mode: 0o600 })
  await chmod(manual.name!, 0o600)
  await mkdir(`${home}/migration`, { recursive: true, mode: 0o700 })
  await mkdir(path.dirname(launcher), { recursive: true })
  await mkdir(`${user}/Library/LaunchAgents`, { recursive: true })
  // A failed beta shutdown must leave the primary web service available.
  if (beta) await host.stopBeta(beta)
  if (exists) {
    await host.stopOld()
    await rename(oldPlist, `${home}/migration/${oldLabel}.plist`)
  }
  for (const name of ["current", "previous"]) {
    const current = await pointer(home, name)
    if (current && !(await Bun.file(`${home}/releases/${current}/manual-release.json`).exists()))
      await rename(`${home}/${name}`, `${home}/legacy-${name}-${randomUUID()}`)
  }
  await host.activate(commit)
  await installLink(`${home}/bin/opencode2`, launcher)
  await installLink(`${home}/${label}.plist`, `${user}/Library/LaunchAgents/${label}.plist`)
  console.log("Migration complete; legacy files/data retained, proxy unchanged")
}

export async function installLink(target: string, destination: string) {
  if ((await readlink(destination).catch(() => undefined)) === target) return
  await mkdir(path.dirname(destination), { recursive: true })
  const existing = await lstat(destination).catch(() => undefined)
  if (existing) {
    const backup = `${destination}.pre-custom-${randomUUID()}`
    await (existing.isSymbolicLink() ? symlink(await readlink(destination), backup) : copyFile(destination, backup))
  }
  const temporary = `${destination}.${randomUUID()}`
  await symlink(target, temporary)
  await rename(temporary, destination).finally(() => rm(temporary, { force: true }))
}

function nativeHost(home: string): MigrationHost {
  const domain = `gui/${process.getuid!()}`
  return {
    async validateOld(file, launcher) {
      const input: unknown = JSON.parse(await command(["plutil", "-convert", "json", "-o", "-", file]))
      if (
        typeof input !== "object" ||
        input === null ||
        !("Label" in input) ||
        input.Label !== oldLabel ||
        !("ProgramArguments" in input) ||
        JSON.stringify(input.ProgramArguments) !== JSON.stringify(["/bin/sh", launcher])
      )
        throw new Error("Unknown legacy LaunchAgent; refusing migration")
      const process = Bun.spawn(["launchctl", "print", `${domain}/${oldLabel}`], { stdout: "pipe", stderr: "ignore" })
      const loaded = await new Response(process.stdout).text()
      if ((await process.exited) === 0) {
        const args = loaded
          .match(/arguments = \{([^}]+)\}/)?.[1]
          .trim()
          .split("\n")
          .map((line) => line.trim())
        if (
          loaded.match(/^\s*program = (.+)$/m)?.[1] !== "/bin/sh" ||
          JSON.stringify(args) !== JSON.stringify(["/bin/sh", launcher])
        )
          throw new Error("Loaded legacy job differs from its plist")
      }
    },
    async stopOld() {
      const loaded = Bun.spawn(["launchctl", "print", `${domain}/${oldLabel}`], { stdout: "ignore", stderr: "ignore" })
      if ((await loaded.exited) === 0) await command(["launchctl", "bootout", `${domain}/${oldLabel}`])
      for (let attempt = 0; !portFree(4178); attempt++) {
        if (attempt === 120) throw new Error("Legacy process still owns 4178; migration stopped")
        await Bun.sleep(1000)
      }
    },
    async beta(binary) {
      const child = Bun.spawn(["lsof", "-nP", "-tiTCP:4097", "-sTCP:LISTEN"], { stdout: "pipe", stderr: "ignore" })
      const output = (await new Response(child.stdout).text()).trim()
      await child.exited
      if (!output) return
      if (!/^\d+$/.test(output)) throw new Error("Multiple/unknown listeners on 4097")
      const processCommand = await command(["ps", "-p", output, "-o", "command="])
      if (processCommand !== `${binary} serve --service`)
        throw new Error("Unknown process on 4097; refusing to stop it")
      return Number(output)
    },
    async stopBeta(pid) {
      if (
        (await command(["ps", "-p", String(pid), "-o", "command="])) !==
        `${os.homedir()}/.opencode/bin/opencode2 serve --service`
      )
        throw new Error("Beta process identity changed; refusing to signal")
      process.kill(pid, "SIGTERM")
      for (let attempt = 0; !portFree(4097); attempt++) {
        if (attempt === 60) throw new Error("Beta did not exit")
        await Bun.sleep(1000)
      }
    },
    async activate(commit) {
      await activate(home, commit, {})
    },
  }
}
