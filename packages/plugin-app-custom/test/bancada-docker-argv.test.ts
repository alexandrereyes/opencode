import { describe, expect, test } from "bun:test"
import { emulatorArgv } from "../src/bancada/daemon/devices/android-docker"
import { mountFor, runArgv } from "../src/bancada/daemon/launcher/docker"

const mounts = [
  {
    type: "volume",
    name: "opencode_fork-workspace",
    source: "/var/lib/docker/volumes/x/_data",
    destination: "/workspace",
  },
  { type: "bind", source: "/var/run/docker.sock", destination: "/var/run/docker.sock" },
  { type: "bind", source: "/srv/scratch", destination: "/scratch" },
]

describe("the Docker mode's command lines", () => {
  test("a folder shows at the same path in a sibling: the subpath of its volume, or the folder behind a bind", () => {
    expect(mountFor("/workspace/.local/state/opencode-bancada/work", mounts)).toBe(
      "type=volume,src=opencode_fork-workspace,dst=/workspace/.local/state/opencode-bancada/work,volume-subpath=.local/state/opencode-bancada/work",
    )
    expect(mountFor("/scratch/a/b", mounts)).toBe("type=bind,src=/srv/scratch/a/b,dst=/scratch/a/b")
    expect(mountFor("/opt/opencode/bin/opencode", mounts)).toBeUndefined()
  })

  test("an execution: the server's image and binary, labels, no capabilities, limits, the emulators' network", () => {
    expect(
      runArgv({
        name: "bancada-test-run-j-1-g1",
        image: "opencode-fork:abc-r20",
        entrypoint: "/opt/opencode/bin/opencode",
        args: ["/s/attempts/j-1/g1/runner.js", "--opencode-bancada-run", "/s/attempts/j-1/g1"],
        cwd: "/s/work/exemplo-1",
        user: "1000:1000",
        labels: ["bancada.attempt=j-1/g1", "bancada.machine=m", "purpose=bancada-test"],
        limits: { cpus: 8, memMb: 16_384, pids: 2_048, low: true },
        network: "opencode-android-private",
        mounts: ["type=volume,src=v,dst=/s/attempts/j-1/g1,volume-subpath=s/attempts/j-1/g1"],
        env: { HOME: "/s/home", BUN_BE_BUN: "1", BANCADA_DOCKER_LABEL: "bancada.job=j-1" },
      }).join(" "),
    ).toBe(
      [
        "run -d --name bancada-test-run-j-1-g1",
        "--label bancada.attempt=j-1/g1 --label bancada.machine=m --label purpose=bancada-test",
        "--user 1000:1000 --cap-drop ALL --security-opt no-new-privileges:true",
        "--cpus 8 --memory 16384m --pids-limit 2048 --cpu-shares 256 --network opencode-android-private",
        "--mount type=volume,src=v,dst=/s/attempts/j-1/g1,volume-subpath=s/attempts/j-1/g1",
        "-e HOME=/s/home -e BUN_BE_BUN=1 -e BANCADA_DOCKER_LABEL=bancada.job=j-1",
        "-w /s/work/exemplo-1 --entrypoint /opt/opencode/bin/opencode opencode-fork:abc-r20",
        "/s/attempts/j-1/g1/runner.js --opencode-bancada-run /s/attempts/j-1/g1",
      ].join(" "),
    )
  })

  test("an emulator's container: KVM and its group, no capabilities, limits, its volume, labels", () => {
    const argv = emulatorArgv({
      name: "bancada-test-emu-1",
      volume: "bancada-test-emu-1-avd",
      image: "opencode-android:emu37.2.13-api36-google-r7",
      network: "opencode-android-private",
      gid: "108",
      cpus: 4,
      memMb: 8_192,
      labels: ["bancada.device=bancada-test-emu-1", "bancada.machine=m", "purpose=bancada-test"],
    })
    expect(argv.slice(0, -1).join(" ")).toBe(
      [
        "run -d --name bancada-test-emu-1 --hostname bancada-test-emu-1 --network opencode-android-private",
        "--network-alias bancada-test-emu-1 --device /dev/kvm --group-add 108 --user 1000:1000 --cap-drop ALL",
        "--security-opt no-new-privileges:true --cpus 4 --memory 8192m --shm-size 1g --pids-limit 1024",
        "--tmpfs /tmp:rw,nosuid,nodev,size=2g,mode=1777 -v bancada-test-emu-1-avd:/home/android/.android",
        "-e BANCADA_AVD=bancada-test-emu-1 -e ANDROID_EMULATOR_CORES=2 -e ANDROID_EMULATOR_MEMORY_MB=2048",
        "--label bancada.device=bancada-test-emu-1 --label bancada.machine=m --label purpose=bancada-test",
        "--entrypoint bash opencode-android:emu37.2.13-api36-google-r7 -c",
      ].join(" "),
    )
    expect(argv.at(-1)).toContain('exec emulator -avd "$name" -port 5554 -accel on')
  })
})
