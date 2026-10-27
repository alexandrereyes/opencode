import { Data } from "effect"

/** A gateway error with its HTTP status: `{ error: { code, message } }`, message in short pt-BR. */
export class Failure extends Data.TaggedError("Watch.Failure")<{
  readonly status: number
  readonly code: string
  readonly message: string
}> {}

export const fail = (status: number, code: string, message: string) => new Failure({ status, code, message })
