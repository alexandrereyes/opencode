import { describe, expect, test } from "bun:test"
import { emulatorArgv } from "../src/bancada/daemon/devices/android-docker"

describe("an emulator's command line", () => {
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
