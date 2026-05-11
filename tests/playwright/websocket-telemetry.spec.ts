import { test, expect, chromium } from '@playwright/test';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import path from 'path';

const rootDir = path.resolve(__dirname, '../..');
const injectScriptPath = path.resolve(rootDir, 'packages/extension/dist/page-inject.js');

test('captures ws rpc pairs, subscription updates, periods, and byte totals', async () => {
  const httpServer = createServer((req, res) => {
    if (req.url === '/app') {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end('<!doctype html><html><body><h1>ws test</h1></body></html>');
      return;
    }
    res.writeHead(404);
    res.end('Not found');
  });

  const wss = new WebSocketServer({ noServer: true });

  httpServer.on('upgrade', (request, socket, head) => {
    if (request.url === '/api/v1/ws') {
      wss.handleUpgrade(request, socket, head, (ws) => {
        wss.emit('connection', ws, request);
      });
      return;
    }
    socket.destroy();
  });

  wss.on('connection', (ws) => {
    ws.on('message', (raw) => {
      const payload = JSON.parse(raw.toString());

      if (payload.type === 'perspective.modelQuery') {
        ws.send(JSON.stringify({
          id: payload.id,
          result: { instances: [{ id: 'x' }], totalCount: 1 },
        }));
        return;
      }

      if (payload.type === 'perspective.modelSubscribe') {
        ws.send(JSON.stringify({
          id: payload.id,
          result: {
            subscription_id: 'sub-e2e',
            result: JSON.stringify({ instances: [] }),
          },
        }));

        setTimeout(() => {
          ws.send(JSON.stringify({
            type: 'query-subscription-update',
            subscriptionId: 'sub-e2e',
            result: { instances: [{ id: '1' }] },
          }));
        }, 20);

        setTimeout(() => {
          ws.send(JSON.stringify({
            type: 'query-subscription-update',
            subscriptionId: 'sub-e2e',
            result: { instances: [{ id: '1' }, { id: '2' }] },
          }));
        }, 50);
      }
    });
  });

  await new Promise<void>((resolve) => {
    httpServer.listen(0, '127.0.0.1', () => resolve());
  });

  const address = httpServer.address();
  if (!address || typeof address === 'string') throw new Error('Server did not bind to a TCP port');
  const port = address.port;

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    await page.goto(`http://127.0.0.1:${port}/app`);
    await page.addScriptTag({ path: injectScriptPath });

    await page.evaluate(async (wsPort) => {
      const waitForBridge = async () => {
        for (let i = 0; i < 60; i += 1) {
          if ((window as any).__AD4M_DEVTOOLS__?.getState) return;
          await new Promise(r => setTimeout(r, 20));
        }
        throw new Error('Bridge not available');
      };

      await waitForBridge();

      const ws = new WebSocket(`ws://127.0.0.1:${wsPort}/api/v1/ws`);
      await new Promise<void>((resolve, reject) => {
        ws.addEventListener('open', () => resolve(), { once: true });
        ws.addEventListener('error', () => reject(new Error('ws open failed')), { once: true });
      });

      ws.send(JSON.stringify({ id: 'q-1', type: 'perspective.modelQuery', params: { uuid: 'p1' } }));
      ws.send(JSON.stringify({ id: 's-1', type: 'perspective.modelSubscribe', params: { uuid: 'p1' } }));

      await new Promise(r => setTimeout(r, 180));
      ws.close();
      await new Promise(r => setTimeout(r, 40));
    }, port);

    const state = await page.evaluate(() => (window as any).__AD4M_DEVTOOLS__.getState());

    expect(state.performance.totalWsSentBytes).toBeGreaterThan(0);
    expect(state.performance.totalWsReceivedBytes).toBeGreaterThan(0);
    expect(state.performance.wsFramesSent).toBeGreaterThanOrEqual(2);
    expect(state.performance.wsFramesReceived).toBeGreaterThanOrEqual(3);

    const queryOp = state.operations.find((o: any) => o.operationName === 'WS-RPC perspective.modelQuery');
    expect(queryOp).toBeTruthy();
    expect(queryOp.wsRequestId || queryOp.requestId).toBe('q-1');
    expect(queryOp.requestBytes).toBeGreaterThan(0);
    expect(queryOp.totalResponseBytes).toBeGreaterThan(0);
    expect(queryOp.responseCount).toBe(1);
    expect(queryOp.totalBytes).toBeGreaterThan(0);
    expect(typeof queryOp.stackTrace).toBe('string');

    const subOp = state.operations.find((o: any) => o.operationName === 'WS-RPC perspective.modelSubscribe');
    expect(subOp).toBeTruthy();
    expect(subOp.wsRequestId || subOp.requestId).toBe('s-1');
    expect(subOp.responseCount).toBeGreaterThanOrEqual(3);
    expect(subOp.responsePeriodMs).toBeGreaterThanOrEqual(0);
    expect(subOp.totalResponseBytes).toBeGreaterThan(0);
    expect(Array.isArray(subOp.responses)).toBe(true);
    expect(subOp.responses.length).toBeGreaterThanOrEqual(2);
  } finally {
    await context.close();
    await browser.close();
    wss.close();
    await new Promise<void>((resolve, reject) => {
      httpServer.close((err) => {
        if (err) reject(err);
        else resolve();
      });
    });
  }
});
