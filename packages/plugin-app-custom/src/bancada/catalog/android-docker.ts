/**
 * The script of an emulator's container on host-6 (`devices/android-docker.ts`), born as a copy of AbacatoV3's
 * `.agents/skills/e2e/scripts/linux/emulators.sh` for one emulator: the AVD (`BANCADA_AVD`) made in the volume on the
 * first start, the light profile with SwiftShader, an adb server on every interface of the container, the emulator in
 * the foreground (the container ends with it).
 */
export const emulatorScript = `set -euo pipefail
cores=\${ANDROID_EMULATOR_CORES:-2}
memory=\${ANDROID_EMULATOR_MEMORY_MB:-2048}
export XDG_CACHE_HOME=/tmp/android-cache XDG_RUNTIME_DIR=/tmp/android-runtime TMPDIR=/tmp
mkdir -p "$ANDROID_AVD_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" /tmp/android-unknown
chmod 700 "$XDG_RUNTIME_DIR"
name=\${BANCADA_AVD:-e2e-1}
[ -e "$ANDROID_AVD_HOME/$name.ini" ] || printf 'no\\n' | avdmanager create avd --name "$name" --package "$ANDROID_SYSTEM_IMAGE" --device pixel_6 >/dev/null
python3 - "$ANDROID_AVD_HOME/$name.avd/config.ini" "$cores" "$memory" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
config = {k.strip(): v.strip() for k, v in (l.split('=', 1) for l in path.read_text().splitlines() if '=' in l)}
config.update({'hw.lcd.width': '720', 'hw.lcd.height': '1600', 'hw.lcd.density': '280',
               'hw.lcd.vsync': '30', 'hw.cpu.ncore': sys.argv[2], 'hw.ramSize': sys.argv[3],
               'hw.gpu.enabled': 'yes', 'hw.gpu.mode': 'swiftshader', 'showDeviceFrame': 'no',
               'skin.name': '720x1600', 'skin.path': '720x1600'})
path.write_text(''.join(f'{k}={v}\\n' for k, v in config.items()))
PY
unset ADB_SERVER_SOCKET
adb -a -P 5037 nodaemon server &
sleep 2
exec emulator -avd "$name" -port 5554 -accel on -no-window -no-audio -no-boot-anim \\
  -no-snapshot -no-metrics -gpu swiftshader -camera-back none -camera-front none \\
  -cores "$cores" -memory "$memory" \${EMU_EXTRA:-} >/tmp/emulator.log 2>&1
`
