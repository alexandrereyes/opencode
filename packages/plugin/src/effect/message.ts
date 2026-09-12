import type { MessageApi } from "@opencode/client/effect/api"

export interface MessageDomain<E = unknown> extends MessageApi<E> {}
