import { Effect } from "effect"
import type { Context } from "../context.js"

/**
 * An optional `description` the agent writes for each `shell`, `grep` and Code Mode `execute` call: why it runs, in a
 * few words of Portuguese, for the apps' activity rows (`docs/tool-descriptions.md`). The field is added to the JSON
 * schema the model receives, on every request (`context`, and `compaction` and `generate` so their tool list matches the
 * one the prompt cache holds), never to the tools themselves: the call's input is stored as the model sent it, field
 * included, and the tools' own decoding drops it before they run.
 */
const rules =
  "de 2 a 6 palavras (até uns 38 caracteres), em português, começando com um verbo no gerúndio. Diga a intenção na tarefa, não a mecânica, e cite o alvo pelo nome curto, sem caminhos, flags ou código."

export const fields = {
  shell: {
    after: "command",
    text: `Para quem acompanha pelo app: por que este comando roda, ${rules} Bons: "Procurando onde o tema Pink é definido", "Conferindo se os testes passam", "Descobrindo o commit que quebrou o total". Ruins: "Rodando sed e grep", "Executando comando no terminal".`,
  },
  grep: {
    after: "pattern",
    text: `Para quem acompanha pelo app: por que esta busca, ${rules} Bons: "Procurando quem chama calcularTotal", "Localizando os TODOs de preços". Ruins: "Buscando regex no código", "Grep em src".`,
  },
  execute: {
    after: "code",
    text: `Para quem acompanha pelo app: por que este código roda, ${rules} Bons: "Somando os pedidos por cliente", "Conferindo o estado das sessões". Ruins: "Executando JavaScript", "Chamando ferramentas".`,
  },
} as const

type Definitions = Record<string, { description: string; input: unknown }>

/** Adds the field after each tool's main argument, unless the schema already has a `description` of its own. */
export function describeTools(tools: Definitions) {
  for (const [name, field] of Object.entries(fields)) {
    const schema = tools[name]?.input
    if (typeof schema !== "object" || schema === null) continue
    const properties = (schema as { properties?: unknown }).properties
    if (typeof properties !== "object" || properties === null || "description" in properties) continue
    const entries = Object.entries(properties)
    const at = entries.findIndex(([key]) => key === field.after) + 1
    entries.splice(at === 0 ? entries.length : at, 0, ["description", { type: "string", description: field.text }])
    ;(schema as { properties: Record<string, unknown> }).properties = Object.fromEntries(entries)
  }
}

export const registerToolDescriptions = Effect.fn("ToolDescriptions.register")(function* (ctx: Context) {
  const hook = (event: { tools: Definitions }) => Effect.sync(() => describeTools(event.tools))
  yield* ctx.session.hook("context", hook)
  yield* ctx.session.hook("compaction", hook)
  yield* ctx.session.hook("generate", hook)
})
