import type { Database } from "bun:sqlite"
import type { BancadaProtocol } from "../protocol.js"

type Row = {
  readonly out_stream: string
  readonly out_seq: number
  readonly out_acked: number
  readonly in_stream: string | null
  readonly in_seq: number
}

/** One side's stream to a peer, as `BancadaProtocol` carries it. */
export type Stream<M = unknown> = {
  readonly stream: string
  readonly base: number
  readonly messages: ReadonlyArray<BancadaProtocol.Envelope<M>>
}

/**
 * The outbox and the inbox cursors of this side, per peer (the hub is the peer `hub` of a machine; each machine is a
 * peer of the hub, by `machineID`). Writing a message and the change that produced it share the caller's transaction;
 * applying a message and moving the cursor share one, so a crash neither repeats nor skips a message.
 */
export function makeMessages(db: Database, random: () => string, now: () => number) {
  const read = db.query<Row, [string]>(
    "SELECT out_stream, out_seq, out_acked, in_stream, in_seq FROM peer WHERE peer = ?",
  )
  const row = (peer: string): Row => {
    const found = read.get(peer)
    if (found) return found
    db.run("INSERT INTO peer (peer, out_stream, out_seq, out_acked, in_stream, in_seq) VALUES (?, ?, 0, 0, NULL, 0)", [
      peer,
      random(),
    ])
    return read.get(peer)!
  }
  const pending = db.query<{ seq: number; body: string }, [string]>(
    "SELECT seq, body FROM outbox WHERE peer = ? ORDER BY seq",
  )

  return {
    /** Writes a message to `peer`; returns its sequence number. Call inside the transaction of the change. */
    send<M>(peer: string, body: M) {
      const seq = row(peer).out_seq + 1
      db.run("UPDATE peer SET out_seq = ? WHERE peer = ?", [seq, peer])
      db.run("INSERT INTO outbox (peer, seq, body, created_at) VALUES (?, ?, ?, ?)", [
        peer,
        seq,
        JSON.stringify(body),
        now(),
      ])
      return seq
    },
    /**
     * Everything `peer` has not acknowledged yet, in order. `M` is the type this side gave `send` for that peer: the
     * bodies are its own messages, stored as JSON.
     */
    outgoing<M>(peer: string): Stream<M> {
      const current = row(peer)
      return {
        stream: current.out_stream,
        base: current.out_acked,
        messages: pending.all(peer).map((message) => ({ seq: message.seq, body: JSON.parse(message.body) as M })),
      }
    },
    /** `peer` applied this side's stream up to `ack`: those messages leave the outbox. Another stream's ack is old. */
    acked(peer: string, ack: BancadaProtocol.Ack) {
      const current = row(peer)
      if (!ack || ack.stream !== current.out_stream || ack.seq <= current.out_acked) return
      const seq = Math.min(ack.seq, current.out_seq)
      db.transaction(() => {
        db.run("DELETE FROM outbox WHERE peer = ? AND seq <= ?", [peer, seq])
        db.run("UPDATE peer SET out_acked = ? WHERE peer = ?", [seq, peer])
      })()
    },
    /**
     * Applies the next messages of `peer`'s stream, in order, each with its cursor in one transaction; repeated ones
     * are skipped and a gap stops. Returns whether the stream was unknown (the peer is new, or replaced its
     * database): the cursor then starts after `base`, what the peer's earlier receiver already acknowledged.
     */
    receive(peer: string, incoming: Stream, apply: (body: unknown, seq: number) => void) {
      const renewed = row(peer).in_stream !== incoming.stream
      if (renewed)
        db.run("UPDATE peer SET in_stream = ?, in_seq = ? WHERE peer = ?", [incoming.stream, incoming.base, peer])
      for (const message of incoming.messages) {
        const next = row(peer).in_seq + 1
        if (message.seq < next) continue
        if (message.seq > next) break
        db.transaction(() => {
          apply(message.body, message.seq)
          db.run("UPDATE peer SET in_seq = ? WHERE peer = ?", [message.seq, peer])
        })()
      }
      return renewed
    },
    /** The last message applied from `peer`'s stream, to acknowledge it. */
    ack(peer: string): BancadaProtocol.Ack {
      const current = row(peer)
      return current.in_stream === null ? null : { stream: current.in_stream, seq: current.in_seq }
    },
    /** The last sequence number `peer` acknowledged of this side's stream. */
    acknowledged(peer: string) {
      return row(peer).out_acked
    },
  }
}

export type Messages = ReturnType<typeof makeMessages>
