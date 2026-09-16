# Host-supplied primary-source references

Collected by the host on 2026-09-16 for the research frontier. These references are evidence inputs, not conclusions about the local Codex host.

## OpenAI async tool calling

- Official guide: https://developers.openai.com/api/docs/guides/async-tool-calling
- Official current-model guide: https://developers.openai.com/api/docs/guides/latest-model
- Official Responses API reference: https://developers.openai.com/api/reference/cli/resources/responses/methods/create

The official guides state that async function/custom tool execution remains application-managed. A later Responses request supplies the result using the original `call_id`. This supports distinguishing API-level asynchronous tool continuation from a still-pending synchronous MCP tool call; it does not by itself establish Codex Desktop timeout behavior.

The Responses API reference also exposes response states and tool-call output items. Any claim about the desktop client's actual timeout, reconnection, or automatic redispatch behavior must therefore be supported by installed code or a bounded local experiment, not inferred from these API documents.

