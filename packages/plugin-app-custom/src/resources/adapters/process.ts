import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"

/** Runs a command without a shell and returns its stdout; throws with stderr on failure or timeout. */
export async function run(
  command: readonly string[],
  options: { readonly timeout?: number; readonly cwd?: string } = {},
) {
  const child = Bun.spawn([...command], { stdout: "pipe", stderr: "pipe", stdin: "ignore", cwd: options.cwd })
  const timer = setTimeout(() => child.kill(), options.timeout ?? 15_000)
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).arrayBuffer().then((buffer) => new Uint8Array(buffer)),
    new Response(child.stderr).text(),
    child.exited,
  ]).finally(() => clearTimeout(timer))
  if (code !== 0) throw new Error(`${path.basename(command[0] ?? "")} exited ${code}: ${stderr.trim().slice(0, 500)}`)
  return stdout
}

export async function text(
  command: readonly string[],
  options: { readonly timeout?: number; readonly cwd?: string } = {},
) {
  return new TextDecoder().decode(await run(command, options))
}

/** Converts and shrinks an image to JPEG with macOS `sips`; returns the input when no resize is needed. */
export async function jpeg(data: Uint8Array<ArrayBuffer>, maxWidth?: number) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-resource-"))
  try {
    const input = path.join(directory, "in")
    const output = path.join(directory, "out.jpg")
    await Bun.write(input, data)
    await run([
      "/usr/bin/sips",
      "-s",
      "format",
      "jpeg",
      "-s",
      "formatOptions",
      "70",
      ...(maxWidth ? ["--resampleWidth", String(maxWidth)] : []),
      input,
      "--out",
      output,
    ])
    return new Uint8Array(await Bun.file(output).arrayBuffer())
  } finally {
    await fs.rm(directory, { recursive: true, force: true })
  }
}

/** Pixel size of a PNG or baseline/progressive JPEG, without decoding it. */
export function size(data: Uint8Array) {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength)
  if (data.byteLength > 24 && view.getUint32(0) === 0x89504e47)
    return { width: view.getUint32(16), height: view.getUint32(20) }
  if (data.byteLength < 4 || view.getUint16(0) !== 0xffd8) return undefined
  const sof = (marker: number) => marker >= 0xffc0 && marker <= 0xffcf && ![0xffc4, 0xffc8, 0xffcc].includes(marker)
  for (let offset = 2; offset + 9 < data.byteLength; ) {
    const marker = view.getUint16(offset)
    const length = view.getUint16(offset + 2)
    if (sof(marker)) return { width: view.getUint16(offset + 7), height: view.getUint16(offset + 5) }
    offset += 2 + length
  }
  return undefined
}
