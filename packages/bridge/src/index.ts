import type {
  AD4MDevTools,
  CompleteOperationOptions,
  DevToolsState,
  ErrorDetail,
  GetterTraceRecord,
  LanguageRecord,
  NotificationRecord,
  OperationRecord,
  SubscriptionRecord,
  SubscriptionUpdateRecord,
} from './core/types';
import { PerformanceTracker } from './core/performance';
import { OperationInterceptor } from './core/interceptor';
import { SubscriptionTracker } from './core/subscription-tracker';
import { NotificationMonitor } from './core/notification-monitor';
import { wrapApolloClient } from './adapters/graphql';

const MAX_GETTER_TRACES = 200;
const MAX_SUB_UPDATES = 500;
const MAX_LANGUAGES = 100;

let nextGetterTraceId = 1;

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
    if ((globalThis as any).window) {
      (globalThis as any).window.__AD4M_DEVTOOLS__ = existing;
    }
    return;
  }

  const perf = new PerformanceTracker();
  const interceptor = new OperationInterceptor(perf);
  const subscriptions = new SubscriptionTracker();
  const notifications = new NotificationMonitor();

  const subscriptionUpdates: SubscriptionUpdateRecord[] = [];
  const getterTraces: GetterTraceRecord[] = [];
  const languages: LanguageRecord[] = [];
  const getClient = () => ((globalThis as any).__AD4M_DEVTOOLS__?._client || client);

  const connectionState = () => {
    const activeClient = getClient();
    // For GraphQL/Apollo, connection info comes from the Apollo link/transport
    const url = activeClient?.executorUrl || activeClient?.baseUrl || '';
    const authenticated = Boolean(activeClient?.hasAuthToken || activeClient?.authenticated);

    return {
      connected: Boolean(activeClient),
      transport: 'graphql' as const,
      url,
      authenticated,
      eventStreamConnected: subscriptions.getActiveCount() > 0,
      activeEventStreams: subscriptions.getActiveCount(),
    };
  };

  const enrichErrors = (errors?: any[]): ErrorDetail[] | undefined =>
    errors?.map(e => ({
      message: e?.message || String(e),
      type: e?.type || e?.name || e?.constructor?.name || (e?.extensions?.code ? `GraphQL: ${e.extensions.code}` : 'Error'),
      stack: e?.stack,
      nested: e?.networkError
        ? [{
            message: e.networkError.message,
            type: 'NetworkError',
            stack: e.networkError.stack,
          }]
        : undefined,
    }));

  const devtools: AD4MDevTools = {
    _version: '2.1.0',
    _client: client,

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
        connection: connectionState(),
      };
    },

    logOperation(op: Partial<OperationRecord>): number {
      return interceptor.log(op);
    },

    completeOperation(id: number, result: any, errors?: any[], options?: CompleteOperationOptions) {
      interceptor.complete(id, result, enrichErrors(errors), options);
    },

    recordEventStreamMessage() {
      perf.recordEventStreamMessage();
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
        const proxy = await activeClient?.perspective?.byUUID?.(perspectiveId);
        if (!proxy) return { error: 'Perspective not found' };
        const result = await proxy.infer(n.triggerQuery);
        return { success: true, result };
      } catch (e: any) {
        return { error: e.message };
      }
    },

    async queryLinks(perspectiveId: string, filter?: { source?: string; predicate?: string; target?: string }): Promise<any[]> {
      try {
        const activeClient = getClient();
        const proxy = await activeClient?.perspective?.byUUID?.(perspectiveId);
        if (!proxy) return [];
        return await proxy.get(filter || {});
      } catch {
        return [];
      }
    },

    async getSubjectClasses(perspectiveId: string): Promise<any[]> {
      try {
        const activeClient = getClient();
        const proxy = await activeClient?.perspective?.byUUID?.(perspectiveId);
        if (!proxy) return [];
        if (proxy.subjectClasses) return await proxy.subjectClasses();
        const result = await proxy.infer(`SELECT ?class ?property WHERE { ?class a sh:NodeShape . ?class sh:property ?prop . ?prop sh:path ?property } LIMIT 100`);
        return result || [];
      } catch {
        return [];
      }
    },

    async getLanguages(): Promise<any[]> {
      try {
        return await getClient()?.languages?.all?.() || [];
      } catch {
        return [];
      }
    },
  };

  (globalThis as any).__AD4M_DEVTOOLS__ = devtools;
  if ((globalThis as any).window) {
    (globalThis as any).window.__AD4M_DEVTOOLS__ = devtools;
  }

  // Attempt to wrap the Apollo client link chain
  // The Ad4mClient stores it as a private field — we need to access it
  // via the client reference passed in
  try {
    // Try to get the apollo client — it may be a private field
    const apolloClient = client._apolloClient || client.apolloClient;
    if (apolloClient) {
      wrapApolloClient(apolloClient, devtools);
    }
  } catch {
    // Apollo client not accessible — bridge will still work via manual instrumentation
  }
}

export { createDevToolsLink, wrapApolloClient } from './adapters/graphql';
export type { AD4MDevTools, DevToolsState, OperationRecord, SubscriptionRecord, SubscriptionUpdateRecord, NotificationRecord, PerformanceState, GetterTraceRecord, LanguageRecord, ErrorDetail } from './core/types';
