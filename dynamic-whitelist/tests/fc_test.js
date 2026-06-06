'use strict';

const assert = require('assert');
const http = require('http');

async function main() {
  const received = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
    });
    req.on('end', () => {
      received.push({
        url: req.url,
        token: req.headers['x-relay-token'],
        body: JSON.parse(body || '{}'),
      });
      res.writeHead(202, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, accepted: true }));
    });
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();

  process.env.CLIENT_TOKEN = 'client-token';
  process.env.RELAY_TOKEN = 'relay-token';
  process.env.RELAY_URL = `http://127.0.0.1:${port}/v1/allow`;
  process.env.RELAY_TIMEOUT_MS = '1000';

  const fc = require('../fc/index.js');

  const baseEvent = {
    rawPath: '/pulse/client-token',
    queryParameters: { device: 'unit', mode: 'wait' },
    headers: { 'x-forwarded-for': '8.8.8.8' },
    requestContext: { http: { method: 'GET' } },
  };

  let resp = await fc.handler(JSON.stringify(baseEvent));
  assert.strictEqual(resp.statusCode, 200);
  let body = JSON.parse(resp.body);
  assert.strictEqual(body.ok, true);
  assert.strictEqual(body.ip, '8.8.8.8');
  assert.strictEqual(received[0].token, 'relay-token');
  assert.strictEqual(received[0].body.ip, '8.8.8.8');
  assert.strictEqual(received[0].body.mode, 'wait');

  resp = await fc.handler(JSON.stringify({ ...baseEvent, rawPath: '/pulse/bad-token' }));
  assert.strictEqual(resp.statusCode, 403);

  resp = await fc.handler(JSON.stringify({
    ...baseEvent,
    headers: { 'x-forwarded-for': '10.0.0.1' },
  }));
  assert.strictEqual(resp.statusCode, 400);

  resp = await fc.handler(JSON.stringify({
    ...baseEvent,
    rawPath: '/rules/client-token.yaml',
    queryParameters: { device: 'mihomo', mode: 'fast' },
    headers: { 'x-forwarded-for': '8.8.4.4' },
  }));
  assert.strictEqual(resp.statusCode, 200);
  assert.strictEqual(resp.headers['content-type'], 'application/yaml; charset=utf-8');
  assert.strictEqual(resp.body, 'payload: []\n');

  await new Promise((resolve) => server.close(resolve));
  console.log('fc tests ok');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

