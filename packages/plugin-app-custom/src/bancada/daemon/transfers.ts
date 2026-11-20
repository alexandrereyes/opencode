import type { Database } from "bun:sqlite"
import { BancadaProtocol } from "../protocol.js"
import type { Alerts } from "./alerts.js"
import { limits as blobLimits, type Blobs } from "./blobs.js"

/**
 * The files of transfers on this machine (`<state>/transfers/`): the bundles its origin sends, the ones its executor
 * receives. A port: the process uses the disk and git, the simulation memory.
 */
export interface Files {
  readonly path: (name: string) => string
  /** 0 when the file does not exist. */
  readonly size: (file: string) => Promise<number>
  readonly sha256: (file: string) => Promise<string>
  readonly read: (file: string, offset: number, length: number) => Promise<Uint8Array>
  readonly append: (file: string, data: Uint8Array) => Promise<void>
  readonly remove: (file: string) => Promise<void>
  /** The origin's bundle of a request's frozen commit, without what the receiver has (`snapshot.ts`, `bundle`). */
  readonly bundle: (input: {
    readonly job: string
    readonly repository: string
    readonly have: ReadonlyArray<string>
    readonly file: string
  }) => Promise<boolean>
  /** The commits this machine has of a project, so the bundle it receives carries less (`workdir.ts`, `have`). */
  readonly have: (project: string) => Promise<ReadonlyArray<string>>
  /**
   * Where the origin puts a part's evidence for the session (`docs/bancada.md`, "Notice"):
   * `<tmp of the server>/bancada/<job>/<part>/<name>`. The folder is the session's; the Bancada never removes it.
   */
  readonly deliver: (job: string, part: string, name: string) => string
  readonly copy: (from: string, to: string) => Promise<void>
  /** After delivery: the ref that held a request's frozen commit in the session's repository goes. */
  readonly release: (repository: string, job: string) => Promise<void>
}

/** A part's evidence where the session can read it: what arrived, and how many files did not. */
export type Delivered = Record<string, { readonly files: Readonly<Record<string, string>>; readonly missing: number }>

/** The hub's `blob.put` and `blob.get`, as this machine reaches them: the link, or on the hub its own. */
export interface BlobLink {
  readonly put: (input: BancadaProtocol.BlobPut) => Promise<BancadaProtocol.BlobPutOutput>
  readonly get: (input: BancadaProtocol.BlobGet) => Promise<BancadaProtocol.BlobGetOutput>
}

export const limits = {
  /** A code bundle may not pass this. */
  codeBytes: 1024 ** 3,
  /** Evidence: each file, and a request's together (`docs/bancada.md`, "Blobs"). */
  evidenceFileBytes: 20 * 1024 * 1024,
  evidenceBytes: 200 * 1024 * 1024,
  /** How long the origin waits for evidence still on its way before it tells the session without it. */
  evidenceWaitMs: 2 * 60_000,
  /** Times an executor asks for a request's code before its attempts are lost. */
  tries: 3,
  /**
   * An executor that asked for a request's code and heard of no transfer for this long gives up: its attempts end with
   * the reason (the origin could not make the bundle, or the hub forgot) instead of holding the machine.
   */
  codeWaitMs: 30 * 60_000,
  /** A transfer's work that failed (the hub did not answer) waits this long before it is tried again. */
  retryMs: 5_000,
}

type CodeOut = {
  readonly transfer: string
  readonly job_id: string
  readonly have: string
  readonly file: string | null
  readonly size: number | null
  readonly sha256: string | null
  readonly state: string
}
type CodeIn = {
  readonly job_id: string
  readonly project: string
  readonly state: "pedir" | "pedido" | "baixar" | "pronto" | "falhou"
  readonly transfer: string | null
  readonly file: string | null
  readonly reason: string | null
  readonly tries: number
  readonly asked_at: number
  readonly first_asked_at: number | null
}
type BlobRow = {
  readonly transfer: string
  readonly job_id: string
  readonly uploader: string
  readonly downloader: string
  readonly received: string
  readonly state: string
  readonly kind: string
  readonly expires_at: number
}

/**
 * A request's code that travels through the hub (`docs/bancada.md`, "Frozen code"): the executor that could not bring
 * the commit from the session's repository or a remote asks for it (`code.have`); the hub names a transfer and asks the
 * origin (`code.request`); the origin sends its bundle in chunks (`blob.put`) and says so (`blob.ready`); the hub tells
 * the executor (`code.source`), which downloads it (`blob.get`) and checks its SHA-256 before anything is fetched from
 * it. Each side's long work runs off the round and asks for one when it ends.
 */
export function makeTransfers(input: {
  readonly db: Database
  readonly now: () => number
  /** A transfer lives this long on the hub; an executor that waited longer for its code asks again. */
  readonly transferMs: number
  readonly self: { readonly machineID: string; readonly instanceID: string }
  readonly files?: Files
  readonly link?: BlobLink
  /** The hub's store of transfers; only on the hub. */
  readonly blobs?: Blobs
  /** Writes a message to the hub. */
  readonly send: (body: BancadaProtocol.FromMachine) => void
  /** The session's repository of a request of this origin. */
  readonly repository: (job: string) => string | undefined
  readonly alerts: Alerts
  readonly log: (line: string) => void
  readonly wake: () => void
}) {
  const db = input.db
  const outgoing = db.query<CodeOut, []>("SELECT * FROM code_out WHERE state = 'enviar'")
  const evidenceOut = db.query<{ transfer: string; job_id: string; files: string }, []>(
    "SELECT transfer, job_id, files FROM evidence_out WHERE state = 'enviar'",
  )
  const sending = db.query<{ transfer: string }, [string]>(
    "SELECT transfer FROM evidence_out WHERE transfer = ? AND state = 'enviar'",
  )
  const pending = db.query<{ transfer: string }, [string]>(
    "SELECT transfer FROM code_out WHERE transfer = ? AND state = 'enviar'",
  )
  const incoming = db.query<CodeIn, []>("SELECT * FROM code_in WHERE state IN ('pedir', 'pedido', 'baixar')")
  const codeIn = db.query<CodeIn, [string]>("SELECT * FROM code_in WHERE job_id = ?")
  const blob = db.query<BlobRow, [string]>("SELECT * FROM hub_blob WHERE transfer = ?")
  const instance = db.query<{ instance_id: string }, [string]>(
    "SELECT instance_id FROM hub_machine WHERE machine_id = ?",
  )
  const caller = {
    protocol: BancadaProtocol.version,
    machineID: input.self.machineID,
    instanceID: input.self.instanceID,
  }
  /**
   * Long work, one per subject at a time. One that ends asks for a round; one that failed (the hub out, say) is tried
   * again only after `limits.retryMs`, never in a loop of rounds.
   */
  const tasks = new Set<string>()
  const failed = new Map<string, number>()
  const run = (id: string, work: () => Promise<void>) => {
    if (tasks.has(id) || input.now() < (failed.get(id) ?? 0)) return
    tasks.add(id)
    void work().then(
      () => {
        tasks.delete(id)
        failed.delete(id)
        input.wake()
      },
      (error: unknown) => {
        tasks.delete(id)
        failed.set(id, input.now() + limits.retryMs)
        input.log(`transfer ${id} failed: ${error instanceof Error ? error.message : error}`)
      },
    )
  }
  /** A transfer's writes one at a time: two chunks of one transfer never race over its files. */
  const queues = new Map<string, Promise<unknown>>()
  const serial = <T>(transfer: string, work: () => Promise<T>) => {
    const next = (queues.get(transfer) ?? Promise.resolve()).then(work, work)
    queues.set(
      transfer,
      next.then(
        () => undefined,
        () => undefined,
      ),
    )
    return next
  }

  /**
   * Sends one file of a transfer from what the hub already has; says whether the hub has it all (false: the hub no
   * longer knows the transfer, or `still` says the send is over). If the executor still needs it, it asks again.
   */
  const sendFile = async (
    transfer: string,
    declared: BancadaProtocol.File,
    source: string,
    still: () => boolean,
  ): Promise<boolean> => {
    const send = async (offset: number, restarted: boolean): Promise<boolean> => {
      if (!still()) return false
      const length = Math.min(blobLimits.chunkBytes, declared.size - offset)
      const data = await input.files!.read(source, offset, length)
      const answer = await input.link!.put({
        ...caller,
        transfer,
        file: declared,
        offset,
        data: Buffer.from(data).toString("base64"),
        end: offset + length >= declared.size,
      })
      if (answer.ok) return answer.done ? true : send(answer.received, restarted)
      if (answer.reason === "offset" && answer.received !== undefined) return send(answer.received, restarted)
      // The hub found another SHA-256 at the end: what it had was spoiled; once more from the start.
      if (answer.reason === "sha256" && !restarted) return send(0, true)
      if (answer.reason === "unknown" || answer.reason === "expired") return false
      throw new Error(`o hub recusou o arquivo ${declared.path} (${answer.reason})`)
    }
    return send(0, false)
  }
  /**
   * Fetches one file of a transfer into `target`, resuming what is there, and checks it; the failure, if any
   * ("expired", "unknown", "incomplete", "sha256").
   */
  const fetchFile = async (transfer: string, file: BancadaProtocol.File, target: string) => {
    const files = input.files!
    const fetch = async (offset: number): Promise<string | undefined> => {
      if (offset >= file.size && file.size > 0) return undefined
      const answer = await input.link!.get({
        ...caller,
        transfer,
        index: file.index,
        offset,
        size: blobLimits.chunkBytes,
      })
      if (!answer.ok) return answer.reason
      const data = Buffer.from(answer.data, "base64")
      await files.append(target, data)
      return answer.end ? undefined : fetch(offset + data.byteLength)
    }
    const failure = await fetch(await files.size(target))
    if (failure) {
      await files.remove(target)
      return failure
    }
    if ((await files.size(target)) === file.size && (await files.sha256(target)) === file.sha256) return undefined
    await files.remove(target)
    return "sha256"
  }

  /** The origin sends its bundle, resuming from what the hub already has; then says it is all there. */
  const upload = async (row: CodeOut) => {
    const files = input.files!
    const repository = input.repository(row.job_id)
    if (!repository) return close(row, "o repositório do pedido não está mais nesta máquina")
    const made = row.file ? { file: row.file, size: row.size!, sha256: row.sha256! } : await bundle(row, repository)
    if (!made) return close(row, "o git não conseguiu fazer o pacote do commit")
    if (made.size > limits.codeBytes) return close(row, "o pacote do commit passa de 1 GB")
    const declared: BancadaProtocol.File = { index: 0, path: "codigo.bundle", ...made }
    // The request was delivered meanwhile: its send is over.
    const whole = await sendFile(row.transfer, declared, made.file, () => pending.get(row.transfer) !== null)
    db.transaction(() => {
      if (!pending.get(row.transfer)) return
      if (!whole) return void db.run("UPDATE code_out SET state = 'desistiu' WHERE transfer = ?", [row.transfer])
      db.run("UPDATE code_out SET state = 'enviado' WHERE transfer = ?", [row.transfer])
      input.send({ type: "blob.ready", transfer: { id: row.transfer, files: [declared] } })
    })()
    if (!whole) input.log(`gave up sending the code of ${row.job_id}: the hub no longer has transfer ${row.transfer}`)
    await files.remove(made.file)
  }
  const bundle = async (row: CodeOut, repository: string) => {
    const files = input.files!
    const file = files.path(`out-${row.transfer}.bundle`)
    await files.remove(file)
    if (!(await files.bundle({ job: row.job_id, repository, have: JSON.parse(row.have), file }))) return undefined
    const made = { file, size: await files.size(file), sha256: await files.sha256(file) }
    db.run("UPDATE code_out SET file = ?, size = ?, sha256 = ? WHERE transfer = ?", [
      made.file,
      made.size,
      made.sha256,
      row.transfer,
    ])
    return made
  }
  /** The origin cannot send it: the executor's wait ends at the hub's alert, then its own limit. */
  const close = (row: CodeOut, reason: string) => {
    db.run("UPDATE code_out SET state = 'falhou' WHERE transfer = ?", [row.transfer])
    input.alerts.raise(
      `codigo:${row.job_id}`,
      "codigo",
      `o código do pedido ${row.job_id} não pôde ser enviado: ${reason}`,
    )
  }

  /** The executor downloads the bundle, resuming what it has, and checks it before it counts. */
  const download = async (row: CodeIn) => {
    const files = input.files!
    const transfer: BancadaProtocol.Transfer = JSON.parse(row.transfer!)
    const file = transfer.files[0]
    if (!file) return retry(row, "a transferência veio sem arquivo", true)
    const target = files.path(`in-${transfer.id}-${file.index}.bundle`)
    const failure = await fetchFile(transfer.id, file, target)
    if (failure === "sha256") return retry(row, "o pacote chegou corrompido (SHA-256 diferente)", true)
    if (failure)
      return retry(
        row,
        failure === "expired" ? "a transferência venceu" : `a transferência não está no hub (${failure})`,
        false,
      )
    db.run("UPDATE code_in SET state = 'pronto', file = ? WHERE job_id = ? AND state = 'baixar'", [target, row.job_id])
  }
  /**
   * Asks again. A bundle that came spoiled counts, up to `limits.tries`, and then the request's attempts here are lost
   * with the reason; one that never came (the origin or this machine cut off, the transfer expired) is only asked again.
   */
  const retry = (row: CodeIn, reason: string, counts: boolean) => {
    input.log(`the code of ${row.job_id} did not arrive: ${reason}`)
    const tries = row.tries + (counts ? 1 : 0)
    db.run("UPDATE code_in SET state = ?, reason = ?, tries = ?, transfer = NULL WHERE job_id = ?", [
      tries >= limits.tries ? "falhou" : "pedir",
      `o código não chegou: ${reason}`,
      tries,
      row.job_id,
    ])
  }
  const giveUp = (row: CodeIn) => {
    const reason = `o código não chegou em ${Math.round(limits.codeWaitMs / 60_000)} min (a origem não o enviou)`
    input.log(`the code of ${row.job_id} did not arrive: gave up after ${Math.round(limits.codeWaitMs / 60_000)} min`)
    db.run("UPDATE code_in SET state = 'falhou', reason = ?, transfer = NULL WHERE job_id = ? AND state = 'pedido'", [
      reason,
      row.job_id,
    ])
    input.alerts.raise(`codigo-esperado:${row.job_id}`, "codigo", `o pedido ${row.job_id} desistiu: ${reason}`)
  }
  /**
   * Tells the hub what this machine has of the project, so the bundle carries less; after a bundle that failed,
   * nothing: the next one comes whole.
   */
  const ask = async (row: CodeIn) => {
    const have = row.tries > 0 ? [] : await input.files!.have(row.project)
    db.transaction(() => {
      const changed = db.run("UPDATE code_in SET state = 'pedido', asked_at = ? WHERE job_id = ? AND state = 'pedir'", [
        input.now(),
        row.job_id,
      ]).changes
      if (changed) input.send({ type: "code.have", job: row.job_id, have: [...have] })
    })()
  }

  /** The executor sends an attempt's evidence, file by file, then says it is all there. */
  const sendEvidence = async (row: { transfer: string; job_id: string; files: string }) => {
    const files: (BancadaProtocol.File & { readonly file: string })[] = JSON.parse(row.files)
    const still = () => sending.get(row.transfer) !== null
    const sent = await Promise.all(
      files.map(({ file, ...declared }) => sendFile(row.transfer, declared, file, still)),
    ).then((all) => all.every(Boolean))
    db.transaction(() => {
      if (!still()) return
      db.run("UPDATE evidence_out SET state = ? WHERE transfer = ?", [sent ? "enviado" : "desistiu", row.transfer])
      if (sent)
        input.send({
          type: "blob.ready",
          transfer: { id: row.transfer, files: files.map(({ file: _, ...declared }) => declared) },
        })
    })()
  }

  /**
   * The origin's copy of a request's evidence (`docs/bancada.md`, "Notice"): from the attempt's folder when it ran
   * here, else from the hub. Evidence still on its way is waited for until `evidenceWaitMs` after `since`; past that,
   * or when the hub no longer has it, the notice goes without it (counted as missing).
   */
  const collect = async (job: string, parts: ReadonlyArray<BancadaProtocol.PartResult>, since: number) => {
    const files = input.files
    const entries = parts.flatMap((part) => (part.evidence ?? []).map((entry) => ({ part: part.part, entry })))
    const results = await Promise.all(
      entries.map(async ({ part, entry }) => {
        const got = await Promise.all(
          entry.files.map(async (file) => {
            const name = safeName(file.path, file.index)
            if (!files) return { name, missing: true }
            const target = files.deliver(job, part, name)
            if (entry.transfer === undefined) {
              const source = localSource(job, part, entry.attempt, file.index)
              if (!source) return { name, missing: true }
              await files.copy(source, target)
              return { name, target }
            }
            if (!input.link) return { name, missing: true }
            const failure = await fetchFile(entry.transfer, file, target)
            if (!failure) return { name, target }
            // Not there yet (still being sent): later, unless the wait is over.
            if (failure !== "sha256" && input.now() - since < limits.evidenceWaitMs)
              throw new Error(`a evidência ${name} ainda não chegou`)
            return { name, missing: true }
          }),
        )
        return { part, got }
      }),
    )
    return results.reduce<Delivered>((all, { part, got }) => {
      const known = all[part] ?? { files: {}, missing: 0 }
      return {
        ...all,
        [part]: {
          files: {
            ...known.files,
            ...Object.fromEntries(got.flatMap((item) => ("target" in item ? [[item.name, item.target!]] : []))),
          },
          missing: known.missing + got.filter((item) => "missing" in item).length,
        },
      }
    }, {})
  }
  const localSource = (job: string, part: string, attempt: number, index: number) => {
    const row = db
      .query<
        { evidence: string | null },
        [string, string, number]
      >("SELECT evidence FROM attempt WHERE job_id = ? AND part = ? AND n = ?")
      .get(job, part, attempt)
    const kept: { index: number; file: string }[] = row?.evidence ? JSON.parse(row.evidence) : []
    return kept.find((item) => item.index === index)?.file
  }

  /** The hub's transfers that ended (delivered, expired) leave its disk. */
  const sweep = () => {
    if (!input.blobs) return
    const blobs = input.blobs
    db.query<{ transfer: string }, [number]>("SELECT transfer FROM hub_blob WHERE state = 'apagar' OR expires_at < ?")
      .all(input.now())
      .forEach((row) =>
        run(`remove:${row.transfer}`, async () => {
          await blobs.remove(row.transfer)
          db.run("DELETE FROM hub_blob WHERE transfer = ?", [row.transfer])
        }),
      )
  }

  return {
    /** Whether this machine can send and receive code through the hub. */
    enabled: () => input.files !== undefined && input.link !== undefined,
    /** The origin: the hub asks for a request's code (in the transaction that applies the message). */
    request: (message: typeof BancadaProtocol.CodeRequest.Type) =>
      db.run(
        "INSERT OR IGNORE INTO code_out (transfer, job_id, have, state, created_at) VALUES (?, ?, ?, 'enviar', ?)",
        [message.transfer, message.job, JSON.stringify(message.have), input.now()],
      ),
    /** The executor: the hub asks for an attempt's evidence (in the transaction that applies the message). */
    evidence: (message: typeof BancadaProtocol.EvidenceRequest.Type) => {
      const row = db
        .query<
          { evidence: string | null },
          [string, string, number]
        >("SELECT evidence FROM attempt WHERE job_id = ? AND part = ? AND n = ?")
        .get(message.job, message.part, message.attempt)
      if (!row?.evidence) return
      db.run(
        "INSERT OR IGNORE INTO evidence_out (transfer, job_id, files, state, created_at) VALUES (?, ?, ?, 'enviar', ?)",
        [message.transfer, message.job, row.evidence, input.now()],
      )
    },
    /** The origin: a request's evidence, where the session can read it. Rejects while some is still on its way. */
    collect,
    /** The executor: the code of `job` could not be brought here; it is asked through the hub. */
    ask: (job: string, project: string) =>
      void db.run(
        "INSERT INTO code_in (job_id, project, state, asked_at, first_asked_at) VALUES (?, ?, 'pedir', ?, ?) ON CONFLICT (job_id) DO UPDATE SET state = 'pedir' WHERE state <> 'falhou'",
        [job, project, input.now(), input.now()],
      ),
    /** The executor: the bundle of `job` came and did not apply; asked again, whole, while tries are left. */
    spoiled: (job: string, reason: string) => {
      const row = codeIn.get(job)
      if (!row || row.state !== "pronto") return
      if (row.file && input.files) void input.files.remove(row.file).catch(() => undefined)
      db.run("UPDATE code_in SET file = NULL WHERE job_id = ?", [job])
      retry({ ...row, file: null }, `o pacote não se aplicou (${reason})`, true)
    },
    /** The executor: where the code of `job` is (in the transaction that applies the message). */
    source: (message: typeof BancadaProtocol.CodeSource.Type) => {
      if (!("transfer" in message.source)) return
      db.run("UPDATE code_in SET state = 'baixar', transfer = ? WHERE job_id = ? AND state = 'pedido'", [
        JSON.stringify(message.source.transfer),
        message.job,
      ])
    },
    /** The executor: how the code of `job` stands, when it was asked through the hub. */
    code: (job: string) => codeIn.get(job) ?? undefined,
    /** The executor: the request is over here; its bundle goes. */
    forget: (job: string) => {
      db.run("DELETE FROM evidence_out WHERE job_id = ?", [job])
      const row = codeIn.get(job)
      if (!row) return
      db.run("DELETE FROM code_in WHERE job_id = ?", [job])
      if (row.file && input.files) void input.files.remove(row.file).catch(() => undefined)
    },
    /** The origin: the request was delivered; what it sent for it is history no more. */
    sent: (job: string) => {
      const files = db
        .query<{ file: string | null }, [string]>("SELECT file FROM code_out WHERE job_id = ?")
        .all(job)
        .flatMap((row) => (row.file ? [row.file] : []))
      // Also a send still running: it stops at its next chunk, and its bundle goes here.
      db.run("DELETE FROM code_out WHERE job_id = ?", [job])
      files.forEach((file) => void input.files?.remove(file).catch(() => undefined))
    },
    /** Starts what each side has to do; never waits for it. */
    tick: () => {
      // Code asked for a request that no longer runs here (withdrawn, cancelled, ended): nothing waits for it.
      db.query<{ job_id: string; file: string | null }, []>(
        "SELECT job_id, file FROM code_in WHERE job_id NOT IN (SELECT job_id FROM attempt WHERE state IN ('aceito', 'compilando', 'rodando'))",
      )
        .all()
        .forEach((row) => {
          db.run("DELETE FROM code_in WHERE job_id = ?", [row.job_id])
          if (row.file && input.files) void input.files.remove(row.file).catch(() => undefined)
        })
      if (input.files && input.link) {
        outgoing.all().forEach((row) => run(`out:${row.transfer}`, () => upload(row)))
        evidenceOut.all().forEach((row) => run(`evidence:${row.transfer}`, () => sendEvidence(row)))
        incoming.all().forEach((row) => {
          if (row.state === "pedir") return run(`in:${row.job_id}`, () => ask(row))
          if (row.state === "baixar") return run(`in:${row.job_id}`, () => download(row))
          // Asked first `codeWaitMs` ago and still nothing: the attempts waiting for it end with the reason. Asked long
          // ago and nothing came (the hub forgot, the transfer expired): asked again.
          if (input.now() - (row.first_asked_at ?? row.asked_at) >= limits.codeWaitMs) return giveUp(row)
          if (input.now() - row.asked_at >= input.transferMs) retry(row, "nada chegou a tempo", false)
        })
      }
      sweep()
    },
    /** The hub's `blob.put`: only the transfer's sender writes, one chunk at a time per transfer. */
    put: (request: BancadaProtocol.BlobPut): Promise<BancadaProtocol.BlobPutOutput> => {
      const row = blob.get(request.transfer)
      const blobs = input.blobs
      if (!blobs || !row || !authorized(row.uploader, request) || row.state !== "aberta")
        return Promise.resolve({ ok: false, reason: "unknown" })
      const data = Buffer.from(request.data, "base64")
      if (data.byteLength > blobLimits.chunkBytes) return Promise.resolve({ ok: false, reason: "size" })
      return serial(request.transfer, async () => {
        const evidence = row.kind === "evidencias"
        await blobs.open({
          id: request.transfer,
          limitBytes: evidence ? limits.evidenceBytes : limits.codeBytes,
          fileLimitBytes: evidence ? limits.evidenceFileBytes : limits.codeBytes,
          expiresAt: row.expires_at,
        })
        const answer = await blobs.put({
          transfer: request.transfer,
          file: request.file,
          offset: request.offset,
          data,
          end: request.end === true,
        })
        if (answer.ok && answer.done) {
          const current = blob.get(request.transfer)
          if (current)
            db.run("UPDATE hub_blob SET received = ? WHERE transfer = ?", [
              JSON.stringify({ ...JSON.parse(current.received), [request.file.index]: request.file.sha256 }),
              request.transfer,
            ])
        }
        return answer
      })
    },
    /** The hub's `blob.get`: only the transfer's receiver reads. */
    get: async (request: BancadaProtocol.BlobGet): Promise<BancadaProtocol.BlobGetOutput> => {
      const row = blob.get(request.transfer)
      if (!input.blobs || !row || !authorized(row.downloader, request) || row.state !== "pronta")
        return { ok: false, reason: "unknown" }
      const answer = await input.blobs.get(request)
      return answer.ok ? { ok: true, data: Buffer.from(answer.data).toString("base64"), end: answer.end } : answer
    },
  }

  function authorized(machineID: string, request: { readonly machineID: string; readonly instanceID: string }) {
    return machineID === request.machineID && instance.get(machineID)?.instance_id === request.instanceID
  }
}

export type Transfers = ReturnType<typeof makeTransfers>

/** A file's name in the session's folder: no folder of its own, no way out of it. */
function safeName(name: string, index: number) {
  const base = name.split(/[\\/]/).at(-1) ?? ""
  return base && base !== "." && base !== ".." ? base : `evidencia-${index}`
}
