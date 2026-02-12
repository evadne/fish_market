# Fish Market

This is a WIP Elixir/Phoenix application acting as a front-end to OpenClaw.

![fish](./docs/fish.png)

## Configuration

The application should be run with the following envars:

- `OPENCLAW_GATEWAY_URL`
- `OPENCLAW_GATEWAY_TOKEN` or `OPENCLAW_GATEWAY_PASSWORD`

The application should be hosted behind Cloudflare Zero Trust, as there is no authentication support currently.

## TODO

- Packaging via Mix Release and testing with systemd unit, etc
- More Session Management stuff
- Refinement

## OpenClaw Upstream Bugs / Follow-ups

These are issues identified while building Fish Market that appear to be on the OpenClaw side.

- Thinking/reasoning stream is produced in embedded subscribe code, but not wired through gateway `chat.send`.
  - OpenClaw references:
    - `src/agents/pi-embedded-subscribe.handlers.messages.ts` (`emitReasoningStream(...)`)
    - `src/agents/pi-embedded-subscribe.ts` (`onReasoningStream` callback usage)
    - `src/gateway/server-methods/chat.ts` (`dispatchInboundMessage(...)` call in `chat.send` should wire `onReasoningStream`)
- Gateway chat projection currently emits text-only `chat` deltas/finals. Reasoning stream does not reach webchat clients through the chat channel.
  - OpenClaw reference:
    - `src/gateway/server-chat.ts` (`emitChatDelta` / `emitChatFinal`)
- OpenClaw web UI chat controller handles `chat` events for streaming text, but does not consume reasoning stream events as first-class chat traces.
  - OpenClaw reference:
    - `ui/src/ui/controllers/chat.ts`
- The control UI speaker label is not sourced from per-message sender metadata; it is injected via a bootstrap global `window.__OPENCLAW_ASSISTANT_NAME__` and then resolved from backend config.
  - OpenClaw references:
    - `src/gateway/control-ui.ts` (`injectControlUiConfig`, `window.__OPENCLAW_ASSISTANT_NAME__`)
    - `src/gateway/assistant-identity.ts` (`resolveAssistantIdentity` precedence)
    - `src/gateway/server-methods/agent.ts` (`agent.identity.get`)
    - `ui/src/ui/assistant-identity.ts`
