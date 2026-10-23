import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

await mkdir(join(tmpdir(), "opencode"), { recursive: true })
const temporary = await mkdtemp(join(tmpdir(), "opencode/markdown-engines-"))
const output = join(import.meta.dir, "../OpenCode/Resources/Markdown")
try {
  await Bun.write(join(temporary, "package.json"), JSON.stringify({
    private: true,
    dependencies: { "highlight.js": "11.11.1", "beautiful-mermaid": "1.1.3", esbuild: "0.25.12" },
    overrides: { elkjs: "0.11.0", entities: "7.0.1" },
  }))
  if (await Bun.spawn(["bun", "install", "--ignore-scripts"], { cwd: temporary, stdout: "inherit", stderr: "inherit" }).exited !== 0) {
    throw new Error("Não foi possível instalar os motores de Markdown")
  }
  await Bun.write(join(temporary, "entry.ts"), Bun.file(join(import.meta.dir, "markdown-engines.entry.ts")))
  if (await Bun.spawn([join(temporary, "node_modules/.bin/esbuild"), "entry.ts", "--bundle", "--platform=browser", "--format=iife", "--minify", `--outfile=${join(output, "dist/markdown-engines.js")}`],
    { cwd: temporary, stdout: "inherit", stderr: "inherit" }).exited !== 0) {
    throw new Error("Não foi possível gerar o bundle de Markdown")
  }
  for (const [name, license] of [["highlight.js", "LICENSE"], ["beautiful-mermaid", "LICENSE"], ["elkjs", "LICENSE.md"], ["entities", "LICENSE"]]) {
    await Bun.write(join(output, "Licenses", `${name}-${license}.txt`), Bun.file(join(temporary, "node_modules", name!, license!)))
  }
} finally {
  await rm(temporary, { recursive: true, force: true })
}
