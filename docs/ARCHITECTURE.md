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
tool stream events to Fish Market connections.

And PubSub helpers for subscription/broadcast.

### PubSub topology

Topics used by the app:

- `openclaw:gateway`
  - transport/connect/disconnect status
- `openclaw:chat`
  - broad chat events used by menu/unread behavior
- `openclaw:ui:session-selection`
  - UI session selection coordination between LiveViews
- `openclaw:event:<event_name>`
  - per-event fanout
- `openclaw:session:<session_key>`
  - per-session fanout for session-specific updates

This lets `MenuLive` observe global updates while `SessionLive` only processes the selected session stream.

## Web UI Composition

Route definition:

- `"/"` -> `FishMarketWeb.ApplicationLive`

`ApplicationLive` renders the shell and composes two child LiveViews:

- `FishMarketWeb.MenuLive` (master pane)
- `FishMarketWeb.SessionLive` (detail pane)

### `MenuLive` responsibilities

- Load and render session list.
- Maintain selected session key.
- Track unread session badges (`new`) for background activity.
- Broadcast selection events (`openclaw:ui:session-selection`).
- Refresh sessions on connection or terminal chat states (`final`, `aborted`, `error`).

### `SessionLive` responsibilities

- React to selected session changes.
- Subscribe to the active session topic.
- Load and display session history.
- Send chat messages and queue while a new session is being created.
- Render live streaming assistant output.
- Render tool events as trace messages.
- Toggle trace visibility and persist preference via cookie-backed connect params.
- When traces are enabled for a session, request `sessions.patch` with `verboseLevel: "on"` so
  OpenClaw emits tool event streams for that session.

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
2. `MenuLive` and `SessionLive` subscribe to required topics.
3. `MenuLive` loads sessions and publishes default/selected session.

### Session selection

1. User clicks a session in `MenuLive`.
2. `MenuLive` broadcasts selection topic.
3. `SessionLive` receives selection, resets transient view state, subscribes to that session topic, loads history.

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
  - `apps/fish_market_web/lib/fish_market_web/live/application_live.ex`
  - `apps/fish_market_web/lib/fish_market_web/live/menu_live.ex`
  - `apps/fish_market_web/lib/fish_market_web/live/session_live.ex`
  - `apps/fish_market_web/assets/js/app.js`
- Config
  - `config/config.exs`
  - `config/runtime.exs`

## Development Notes

- Preferred validation command: `mix precommit`
- Asset pipeline is Phoenix-native (`tailwind` + `esbuild`) and configured in umbrella config.
