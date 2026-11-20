import os from "node:os"
import path from "node:path"

/**
 * Executions in sibling containers (`docs/bancada.md`, "Execution", the Docker mode of host-6): the same image as the
 * server's container and its binary as the entrypoint, the attempt's folder, the working folders and a home of the
 * Bancada's own mounted at the same absolute paths (the subpath of the volume that holds them, never the rest of it),
 * no Docker socket, limits, labels. Not removed when it ends: the ended container keeps the exit code and whether it
 * ran out of memory, which the ending reads; the cleanup removes it.
 */

export type Mount = {
  readonly type: string
  readonly name?: string
  readonly source?: string
  readonly destination: string
}

export type Execution = {
  readonly name: string
  readonly image: string
  readonly entrypoint: string
  readonly args: ReadonlyArray<string>
  readonly cwd: string
  readonly user: string
  readonly labels: ReadonlyArray<string>
  readonly limits: { readonly cpus: number; readonly memMb: number; readonly pids: number; readonly low: boolean }
  readonly network?: string
  readonly mounts: ReadonlyArray<string>
  readonly env: Readonly<Record<string, string>>
}

/** The `docker run` of an execution (pure: the tests read it as it is). */
export function runArgv(execution: Execution) {
  return [
    "run",
    "-d",
    "--name",
    execution.name,
    ...execution.labels.flatMap((label) => ["--label", label]),
    "--user",
    execution.user,
    "--cap-drop",
    "ALL",
    "--security-opt",
    "no-new-privileges:true",
    "--cpus",
    String(execution.limits.cpus),
    "--memory",
    `${execution.limits.memMb}m`,
    "--pids-limit",
    String(execution.limits.pids),
    ...(execution.limits.low ? ["--cpu-shares", "256"] : []),
    ...(execution.network ? ["--network", execution.network] : []),
    ...execution.mounts.flatMap((mount) => ["--mount", mount]),
    ...Object.entries(execution.env).flatMap(([name, value]) => ["-e", `${name}=${value}`]),
    "-w",
    execution.cwd,
    "--entrypoint",
    execution.entrypoint,
    execution.image,
    ...execution.args,
  ]
}

/**
 * The `--mount` that shows `folder` at the same path in a sibling: the subpath of the volume of this container that
 * holds it, or the host folder behind a bind. Undefined when no mount of this container holds it.
 */
export function mountFor(folder: string, mounts: ReadonlyArray<Mount>) {
  const holder = mounts
    .filter((mount) => folder === mount.destination || folder.startsWith(`${mount.destination}/`))
    .toSorted((a, b) => b.destination.length - a.destination.length)[0]
  if (!holder) return undefined
  const relative = path.relative(holder.destination, folder)
  if (holder.type === "volume" && holder.name)
    return `type=volume,src=${holder.name},dst=${folder}${relative ? `,volume-subpath=${relative}` : ""}`
  if (holder.type === "bind" && holder.source)
    return `type=bind,src=${path.join(holder.source, relative)},dst=${folder}`
  return undefined
}

/** How the Bancada process sees the Docker daemon: its own container (image, mounts) and `docker` itself. */
export function makeDocker(input: {
  readonly docker: string
  readonly run?: (argv: ReadonlyArray<string>) => Promise<{ code: number; stdout: string; stderr: string }>
}) {
  const run =
    input.run ??
    (async (argv: ReadonlyArray<string>) => {
      const child = Bun.spawn([input.docker, ...argv], {
        stdin: "ignore",
        stdout: "pipe",
        stderr: "pipe",
        timeout: 120_000,
      })
      const [stdout, stderr, code] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ])
      return { code, stdout, stderr }
    })
  return {
    run,
    /** This process's own container: its image and mounts (`docker inspect <hostname>`). */
    self: async () => {
      const inspected = await run(["inspect", os.hostname(), "--format", "{{json .Config.Image}}|{{json .Mounts}}"])
      if (inspected.code !== 0)
        throw new Error(`este processo não está num contêiner que o Docker conheça: ${inspected.stderr.trim()}`)
      const [image, mounts] = inspected.stdout.trim().split("|")
      return {
        image: JSON.parse(image!) as string,
        mounts: (JSON.parse(mounts!) as { Type: string; Name?: string; Source?: string; Destination: string }[]).map(
          (mount): Mount => ({
            type: mount.Type,
            ...(mount.Name ? { name: mount.Name } : {}),
            ...(mount.Source ? { source: mount.Source } : {}),
            destination: mount.Destination,
          }),
        ),
      }
    },
    /** A container's state: running, ended (with its exit code and whether memory ran out), absent, or unknown. */
    state: async (name: string) => {
      const inspected = await run([
        "inspect",
        name,
        "--format",
        "{{.State.Running}} {{.State.ExitCode}} {{.State.OOMKilled}}",
      ])
      if (inspected.code !== 0)
        return /no such (object|container)/i.test(inspected.stderr) ? ("absent" as const) : ("unknown" as const)
      const [running, exit, oom] = inspected.stdout.trim().split(" ")
      return { running: running === "true", exit: Number(exit), oom: oom === "true" }
    },
    /** A container's address on a network. */
    address: async (name: string, network: string) => {
      const inspected = await run([
        "inspect",
        name,
        "--format",
        `{{(index .NetworkSettings.Networks "${network}").IPAddress}}`,
      ])
      return inspected.code === 0 ? inspected.stdout.trim() || undefined : undefined
    },
  }
}

export type Docker = ReturnType<typeof makeDocker>

/**
 * The launcher's container side in the Docker mode: starts the runner in a sibling, tells whether it runs, stops and
 * removes it. The container is named after the attempt's group.
 */
export function dockerExecutions(input: {
  readonly docker: Docker
  readonly state: string
  readonly prefix: string
  readonly machineID: string
  readonly labels: ReadonlyArray<string>
  readonly limits: Execution["limits"]
  readonly network?: string
  readonly entrypoint: string
}) {
  const docker = input.docker
  const nameOf = (key: { job: string; group: string }) => `${input.prefix}run-${key.job}-${key.group}`.slice(0, 120)
  const self = { current: undefined as Awaited<ReturnType<Docker["self"]>> | undefined }
  return {
    nameOf,
    start: async (key: { job: string; group: string }, argv: ReadonlyArray<string>, dir: string, workdir: string) => {
      self.current ??= await docker.self()
      const home = path.join(input.state, "home")
      const folders = [dir, path.join(input.state, "work"), home]
      const mounts = folders.map((folder) => {
        const mount = mountFor(folder, self.current!.mounts)
        if (!mount) throw new Error(`${folder} não está num volume deste contêiner: o modo docker não pode montá-lo`)
        return mount
      })
      if (mountFor(input.entrypoint, self.current.mounts))
        throw new Error(`${input.entrypoint} está num volume: o modo docker precisa do binário na imagem`)
      const uid = process.getuid?.() ?? 1000
      const gid = process.getgid?.() ?? 1000
      const started = await docker.run(
        runArgv({
          name: nameOf(key),
          image: self.current.image,
          entrypoint: input.entrypoint,
          args: argv,
          cwd: workdir,
          user: `${uid}:${gid}`,
          labels: [`bancada.attempt=${key.job}/${key.group}`, `bancada.machine=${input.machineID}`, ...input.labels],
          limits: input.limits,
          ...(input.network ? { network: input.network } : {}),
          mounts,
          env: { HOME: home, BUN_BE_BUN: "1", BANCADA_DOCKER_LABEL: `bancada.job=${key.job}` },
        }),
      )
      if (started.code !== 0 && !/already in use/.test(started.stderr))
        throw new Error(`o contêiner da execução não partiu: ${started.stderr.trim()}`)
    },
    state: (key: { job: string; group: string }) => docker.state(nameOf(key)),
    stop: (key: { job: string; group: string }) => docker.run(["stop", "-t", "15", nameOf(key)]).then(() => undefined),
    remove: (key: { job: string; group: string }) => docker.run(["rm", "-f", nameOf(key)]).then(() => undefined),
    address: (key: { job: string; group: string }) =>
      input.network ? docker.address(nameOf(key), input.network) : Promise.resolve(undefined),
  }
}

export type DockerExecutions = ReturnType<typeof dockerExecutions>
