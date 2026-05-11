import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import {
  installWebSocketMonitor,
  stashCallerStack,
  patchClientForCallerStacks,
  patchModelClassForCallerStacks,
} from './websocket';
import type { OperationRecord } from '../core/types';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class FakeWebSocket {
  static instances: FakeWebSocket[] = [];
  url: string;
  readyState = 1;
  listeners: Record<string, Array<(event?: any) => void>> = {};
  sent: any[] = [];

  constructor(url: string) {
    this.url = url;
    FakeWebSocket.instances.push(this);
  }
  addEventListener(type: string, cb: (event?: any) => void) {
    if (!this.listeners[type]) this.listeners[type] = [];
    this.listeners[type].push(cb);
  }
  send(data: any) { this.sent.push(data); }
  emit(type: string, event?: any) {
    for (const cb of this.listeners[type] || []) cb(event);
  }
}

/** Minimal bridge that collects operations and their stack traces. */
function createMockBridge() {
  const ops = new Map<number, Partial<OperationRecord>>();
  let nextId = 1;
  return {
    ops,
    bridge: {
      logOperation(op: Partial<OperationRecord>) {
        const id = nextId++;
        ops.set(id, { ...op, id });
        return id;
      },
      completeOperation(id: number, result: any, errors?: any[]) {
        const op = ops.get(id)!;
        if (op) ops.set(id, { ...op, response: result, errors, endTime: Date.now() });
      },
      patchOperation(id: number, patch: Partial<OperationRecord>) {
        const op = ops.get(id)!;
        if (op) ops.set(id, { ...op, ...patch });
      },
      getOperation(id: number) { return ops.get(id) as OperationRecord | undefined; },
      recordEventStreamMessage() {},
      recordWebSocketFrame() {},
      setActiveWebSockets() {},
    } as any,
  };
}

/** Returns the stack trace of the most recent WS-RPC operation logged. */
function lastRpcStackTrace(ops: Map<number, Partial<OperationRecord>>): string | undefined {
  const rpcOps = [...ops.values()].filter(o =>
    o.method === 'WS-RPC' || o.operationName?.startsWith('WS-RPC')
  );
  return rpcOps[rpcOps.length - 1]?.stackTrace as string | undefined;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('caller stack capture', () => {
  const originalWebSocket = (globalThis as any).WebSocket;
  let monitor: ReturnType<typeof installWebSocketMonitor>;
  let ws: FakeWebSocket;
  let mockBridge: ReturnType<typeof createMockBridge>;

  beforeEach(() => {
    FakeWebSocket.instances = [];
    (globalThis as any).WebSocket = FakeWebSocket as any;
    delete (globalThis as any).__AD4M_DEVTOOLS_WS_INSTALLED__;

    mockBridge = createMockBridge();
    monitor = installWebSocketMonitor(mockBridge.bridge);
    ws = new (globalThis as any).WebSocket('ws://127.0.0.1:12000/api/v1/ws') as FakeWebSocket;
    ws.emit('open');
  });

  afterEach(() => {
    monitor.uninstall();
    (globalThis as any).WebSocket = originalWebSocket;
    delete (globalThis as any).__AD4M_DEVTOOLS_WS_INSTALLED__;
  });

  function sendRpc(id: string, method: string) {
    ws.send(JSON.stringify({ id, type: method, params: {} }));
  }

  // -----------------------------------------------------------------------
  // stashCallerStack
  // -----------------------------------------------------------------------

  it('stashCallerStack is consumed by the next ws.send', () => {
    stashCallerStack('at myFunction (app.js:10:5)\nat main (app.js:1:1)');
    sendRpc('1', 'perspective.all');

    const stack = lastRpcStackTrace(mockBridge.ops);
    expect(stack).toBeDefined();
    expect(stack).toContain('myFunction');
    expect(stack).toContain('--- async ws.send ---');
  });

  it('stashed stack is cleared after consumption (not reused)', () => {
    stashCallerStack('at myFunction (app.js:10:5)');
    sendRpc('1', 'perspective.all');

    // Second send should NOT contain the stashed stack
    sendRpc('2', 'agent.status');
    const stack2 = lastRpcStackTrace(mockBridge.ops);
    expect(stack2).not.toContain('myFunction');
  });

  it('ws.send without stash still captures a stack trace', () => {
    sendRpc('1', 'perspective.all');
    const stack = lastRpcStackTrace(mockBridge.ops);
    expect(stack).toBeDefined();
    expect(stack!.length).toBeGreaterThan(0);
    expect(stack).not.toContain('--- async ws.send ---');
  });

  // -----------------------------------------------------------------------
  // wrapAsyncMethods (via patchClientForCallerStacks)
  // -----------------------------------------------------------------------

  it('patchClientForCallerStacks wraps sub-client async methods to stash a stack', async () => {
    // Build a fake client whose .perspective.all() calls ws.send
    const client = {
      perspective: {
        all: async function all() {
          sendRpc('10', 'perspective.all');
          return [];
        },
      },
    };

    patchClientForCallerStacks(client);

    await client.perspective.all();

    const stack = lastRpcStackTrace(mockBridge.ops);
    expect(stack).toBeDefined();
    // The stashed stack should include this test function's frame
    expect(stack).toContain('--- async ws.send ---');
  });

  it('patchClientForCallerStacks wraps PerspectiveProxy returned by byUUID', async () => {
    const fakeProxy = {
      querySparql: async function querySparql(q: string) {
        sendRpc('20', 'perspective.querySparql');
        return [];
      },
    };

    const client = {
      perspective: {
        byUUID: async function byUUID(uuid: string) {
          return fakeProxy;
        },
        // Provide these so the patching loop doesn't error
        all: async () => [],
      },
    };

    patchClientForCallerStacks(client);

    const proxy = await client.perspective.byUUID('test-uuid');
    await proxy.querySparql('SELECT * WHERE { ?s ?p ?o }');

    const stack = lastRpcStackTrace(mockBridge.ops);
    expect(stack).toBeDefined();
    expect(stack).toContain('--- async ws.send ---');
  });

  // -----------------------------------------------------------------------
  // patchModelClassForCallerStacks
  // -----------------------------------------------------------------------

  it('patchModelClassForCallerStacks wraps static methods', async () => {
    class FakeModel {
      static async findAll(opts: any) {
        sendRpc('30', 'perspective.modelQuery');
        return [];
      }
    }

    patchModelClassForCallerStacks(FakeModel);

    await FakeModel.findAll({});

    const stack = lastRpcStackTrace(mockBridge.ops);
    expect(stack).toBeDefined();
    expect(stack).toContain('--- async ws.send ---');
  });

  it('preserves function name on patched model methods', () => {
    class FakeModel {
      static async findAll() { return []; }
      static async findOne() { return null; }
    }

    patchModelClassForCallerStacks(FakeModel);

    expect(FakeModel.findAll.name).toBe('findAll');
    expect(FakeModel.findOne.name).toBe('findOne');
  });

  // -----------------------------------------------------------------------
  // Outermost-wins: the critical behavior
  // -----------------------------------------------------------------------

  describe('outermost-wins semantics', () => {
    it('inner wrapAsyncMethods wrapper does NOT overwrite outer wrapper stack', async () => {
      /**
       * Simulates the real call chain:
       *   app code → proxy.querySparql() → client.querySparql() → ws.send()
       *
       * Both proxy and client are wrapped by wrapAsyncMethods.
       * The proxy wrapper (outermost) should win — its stack includes the
       * application frame. The client wrapper (inner) must NOT overwrite it.
       */
      let capturedStack: string | undefined;

      const innerClient = {
        querySparql: async function querySparql(q: string) {
          // This is the innermost call that talks to the wire
          sendRpc('40', 'perspective.querySparql');
        },
      };

      const outerProxy = {
        querySparql: async function querySparql(q: string) {
          // Delegates to the inner client (like PerspectiveProxy → PerspectiveClient)
          return innerClient.querySparql(q);
        },
      };

      const client = {
        perspective: outerProxy,
      };

      // Patch both levels (simulates what patchClientForCallerStacks does)
      patchClientForCallerStacks(client);
      // Also directly wrap innerClient (simulates sub-client patching)
      // patchClientForCallerStacks already wrapped outerProxy, so let's
      // wrap innerClient separately to simulate the two-layer wrapper chain
      const innerClientWrapper = { perspective: innerClient };
      patchClientForCallerStacks(innerClientWrapper);

      // Now call from "application code" — this function's name should appear
      await (async function applicationCodeFindAll() {
        await outerProxy.querySparql('SELECT * WHERE { ?s ?p ?o }');
      })();

      const stack = lastRpcStackTrace(mockBridge.ops);
      expect(stack).toBeDefined();
      expect(stack).toContain('--- async ws.send ---');

      // The stashed part (before the separator) should contain the OUTER
      // wrapper's capture, which includes applicationCodeFindAll
      const stashedPart = stack!.split('--- async ws.send ---')[0];
      expect(stashedPart).toContain('applicationCodeFindAll');
    });

    it('Model static wrapper + sub-client wrapper: outermost (Model) wins', async () => {
      /**
       * Real chain: findAll() → executeModelQuery() → client.querySparql() → ws.send()
       *
       * Model static methods are patched by patchModelClassForCallerStacks.
       * client.querySparql is patched by patchClientForCallerStacks (wrapAsyncMethods).
       *
       * The Model wrapper fires first (outermost) and should win.
       */
      const fakeClient = {
        querySparql: async function querySparql(q: string) {
          sendRpc('50', 'perspective.querySparql');
          return [];
        },
      };

      // Wrap the client's methods
      const wrapper = { perspective: fakeClient };
      patchClientForCallerStacks(wrapper);

      class TestModel {
        static async findAll(opts: any) {
          // Simulates the internal call chain
          return fakeClient.querySparql('SELECT * WHERE { ?s ?p ?o }');
        }
        static async executeModelQuery(opts: any) {
          return fakeClient.querySparql('SELECT * WHERE { ?s ?p ?o }');
        }
      }

      patchModelClassForCallerStacks(TestModel);

      // Application code calls findAll
      await (async function vueComponentSetup() {
        await TestModel.findAll({ where: {} });
      })();

      const stack = lastRpcStackTrace(mockBridge.ops);
      expect(stack).toBeDefined();

      const stashedPart = stack!.split('--- async ws.send ---')[0];
      // The outermost wrapper (findAll on TestModel) fires first.
      // Its captured stack should include vueComponentSetup.
      expect(stashedPart).toContain('vueComponentSetup');
    });

    it('three levels of wrapping: outermost still wins', async () => {
      /**
       * Chain: app → proxy.findAll() → client.querySparql() → apiClient.call() → ws.send()
       * All three are wrapped. Only the outermost stack should survive.
       */
      const apiClient = {
        call: async function call(method: string, params: any) {
          sendRpc('60', method);
        },
      };

      const perspectiveClient = {
        querySparql: async function querySparql(q: string) {
          return apiClient.call('perspective.querySparql', { query: q });
        },
      };

      const perspectiveProxy = {
        querySparql: async function querySparql(q: string) {
          return perspectiveClient.querySparql(q);
        },
      };

      // Wrap all three levels
      const c1 = { perspective: perspectiveProxy };
      patchClientForCallerStacks(c1);
      const c2 = { perspective: perspectiveClient };
      patchClientForCallerStacks(c2);
      const c3 = { perspective: apiClient };
      patchClientForCallerStacks(c3);

      await (async function topLevelAppCode() {
        await perspectiveProxy.querySparql('SELECT ?s WHERE { ?s ?p ?o }');
      })();

      const stack = lastRpcStackTrace(mockBridge.ops);
      expect(stack).toBeDefined();

      const stashedPart = stack!.split('--- async ws.send ---')[0];
      expect(stashedPart).toContain('topLevelAppCode');
    });

    it('stash is cleaned up after the call completes', async () => {
      const client = {
        perspective: {
          doSomething: async function doSomething() {
            sendRpc('70', 'perspective.doSomething');
          },
        },
      };

      patchClientForCallerStacks(client);

      await client.perspective.doSomething();

      // Now a raw ws.send should NOT have a stale stashed stack
      sendRpc('71', 'agent.status');
      const stack = lastRpcStackTrace(mockBridge.ops);
      // Should be a plain ws.send stack (no separator), not a leftover stash
      expect(stack).not.toContain('doSomething');
    });

    it('error in wrapped method clears the stash', async () => {
      const client = {
        perspective: {
          failingMethod: async function failingMethod() {
            throw new Error('boom');
          },
        },
      };

      patchClientForCallerStacks(client);

      try {
        await client.perspective.failingMethod();
      } catch { /* expected */ }

      // Stash should be cleared — next send should not have a stale stack
      sendRpc('80', 'agent.status');
      const stack = lastRpcStackTrace(mockBridge.ops);
      expect(stack).not.toContain('failingMethod');
    });
  });

  // -----------------------------------------------------------------------
  // Async break (the real scenario)
  // -----------------------------------------------------------------------

  describe('async break in ApiClient.call (await _ready)', () => {
    it('stash survives a single microtask yield before ws.send', async () => {
      /**
       * Real scenario: ApiClient.call() does `await this._ready()` before
       * `this._ws.send()`. Even though _ready() resolves immediately,
       * `await` always yields one microtask tick. The stash must survive.
       */
      const client = {
        perspective: {
          modelQuery: async function modelQuery(className: string, queryJson: string) {
            // Simulate ApiClient.call: await _ready() then ws.send
            await Promise.resolve(); // one microtask yield
            sendRpc('200', 'perspective.modelQuery');
            return { instances: [], totalCount: 0 };
          },
        },
      };

      patchClientForCallerStacks(client);

      await (async function vueComponentCall() {
        await client.perspective.modelQuery('Community', '{}');
      })();

      const stack = lastRpcStackTrace(mockBridge.ops);
      expect(stack).toBeDefined();

      // The stash should have survived the await and been consumed by ws.send
      const stashedPart = stack!.split('--- async ws.send ---')[0];
      expect(stashedPart).toContain('vueComponentCall');
    });

    it('stash survives concurrent calls with FIFO queue', async () => {
      /**
       * Two concurrent findAll calls: each outermost wrapper pushes a
       * stack to the FIFO queue. Each ws.send shifts from the queue.
       * Both calls should get their own caller stack.
       */
      const client = {
        perspective: {
          modelQuery: async function modelQuery(className: string) {
            await Promise.resolve(); // one microtask yield
            sendRpc(`rpc-${className}`, 'perspective.modelQuery');
            return { instances: [], totalCount: 0 };
          },
        },
      };

      patchClientForCallerStacks(client);

      // Fire two concurrent calls (like Promise.all([findAll(), findAll()]))
      const p1 = (async function callA() {
        await client.perspective.modelQuery('Community');
      })();
      const p2 = (async function callB() {
        await client.perspective.modelQuery('Channel');
      })();

      await Promise.all([p1, p2]);

      const allOps = [...mockBridge.ops.values()].filter(o =>
        o.operationName?.startsWith('WS-RPC')
      );

      // With the FIFO queue, BOTH calls should have a stashed caller stack
      const withStash = allOps.filter(o =>
        o.stackTrace && (o.stackTrace as string).includes('--- async ws.send ---')
      );

      expect(withStash.length).toBe(2);
    });
  });

  // -----------------------------------------------------------------------
  // Combined stack format
  // -----------------------------------------------------------------------

  describe('combined stack format', () => {
    it('combined stack has caller portion + separator + ws.send portion', () => {
      stashCallerStack(
        'at findAll (Ad4mModel.js:100:10)\nat vueSetup (App.vue:50:5)'
      );
      sendRpc('90', 'perspective.modelQuery');

      const stack = lastRpcStackTrace(mockBridge.ops);
      expect(stack).toBeDefined();

      const parts = stack!.split('--- async ws.send ---');
      expect(parts.length).toBe(2);

      const callerPart = parts[0].trim();
      const wsPart = parts[1].trim();

      expect(callerPart).toContain('findAll');
      expect(callerPart).toContain('vueSetup');
      // ws part should contain something (the ws.send call stack)
      expect(wsPart.length).toBeGreaterThan(0);
    });
  });

  // -----------------------------------------------------------------------
  // Idempotency
  // -----------------------------------------------------------------------

  describe('idempotency', () => {
    it('patchClientForCallerStacks is idempotent (double-patch is safe)', async () => {
      let callCount = 0;
      const client = {
        perspective: {
          all: async function all() {
            callCount++;
            sendRpc('100', 'perspective.all');
            return [];
          },
        },
      };

      patchClientForCallerStacks(client);
      patchClientForCallerStacks(client); // second call should be no-op

      await client.perspective.all();

      // Should only have been called once (not double-wrapped)
      expect(callCount).toBe(1);
    });

    it('patchModelClassForCallerStacks is idempotent', async () => {
      let callCount = 0;
      class M {
        static async findAll() {
          callCount++;
          sendRpc('110', 'perspective.modelQuery');
          return [];
        }
      }

      patchModelClassForCallerStacks(M);
      patchModelClassForCallerStacks(M);

      await M.findAll();
      expect(callCount).toBe(1);
    });
  });
});
