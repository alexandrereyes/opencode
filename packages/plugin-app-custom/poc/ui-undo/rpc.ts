import { Rpc } from "@opencode/plugin/rpc"

export const UiUndoRpc = Rpc.define({
  id: "poc.ui-undo",
  methods: {
    record: {
      input: {
        type: "object",
        properties: {
          childSessionID: { type: "string" },
          inputID: { type: "string" },
          assignedSeq: { type: "number" },
          origin: {
            type: "object",
            properties: {
              parentSessionID: { type: "string" },
              parentMessageID: { type: "string" },
              toolCallID: { type: "string" },
            },
            required: ["parentSessionID", "parentMessageID", "toolCallID"],
            additionalProperties: false,
          },
        },
        required: ["childSessionID", "inputID", "assignedSeq", "origin"],
        additionalProperties: false,
      },
      output: { type: "boolean" },
    },
    importLegacy: {
      input: {
        type: "object",
        properties: {
          rows: {
            type: "array",
            items: {
              type: "object",
              properties: {
                inputID: { type: "string" },
                parentSessionID: { type: "string" },
                childSessionID: { type: "string" },
                assignedSeq: { type: "number" },
                messageID: { type: "string" },
                toolCallID: { type: "string" },
              },
              required: ["inputID", "parentSessionID", "childSessionID", "assignedSeq", "messageID", "toolCallID"],
              additionalProperties: false,
            },
          },
        },
        required: ["rows"],
        additionalProperties: false,
      },
      output: {
        type: "object",
        properties: { migrated: { type: "number" }, alreadyApplied: { type: "boolean" } },
        required: ["migrated", "alreadyApplied"],
        additionalProperties: false,
      },
    },
    stage: {
      input: {
        type: "object",
        properties: { rootSessionID: { type: "string" }, rootMessageID: { type: "string" } },
        required: ["rootSessionID", "rootMessageID"],
        additionalProperties: false,
      },
      output: {
        type: "object",
        properties: { phase: { type: "string", enum: ["staged"] } },
        required: ["phase"],
        additionalProperties: false,
      },
    },
    redo: {
      input: {
        type: "object",
        properties: { rootSessionID: { type: "string" } },
        required: ["rootSessionID"],
        additionalProperties: false,
      },
      output: { type: "boolean" },
    },
  },
  events: {
    lateCancellation: {
      schema: {
        type: "object",
        properties: {
          sessionID: { type: "string" },
          inboxID: { type: "string" },
          outcome: { type: "string", enum: ["cancelled", "too-late"] },
        },
        required: ["sessionID", "inboxID", "outcome"],
        additionalProperties: false,
      },
    },
  },
})
