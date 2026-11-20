import { describe, expect, test } from "bun:test"
import path from "node:path"
import { normalizeRemote, parseContract, partSpec, type Contract } from "../src/bancada/contract"

const example = path.join(import.meta.dir, "fixture/bancada-exemplo")
const modes = new Map([
  ["scripts/build", "100755"],
  ["scripts/plan", "100755"],
  ["scripts/run", "100755"],
  ["scripts/por-fora", "100755"],
  ["scripts/link", "120000"],
  ["scripts/sem-x", "100644"],
])
const read = (text: string) => parseContract(text, { project: "pasta", mode: (file) => modes.get(file) })
const valid = async (): Promise<Contract> => {
  const parsed = read(await Bun.file(path.join(example, ".bancada.toml")).text())
  if (!parsed.ok) throw new Error(parsed.problems.join("\n"))
  return parsed.contract
}

describe("project contract", () => {
  test("the example project's contract resolves inheritance, defaults and the parts the hub schedules", async () => {
    const contract = await valid()
    expect(contract).toMatchObject({
      version: 1,
      project: "bancada-exemplo",
      caches: ["cache/"],
      outside: ["scripts/por-fora"],
    })
    expect(Object.keys(contract.tests).toSorted()).toEqual([
      "android",
      "exclusivo",
      "fisico",
      "ios",
      "lento",
      "servidor",
      "simples",
    ])
    // A child takes its parent's fields and replaces the ones it defines; lists never add up.
    expect(contract.tests.lento).toMatchObject({
      label: "Lento",
      build: ["scripts/build"],
      run: ["scripts/run"],
      args: ["--dorme", "5"],
      devices: { min: 0, max: 0 },
    })
    expect(contract.tests.servidor).toMatchObject({
      label: "Android + servidor",
      needs: ["android", "docker"],
      plan: ["scripts/plan"],
      device: { api: ">=36", slim: "aceita" },
      devices: { min: 1, max: 2 },
    })
    expect(partSpec(contract.tests.servidor!, ["--filtro", "Voz"])).toEqual({
      part: "servidor",
      label: "Android + servidor",
      platform: "android",
      needs: ["android", "docker"],
      device: { api: ">=36", slim: "aceita" },
      devices: { min: 1, max: 2 },
      exclusive: [],
      unsafe: false,
      build: true,
      args: ["--server", "--filtro", "Voz"],
    })
    expect(
      Object.values(contract.tests).map((test) => [test.name, partSpec(test).platform, partSpec(test).unsafe]),
    ).toEqual([
      ["simples", "none", false],
      ["lento", "none", false],
      ["android", "android", false],
      ["ios", "ios", false],
      ["fisico", "android", true],
      ["exclusivo", "none", true],
      ["servidor", "android", false],
    ])
  })

  test("a symlinked command is left to run time; docker alone is fine for a test without devices", () => {
    expect(
      read(`versao = 1\n[teste.a]\nprecisa = ["docker"]\naparelhos = { min = 0, max = 0 }\nrun = "scripts/link"`),
    ).toMatchObject({ ok: true, contract: { tests: { a: { needs: ["docker"], run: ["scripts/link"] } } } })
  })

  test("without projeto the caller's name (the normalized remote or the folder) is the project", () => {
    expect(read(`versao = 1\n[teste.a]\naparelhos = { min = 0, max = 0 }\nrun = "scripts/run"`)).toMatchObject({
      ok: true,
      contract: { project: "pasta", tests: { a: { label: "a", run: ["scripts/run"], needs: [] } } },
    })
  })

  test("every problem of a contract is listed at once", () => {
    const parsed = read(
      `versao = 2\nextra = 1\n[teste.a]\nprecisa = ["android"]\nrun = "/bin/sh"\naparelhos = { min = 2, max = 1 }`,
    )
    expect(parsed.ok).toBe(false)
    if (parsed.ok) return
    expect(parsed.problems).toEqual([
      "extra: chave desconhecida",
      "versao: precisa ser 1",
      "teste.a.aparelhos: use { min, max } inteiros com 0 ≤ min ≤ max ≤ 16",
      'teste.a.run: "/bin/sh" precisa ser um caminho relativo à raiz do repositório, sem ".."',
    ])
  })

  const test1 = (body: string) => `versao = 1\n[teste.a]\nprecisa = ["android"]\nrun = "scripts/run"\n${body}`
  test.each([
    ["TOML inválido", "versao = = 1", ".bancada.toml não é TOML válido"],
    ["sem testes", "versao = 1", "teste: declare pelo menos um teste"],
    ["chave desconhecida no teste", test1(`argz = []`), "teste.a.argz: chave desconhecida"],
    ["chave desconhecida no aparelho", test1(`aparelho = { abi = "x86" }`), "teste.a.aparelho.abi: chave desconhecida"],
    ["nome de teste", `versao = 1\n[teste.Android]\nrun = "scripts/run"`, "teste.Android: o nome precisa casar"],
    ["herda quem não existe", test1(`herda = "b"`), 'teste.a: herda "b", que não existe'],
    [
      "herda em ciclo",
      `versao = 1\n[teste.a]\nherda = "b"\n[teste.b]\nherda = "a"\nrun = "scripts/run"`,
      "teste.a: herda forma um ciclo (a → b → a)",
    ],
    [
      "herda além de 5 níveis",
      `versao = 1\n${["a", "b", "c", "d", "e", "f"].map((name, index, all) => `[teste.${name}]\nherda = "${all[index + 1] ?? "g"}"`).join("\n")}\n[teste.g]\nrun = "scripts/run"\naparelhos = { min = 0, max = 0 }`,
      "teste.a: herda passa de 5 níveis",
    ],
    ["sem run", `versao = 1\n[teste.a]\naparelhos = { min = 0, max = 0 }`, "teste.a.run: obrigatório"],
    ["comando com ..", test1(`build = "../fora"`), 'teste.a.build: "../fora" precisa ser um caminho relativo'],
    [
      "comando que não está no commit",
      test1(`plan = ["scripts/plano", "--x"]`),
      'teste.a.plan: "scripts/plano" não existe neste commit',
    ],
    [
      "comando sem permissão de execução no commit",
      test1(`build = "scripts/sem-x"`),
      'teste.a.build: "scripts/sem-x" não é executável neste commit (chmod +x e commit)',
    ],
    ["comando vazio", test1(`build = []`), "teste.a.build: um caminho, ou uma lista"],
    ["api", test1(`aparelho = { api = "36+" }`), 'teste.a.aparelho.api: use ">=36" ou "36"'],
    ["enxuto", test1(`aparelho = { enxuto = "talvez" }`), 'teste.a.aparelho.enxuto: "aceita", "exige" ou "recusa"'],
    [
      "etiquetas sem celular",
      test1(`aparelho = { etiquetas = ["x"] }`),
      "teste.a.aparelho.etiquetas: só vale para celular",
    ],
    ["mais de 16 aparelhos", test1(`aparelhos = { min = 1, max = 17 }`), "teste.a.aparelhos: use { min, max }"],
    [
      "celular com 2 aparelhos",
      `versao = 1\n[teste.a]\nprecisa = ["android-fisico"]\naparelhos = { min = 1, max = 2 }\nrun = "scripts/run"`,
      "teste.a.aparelhos: um teste com celular usa no máximo 1 aparelho",
    ],
    [
      "aparelho sem precisa",
      `versao = 1\n[teste.a]\nrun = "scripts/run"`,
      "sem aparelho, escreva aparelhos = { min = 0, max = 0 }",
    ],
    [
      "aparelho sem tipo",
      `versao = 1\n[teste.a]\nprecisa = ["docker"]\nrun = "scripts/run"`,
      'teste.a.precisa: um teste com aparelho precisa de "android", "android-fisico", "ios" ou "ios-fisico"',
    ],
    [
      "Android e iOS no mesmo teste",
      `versao = 1\n[teste.a]\nprecisa = ["android", "ios-fisico"]\naparelhos = { min = 1, max = 1 }\nrun = "scripts/run"`,
      "teste.a.precisa: um teste usa aparelhos de um tipo só; separe Android e iOS em dois testes",
    ],
    [
      "precisa com nome inválido",
      `versao = 1\n[teste.a]\nprecisa = ["Android"]\nrun = "scripts/run"`,
      'teste.a.precisa: "Android" precisa casar com [a-z0-9:-]+',
    ],
    ["exclusivo", test1(`exclusivo = ["trava servidor"]`), 'teste.a.exclusivo: "trava servidor" precisa casar'],
    [
      "fora absoluto",
      `versao = 1\nfora = ["/usr/bin/x"]\n[teste.a]\nprecisa = ["android"]\nrun = "scripts/run"`,
      'fora: "/usr/bin/x" precisa ser um caminho relativo',
    ],
    ["rotulo longo", test1(`rotulo = "${"x".repeat(41)}"`), "teste.a.rotulo: de 1 a 40 caracteres, numa linha só"],
    ["rotulo em duas linhas", test1(`rotulo = "a\\nb"`), "teste.a.rotulo: de 1 a 40 caracteres, numa linha só"],
    ["prazo_min", test1(`prazo_min = 0`), "teste.a.prazo_min: precisa ser um número de minutos maior que zero"],
    ["segredos", test1(`segredos = "minha policy"`), "teste.a.segredos: nome de policy inválido"],
  ])("refuses: %s", (_name, text, problem) => {
    const parsed = read(text)
    expect(parsed.ok).toBe(false)
    expect(parsed.ok ? [] : parsed.problems.join("\n")).toContain(problem)
  })

  test.each([
    ["git@github.com:alexandrereyes/AbacatoV3.git", "github.com/alexandrereyes/AbacatoV3"],
    ["https://x-access-token:segredo@github.com/alexandrereyes/opencode.git", "github.com/alexandrereyes/opencode"],
    ["ssh://git@GitLab.example.com:2222/grupo/projeto/", "gitlab.example.com/grupo/projeto"],
    ["/workspace/Dev/AbacatoV3", undefined],
    ["file:///workspace/Dev/AbacatoV3", undefined],
  ])("a remote's URL as a project name, never its credentials: %s", (url, project) =>
    expect(normalizeRemote(url)).toBe(project),
  )
})
