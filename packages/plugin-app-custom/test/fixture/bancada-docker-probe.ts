// By hand on host-6 (P13): one emulator container `bancada-test-probe-emu-1` as the Bancada starts it, a listener in a
// sibling on the same network, and whether the emulator reaches it with Wi-Fi on and off. Removes everything.
import { emulatorArgv } from "../../src/bancada/daemon/devices/android-docker"

const image = "opencode-android:emu37.2.13-api36-google-r7"
const network = "opencode-android-private"
const name = "bancada-test-probe-emu-1"
const listener = "bancada-test-probe-listen"
const run = (argv: string[]) => {
  const done = Bun.spawnSync(argv, { stdout: "pipe", stderr: "pipe" })
  return { code: done.exitCode, out: `${done.stdout.toString()}${done.stderr.toString()}`.trim() }
}
const adb = (...args: string[]) =>
  run(["/opt/android-sdk/platform-tools/adb", "-H", name, "-P", "5037", "-s", "emulator-5554", ...args])
try {
  const gid = run([
    "docker",
    "run",
    "--rm",
    "--device",
    "/dev/kvm",
    "--entrypoint",
    "stat",
    image,
    "-c",
    "%g",
    "/dev/kvm",
  ]).out
  run(["docker", "volume", "create", "--label", "purpose=bancada-test", `${name}-avd`])
  console.log(
    run([
      "docker",
      ...emulatorArgv({
        name,
        volume: `${name}-avd`,
        image,
        network,
        gid,
        cpus: 4,
        memMb: 6_144,
        labels: ["purpose=bancada-test"],
      }),
    ]).code,
  )
  console.log(
    run([
      "docker",
      "run",
      "-d",
      "--name",
      listener,
      "--label",
      "purpose=bancada-test",
      "--network",
      network,
      "--entrypoint",
      "bash",
      "opencode-fork:0278da4c93d6e04c6df49d0bfa98804effe02ef8-r20",
      "-c",
      "while true; do echo pronto | nc -l 48390; done",
    ]).out,
  )
  const ip = run([
    "docker",
    "inspect",
    listener,
    "--format",
    `{{(index .NetworkSettings.Networks "${network}").IPAddress}}`,
  ]).out
  console.log("listener at", ip)
  const deadline = Date.now() + 8 * 60_000
  while (Date.now() < deadline && adb("shell", "getprop", "sys.boot_completed").out !== "1") await Bun.sleep(3_000)
  console.log("booted:", adb("shell", "getprop", "sys.boot_completed").out)
  const started = Date.now()
  while (Date.now() - started < 180_000 && !adb("shell", `ip route get ${ip}`).out.includes(" dev "))
    await Bun.sleep(3_000)
  console.log(`route after ${Math.round((Date.now() - started) / 1000)} s:`, adb("shell", `ip route get ${ip}`).out)
  console.log("ip addr:", adb("shell", "ip -o -4 addr").out.replace(/\s+/g, " "))
  console.log("wifi on, read:", adb("shell", `toybox nc -w 3 ${ip} 48390 < /dev/null`).out)
  adb("shell", "setprop ctl.stop vendor.radio-ranchu")
  await Bun.sleep(5_000)
  console.log("radio stopped, read:", adb("shell", `toybox nc -w 3 ${ip} 48390 < /dev/null`).out)
  adb("shell", "svc wifi disable")
  await Bun.sleep(10_000)
  console.log(
    "wifi off, route:",
    adb("shell", `ip route get ${ip}`).out,
    "| read:",
    adb("shell", `toybox nc -w 3 ${ip} 48390 < /dev/null`).out,
  )
} finally {
  run(["docker", "rm", "-f", name, listener])
  run(["docker", "volume", "rm", "-f", `${name}-avd`])
  console.log(
    "left:",
    run(["docker", "ps", "-a", "--filter", "label=purpose=bancada-test", "--format", "{{.Names}}"]).out || "nothing",
  )
}
