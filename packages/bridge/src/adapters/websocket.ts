import type { OperationRecord } from '../core/types';

interface DevToolsBridge {
  logOperation(op: Partial<OperationRecord>): number;
  completeOperation(id: number, result: any, errors?: any[], options?: any): void;
  patchOperation(id: number, patch: Partial<OperationRecord>): void;
  getOperation(id: number): OperationRecord | undefined;
  trackSubscription?(sub: {
    query: string;
    perspectiveUUID: string;
    modelName: string;
    stackTrace?: string;
  }): number;
  updateSubscription?(id: number, update: {
    active?: boolean;
    lastUpdateTimestamp?: number;
  }): void;
  recordEventStreamMessage(): void;
  recordWebSocketFrame(direction: 'in' | 'out', bytes: number): void;
  setActiveWebSockets(count: number): void;
  logSubscriptionUpdate?(update: {
    subscriptionId: number;
    rawResultCount: number;
    processedCount: number;
    fingerprintChanged: boolean;
    timestamp: number;
  }): void;
  onPassiveResponse?(method: string, result: any): void;
}

type PendingRequest = {
  operationId: number;
  method: string;
  startTime: number;
  requestBytes: number;
  responseCount: number;
  totalResponseBytes: number;
  firstResponseAt?: number;
  lastResponseAt?: number;
  resolve?: (result: any) => void;
  reject?: (error: any) => void;
};

type SocketState = {
  id: string;
  url: string;
  sentBytes: number;
  receivedBytes: number;
};

const WS_INSTALL_KEY = '__AD4M_DEVTOOLS_WS_INSTALLED__';

const SUBSCRIPTION_METHODS = new Set([
  'perspective.modelSubscribe',
  'perspective.subscribeQuery',
  'perspective.addListener',
  'agent.subscribeAgentUpdated',
  'runtime.addMessageCallback',
]);

const DISPOSE_METHODS = new Set([
  'perspective.disposeQuery',
  'perspective.disposeQuerySubscription',
  'perspective.removeListener',
]);

export interface WebSocketMonitorHandle {
  uninstall: () => void;
  sendRpc: (method: string, params?: any) => Promise<any>;
  getOpenSocketUrl: () => string | undefined;
}

let nextSocketId = 1;

/**
 * Caller-stack stash: set by SDK method wrappers (captured synchronously
 * in application code), consumed by ws.send interceptor.
 *
 * Uses a FIFO queue + synchronous flag to handle concurrent calls correctly.
 * When Promise.all fires multiple findAll() chains synchronously:
 *   - Each outermost wrapper pushes a stack to the queue
 *   - Nested wrappers (same chain) see _inWrappedChain=true and skip
 *   - Each ws.send shifts the oldest entry from the queue
 *   - Result: each ws.send gets the stack from its own call chain
 */
const _callerStacks: string[] = [];
let _inWrappedChain = false;

// Legacy single-value API (for stashCallerStack callers)
let _callerStack: string | undefined;

/** Stash a caller stack that the next ws.send will attach to the operation. */
export function stashCallerStack(stack: string): void {
  _callerStacks.push(stack);
}

function captureCallerStack(): string {
  const prev = Error.stackTraceLimit;
  Error.stackTraceLimit = 50;
  const e = new Error();
  Error.stackTraceLimit = prev;
  // Skip: Error, captureCallerStack, the SDK wrapper
  return (e.stack || '').split('\n').slice(3).join('\n');
}

function stackTrace(skip = 3): string | undefined {
  try {
    const e = new Error();
    if (!e.stack) return undefined;
    return e.stack.split('\n').slice(skip).join('\n');
  } catch {
    return undefined;
  }
}

function toByteSize(data: any): number {
  if (typeof data === 'string') {
    return new TextEncoder().encode(data).byteLength;
  }
  if (typeof ArrayBuffer !== 'undefined') {
    if (data instanceof ArrayBuffer) return data.byteLength;
    if (ArrayBuffer.isView(data)) return data.byteLength;
  }
  if (typeof Blob !== 'undefined' && data instanceof Blob) return data.size;
  try {
    return new TextEncoder().encode(String(data ?? '')).byteLength;
  } catch {
    return 0;
  }
}

function tryParseJson(data: any): any {
  if (typeof data !== 'string') return null;
  try {
    return JSON.parse(data);
  } catch {
    return null;
  }
}

function extractSubscriptionId(input: any): string | undefined {
  if (!input || typeof input !== 'object') return undefined;
  return input.subscriptionId || input.subscription_id;
}

/**
 * Extract semantic metadata from an RPC payload.
 * Returns fields like modelClassName, perspectiveUUID, rpcMethod,
 * queryFingerprint (for dedup), and a cleaned-up operationName.
 */
function extractRpcMetadata(method: string, parsed: any): {
  modelClassName?: string;
  perspectiveUUID?: string;
  rpcMethod: string;
  queryFingerprint?: string;
  operationName: string;
  sparqlQuery?: string;
} {
  const params = parsed?.params;
  const perspectiveUUID = params?.uuid;

  // perspective.modelQuery / perspective.modelSubscribe
  if (method === 'perspective.modelQuery' || method === 'perspective.modelSubscribe') {
    const className = params?.class_name;
    const queryJson = params?.query_json;
    let queryDesc = '';
    try {
      const q = typeof queryJson === 'string' ? JSON.parse(queryJson) : queryJson;
      const parts: string[] = [];
      if (q?.where) parts.push('where');
      if (q?.limit != null) parts.push(`limit=${q.limit}`);
      if (q?.offset != null) parts.push(`offset=${q.offset}`);
      if (q?.order) parts.push('ordered');
      queryDesc = parts.length ? ` (${parts.join(', ')})` : '';
    } catch {}
    const fingerprint = `${method}|${perspectiveUUID}|${className}|${queryJson}`;
    return {
      modelClassName: className,
      perspectiveUUID,
      rpcMethod: method,
      queryFingerprint: fingerprint,
      operationName: className
        ? `${className}.${method === 'perspective.modelSubscribe' ? 'subscribe' : 'query'}${queryDesc}`
        : `WS-RPC ${method}`,
    };
  }

  // perspective.querySparql
  if (method === 'perspective.querySparql') {
    const sparql = params?.query;
    const fingerprint = `${method}|${perspectiveUUID}|${sparql}`;
    // Try to extract a short label from the SPARQL
    let label = 'SPARQL';
    if (sparql) {
      // Extract class hint from WHERE clause if possible
      const classMatch = sparql.match(/rdf:type\s+[<:]?(\w+)/i);
      if (classMatch) label = `SPARQL(${classMatch[1]})`;
    }
    return {
      perspectiveUUID,
      rpcMethod: method,
      queryFingerprint: fingerprint,
      operationName: label,
      sparqlQuery: sparql,
    };
  }

  // perspective.* with uuid
  if (method.startsWith('perspective.') && perspectiveUUID) {
    const shortMethod = method.replace('perspective.', '');
    return {
      perspectiveUUID,
      rpcMethod: method,
      operationName: `perspective.${shortMethod}`,
    };
  }

  return {
    rpcMethod: method,
    operationName: `WS-RPC ${method}`,
  };
}

/**
 * Dedup tracker: counts how many times a query fingerprint has been seen.
 * Maps fingerprint → { count, firstOpId, lastTimestamp }
 */
interface DupEntry { count: number; firstOpId: number; lastTimestamp: number; }
const _dupTracker = new Map<string, DupEntry>();

export function installWebSocketMonitor(bridge: DevToolsBridge): WebSocketMonitorHandle {
  const g = globalThis as any;
  const OriginalWebSocket = g.WebSocket;

  if (!OriginalWebSocket) {
    return { uninstall: () => {}, sendRpc: () => Promise.reject(new Error('No WebSocket')), getOpenSocketUrl: () => undefined };
  }

  if (g[WS_INSTALL_KEY]) {
    return { uninstall: () => {}, sendRpc: () => Promise.reject(new Error('Already installed')), getOpenSocketUrl: () => undefined };
  }

  const sockets = new WeakMap<any, SocketState>();
  const openSockets = new Set<string>();
  const openSocketRefs = new Map<string, any>();
  const pending = new Map<string, PendingRequest>();
  const subscriptionRoots = new Map<string, { operationId: number; fingerprint?: string; logicalId: number }>();
  const trackedSubscriptionIds = new Map<string, number>();
  const logicalSubscriptionIds = new Map<string, number>();
  let nextLogicalSubscriptionId = 1;
  let nextRpcId = 900000;

  const updateActiveCount = () => {
    bridge.setActiveWebSockets(openSockets.size);
  };

  function socketKey(socketId: string, requestId: string): string {
    return `${socketId}:${requestId}`;
  }

  function ensureLogicalSubId(subscriptionId: string): number {
    const existing = logicalSubscriptionIds.get(subscriptionId);
    if (existing) return existing;
    const id = nextLogicalSubscriptionId++;
    logicalSubscriptionIds.set(subscriptionId, id);
    return id;
  }

  function annotateResponse(root: PendingRequest, responseBytes: number) {
    const now = Date.now();
    root.responseCount += 1;
    root.totalResponseBytes += responseBytes;
    if (!root.firstResponseAt) root.firstResponseAt = now;
    root.lastResponseAt = now;

    bridge.patchOperation(root.operationId, {
      responseCount: root.responseCount,
      totalResponseBytes: root.totalResponseBytes,
      responseBytes,
      firstResponseAt: root.firstResponseAt,
      lastResponseAt: root.lastResponseAt,
      responsePeriodMs: root.firstResponseAt && root.lastResponseAt
        ? Math.max(0, root.lastResponseAt - root.firstResponseAt)
        : 0,
      totalBytes: root.requestBytes + root.totalResponseBytes,
    });
  }

  function appendResponseToOperation(operationId: number, responseBytes: number, responseSample: any) {
    const existing = bridge.getOperation(operationId);
    const responseCount = (existing?.responseCount || 0) + 1;
    const totalResponseBytes = (existing?.totalResponseBytes || 0) + responseBytes;
    const firstResponseAt = existing?.firstResponseAt || Date.now();
    const lastResponseAt = Date.now();
    const responses = Array.isArray(existing?.responses) ? [...existing!.responses] : [];
    responses.push(responseSample);
    if (responses.length > 20) responses.shift();

    bridge.patchOperation(operationId, {
      responseCount,
      responseBytes,
      totalResponseBytes,
      firstResponseAt,
      lastResponseAt,
      responsePeriodMs: Math.max(0, lastResponseAt - firstResponseAt),
      responses,
      totalBytes: (existing?.requestBytes || 0) + totalResponseBytes,
    });
  }

  function trackSocket(ws: any, url: string) {
    const socketId = `ws-${nextSocketId++}`;
    const state: SocketState = { id: socketId, url, sentBytes: 0, receivedBytes: 0 };
    sockets.set(ws, state);

    ws.addEventListener?.('open', () => {
      openSockets.add(socketId);
      openSocketRefs.set(socketId, ws);
      updateActiveCount();
    });

    ws.addEventListener?.('close', () => {
      openSockets.delete(socketId);
      openSocketRefs.delete(socketId);
      // Clean up pending requests for this socket
      for (const [key, req] of pending.entries()) {
        if (key.startsWith(socketId + ':')) {
          if (req.reject) req.reject(new Error('WebSocket closed'));
          pending.delete(key);
        }
      }
      updateActiveCount();
    });

    const originalSend = ws.send?.bind(ws);
    if (originalSend) {
      ws.send = function patchedSend(data: any) {
        const bytes = toByteSize(data);
        state.sentBytes += bytes;
        bridge.recordWebSocketFrame('out', bytes);

        const parsed = tryParseJson(data);
        const method = parsed?.type;
        const requestId = parsed?.id != null ? String(parsed.id) : undefined;

        if (parsed && requestId && method) {
          // Consume the stashed caller stack from the queue (FIFO)
          const stashedStack = _callerStacks.shift() || _callerStack;
          _callerStack = undefined;
          const wsStack = stackTrace();
          const combinedStack = stashedStack
            ? stashedStack + (wsStack ? '\n    --- async ws.send ---\n' + wsStack : '')
            : wsStack;

          // Extract semantic metadata from the RPC payload
          const meta = extractRpcMetadata(method, parsed);

          // Track duplicates
          let dupCount: number | undefined;
          let dupGroupId: string | undefined;
          if (meta.queryFingerprint) {
            dupGroupId = meta.queryFingerprint;
            const existing = _dupTracker.get(meta.queryFingerprint);
            if (existing) {
              existing.count++;
              existing.lastTimestamp = Date.now();
              dupCount = existing.count;
            } else {
              _dupTracker.set(meta.queryFingerprint, { count: 1, firstOpId: -1, lastTimestamp: Date.now() });
              dupCount = 1;
            }
          }

          const opId = bridge.logOperation({
            type: 'request',
            transport: 'websocket',
            socketId,
            requestId,
            wsRequestId: requestId,
            operationName: meta.operationName,
            method: 'WS-RPC',
            path: method,
            url,
            requestBody: parsed,
            requestBytes: bytes,
            payloadSize: bytes,
            responseCount: 0,
            totalResponseBytes: 0,
            totalBytes: bytes,
            stackTrace: combinedStack,
            modelClassName: meta.modelClassName,
            perspectiveUUID: meta.perspectiveUUID,
            rpcMethod: meta.rpcMethod,
            queryFingerprint: meta.queryFingerprint,
            sparqlQuery: meta.sparqlQuery,
            dupCount,
            dupGroupId,
          });

          pending.set(socketKey(socketId, requestId), {
            operationId: opId,
            method,
            startTime: Date.now(),
            requestBytes: bytes,
            responseCount: 0,
            totalResponseBytes: 0,
          });
        } else {
          bridge.logOperation({
            type: 'trace',
            transport: 'websocket',
            socketId,
            operationName: 'WS Frame Out',
            method: 'WS-OUT',
            url,
            requestBody: parsed ?? data,
            requestBytes: bytes,
            totalBytes: bytes,
            startTime: Date.now(),
            endTime: Date.now(),
            duration: 0,
            payloadSize: bytes,
            stackTrace: stackTrace(),
          });
        }

        return originalSend(data);
      };
    }

    ws.addEventListener?.('message', (event: any) => {
      const bytes = toByteSize(event?.data);
      state.receivedBytes += bytes;
      bridge.recordWebSocketFrame('in', bytes);

      const parsed = tryParseJson(event?.data);

      if (parsed && parsed.id != null) {
        const requestId = String(parsed.id);
        const key = socketKey(socketId, requestId);
        const root = pending.get(key);

        if (root) {
          annotateResponse(root, bytes);

          const response = parsed.error ? null : parsed.result;
          const errors = parsed.error ? [parsed.error] : undefined;

          const subscriptionId = extractSubscriptionId(response);
          if (subscriptionId && SUBSCRIPTION_METHODS.has(root.method)) {
            let logicalId = trackedSubscriptionIds.get(subscriptionId);
            if (!logicalId) {
              const op = bridge.getOperation(root.operationId);
              const params = op?.requestBody?.params || {};
              const query = params.query_json
                ? (typeof params.query_json === 'string' ? params.query_json : JSON.stringify(params.query_json))
                : JSON.stringify(params || {});
              const perspectiveUUID = typeof params.uuid === 'string' ? params.uuid : '';
              const modelName = typeof params.class_name === 'string'
                ? params.class_name
                : root.method.split('.').pop() || root.method;

              const trackedId = bridge.trackSubscription?.({
                query,
                perspectiveUUID,
                modelName,
                stackTrace: op?.stackTrace,
              });
              logicalId = trackedId || ensureLogicalSubId(subscriptionId);
              trackedSubscriptionIds.set(subscriptionId, logicalId);
            }

            subscriptionRoots.set(subscriptionId, {
              operationId: root.operationId,
              logicalId,
            });
          }

          if (!parsed.error && DISPOSE_METHODS.has(root.method)) {
            const op = bridge.getOperation(root.operationId);
            const params = op?.requestBody?.params;
            const disposeId = params?.subscriptionId || params?.subscription_id || params?.id;
            if (disposeId != null) {
              const subId = trackedSubscriptionIds.get(String(disposeId));
              if (subId) bridge.updateSubscription?.(subId, { active: false, lastUpdateTimestamp: Date.now() });
            }
          }

          bridge.completeOperation(root.operationId, response, errors, {
            statusCode: parsed.error ? (parsed.error.code || 500) : 200,
          });

          // Resolve/reject for sendRpc-initiated requests
          if (parsed.error) {
            root.reject?.(parsed.error);
          } else {
            root.resolve?.(response);
          }

          // Passive data extraction
          if (!parsed.error && response != null) {
            bridge.onPassiveResponse?.(root.method, response);
          }

          pending.delete(key);
          return;
        }
      }

      if (parsed?.type) {
        const eventType = String(parsed.type);

        if (eventType === 'query-subscription-update') {
          bridge.recordEventStreamMessage();

          const subId = extractSubscriptionId(parsed);
          if (subId) {
            const root = subscriptionRoots.get(subId);
            if (root) {
              const nextFingerprint = typeof parsed.result === 'string'
                ? parsed.result
                : JSON.stringify(parsed.result ?? '');
              const changed = root.fingerprint !== nextFingerprint;
              root.fingerprint = nextFingerprint;

              appendResponseToOperation(root.operationId, bytes, parsed.result);

              bridge.logSubscriptionUpdate?.({
                subscriptionId: root.logicalId,
                rawResultCount: 1,
                processedCount: 1,
                fingerprintChanged: changed,
                timestamp: Date.now(),
              });
            }
          }
        }

        bridge.logOperation({
          type: 'trace',
          transport: 'websocket',
          socketId,
          operationName: `WS Event ${eventType}`,
          method: 'WS-EVENT',
          path: eventType,
          url,
          response: parsed,
          responseBytes: bytes,
          totalResponseBytes: bytes,
          totalBytes: bytes,
          responseCount: 1,
          startTime: Date.now(),
          endTime: Date.now(),
          duration: 0,
          payloadSize: bytes,
          stackTrace: stackTrace(),
        });
        return;
      }

      bridge.logOperation({
        type: 'trace',
        transport: 'websocket',
        socketId,
        operationName: 'WS Frame In',
        method: 'WS-IN',
        url,
        response: parsed ?? event?.data,
        responseBytes: bytes,
        totalResponseBytes: bytes,
        totalBytes: bytes,
        responseCount: 1,
        startTime: Date.now(),
        endTime: Date.now(),
        duration: 0,
        payloadSize: bytes,
        stackTrace: stackTrace(),
      });
    });
  }

  const InstrumentedWebSocket = function(this: any, url: string, protocols?: string | string[]) {
    const ws = protocols ? new OriginalWebSocket(url, protocols) : new OriginalWebSocket(url);
    trackSocket(ws, String(url));
    return ws;
  } as any;

  InstrumentedWebSocket.prototype = OriginalWebSocket.prototype;
  Object.setPrototypeOf(InstrumentedWebSocket, OriginalWebSocket);

  g.WebSocket = InstrumentedWebSocket;
  g[WS_INSTALL_KEY] = true;

  function sendRpc(method: string, params?: any): Promise<any> {
    return new Promise((resolve, reject) => {
      const entries = Array.from(openSocketRefs.entries());
      if (entries.length === 0) return reject(new Error('No open WebSocket'));
      const [sid, ws] = entries[0];
      if (ws.readyState !== 1) return reject(new Error('WebSocket not open'));

      const id = `dt-${nextRpcId++}`;
      const message = JSON.stringify({ type: method, id, params: params || {} });

      // ws.send is our patched version, which creates a pending entry
      ws.send(message);

      // Attach resolve/reject to the pending entry created by our patched send
      const key = socketKey(sid, id);
      const entry = pending.get(key);
      if (entry) {
        entry.resolve = resolve;
        entry.reject = reject;
      } else {
        reject(new Error('Failed to create pending entry'));
      }
    });
  }

  function getOpenSocketUrl(): string | undefined {
    for (const [sid] of openSocketRefs) {
      // Find the SocketState via the WeakMap by iterating tracked sockets
      // Use the first open socket's URL from its state
      for (const [, ws] of openSocketRefs) {
        const state = sockets.get(ws);
        if (state) return state.url;
      }
    }
    return undefined;
  }

  return {
    uninstall: () => {
      if (g.WebSocket === InstrumentedWebSocket) {
        g.WebSocket = OriginalWebSocket;
      }
      delete g[WS_INSTALL_KEY];
    },
    sendRpc,
    getOpenSocketUrl,
  };
}

/**
 * Wrap an Ad4mClient's sub-client methods so they capture a caller stack
 * synchronously before the async chain starts.  The captured stack is
 * stashed in a module-global and consumed by the next ws.send().
 *
 * Since JS is single-threaded and the call chain
 *   findAll() → executeModelQuery() → querySparql() → ApiClient.call() → ws.send()
 * executes synchronously within one tick (each await calls the next function
 * synchronously before suspending), the stash is always consumed by the right
 * ws.send call.
 */
const PATCHED_KEY = Symbol('__ad4mDevtoolsPatched');

export function patchClientForCallerStacks(client: any): void {
  if (!client || client[PATCHED_KEY]) return;
  client[PATCHED_KEY] = true;

  // Patch sub-clients: perspective, agent, runtime, expression, language, neighbourhood
  const subClients = ['perspective', 'agent', 'runtime', 'expression', 'language', 'neighbourhood'];
  for (const name of subClients) {
    const subClient = client[name];
    if (!subClient) continue;
    wrapAsyncMethods(subClient);
    // Also patch the class prototype so ALL instances of this sub-client class
    // are covered (e.g. chat-view may use a different Ad4mClient instance with
    // a different PerspectiveClient, but same prototype).
    const subProto = Object.getPrototypeOf(subClient);
    if (subProto && subProto !== Object.prototype && !subProto[PATCHED_KEY]) {
      subProto[PATCHED_KEY] = true;
      wrapAsyncMethods(subProto);
    }
  }

  // Patch PerspectiveClient methods that return PerspectiveProxy instances,
  // so the proxy's methods also capture caller stacks.
  // We also patch the PROTOTYPE when we first see a proxy, so ALL instances
  // (even those obtained before patching) benefit.
  const perspectiveClient = client.perspective;
  if (!perspectiveClient) return;

  let protoPatched = false;
  const ensureProtoPatched = (proxy: any) => {
    if (protoPatched || !proxy || typeof proxy !== 'object') return;
    const proto = Object.getPrototypeOf(proxy);
    if (proto && proto !== Object.prototype) {
      protoPatched = true;
      wrapAsyncMethods(proto);
    }
  };

  for (const method of ['byUUID', 'byDID', 'byName']) {
    const original = perspectiveClient[method];
    if (typeof original !== 'function') continue;
    perspectiveClient[method] = async function (this: any, ...args: any[]) {
      const proxy = await original.apply(this, args);
      if (proxy && typeof proxy === 'object') {
        ensureProtoPatched(proxy);
        wrapAsyncMethods(proxy);
      }
      return proxy;
    };
  }

  // Patch `all()` which returns an array of proxies
  const originalAll = perspectiveClient.all;
  if (typeof originalAll === 'function') {
    perspectiveClient.all = async function (this: any, ...args: any[]) {
      const proxies = await originalAll.apply(this, args);
      if (Array.isArray(proxies)) {
        for (const proxy of proxies) {
          if (proxy && typeof proxy === 'object') {
            ensureProtoPatched(proxy);
            wrapAsyncMethods(proxy);
          }
        }
      }
      return proxies;
    };
  }

  // Patch `add()` / `create()` which return new proxies
  for (const method of ['add', 'create']) {
    const original = perspectiveClient[method];
    if (typeof original !== 'function') continue;
    perspectiveClient[method] = async function (this: any, ...args: any[]) {
      const proxy = await original.apply(this, args);
      if (proxy && typeof proxy === 'object') {
        ensureProtoPatched(proxy);
        wrapAsyncMethods(proxy);
      }
      return proxy;
    };
  }
}

export function wrapAsyncMethods(obj: any): void {
  if (!obj || typeof obj !== 'object') return;

  const proto = Object.getPrototypeOf(obj);
  const keys = new Set([
    ...Object.getOwnPropertyNames(obj),
    ...(proto ? Object.getOwnPropertyNames(proto) : []),
  ]);

  for (const key of keys) {
    if (key === 'constructor' || key.startsWith('_') || key.startsWith('#')) continue;
    let desc: PropertyDescriptor | undefined;
    try {
      desc = Object.getOwnPropertyDescriptor(obj, key) || (proto && Object.getOwnPropertyDescriptor(proto, key));
    } catch { continue; }
    if (!desc || typeof desc.value !== 'function') continue;

    const original = desc.value;
    obj[key] = function (this: any, ...args: any[]) {
      // Use _inWrappedChain flag to detect outermost wrapper in the
      // synchronous call chain. Only the outermost pushes to the queue.
      // This correctly handles concurrent chains (Promise.all) because
      // each chain's synchronous phase runs to its first await, then
      // _inWrappedChain resets, allowing the next chain to push.
      const isOutermost = !_inWrappedChain;
      if (isOutermost) {
        _inWrappedChain = true;
        _callerStacks.push(captureCallerStack());
      }
      try {
        const result = original.apply(this, args);
        return result;
      } catch (e) {
        // Synchronous throw — remove our entry
        if (isOutermost) {
          _callerStacks.pop();
        }
        throw e;
      } finally {
        if (isOutermost) {
          _inWrappedChain = false;
        }
      }
    };
  }
}

/**
 * Wrap Ad4mModel's static query methods (findAll, findOne, get, create, etc.)
 * so the caller stack is captured at the application-facing API surface.
 *
 * Since all model subclasses (Community, Message, Channel, …) inherit these
 * from Ad4mModel, patching the base prototype covers everything.
 */
const MODEL_PATCHED_KEY = Symbol('__ad4mDevtoolsModelPatched');
const MODEL_STATIC_METHODS = [
  'findAll', 'findAllAndCount', 'findOne', 'get', 'create',
  'executeModelQuery',
];

export function patchModelClassForCallerStacks(ModelClass: any): void {
  if (!ModelClass || ModelClass[MODEL_PATCHED_KEY]) return;
  ModelClass[MODEL_PATCHED_KEY] = true;

  for (const methodName of MODEL_STATIC_METHODS) {
    const original = ModelClass[methodName];
    if (typeof original !== 'function') continue;

    ModelClass[methodName] = function (this: any, ...args: any[]) {
      const alreadyStashed = !!_callerStack;
      if (!alreadyStashed) {
        _callerStack = captureCallerStack();
      }
      try {
        const result = original.apply(this, args);
        if (result && typeof result.then === 'function') {
          result.then(
            () => {},
            () => { if (!alreadyStashed) _callerStack = undefined; },
          );
        }
        return result;
      } catch (e) {
        if (!alreadyStashed) _callerStack = undefined;
        throw e;
      }
    };
    // Preserve the original function name for stack traces
    Object.defineProperty(ModelClass[methodName], 'name', { value: methodName });
  }
}
