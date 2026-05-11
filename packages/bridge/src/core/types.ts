export type OperationType = 'request' | 'trace' | 'subscription';
export type OperationTransport = 'rest' | 'graphql' | 'websocket' | 'sparql' | 'prolog' | 'sse' | 'internal';
export type QueryLanguage = 'sparql' | 'prolog';

export interface OperationRecord {
  id: number;
  type: OperationType;
  transport: OperationTransport;
  operationName: string;
  socketId?: string;
  wsRequestId?: string;
  requestId?: string;
  method?: string;
  path?: string;
  url?: string;
  queryLanguage?: QueryLanguage;
  query?: string;
  variables?: Record<string, any>;
  requestBody?: any;
  requestHeaders?: Record<string, string>;
  response?: any;
  responseHeaders?: Record<string, string>;
  statusCode?: number;
  errors?: ErrorDetail[];
  startTime: number;
  firstResponseAt?: number;
  lastResponseAt?: number;
  responsePeriodMs?: number;
  responseCount?: number;
  requestBytes?: number;
  responseBytes?: number;
  totalResponseBytes?: number;
  totalBytes?: number;
  responses?: any[];
  endTime?: number;
  duration?: number;
  payloadSize?: number;
  sparqlQuery?: string;
  sparqlResult?: any;
  stackTrace?: string;

  // Semantic metadata (extracted from RPC params)
  modelClassName?: string;
  perspectiveUUID?: string;
  rpcMethod?: string;         // e.g. "perspective.modelQuery"
  queryFingerprint?: string;  // hash for dedup detection
  dupCount?: number;          // how many times this exact query was seen
  dupGroupId?: string;        // shared key for duplicate ops
}

export interface CompleteOperationOptions {
  statusCode?: number;
  responseHeaders?: Record<string, string>;
}

export interface ErrorDetail {
  message: string;
  type?: string;
  stack?: string;
  nested?: ErrorDetail[];
}

export interface SubscriptionRecord {
  stackTrace?: string;
  id: number;
  query: string;
  perspectiveUUID: string;
  modelName: string;
  updateCount: number;
  lastUpdateTimestamp: number;
  fingerprintHits: number;
  fingerprintMisses: number;
  callbackTimings: number[];
  active: boolean;
}

export interface SubscriptionUpdateRecord {
  subscriptionId: number;
  rawResultCount: number;
  processedCount: number;
  fingerprintChanged: boolean;
  timestamp: number;
}

export interface NotificationRecord {
  id: string;
  triggerQuery: string;
  lastResult?: any;
  lastError?: string;
  matchHistory: Array<{ timestamp: number; matched: boolean }>;
  registered: number;
}

export interface GetterTraceRecord {
  id: number;
  property: string;
  getterType: 'sparql' | 'legacy';
  query: string;
  result: any;
  error: string | null;
  duration: number;
  instanceId: string;
  timestamp: number;
}

export interface LanguageRecord {
  name: string;
  address: string;
  loadStatus: 'loading' | 'loaded' | 'error';
  loadTime?: number;
  error?: string;
  timestamp: number;
}

export interface PerformanceState {
  totalRequests: number;
  totalErrors: number;
  avgRTT: number;
  peakRTT: number;
  requestsPerSecond: number;
  restRequestCount: number;
  sparqlTraceCount: number;
  prologRequestCount: number;
  activeSubscriptions: number;
  subscriptionUpdateRate: number;
  eventStreamMessageRate: number;
  totalWsSentBytes: number;
  totalWsReceivedBytes: number;
  totalWsBytes: number;
  wsFramesSent: number;
  wsFramesReceived: number;
  activeWebSockets: number;
  estimatedMemory: number;
  // Legacy aliases kept for compatibility with older panel/export readers.
  totalQueries: number;
  queriesPerSecond: number;
  sparqlQueryCount: number;
  prologQueryCount: number;
  wsMessageRate: number;
}

export interface PerspectiveInfo {
  uuid: string;
  name: string;
  neighbourhood?: any;
  sharedUrl?: string;
  state?: string;
}

export interface DevToolsState {
  operations: OperationRecord[];
  subscriptions: SubscriptionRecord[];
  subscriptionUpdates: SubscriptionUpdateRecord[];
  notifications: NotificationRecord[];
  performance: PerformanceState;
  getterTraces: GetterTraceRecord[];
  languages: LanguageRecord[];
  perspectives: PerspectiveInfo[];
  agentStatus: any;
  connection: {
    connected: boolean;
    transport: 'rest' | 'graphql' | 'websocket';
    url: string;
    authenticated: boolean;
    eventStreamConnected: boolean;
    activeEventStreams: number;
    wsFramesSent?: number;
    wsFramesReceived?: number;
    wsSentBytes?: number;
    wsReceivedBytes?: number;
  };
}

export interface AD4MDevTools {
  getState(): DevToolsState;
  trackSubscription(sub: Partial<SubscriptionRecord>): number;
  updateSubscription(id: number, update: Partial<SubscriptionRecord>): void;
  logSparqlQuery(info: { query: string; modelName: string; perspectiveUUID: string }): void;
  logOperation(op: Partial<OperationRecord>): number;
  completeOperation(id: number, result: any, errors?: any[], options?: CompleteOperationOptions): void;
  patchOperation?(id: number, patch: Partial<OperationRecord>): void;
  getOperation?(id: number): OperationRecord | undefined;
  recordEventStreamMessage(): void;
  recordWebSocketFrame?(direction: 'in' | 'out', bytes: number): void;
  setActiveWebSockets?(count: number): void;
  registerNotification(notification: NotificationRecord): void;
  updateNotification(id: string, update: Partial<NotificationRecord>): void;
  logSubscriptionUpdate(update: SubscriptionUpdateRecord): void;
  logGetterTrace(trace: Omit<GetterTraceRecord, 'id' | 'timestamp'>): void;
  logLanguageEvent(lang: LanguageRecord): void;
  testNotificationTrigger(notificationId: string, perspectiveId: string): Promise<any>;
  queryLinks(perspectiveId: string, filter?: { source?: string; predicate?: string; target?: string }): Promise<any[]>;
  getSubjectClasses(perspectiveId: string): Promise<any[]>;
  getLanguages(): Promise<any[]>;
  getPerspectives(): Promise<any[]>;
  getAgentStatus(): Promise<any>;
  runQuery(perspectiveId: string, query: string): Promise<any>;
  sendRpc?(method: string, params?: any): Promise<any>;
  _client?: any;
  _Ad4mModel?: any;
  _version: string;
}

declare global {
  interface Window {
    __AD4M_DEVTOOLS__?: AD4MDevTools;
  }
}
