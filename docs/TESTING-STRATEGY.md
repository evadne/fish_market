# Testing Strategy

*Proposed 2026-02-15. Pending review.*

## Current State

| Module | Tests | Notes |
|---|---|---|
| `FishMarket.OpenClaw.Message` | 2 | Blank text fallback, error message extraction |
| `FishMarketWeb.SessionRoute` | 3 | Encode/decode, validation, malformed rejection |
| `FishMarketWeb.ErrorHTML/JSON` | 4 | Complete |
| `FishMarketWeb.ApplicationLiveTest` | 8 | Shell rendering, streaming, thinking, tool traces, delta modes |
| **Total** | **17** (1 pre-existing failure) | |

## Pre-existing Failure

`ApplicationLiveTest` — `#session-model-select` element assertion fails. Likely a template change that removed or renamed the element ID. Should be fixed before adding new tests.

## Untested Modules

### FishMarket.OpenClaw (~150 LOC)
PubSub wiring, request dispatch, topic helpers. All public API untested.

### FishMarket.OpenClaw.GatewayClient (~500 LOC)
Core WebSocket GenServer. Complex state machine: connect → upgrade → challenge → ready → request/response. Zero tests.

### FishMarketWeb.SessionLive (event handlers)
Remaining untested: `send-message`, `new-session`, `delete-session`, `change-session-model/thinking/verbosity/label`, history loading/error states, gateway reconnection.

### FishMarketWeb.MenuLive
Zero tests. Helper functions for session display.

## Proposed Additions (Priority Order)

### 1. Message edge cases (low effort, high value)
- Timestamp normalization: seconds vs milliseconds, ISO 8601 strings, nil/zero
- Multi-part content extraction: mixed text + thinking + tool_call arrays
- Tool call name extraction from content arrays
- Thinking tag stripping (`<thinking>`, `<think>`, nested, malformed)
- Role extraction defaults

### 2. SessionRoute edge cases (low effort)
- URL-encoded session keys
- Boundary patterns (empty segments, trailing colons)

### 3. SessionLive interaction tests (medium effort)
- `send-message`: valid send, empty message rejection, pending session queuing
- `new-session`: creation flow, placeholder insertion in menu
- `delete-session`: optimistic removal, adjacent session selection, error rollback
- Model/thinking/verbosity selector changes: optimistic update, error flash
- History loading: success, invalid payload, error state
- Gateway disconnect/reconnect: error message display, auto-reload

### 4. OpenClaw context tests (medium effort)
- Topic string generation (`session_topic/1`, `event_topic`)
- Idempotency key format validation
- PubSub broadcast/subscribe wiring (subscribe then assert_receive)
- `request/3` when gateway unavailable

### 5. GatewayClient (high effort — defer)
Would need mock WebSocket server or careful process-level testing. The existing `ApplicationLiveTest` covers happy path indirectly via PubSub event injection. Recommend deferring unless stability concerns arise.

## Recommendations

- Fix the pre-existing `#session-model-select` failure first
- Implement groups 1–4
- Defer group 5 until a mock WebSocket test helper is justified
