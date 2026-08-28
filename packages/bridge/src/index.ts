import type {
  AD4MDevTools,
  CompleteOperationOptions,
  DevToolsState,
  ErrorDetail,
  GetterTraceRecord,
  LanguageRecord,
  NotificationRecord,
  OperationRecord,
  PerspectiveInfo,
  SubscriptionRecord,
  SubscriptionUpdateRecord,
} from './core/types';
import { PerformanceTracker } from './core/performance';
import { OperationInterceptor } from './core/interceptor';
import { SubscriptionTracker } from './core/subscription-tracker';
import { NotificationMonitor } from './core/notification-monitor';
import { installWebSocketMonitor, patchClientForCallerStacks, patchModelClassForCallerStacks, wrapAsyncMethods, type WebSocketMonitorHandle } from './adapters/websocket';

const MAX_GETTER_TRACES = 200;
const MAX_SUB_UPDATES = 500;
const MAX_LANGUAGES = 100;

let nextGetterTraceId = 1;

function createBridge(client?: any): AD4MDevTools {
  const perf = new PerformanceTracker();
  const interceptor = new OperationInterceptor(perf);
  const subscriptions = new SubscriptionTracker();
  const notifications = new NotificationMonitor();
  let monitor: WebSocketMonitorHandle | undefined;

  // Passive data stores - populated from observed WS traffic
  const passivePerspectives: PerspectiveInfo[] = [];
  let passiveAgentStatus: any = null;

  const subscriptionUpdates: SubscriptionUpdateRecord[] = [];
  const getterTraces: GetterTraceRecord[] = [];
  const languages: LanguageRecord[] = [];
  const getClient = () => ((globalThis as any).__AD4M_DEVTOOLS__?._client || client);

  const connectionState = () => {
    const activeClient = getClient();
    const perfState = perf.getState(interceptor.estimateMemory());
    const url = activeClient?.executorUrl || activeClient?.baseUrl || monitor?.getOpenSocketUrl() || '';
    const authenticated = Boolean(activeClient?.hasAuthToken || activeClient?.authenticated);

    return {
      connected: perfState.activeWebSockets > 0 || Boolean(activeClient),
      transport: 'websocket' as const,
      url,
      authenticated,
      eventStreamConnected: perfState.activeWebSockets > 0,
      activeEventStreams: perfState.activeWebSockets,
      wsFramesSent: perfState.wsFramesSent,
      wsFramesReceived: perfState.wsFramesReceived,
      wsSentBytes: perfState.totalWsSentBytes,
      wsReceivedBytes: perfState.totalWsReceivedBytes,
    };
  };

  const enrichErrors = (errors?: any[]): ErrorDetail[] | undefined =>
    errors?.map(e => ({
      message: e?.message || String(e),
      type: e?.type || e?.name || e?.constructor?.name || (e?.extensions?.code ? `RPC: ${e.extensions.code}` : 'Error'),
      stack: e?.stack,
      nested: e?.networkError
        ? [{
            message: e.networkError.message,
            type: 'NetworkError',
            stack: e.networkError.stack,
          }]
        : undefined,
    }));

  if (client) patchClientForCallerStacks(client);

  let _clientValue = client;
  let _ad4mModelValue: any = undefined;
  const devtools: AD4MDevTools = {
    _version: '3.0.0',
    get _client() { return _clientValue; },
    set _client(c: any) {
      _clientValue = c;
      if (c) {
        patchClientForCallerStacks(c);
      }
    },
    get _Ad4mModel() { return _ad4mModelValue; },
    set _Ad4mModel(cls: any) {
      _ad4mModelValue = cls;
      if (cls) {
        patchModelClassForCallerStacks(cls);
      }
    },

    getState(): DevToolsState {
      const activeSubs = subscriptions.getActiveCount();
      const perfState = perf.getState(interceptor.estimateMemory());
      perfState.activeSubscriptions = activeSubs;

      return {
        operations: interceptor.getAll(),
        subscriptions: subscriptions.getAll(),
        subscriptionUpdates,
        notifications: notifications.getAll(),
        performance: perfState,
        getterTraces,
        languages,
        perspectives: passivePerspectives,
        agentStatus: passiveAgentStatus,
        connection: connectionState(),
      };
    },

    logOperation(op: Partial<OperationRecord>): number {
      return interceptor.log(op);
    },

    getOperation(id: number): OperationRecord | undefined {
      return interceptor.getAll().find(o => o.id === id);
    },

    patchOperation(id: number, patch: Partial<OperationRecord>) {
      interceptor.patch(id, patch);
    },

    completeOperation(id: number, result: any, errors?: any[], options?: CompleteOperationOptions) {
      interceptor.complete(id, result, enrichErrors(errors), options);
    },

    recordEventStreamMessage() {
      perf.recordEventStreamMessage();
    },

    recordWebSocketFrame(direction: 'in' | 'out', bytes: number) {
      perf.recordWebSocketFrame(direction, bytes);
    },

    setActiveWebSockets(count: number) {
      perf.setActiveWebSockets(count);
    },

    trackSubscription(sub: Partial<SubscriptionRecord>): number {
      return subscriptions.track(sub);
    },

    updateSubscription(id: number, update: Partial<SubscriptionRecord>) {
      subscriptions.update(id, update);
    },

    logSparqlQuery(info: { query: string; modelName: string; perspectiveUUID: string }) {
      const now = Date.now();
      interceptor.log({
        type: 'trace',
        transport: 'sparql',
        queryLanguage: 'sparql',
        operationName: info.modelName ? `SPARQL Trace • ${info.modelName}` : 'SPARQL Trace',
        query: info.query,
        sparqlQuery: info.query,
        startTime: now,
        endTime: now,
        duration: 0,
      });
      perf.recordSparqlTrace();
    },

    logSubscriptionUpdate(update: SubscriptionUpdateRecord) {
      subscriptionUpdates.push(update);
      if (subscriptionUpdates.length > MAX_SUB_UPDATES) subscriptionUpdates.shift();
      perf.recordSubscriptionUpdate();

      const sub = subscriptions.getAll().find(s => s.id === update.subscriptionId);
      if (sub) {
        subscriptions.update(update.subscriptionId, {
          updateCount: sub.updateCount + 1,
          lastUpdateTimestamp: update.timestamp,
          fingerprintHits: sub.fingerprintHits + (update.fingerprintChanged ? 0 : 1),
          fingerprintMisses: sub.fingerprintMisses + (update.fingerprintChanged ? 1 : 0),
        });
      }
    },

    logGetterTrace(trace: Omit<GetterTraceRecord, 'id' | 'timestamp'>) {
      getterTraces.push({
        ...trace,
        id: nextGetterTraceId++,
        timestamp: Date.now(),
      });
      if (getterTraces.length > MAX_GETTER_TRACES) getterTraces.shift();
    },

    logLanguageEvent(lang: LanguageRecord) {
      const idx = languages.findIndex(l => l.address === lang.address);
      if (idx >= 0) languages[idx] = lang;
      else {
        languages.push(lang);
        if (languages.length > MAX_LANGUAGES) languages.shift();
      }
    },

    registerNotification(notification: NotificationRecord) {
      notifications.register(notification);
    },

    updateNotification(id: string, update: Partial<NotificationRecord>) {
      notifications.update(id, update);
    },

    async testNotificationTrigger(notificationId: string, perspectiveId: string): Promise<any> {
      const n = notifications.getAll().find(n => n.id === notificationId);
      if (!n) return { error: 'Notification not found' };
      try {
        const activeClient = getClient();
        if (activeClient?.perspective?.byUUID) {
          const proxy = await activeClient.perspective.byUUID(perspectiveId);
          if (proxy) {
            const result = await proxy.infer(n.triggerQuery);
            return { success: true, result };
          }
        }
        if (monitor?.sendRpc) {
          const result = await monitor.sendRpc('perspective.queryProlog', { uuid: perspectiveId, query: n.triggerQuery });
          return { success: true, result };
        }
        return { error: 'No client or WS connection available' };
      } catch (e: any) {
        return { error: e.message };
      }
    },

    async queryLinks(perspectiveId: string, filter?: { source?: string; predicate?: string; target?: string }): Promise<any[]> {
      try {
        const activeClient = getClient();
        if (activeClient?.perspective?.byUUID) {
          const proxy = await activeClient.perspective.byUUID(perspectiveId);
          if (proxy) return await proxy.get(filter || {});
        }
        if (monitor?.sendRpc) {
          return await monitor.sendRpc('perspective.queryLinks', { uuid: perspectiveId, ...(filter || {}) });
        }
        return [];
      } catch {
        return [];
      }
    },

    async getSubjectClasses(perspectiveId: string): Promise<any[]> {
      try {
        const activeClient = getClient();
        if (activeClient?.perspective?.byUUID) {
          const proxy = await activeClient.perspective.byUUID(perspectiveId);
          if (proxy) {
            if (proxy.subjectClasses) return await proxy.subjectClasses();
          }
        }
        return [];
      } catch {
        return [];
      }
    },

    async getLanguages(): Promise<any[]> {
      try {
        const activeClient = getClient();
        if (activeClient?.languages?.all) {
          return await activeClient.languages.all() || [];
        }
        if (monitor?.sendRpc) {
          return await monitor.sendRpc('language.all', {});
        }
        return [];
      } catch {
        return [];
      }
    },

    async getPerspectives(): Promise<any[]> {
      try {
        const activeClient = getClient();
        if (activeClient?.perspective?.all) {
          const ps = await activeClient.perspective.all();
          return (ps || []).map((p: any) => ({ uuid: p.uuid, name: p.name, neighbourhood: p.neighbourhood, sharedUrl: p.sharedUrl, state: p.state }));
        }
        if (monitor?.sendRpc) {
          const result = await monitor.sendRpc('perspective.all', {});
          if (Array.isArray(result)) return result;
        }
        return passivePerspectives.length > 0 ? passivePerspectives : [];
      } catch {
        return passivePerspectives.length > 0 ? passivePerspectives : [];
      }
    },

    async getAgentStatus(): Promise<any> {
      try {
        const activeClient = getClient();
        if (activeClient?.agent?.status) {
          return await activeClient.agent.status();
        }
        if (monitor?.sendRpc) {
          return await monitor.sendRpc('agent.status', {});
        }
        return passiveAgentStatus;
      } catch {
        return passiveAgentStatus;
      }
    },

    async runQuery(perspectiveId: string, query: string): Promise<any> {
      try {
        const activeClient = getClient();
        if (activeClient?.perspective?.byUUID) {
          const proxy = await activeClient.perspective.byUUID(perspectiveId);
          if (proxy) return await proxy.infer(query);
        }
        if (monitor?.sendRpc) {
          return await monitor.sendRpc('perspective.queryProlog', { uuid: perspectiveId, query });
        }
        return { error: 'No client or WS connection available' };
      } catch (e: any) {
        throw e;
      }
    },

    async runSparqlQuery(perspectiveId: string, query: string): Promise<any> {
      try {
        const activeClient = getClient();
        if (activeClient?.perspective?.byUUID) {
          const proxy = await activeClient.perspective.byUUID(perspectiveId);
          if (proxy?.querySparql) return await proxy.querySparql(query);
        }
        if (monitor?.sendRpc) {
          return await monitor.sendRpc('perspective.querySparql', { uuid: perspectiveId, query });
        }
        return { error: 'No client or WS connection available' };
      } catch (e: any) {
        throw e;
      }
    },

    async sendRpc(method: string, params?: any): Promise<any> {
      if (monitor?.sendRpc) {
        return await monitor.sendRpc(method, params);
      }
      throw new Error('No WebSocket monitor available');
    },
  };

  monitor = installWebSocketMonitor(devtools as any);

  // Handle passive data from WS traffic
  (devtools as any).onPassiveResponse = (method: string, result: any) => {
    switch (method) {
      case 'perspective.all':
        passivePerspectives.length = 0;
        if (Array.isArray(result)) {
          result.forEach((p: any) => passivePerspectives.push({
            uuid: p.uuid, name: p.name, neighbourhood: p.neighbourhood, sharedUrl: p.sharedUrl, state: p.state,
          }));
        }
        break;
      case 'agent.status':
      case 'agent.me':
        passiveAgentStatus = result;
        break;
      case 'language.all':
        if (Array.isArray(result)) {
          languages.length = 0;
          result.forEach((lang: any) => {
            languages.push({
              name: lang.name || '',
              address: lang.address || '',
              loadStatus: 'loaded',
              timestamp: Date.now(),
            });
          });
        }
        break;
    }
  };

  return devtools;
}

/**
 * Initialize the AD4M DevTools bridge for GraphQL/Apollo transport.
 * 
 * Call this from the Ad4mClient constructor:
 * ```typescript
 * import { initDevToolsBridge } from '@ad4m-devtools/bridge';
 * initDevToolsBridge(this);
 * ```
 * 
 * @param client - The Ad4mClient instance (must have #apolloClient accessible)
 */
export function initDevToolsBridge(client: any): void {
  if (typeof globalThis === 'undefined') return;

  const existing = (globalThis as any).__AD4M_DEVTOOLS__ as AD4MDevTools | undefined;
  if (existing) {
    existing._client = client;
    patchClientForCallerStacks(client);
    if ((globalThis as any).window) {
      (globalThis as any).window.__AD4M_DEVTOOLS__ = existing;
    }
    return;
  }

  const devtools = createBridge(client);

  (globalThis as any).__AD4M_DEVTOOLS__ = devtools;
  if ((globalThis as any).window) {
    (globalThis as any).window.__AD4M_DEVTOOLS__ = devtools;
  }

}

/**
 * Auto-discover the Ad4mClient from the <ad4m-connect> custom element.
 *
 * ad4m-connect appends an <ad4m-connect> element to the body and stores
 * the Ad4mConnect core as `element.core`. The client is at
 * `element.core.ad4mClient`. By polling for this element, we can patch
 * the client and PerspectiveProxy prototype WITHOUT any SDK modifications.
 *
 * We also walk from the client to find the PerspectiveProxy class used by
 * the SAME bundle (ad4m-connect's bundled copy) and wrap its prototype
 * methods for caller stack capture.
 */
function autoDiscoverClient(devtools: AD4MDevTools): void {
  let discovered = false;
  let attempts = 0;
  const MAX_ATTEMPTS = 100; // ~10 seconds at 100ms intervals

  const tryDiscover = () => {
    if (discovered || attempts++ > MAX_ATTEMPTS) {
      return;
    }

    // Already set by SDK self-registration?
    if (devtools._client) {
      discovered = true;
      tryDiscoverAdditionalClasses(devtools, devtools._client);
      return;
    }

    const el = document.querySelector('ad4m-connect') as any;
    const client = el?.core?.ad4mClient;
    if (!client) {
      setTimeout(tryDiscover, 100);
      return;
    }

    discovered = true;

    // Set client — this triggers patchClientForCallerStacks via the setter
    devtools._client = client;

    // Try to find Ad4mModel from the same module scope as the client.
    // The client constructor imports Ad4mModel, so it should be on the
    // same module's exports. We can find it via the PerspectiveProxy's
    // prototype since model queries go through it.
    tryDiscoverAdditionalClasses(devtools, client);
  };

  // Start polling after a short delay (let the app boot)
  setTimeout(tryDiscover, 50);
}

/**
 * Try to find and patch PerspectiveProxy prototype and Ad4mModel.
 *
 * Strategy: call client.perspective.all() to get real PerspectiveProxy
 * instances, then patch the prototype so ALL future proxy instances
 * get caller-stack wrappers automatically (even ones obtained before
 * the patch — they share the same prototype).
 */
function tryDiscoverAdditionalClasses(devtools: AD4MDevTools, client: any): void {
  const perspectiveClient = client.perspective;
  if (!perspectiveClient) return;

  const patchProxyPrototype = (proxy: any) => {
    if (!proxy || typeof proxy !== 'object') return;
    const proto = Object.getPrototypeOf(proxy);
    if (proto && !proto.__ad4mDevtoolsProtoPatched) {
      proto.__ad4mDevtoolsProtoPatched = true;
      wrapAsyncMethods(proto);
    }
  };

  // Try to get a proxy instance to patch the prototype.
  // Use a microtask so we don't block initialization.
  // Retry a few times since perspectives may not exist yet at startup.
  const tryPatch = async (retriesLeft: number) => {
    try {
      const proxies = await perspectiveClient.all();
      if (Array.isArray(proxies) && proxies.length > 0) {
        patchProxyPrototype(proxies[0]);
      } else if (retriesLeft > 0) {
        setTimeout(() => tryPatch(retriesLeft - 1), 2000);
      }
    } catch (err) {
      if (retriesLeft > 0) {
        setTimeout(() => tryPatch(retriesLeft - 1), 2000);
      }
    }
  };
  tryPatch(15); // retry up to 15 times (~30s total)
}

export function initExternalWebSocketDevTools(): void {
  if (typeof globalThis === 'undefined') return;

  const existing = (globalThis as any).__AD4M_DEVTOOLS__ as AD4MDevTools | undefined;
  if (existing) {
    // Even if already initialized, try discovery if client not set
    if (!existing._client && typeof document !== 'undefined') {
      autoDiscoverClient(existing);
    }
    return;
  }

  const devtools = createBridge(undefined);
  (globalThis as any).__AD4M_DEVTOOLS__ = devtools;
  if ((globalThis as any).window) {
    (globalThis as any).window.__AD4M_DEVTOOLS__ = devtools;
  }

  // Auto-discover Ad4mClient from the <ad4m-connect> custom element.
  // This works without any SDK modifications — we poll for the element
  // and extract the client + PerspectiveProxy prototype from it.
  if (typeof document !== 'undefined') {
    autoDiscoverClient(devtools);
  }
}

export type { AD4MDevTools, DevToolsState, OperationRecord, SubscriptionRecord, SubscriptionUpdateRecord, NotificationRecord, PerformanceState, GetterTraceRecord, LanguageRecord, ErrorDetail } from './core/types';
