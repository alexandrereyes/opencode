import type { Database } from "bun:sqlite"
import type { Phone } from "../machine-config.js"
import type { BancadaProtocol } from "../protocol.js"

/**
 * Holds this machine decides (`docs/bancada.md`, "Holds"): a light slot for an emulator or simulator a session starts
 * itself (the cost of one device of its kind, reserved; the Bancada neither creates nor stops it), or a phone of the
 * machine's catalog, for one family at a time. The rules are `device-lease`'s: renewed by use, expired when idle while
 * someone waits, idle long, or held long while someone waits; a phone's queue in arrival order, each place kept while
 * its session keeps asking.
 */

export type Target = typeof BancadaProtocol.HoldTarget.Type

export type Times = {
  /** Idle this long with someone waiting: it expires. */
  readonly idleQueuedMs: number
  /** Idle this long with nobody waiting: it expires. */
  readonly idleMs: number
  /** Held this long in all with someone waiting: it expires. */
  readonly totalQueuedMs: number
  /** A place in a queue stays this long without a new request of its session. */
  readonly placeMs: number
}

export type HoldRow = {
  readonly id: string
  readonly origin_machine: string
  readonly origin: string
  readonly root_session_id: string
  readonly kind: "vaga" | "fisico"
  readonly platform: string | null
  readonly target: string
  readonly lease_id: string | null
  readonly state: "concedida" | "esperando" | "vencida" | "solta" | "negada"
  readonly requested_at: number
  readonly acquired_at: number | null
  readonly last_activity_at: number | null
  readonly last_seen_at: number
  readonly reason: string | null
}

/** What the machine says of a hold: the body of `hold.state`, also when the session is this machine's own. */
export type Answer = Omit<typeof BancadaProtocol.HoldState.Type, "type">

/**
 * Why a held device expires now, if it does: idle `idleQueuedMs` with someone waiting, idle `idleMs` with nobody, or
 * `totalQueuedMs` in all with someone waiting; nothing while the machine file keeps it for someone (`pinnedUntil`).
 */
export function expiry(
  hold: { readonly acquiredAt: number; readonly lastActivityAt: number; readonly pinnedUntil?: number },
  now: number,
  waiting: boolean,
  times: Times,
) {
  if (hold.pinnedUntil !== undefined && now < hold.pinnedUntil) return undefined
  const idle = now - hold.lastActivityAt
  if (waiting && idle >= times.idleQueuedMs) return `parada há ${minutes(idle)} min com alguém esperando`
  if (!waiting && idle >= times.idleMs) return `parada há ${minutes(idle)} min`
  if (waiting && now - hold.acquiredAt >= times.totalQueuedMs)
    return `${minutes(now - hold.acquiredAt)} min no total com alguém esperando`
  return undefined
}

/** When a held device ends at the latest, if someone starts waiting now. */
export function worstEnd(
  hold: { readonly acquiredAt: number; readonly lastActivityAt: number; readonly pinnedUntil?: number },
  times: Times,
) {
  const end = Math.min(hold.lastActivityAt + times.idleQueuedMs, hold.acquiredAt + times.totalQueuedMs)
  return hold.pinnedUntil !== undefined ? Math.max(end, hold.pinnedUntil) : end
}

export function makeHolds(input: {
  readonly db: Database
  readonly now: () => number
  readonly machineID: string
  readonly phones: () => ReadonlyArray<Phone>
  readonly times: Times
  /** A light slot of `platform` reserved now, if one fits (the lease's id); the next room goes to waiting ones. */
  readonly reserve: (platform: "android" | "ios") => string | undefined
  readonly release: (lease: string) => void
  /** Where an answer goes: this machine's own origin, or the hub (`hold.state`). */
  readonly answer: (hold: HoldRow, answer: Answer) => void
}) {
  const db = input.db
  const find = db.query<HoldRow, [string]>("SELECT * FROM hold WHERE id = ?")
  const open = db.query<HoldRow, []>(
    "SELECT * FROM hold WHERE state IN ('concedida', 'esperando') ORDER BY requested_at, id",
  )
  /** The queue a target waits in: a phone's own, or the light slots of one kind. */
  const key = (target: Target) => (target.kind === "fisico" ? `fisico:${target.device}` : `vaga:${target.platform}`)
  /** What a family holds: a phone, or a slot by its device's name. */
  const owned = (target: Target) => (target.kind === "fisico" ? key(target) : `${key(target)}:${target.name}`)
  const targetOf = (row: HoldRow): Target => JSON.parse(row.target)
  const phoneOf = (target: Target) =>
    target.kind === "fisico" ? input.phones().find((phone) => phone.alias === target.device) : undefined
  const pinned = (row: HoldRow) => {
    const until = phoneOf(targetOf(row))?.reserved?.until
    return until !== undefined && until > input.now() ? until : undefined
  }
  const timing = (row: HoldRow) => ({
    acquiredAt: row.acquired_at ?? row.requested_at,
    lastActivityAt: row.last_activity_at ?? row.acquired_at ?? row.requested_at,
    ...(pinned(row) === undefined ? {} : { pinnedUntil: pinned(row) }),
  })
  /** The queue of a target, in arrival order. */
  const queue = (target: Target) =>
    open.all().filter((row) => row.state === "esperando" && key(targetOf(row)) === key(target))
  const holder = (target: Target) =>
    open.all().find((row) => row.state === "concedida" && key(targetOf(row)) === key(target))
  const update = (row: HoldRow, fields: Record<string, string | number | null>) =>
    db.run(
      `UPDATE hold SET ${Object.keys(fields)
        .map((name) => `${name} = ?`)
        .join(", ")} WHERE id = ?`,
      [...Object.values(fields), row.id],
    )
  const tell = (row: HoldRow) => {
    const current = find.get(row.id)!
    const target = targetOf(current)
    if (current.state === "concedida")
      return input.answer(current, {
        hold: current.id,
        state: "concedida",
        device: device(target),
        expiresAt: worstEnd(timing(current), input.times),
      })
    if (current.state === "esperando") {
      const busy = target.kind === "fisico" ? holder(target) : undefined
      return input.answer(current, {
        hold: current.id,
        state: "esperando",
        position: queue(target).findIndex((item) => item.id === current.id) + 1,
        reason: waitReason(target),
        ...(busy ? { expiresAt: worstEnd(timing(busy), input.times) } : {}),
      })
    }
    return input.answer(current, {
      hold: current.id,
      state: current.state,
      ...(current.reason ? { reason: { code: "orcamento", text: current.reason } } : {}),
    })
  }
  /** What the session can use now: a phone's id (its serial comes with P12's devices), the slot's name. */
  const device = (target: Target): Record<string, string> =>
    target.kind === "fisico" ? { id: phoneOf(target)?.id ?? target.device } : { nome: target.name }
  const waitReason = (target: Target): BancadaProtocol.Reason => {
    if (target.kind === "vaga") return { code: "orcamento", text: "sem folga para mais um aparelho agora" }
    const current = holder(target)
    const by = current ? (JSON.parse(current.origin) as BancadaProtocol.Origin) : undefined
    return {
      code: "aparelho_ocupado",
      detail: target.device,
      text: `aguardando ${target.device}${by ? ` (com ${by.rootTitle ?? by.sessionTitle ?? "outra sessão"} em ${by.name})` : ""}`,
    }
  }

  /** Gives a waiting hold its device when it can: a free phone, or room for one device. */
  const grant = (row: HoldRow) => {
    const target = targetOf(row)
    if (target.kind === "fisico") {
      if (holder(target)) return false
      update(row, { state: "concedida", acquired_at: input.now(), last_activity_at: input.now() })
      return true
    }
    const lease = input.reserve(target.platform)
    if (!lease) return false
    update(row, { state: "concedida", lease_id: lease, acquired_at: input.now(), last_activity_at: input.now() })
    return true
  }
  const end = (row: HoldRow, state: "vencida" | "solta" | "negada", reason?: string) => {
    if (row.lease_id) input.release(row.lease_id)
    update(row, { state, ended_at: input.now(), reason: reason ?? null })
    tell(row)
  }

  return {
    /**
     * A session asks for a hold (its family asking again keeps its hold, or its place in the queue). Answered at once:
     * granted, waiting with its place, or refused.
     */
    ask: (hold: string, origin: BancadaProtocol.Origin, originMachine: string, target: Target) =>
      db.transaction(() => {
        const mine = open
          .all()
          .find((row) => row.root_session_id === origin.rootSessionID && owned(targetOf(row)) === owned(target))
        if (mine) {
          update(mine, { last_seen_at: input.now() })
          return tell(mine)
        }
        db.run(
          "INSERT OR IGNORE INTO hold (id, origin_machine, origin, root_session_id, kind, platform, target, state, requested_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'esperando', ?, ?)",
          [
            hold,
            originMachine,
            JSON.stringify(origin),
            origin.rootSessionID,
            target.kind,
            target.kind === "vaga" ? target.platform : null,
            JSON.stringify(target),
            input.now(),
            input.now(),
          ],
        )
        const row = find.get(hold)!
        if (target.kind === "fisico") {
          const phone = phoneOf(target)
          if (!phone) return end(row, "negada", `${target.device} não está no catálogo desta máquina`)
          if (phone.policy === "negar") return end(row, "negada", `${target.device} não é reservável`)
        }
        // First in its queue: it may take the device at once.
        if (queue(target)[0]?.id === row.id) grant(row)
        tell(row)
      })(),
    /** Use by its family: the hold is renewed. */
    renew: (hold: string, at: number) =>
      db.run(
        "UPDATE hold SET last_activity_at = MAX(COALESCE(last_activity_at, 0), ?) WHERE id = ? AND state = 'concedida'",
        [at, hold],
      ),
    drop: (hold: string) =>
      db.transaction(() => {
        const row = find.get(hold)
        if (row && (row.state === "concedida" || row.state === "esperando")) end(row, "solta")
      })(),
    /** Expiry, then the queues: a place not asked again in `placeMs` is lost; the first live one takes what is free. */
    tick: () =>
      db.transaction(() => {
        const now = input.now()
        for (const row of open.all()) {
          if (row.state === "esperando" && now - row.last_seen_at >= input.times.placeMs)
            end(row, "solta", "o lugar na fila venceu")
        }
        for (const row of open.all()) {
          if (row.state !== "concedida") continue
          const why = expiry(timing(row), now, queue(targetOf(row)).length > 0, input.times)
          if (why) end(row, "vencida", why)
        }
        const firsts = new Map<string, HoldRow>()
        for (const row of open.all())
          if (row.state === "esperando" && !firsts.has(key(targetOf(row)))) firsts.set(key(targetOf(row)), row)
        for (const row of firsts.values()) if (grant(row)) tell(row)
      })(),
    /** Light slots waiting for room, per kind: the next room is theirs (the queue of tests waits behind them). */
    waiting: () => {
      const rows = open.all().filter((row) => row.state === "esperando" && row.kind === "vaga")
      return {
        android: rows.filter((row) => row.platform === "android").length,
        ios: rows.filter((row) => row.platform === "ios").length,
      }
    },
    /** Holds in force, for the hook: whose each device is. */
    held: () => open.all().filter((row) => row.state === "concedida"),
    find: (hold: string) => find.get(hold) ?? undefined,
  }
}

export type Holds = ReturnType<typeof makeHolds>

function minutes(ms: number) {
  return Math.max(1, Math.round(ms / 60_000))
}

export type MirrorRow = {
  readonly hold: string
  readonly session_id: string
  readonly root_session_id: string
  readonly machine_id: string
  readonly target: string
  readonly state: "pedida" | "concedida" | "esperando" | "negada" | "vencida" | "solta"
  readonly machine_name: string | null
  readonly device: string | null
  readonly expires_at: number | null
  readonly position: number | null
  readonly reason: string | null
  readonly requested_at: number
}

/**
 * What this server's sessions hold, here or on another machine, as the machine that has the device said
 * (`grant_mirror`): what the tools show and the hook checks without asking anyone. A hold that came out after waiting
 * and one that expired become notes in the session: the first wakes it (it was waiting for it), the second does not
 * (it expired because the session was idle; the hook refuses its next command anyway).
 */
export function makeMirror(input: {
  readonly db: Database
  readonly now: () => number
  /** A message id drawn once per note. */
  readonly messageID: () => string
  /** How long the session's call waits for the first answer (8 s): a grant after that is told by a note. */
  readonly answerMs: number
}) {
  const db = input.db
  const find = db.query<MirrorRow, [string]>("SELECT * FROM grant_mirror WHERE hold = ?")
  const note = (key: string, sessionID: string, text: string, resume: boolean) =>
    db.run(
      "INSERT OR IGNORE INTO note (key, session_id, message_id, text, resume, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [key, sessionID, input.messageID(), text, resume ? 1 : 0, input.now()],
    )
  return {
    /** A hold this server asks for (before any answer). */
    asked: (row: { hold: string; sessionID: string; rootSessionID: string; machineID: string; target: Target }) =>
      db.run(
        "INSERT OR IGNORE INTO grant_mirror (hold, session_id, root_session_id, machine_id, target, state, requested_at, updated_at) VALUES (?, ?, ?, ?, ?, 'pedida', ?, ?)",
        [
          row.hold,
          row.sessionID,
          row.rootSessionID,
          row.machineID,
          JSON.stringify(row.target),
          input.now(),
          input.now(),
        ],
      ),
    /**
     * What the machine that has the device said; `machine` names it (empty: the name known already). A hold that
     * comes out after the session stopped waiting for the answer (it waited in the queue, or the answer took longer
     * than the tool waits) becomes a note that wakes it.
     */
    answer: (answer: Answer, machine: string) => {
      const row = find.get(answer.hold)
      if (!row) return
      const name = machine || row.machine_name || "outra máquina"
      db.run(
        "UPDATE grant_mirror SET state = ?, machine_name = ?, device = ?, expires_at = ?, position = ?, reason = ?, updated_at = ? WHERE hold = ?",
        [
          answer.state,
          name,
          answer.device ? JSON.stringify(answer.device) : row.device,
          answer.expiresAt ?? null,
          answer.position ?? null,
          answer.reason?.text ?? null,
          input.now(),
          answer.hold,
        ],
      )
      const target: Target = JSON.parse(row.target)
      const late = row.state === "pedida" && input.now() - row.requested_at >= input.answerMs
      if (answer.state === "concedida" && (row.state === "esperando" || late))
        note(
          `${answer.hold}:concedida`,
          row.session_id,
          `[Bancada] Sua vaga saiu: ${targetText(target)} em ${name} (reserva ${answer.hold}). Use agora; ela vence se ficar parada.`,
          true,
        )
      if (answer.state === "vencida" && row.state === "concedida")
        note(
          `${answer.hold}:vencida`,
          row.session_id,
          `[Bancada] A reserva ${answer.hold} (${targetText(target)} em ${name}) venceu: ${answer.reason?.text ?? "ficou parada"}. Se ainda precisar, peça de novo com bancada_hold.`,
          false,
        )
    },
    find: (hold: string) => find.get(hold) ?? undefined,
    /** The holds of a session's family still asked, waiting or granted. */
    family: (rootSessionID: string) =>
      db
        .query<
          MirrorRow,
          [string]
        >("SELECT * FROM grant_mirror WHERE root_session_id = ? AND state IN ('pedida', 'esperando', 'concedida') ORDER BY requested_at")
        .all(rootSessionID),
    /** Every hold in force on any machine, for the hook. */
    granted: () => db.query<MirrorRow, []>("SELECT * FROM grant_mirror WHERE state = 'concedida'").all(),
    notes: () =>
      db
        .query<
          { key: string; session_id: string; message_id: string; text: string; resume: number },
          []
        >("SELECT key, session_id, message_id, text, resume FROM note WHERE delivered_at IS NULL ORDER BY created_at")
        .all(),
    noted: (key: string) => db.run("UPDATE note SET delivered_at = ? WHERE key = ?", [input.now(), key]),
  }
}

export type Mirror = ReturnType<typeof makeMirror>

/** `o celular poco-x7`, `a vaga para Pixel_9 (Android)`. */
export function targetText(target: Target) {
  return target.kind === "fisico"
    ? `o celular ${target.device}`
    : `a vaga para ${target.name} (${target.platform === "ios" ? "iOS" : "Android"})`
}
