import { StatusBadge } from './StatusBadge';

interface Props {
  state: any;
  connected: boolean;
}

export function ConnectionTab({ state, connected }: Props) {
  const conn = state.connection || {};
  return (
    <div class="tab-panel">
      <h2>WebSocket Transport</h2>
      <div class="info-grid">
        <div class="info-row">
          <span class="info-label">WS Bridge</span>
          <StatusBadge ok={connected} label={connected ? 'Detected' : 'Not detected'} />
        </div>
        <div class="info-row">
          <span class="info-label">Auth Token</span>
          <StatusBadge ok={conn.authenticated} label={conn.authenticated ? 'Present' : 'Missing'} />
        </div>
        <div class="info-row">
          <span class="info-label">Event Stream</span>
          <StatusBadge ok={conn.eventStreamConnected} label={conn.eventStreamConnected ? 'Streaming' : 'Idle'} />
        </div>
        <div class="info-row">
          <span class="info-label">Active Streams</span>
          <span class="info-value">{conn.activeEventStreams ?? 0}</span>
        </div>
        <div class="info-row">
          <span class="info-label">Transport</span>
          <span class="info-value">{conn.transport ? conn.transport.toUpperCase() : 'WEBSOCKET'}</span>
        </div>
        <div class="info-row">
          <span class="info-label">URL</span>
          <span class="info-value">{conn.url || '(not available)'}</span>
        </div>
      </div>

      <h3>Activity Breakdown</h3>
      <div class="info-grid">
        <div class="info-row">
          <span class="info-label">RPC Requests</span>
          <span class="info-value">{state.performance.restRequestCount}</span>
        </div>
        <div class="info-row">
          <span class="info-label">SPARQL Traces</span>
          <span class="info-value">{state.performance.sparqlTraceCount}</span>
        </div>
        <div class="info-row">
          <span class="info-label">Prolog Requests</span>
          <span class="info-value">{state.performance.prologRequestCount}</span>
        </div>
        <div class="info-row">
          <span class="info-label">Active Subscriptions</span>
          <span class="info-value">{state.performance.activeSubscriptions}</span>
        </div>
        <div class="info-row">
          <span class="info-label">Sub Update Rate</span>
          <span class="info-value">{state.performance.subscriptionUpdateRate}/s</span>
        </div>
        <div class="info-row">
          <span class="info-label">Event Msg Rate</span>
          <span class="info-value">{state.performance.eventStreamMessageRate}/s</span>
        </div>
        <div class="info-row">
          <span class="info-label">WS Frames Sent</span>
          <span class="info-value">{state.performance.wsFramesSent ?? 0}</span>
        </div>
        <div class="info-row">
          <span class="info-label">WS Frames Recv</span>
          <span class="info-value">{state.performance.wsFramesReceived ?? 0}</span>
        </div>
        <div class="info-row">
          <span class="info-label">WS Bytes Sent</span>
          <span class="info-value">{state.performance.totalWsSentBytes ?? 0}</span>
        </div>
        <div class="info-row">
          <span class="info-label">WS Bytes Recv</span>
          <span class="info-value">{state.performance.totalWsReceivedBytes ?? 0}</span>
        </div>
      </div>
    </div>
  );
}
