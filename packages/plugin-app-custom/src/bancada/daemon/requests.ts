import { randomBytes } from "node:crypto"
import { Result, Schema } from "effect"
import { partSpec } from "../contract.js"
import { BancadaProtocol } from "../protocol.js"
import { Bancada } from "../rpc.js"
import type { Core } from "./core.js"
import type { Git } from "./git.js"
import { freeze, release } from "./snapshot.js"

const decodeRequest = Schema.decodeUnknownResult(Bancada.Request)

/** A request refused before anything was queued, with every problem for the agent. */
export class Invalid extends Error {
  constructor(readonly problems: string[]) {
    super(problems.join("\n"))
  }
}

/**
 * `custom.bancada/submit` on this machine (`docs/bancada.md`, "Request"): the code is frozen in the session's
 * repository, the tests are resolved against the contract of that very commit, and the request goes to the queue. An
 * id that exists is the same request, answered as it is, never frozen again.
 */
export async function submit(core: Core, git: Git, raw: unknown): Promise<Bancada.Submitted> {
  const decoded = decodeRequest(raw)
  if (Result.isFailure(decoded)) throw new Invalid([decoded.failure.message])
  const request = decoded.success
  const id = request.id ?? BancadaProtocol.jobID(randomBytes(16).toString("hex"))
  const known = core.status(id)
  if (known)
    return {
      job: id,
      state: known.state,
      commit: known.commit,
      partes: Object.entries(known.parts).map(([teste, part]) => ({
        teste,
        ...(part.position === undefined ? {} : { posicao: part.position }),
        ...(part.etaMs === undefined ? {} : { etaMs: part.etaMs }),
        ...(part.reason ? { motivo: part.reason } : {}),
      })),
    }
  const frozen = await freeze({
    git,
    directory: request.diretorio,
    job: id,
    snapshot: request.snapshot === true,
    ...(request.commit ? { commit: request.commit } : {}),
  })
  if (!frozen.ok) throw new Invalid(frozen.problems)
  const contract = frozen.frozen.contract
  const missing = request.testes.filter((item) => !contract.tests[item.teste])
  if (missing.length) {
    await release(git, frozen.frozen.root, id)
    throw new Invalid(
      missing.map(
        (item) =>
          `o teste "${item.teste}" não existe no .bancada.toml deste commit (há: ${Object.keys(contract.tests).join(", ")})`,
      ),
    )
  }
  const parts = request.testes.map((item) => partSpec(contract.tests[item.teste]!, item.args ?? []))
  const row = core.submit({
    id,
    sessionID: request.sessionID,
    rootSessionID: request.rootSessionID ?? request.sessionID,
    ...(request.sessionTitle ? { sessionTitle: request.sessionTitle } : {}),
    ...(request.rootTitle ? { rootTitle: request.rootTitle } : {}),
    code: {
      project: frozen.frozen.project,
      commit: frozen.frozen.commit,
      remotes: [...frozen.frozen.remotes],
      inRemote: frozen.frozen.inRemote,
    },
    parts,
    repository: frozen.frozen.root,
  })
  const changes = frozen.frozen.files.map((file) => ({ caminho: file.path, mudanca: file.change }))
  return {
    job: id,
    state: row.state,
    commit: frozen.frozen.commit,
    ...(request.snapshot || frozen.frozen.notIncluded
      ? {
          snapshot: {
            arquivos: changes,
            ...(frozen.frozen.notIncluded ? { naoIncluidos: frozen.frozen.notIncluded } : {}),
          },
        }
      : {}),
    partes: parts.map((part) => ({
      teste: part.part,
      motivo: { code: "aguardando_confirmacao", text: "aguardando confirmação do hub" },
    })),
  }
}
