import type { OperationRecord } from '../core/types';

// Ensure V8 captures enough frames to reach application code
if (typeof Error.stackTraceLimit === 'number') {
  Error.stackTraceLimit = Math.max(Error.stackTraceLimit, 50);
}

/** Capture a stack trace synchronously (before any async boundary). */
function captureStack(): string {
  const prev = Error.stackTraceLimit;
  Error.stackTraceLimit = 50;
  const err = new Error();
  Error.stackTraceLimit = prev;
  // Remove "Error" header + captureStack + caller (the patched method)
  return (err.stack || '').split('\n').slice(3).join('\n');
}

/**
 * REST + WebSocket adapter for AD4M DevTools bridge.
 * 
 * Intercepts RestClient HTTP calls and WebSocket RPC frames.
 * Works with the `feat/sse-to-websocket` branch of coasys/ad4m.
 */

interface DevToolsBridge {
  logOperation(op: Partial<OperationRecord>): number;
  completeOperation(id: number, result: any, errors?: any[], options?: any): void;
  trackSubscription(sub: any): number;
  updateSubscription(id: number, update: any): void;
  recordEventStreamMessage(): void;
}

/**
 * Wraps a RestClient instance to intercept HTTP and WebSocket calls.
 */
export function wrapRestClient(restClient: any, bridge: DevToolsBridge): void {
  if (!restClient) return;

  const baseUrl = restClient.getBaseUrl?.() || restClient.baseUrl || '';

  // Patch the call method (HTTP RPC)
  const originalCall = restClient.call?.bind(restClient);
  if (originalCall) {
    restClient.call = async function(method: string, path: string, body?: any, options?: any) {
      const stackTrace = captureStack();
      const opId = bridge.logOperation({
        type: 'request',
        transport: 'rest',
        operationName: `${method.toUpperCase()} ${path}`,
        method: method.toUpperCase(),
        path,
        url: `${baseUrl}${path}`,
        requestBody: body,
        stackTrace,
      });

      try {
        const result = await originalCall(method, path, body, options);
        bridge.completeOperation(opId, result, undefined, { statusCode: 200 });
        return result;
      } catch (err: any) {
        bridge.completeOperation(opId, null, [err], { statusCode: err?.status || 500 });
        throw err;
      }
    };
  }

  // Patch WebSocket RPC if available
  const originalWsCall = restClient.wsCall?.bind(restClient) || restClient.rpc?.bind(restClient);
  if (originalWsCall) {
    const patchedWsCall = async function(method: string, params?: any) {
      const stackTrace = captureStack();
      const opId = bridge.logOperation({
        type: 'request',
        transport: 'rest',
        operationName: `WS-RPC ${method}`,
        method: 'WS',
        path: method,
        url: `${baseUrl}/ws`,
        requestBody: params,
        stackTrace,
      });

      try {
        const result = await originalWsCall(method, params);
        bridge.completeOperation(opId, result, undefined, { statusCode: 200 });
        return result;
      } catch (err: any) {
        bridge.completeOperation(opId, null, [err], { statusCode: err?.status || 500 });
        throw err;
      }
    };
    if (restClient.wsCall) restClient.wsCall = patchedWsCall;
    else if (restClient.rpc) restClient.rpc = patchedWsCall;
  }

  // Patch event stream subscription
  const originalSubscribe = restClient.subscribe?.bind(restClient);
  if (originalSubscribe) {
    restClient.subscribe = function(eventType: string, callback: any, ...args: any[]) {
      const subId = bridge.trackSubscription({
        query: eventType,
        modelName: eventType,
        perspectiveUUID: '',
      });

      const wrappedCallback = (data: any) => {
        bridge.recordEventStreamMessage();
        bridge.updateSubscription(subId, {
          lastUpdateTimestamp: Date.now(),
        });
        return callback(data);
      };

      return originalSubscribe(eventType, wrappedCallback, ...args);
    };
  }
}

/**
 * Intercepts WebSocket frames for detailed frame-level tracking.
 * Call this after the RestClient's WebSocket connection is established.
 */
export function interceptWebSocketFrames(ws: WebSocket, bridge: DevToolsBridge): void {
  if (!ws) return;

  const originalSend = ws.send.bind(ws);
  ws.send = function(data: string | ArrayBufferLike | Blob | ArrayBufferView) {
    bridge.logOperation({
      type: 'request',
      transport: 'rest',
      operationName: 'WS Frame (outgoing)',
      method: 'WS-OUT',
      path: '/ws',
      requestBody: typeof data === 'string' ? tryParse(data) : '[binary]',
      startTime: Date.now(),
      endTime: Date.now(),
      duration: 0,
    });
    return originalSend(data);
  };

  ws.addEventListener('message', (event) => {
    bridge.recordEventStreamMessage();
    bridge.logOperation({
      type: 'trace',
      transport: 'rest',
      operationName: 'WS Frame (incoming)',
      method: 'WS-IN',
      path: '/ws',
      response: typeof event.data === 'string' ? tryParse(event.data) : '[binary]',
      startTime: Date.now(),
      endTime: Date.now(),
      duration: 0,
    });
  });
}

function tryParse(str: string): any {
  try { return JSON.parse(str); } catch { return str; }
}
