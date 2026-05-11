# AD4M DevTools

Chrome DevTools extension for real-time debugging of AD4M applications.

## Architecture

This is a pnpm monorepo with two packages:

- **`packages/extension`** — Chrome DevTools panel (Preact + Vite)
- **`packages/bridge`** — WebSocket-first instrumentation bridge

The extension reads from `window.__AD4M_DEVTOOLS__` state exposed by the bridge.

Current bridge behavior on this branch:

- WS-RPC request/response pairing (`id` correlation)
- WebSocket event tracking (including subscription updates)
- Multi-response subscription aggregation
- Response period and byte metrics
- Socket/frame counters and totals
- Call stack capture on websocket operations/events

The bridge supports two runtime modes:

1. Integrated mode: app/SDK calls `initDevToolsBridge(client)`
2. External mode: extension injects page-world websocket monitor via `initExternalWebSocketDevTools()`

## Development

```bash
pnpm install
pnpm build
```

## Testing

```bash
pnpm test          # workspace unit tests
pnpm test:e2e      # build + Playwright integration tests
pnpm test:all      # unit + e2e
```

### Extension

```bash
cd packages/extension
pnpm dev  # watch mode
```

Load the `packages/extension/dist` directory as an unpacked Chrome extension.

The extension injects `page-inject.js` into the page world to instrument `window.WebSocket` directly when needed.

### Bridge Integration

The bridge package exports `initDevToolsBridge()` which should be called from `Ad4mClient`'s constructor:

```typescript
import { initDevToolsBridge } from '@ad4m-devtools/bridge';

// In Ad4mClient constructor:
initDevToolsBridge(this);
```

For extension-only fallback instrumentation in page context:

```typescript
import { initExternalWebSocketDevTools } from '@ad4m-devtools/bridge';

initExternalWebSocketDevTools();
```

## Branches

- **`main`** — WebSocket-first bridge + external injection support

## License

MIT
