# Fish Market Architecture

## Purpose

Fish Market is a Phoenix umbrella application that provides a LiveView UI for OpenClaw sessions.
It connects to an OpenClaw gateway over WebSocket, loads sessions/history, sends chat messages, and renders live updates.

## Repository Layout

- `apps/fish_market`
  - Core runtime app.
  - Owns PubSub and the persistent OpenClaw gateway client.
  - Exposes the `FishMarket.OpenClaw` API used by LiveViews.
- `apps/fish_market_web`
  - Phoenix web app.
  - Owns Endpoint, Router, LiveViews, assets, and UI behavior.
- `config`
  - Shared umbrella config and runtime environment loading.
- `docs`
  - Project documentation.

## Runtime and Supervision

### `fish_market` app

`FishMarket.Application` starts:

- `DNSCluster` (optional cluster discovery)
- `Phoenix.PubSub` (`FishMarket.PubSub`)
- `FishMarket.OpenClaw.GatewayClient`

`GatewayClient` is a GenServer using `Mint.HTTP` + `Mint.WebSocket`.
It handles transport connect/reconnect, websocket upgrade, handshake (`connect`), request/response correlation, and event broadcasting.

### `fish_market_web` app

`FishMarketWeb.Application` starts:

- `FishMarketWeb.Telemetry`
- `FishMarketWeb.Endpoint`

## OpenClaw Integration

### Required runtime env vars

Configured in `config/runtime.exs` (except test):

- `OPENCLAW_GATEWAY_URL` (required)
- At least one of:
  - `OPENCLAW_GATEWAY_TOKEN`
  - `OPENCLAW_GATEWAY_PASSWORD`

### Core API surface

`FishMarket.OpenClaw` provides gateway methods:

- `sessions_list/1`
- `sessions_patch/2`
- `chat_history/2`
- `chat_send/3`

Gateway client connect metadata advertises `caps: ["tool-events"]` so OpenClaw can route live
tool-event streams to Fish Market connections.

And PubSub helpers for subscription/broadcast.

### PubSub topology

Topics used by the app:

- `openclaw:gateway`
  - transport/connect/disconnect status
- `openclaw:chat`
  - broad chat events used by menu/unread behavior
- `openclaw:event:<event_name>`
  - per-event fanout
- `openclaw:session:<session_key>`
  - per-session fanout for session-specific updates

This lets `SessionLive` process both global and selected-session-specific streams.

## Web UI Composition

Route definition:

- `"/"` -> `FishMarketWeb.SessionLive`
- `"/session/:session_id"` -> `FishMarketWeb.SessionLive`

`SessionLive` renders the full shell and composes:

- `FishMarketWeb.MenuLive` (master pane, rendered as a LiveComponent)

### `MenuLive` responsibilities

- Load and render session list.
- Maintain selected session key.
- Track unread session badges (`new`) for background activity.
- Send selected session changes to `SessionLive` via `menu-select-session` events.
- Refresh sessions on connection or terminal chat states (`final`, `aborted`, `error`).

### `SessionLive` responsibilities

- React to selected session changes (including route params).
- Subscribe to the active session streams.
- Load and display session history.
- Send chat messages and queue while a new session is being created.
- Render live streaming assistant output.
- Render tool events as trace messages.
- Toggle trace visibility and persist preference via cookie-backed connect params.
- Load `models.list` once per LiveView lifecycle and cache model options for the top-bar model picker.
- Patch per-session model/thinking overrides via `sessions.patch` from top-bar controls.
- When traces are enabled for a session, request `sessions.patch` with `verboseLevel: "on"` so
  OpenClaw emits tool event streams for that session.

### Routing and session identity

- Session routes use encoded session tokens.
- `FishMarketWeb.SessionRoute` handles encode/decode plus validation.
- URL tokens are normalized before session selection is accepted.

## Front-End JS Responsibilities

`apps/fish_market_web/assets/js/app.js` handles:

- LiveSocket setup.
- Theme persistence (`localStorage`).
- Sidebar/open-close interactions for layout.
- Chat input focus/clear events.
- Auto-scroll behavior for messages (stick to bottom only when already near bottom).
- Trace preference cookie:
  - Reads cookie on LiveSocket connect (`show_traces` param).
  - Persists toggle updates from `phx:set-show-traces`.

## Data Flow (High-Level)

### Startup

1. `GatewayClient` boots and connects to OpenClaw.
2. `SessionLive` subscribes to required topics, loads sessions, and loads models.
3. `SessionLive` resolves selected session from params and loads history if present.

### Session selection

1. User clicks a session in `MenuLive`.
2. `MenuLive` sends `menu-select-session` with `session_key`.
3. `SessionLive` updates selected session state, resets transient view state, and loads history.

### Chat send

1. User submits message in `SessionLive`.
2. Message is optimistically rendered locally.
3. `OpenClaw.chat_send/3` is called.
4. Incoming events update stream state and history.

### Streaming to final

1. Delta/tool/agent events update in-flight UI.
2. On terminal state, history reload is requested.
3. Stream placeholder is cleared after history applies.

## Key Files

- Core
  - `apps/fish_market/lib/fish_market/application.ex`
  - `apps/fish_market/lib/fish_market/open_claw.ex`
  - `apps/fish_market/lib/fish_market/open_claw/gateway_client.ex`
  - `apps/fish_market/lib/fish_market/open_claw/message.ex`
- Web
  - `apps/fish_market_web/lib/fish_market_web/router.ex`
  - `apps/fish_market_web/lib/fish_market_web/session_route.ex`
  - `apps/fish_market_web/lib/fish_market_web/live/menu_live.ex`
  - `apps/fish_market_web/lib/fish_market_web/live/menu_live.html.heex`
  - `apps/fish_market_web/lib/fish_market_web/live/session_live.ex`
  - `apps/fish_market_web/lib/fish_market_web/live/session_live.html.heex`
  - `apps/fish_market_web/assets/js/app.js`
- Config
  - `config/config.exs`
  - `config/runtime.exs`

## Development Notes

- Preferred validation command: `mix precommit`
- Asset pipeline is Phoenix-native (`tailwind` + `esbuild`) and configured in umbrella config.
