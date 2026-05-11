import { initExternalWebSocketDevTools } from '@ad4m-devtools/bridge';

// Runs in page world, allowing websocket constructor patching.
try {
  initExternalWebSocketDevTools();
  window.postMessage({ type: 'AD4M_DEVTOOLS_EVENT', event: 'ws-monitor-installed' }, '*');
} catch (e: any) {
  window.postMessage({ type: 'AD4M_DEVTOOLS_EVENT', event: 'ws-monitor-error', message: e?.message || String(e) }, '*');
}
