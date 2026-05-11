import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { installWebSocketMonitor } from './websocket';
import type { OperationRecord } from '../core/types';

class FakeWebSocket {
  static instances: FakeWebSocket[] = [];

  url: string;
  readyState = 1; // OPEN
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

  send(data: any) {
    this.sent.push(data);
  }

  emit(type: string, event?: any) {
    for (const cb of this.listeners[type] || []) cb(event);
  }
}

describe('installWebSocketMonitor', () => {
  const originalWebSocket = (globalThis as any).WebSocket;

  beforeEach(() => {
    FakeWebSocket.instances = [];
    (globalThis as any).WebSocket = FakeWebSocket as any;
    delete (globalThis as any).__AD4M_DEVTOOLS_WS_INSTALLED__;
  });

  afterEach(() => {
    (globalThis as any).WebSocket = originalWebSocket;
    delete (globalThis as any).__AD4M_DEVTOOLS_WS_INSTALLED__;
  });

  it('pairs rpc request/response and captures websocket byte metrics', () => {
    const ops = new Map<number, Partial<OperationRecord>>();
    let nextId = 1;
    let outFrames = 0;
    let inFrames = 0;

    const monitor = installWebSocketMonitor({
      logOperation(op: Partial<OperationRecord>) {
        const id = nextId++;
        ops.set(id, { ...op, id });
        return id;
      },
      completeOperation(id: number, result: any, errors?: any[]) {
        const op = ops.get(id)!;
        ops.set(id, {
          ...op,
          response: result,
          errors,
          endTime: Date.now(),
        });
      },
      patchOperation(id: number, patch: Partial<OperationRecord>) {
        const op = ops.get(id)!;
        ops.set(id, { ...op, ...patch });
      },
      getOperation(id: number) {
        return ops.get(id) as OperationRecord | undefined;
      },
      recordEventStreamMessage() {},
      recordWebSocketFrame(direction: 'in' | 'out') {
        if (direction === 'out') outFrames += 1;
        else inFrames += 1;
      },
      setActiveWebSockets() {},
    } as any);

    const ws = new (globalThis as any).WebSocket('ws://127.0.0.1:12000/api/v1/ws') as FakeWebSocket;
    ws.emit('open');

    ws.send(JSON.stringify({ id: '1', type: 'perspective.modelQuery', params: { uuid: 'p1' } }));
    ws.emit('message', {
      data: JSON.stringify({ id: '1', result: { instances: [{ id: 'a' }], totalCount: 1 } }),
    });

    expect(outFrames).toBe(1);
    expect(inFrames).toBe(1);

    const requestOps = [...ops.values()].filter(o => o.operationName === 'WS-RPC perspective.modelQuery');
    expect(requestOps.length).toBe(1);

    const op = requestOps[0];
    expect(op.requestBytes).toBeGreaterThan(0);
    expect(op.totalResponseBytes).toBeGreaterThan(0);
    expect(op.responseCount).toBe(1);
    expect(op.totalBytes).toBeGreaterThan(0);
    expect(typeof op.stackTrace).toBe('string');

    monitor.uninstall();
  });

  it('aggregates subscription update responses onto the subscribe operation', () => {
    const ops = new Map<number, Partial<OperationRecord>>();
    const subs = new Map<number, any>();
    let nextId = 1;
    let nextSubId = 1;

    installWebSocketMonitor({
      logOperation(op: Partial<OperationRecord>) {
        const id = nextId++;
        ops.set(id, { ...op, id });
        return id;
      },
      completeOperation(id: number, result: any, errors?: any[]) {
        const op = ops.get(id)!;
        ops.set(id, { ...op, response: result, errors, endTime: Date.now() });
      },
      patchOperation(id: number, patch: Partial<OperationRecord>) {
        const op = ops.get(id)!;
        ops.set(id, { ...op, ...patch });
      },
      getOperation(id: number) {
        return ops.get(id) as OperationRecord | undefined;
      },
      recordEventStreamMessage() {},
      recordWebSocketFrame() {},
      setActiveWebSockets() {},
      trackSubscription(sub: any) {
        const id = nextSubId++;
        subs.set(id, { id, active: true, ...sub });
        return id;
      },
      updateSubscription(id: number, update: any) {
        const sub = subs.get(id);
        if (!sub) return;
        subs.set(id, { ...sub, ...update });
      },
      logSubscriptionUpdate() {},
    } as any);

    const ws = new (globalThis as any).WebSocket('ws://127.0.0.1:12000/api/v1/ws') as FakeWebSocket;
    ws.emit('open');

    ws.send(JSON.stringify({ id: '2', type: 'perspective.modelSubscribe', params: { uuid: 'p1' } }));
    ws.emit('message', {
      data: JSON.stringify({
        id: '2',
        result: {
          subscription_id: 'sub-1',
          result: JSON.stringify({ instances: [] }),
        },
      }),
    });

    ws.emit('message', {
      data: JSON.stringify({
        type: 'query-subscription-update',
        subscriptionId: 'sub-1',
        result: { instances: [{ id: '1' }] },
      }),
    });

    ws.emit('message', {
      data: JSON.stringify({
        type: 'query-subscription-update',
        subscriptionId: 'sub-1',
        result: { instances: [{ id: '1' }, { id: '2' }] },
      }),
    });

    const requestOps = [...ops.values()].filter(o => o.operationName === 'WS-RPC perspective.modelSubscribe');
    expect(requestOps.length).toBe(1);
    expect(subs.size).toBe(1);

    const op = requestOps[0];
    expect((op.responseCount || 0)).toBeGreaterThanOrEqual(3);
    expect((op.totalResponseBytes || 0)).toBeGreaterThan(0);
    expect((op.responsePeriodMs || 0)).toBeGreaterThanOrEqual(0);
    expect(Array.isArray(op.responses)).toBe(true);
    expect((op.responses || []).length).toBeGreaterThanOrEqual(2);
  });

  it('calls onPassiveResponse with method and result for successful RPC replies', () => {
    const ops = new Map<number, Partial<OperationRecord>>();
    let nextId = 1;
    const passiveData: Array<{ method: string; result: any }> = [];

    installWebSocketMonitor({
      logOperation(op: Partial<OperationRecord>) {
        const id = nextId++;
        ops.set(id, { ...op, id });
        return id;
      },
      completeOperation(id: number, result: any) {
        const op = ops.get(id)!;
        ops.set(id, { ...op, response: result, endTime: Date.now() });
      },
      patchOperation(id: number, patch: Partial<OperationRecord>) {
        const op = ops.get(id)!;
        ops.set(id, { ...op, ...patch });
      },
      getOperation(id: number) {
        return ops.get(id) as OperationRecord | undefined;
      },
      recordEventStreamMessage() {},
      recordWebSocketFrame() {},
      setActiveWebSockets() {},
      onPassiveResponse(method: string, result: any) {
        passiveData.push({ method, result });
      },
    } as any);

    const ws = new (globalThis as any).WebSocket('ws://127.0.0.1:12000/api/v1/ws') as FakeWebSocket;
    ws.emit('open');

    ws.send(JSON.stringify({ id: '10', type: 'perspective.all', params: {} }));
    const perspectives = [{ uuid: 'abc', name: 'Test' }];
    ws.emit('message', { data: JSON.stringify({ id: '10', result: perspectives }) });

    expect(passiveData.length).toBe(1);
    expect(passiveData[0].method).toBe('perspective.all');
    expect(passiveData[0].result).toEqual(perspectives);
  });

  it('cleans up pending requests on socket close', () => {
    const ops = new Map<number, Partial<OperationRecord>>();
    let nextId = 1;
    let activeCount = 0;

    installWebSocketMonitor({
      logOperation(op: Partial<OperationRecord>) {
        const id = nextId++;
        ops.set(id, { ...op, id });
        return id;
      },
      completeOperation() {},
      patchOperation(id: number, patch: Partial<OperationRecord>) {
        const op = ops.get(id)!;
        ops.set(id, { ...op, ...patch });
      },
      getOperation(id: number) {
        return ops.get(id) as OperationRecord | undefined;
      },
      recordEventStreamMessage() {},
      recordWebSocketFrame() {},
      setActiveWebSockets(count: number) { activeCount = count; },
    } as any);

    const ws = new (globalThis as any).WebSocket('ws://127.0.0.1:12000/api/v1/ws') as FakeWebSocket;
    ws.emit('open');
    expect(activeCount).toBe(1);

    // Send a request but don't respond
    ws.send(JSON.stringify({ id: '99', type: 'perspective.all', params: {} }));

    // Close the socket
    ws.emit('close');
    expect(activeCount).toBe(0);
  });

  it('sendRpc sends a message through an open socket and resolves on response', async () => {
    const ops = new Map<number, Partial<OperationRecord>>();
    let nextId = 1;

    const monitor = installWebSocketMonitor({
      logOperation(op: Partial<OperationRecord>) {
        const id = nextId++;
        ops.set(id, { ...op, id });
        return id;
      },
      completeOperation(id: number, result: any) {
        const op = ops.get(id)!;
        ops.set(id, { ...op, response: result, endTime: Date.now() });
      },
      patchOperation(id: number, patch: Partial<OperationRecord>) {
        const op = ops.get(id)!;
        ops.set(id, { ...op, ...patch });
      },
      getOperation(id: number) {
        return ops.get(id) as OperationRecord | undefined;
      },
      recordEventStreamMessage() {},
      recordWebSocketFrame() {},
      setActiveWebSockets() {},
    } as any);

    const ws = new (globalThis as any).WebSocket('ws://127.0.0.1:12000/api/v1/ws') as FakeWebSocket;
    ws.emit('open');

    const resultPromise = monitor.sendRpc('agent.status', {});

    // The monitor should have sent a message through the socket
    const lastSent = ws.sent[ws.sent.length - 1];
    const parsed = JSON.parse(lastSent);
    expect(parsed.type).toBe('agent.status');
    expect(parsed.id).toMatch(/^dt-/);

    // Simulate response
    ws.emit('message', {
      data: JSON.stringify({ id: parsed.id, result: { did: 'did:test:123', isInitialized: true } }),
    });

    const result = await resultPromise;
    expect(result.did).toBe('did:test:123');
    expect(result.isInitialized).toBe(true);

    monitor.uninstall();
  });

  it('sendRpc rejects when no open socket', async () => {
    const monitor = installWebSocketMonitor({
      logOperation() { return 1; },
      completeOperation() {},
      patchOperation() {},
      getOperation() { return undefined; },
      recordEventStreamMessage() {},
      recordWebSocketFrame() {},
      setActiveWebSockets() {},
    } as any);

    await expect(monitor.sendRpc('perspective.all', {})).rejects.toThrow('No open WebSocket');
    monitor.uninstall();
  });

  it('getOpenSocketUrl returns the URL of an open socket', () => {
    const monitor = installWebSocketMonitor({
      logOperation() { return 1; },
      completeOperation() {},
      patchOperation() {},
      getOperation() { return undefined; },
      recordEventStreamMessage() {},
      recordWebSocketFrame() {},
      setActiveWebSockets() {},
    } as any);

    expect(monitor.getOpenSocketUrl()).toBeUndefined();

    const ws = new (globalThis as any).WebSocket('ws://127.0.0.1:12000/api/v1/ws') as FakeWebSocket;
    ws.emit('open');

    expect(monitor.getOpenSocketUrl()).toBe('ws://127.0.0.1:12000/api/v1/ws');

    ws.emit('close');
    expect(monitor.getOpenSocketUrl()).toBeUndefined();

    monitor.uninstall();
  });

  it('tracks agent.subscribeAgentUpdated as a subscription', () => {
    const ops = new Map<number, Partial<OperationRecord>>();
    const subs = new Map<number, any>();
    let nextId = 1;
    let nextSubId = 1;

    installWebSocketMonitor({
      logOperation(op: Partial<OperationRecord>) {
        const id = nextId++;
        ops.set(id, { ...op, id });
        return id;
      },
      completeOperation(id: number, result: any) {
        const op = ops.get(id)!;
        ops.set(id, { ...op, response: result, endTime: Date.now() });
      },
      patchOperation(id: number, patch: Partial<OperationRecord>) {
        const op = ops.get(id)!;
        ops.set(id, { ...op, ...patch });
      },
      getOperation(id: number) {
        return ops.get(id) as OperationRecord | undefined;
      },
      recordEventStreamMessage() {},
      recordWebSocketFrame() {},
      setActiveWebSockets() {},
      trackSubscription(sub: any) {
        const id = nextSubId++;
        subs.set(id, { id, active: true, ...sub });
        return id;
      },
      updateSubscription() {},
      logSubscriptionUpdate() {},
    } as any);

    const ws = new (globalThis as any).WebSocket('ws://127.0.0.1:12000/api/v1/ws') as FakeWebSocket;
    ws.emit('open');

    ws.send(JSON.stringify({ id: '5', type: 'agent.subscribeAgentUpdated', params: {} }));
    ws.emit('message', {
      data: JSON.stringify({ id: '5', result: { subscription_id: 'agent-sub-1' } }),
    });

    expect(subs.size).toBe(1);
    const sub = [...subs.values()][0];
    expect(sub.modelName).toBe('subscribeAgentUpdated');
  });
});
