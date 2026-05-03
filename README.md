# AD4M DevTools

Chrome DevTools extension for real-time debugging of AD4M applications.

## Architecture

This is a pnpm monorepo with two packages:

- **`packages/extension`** — Chrome DevTools panel (Preact + Vite)
- **`packages/bridge`** — Transport-aware instrumentation bridge

The extension is **transport-agnostic** — it reads from `window.__AD4M_DEVTOOLS__` state exposed by the bridge. The bridge adapters differ per AD4M transport:

| Branch | AD4M Branch | Transport |
|--------|-------------|-----------|
| `main` | `dev` | GraphQL / Apollo |
| `feat/sse-to-websocket` | `feat/sse-to-websocket` | REST + WebSocket RPC |
| `feat/sparql-1.2-cleanup` | `feat/sparql-1.2-cleanup` | GraphQL + SPARQL traces |

## Development

```bash
pnpm install
pnpm build
```

### Extension

```bash
cd packages/extension
pnpm dev  # watch mode
```

Load the `packages/extension/dist` directory as an unpacked Chrome extension.

### Bridge Integration

The bridge package exports `initDevToolsBridge()` which should be called from `Ad4mClient`'s constructor:

```typescript
import { initDevToolsBridge } from '@ad4m-devtools/bridge';

// In Ad4mClient constructor:
initDevToolsBridge(this);
```

## Branches

- **`main`** — GraphQL/Apollo adapter (works with `coasys/ad4m` `dev` branch)
- **`feat/sse-to-websocket`** — REST + WebSocket adapter (works with `coasys/ad4m` `feat/sse-to-websocket`)
- **`feat/sparql-1.2-cleanup`** — GraphQL + SPARQL trace enrichment (works with `coasys/ad4m` `feat/sparql-1.2-cleanup`)

## License

MIT
