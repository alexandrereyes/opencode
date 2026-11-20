/**
 * How the Bancada process sees the Docker daemon (host-6): the emulators' containers (`android-docker.ts`), this
 * process's own container on their network, and the containers a test started (`BANCADA_DOCKER_LABEL`).
 */
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
