'use strict';

const CLIENT_TOKEN = process.env.CLIENT_TOKEN || '';
const RELAY_URL = process.env.RELAY_URL || '';
const RELAY_TOKEN = process.env.RELAY_TOKEN || '';
const RELAY_TIMEOUT_MS = Number(process.env.RELAY_TIMEOUT_MS || 1200);

function response(statusCode, body, contentType = 'application/json; charset=utf-8') {
  return {
    statusCode,
    headers: {
      'content-type': contentType,
      'cache-control': 'no-store',
    },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  };
}

function parseEvent(event) {
  if (typeof event === 'string') {
    return JSON.parse(event || '{}');
  }
  return event || {};
}

function header(headers, name) {
  if (!headers) return '';
  const wanted = name.toLowerCase();
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() === wanted) {
      return Array.isArray(value) ? value[0] : String(value || '');
    }
  }
  return '';
}

function parseQuery(queryParameters) {
  const out = {};
  for (const [key, value] of Object.entries(queryParameters || {})) {
    out[key] = Array.isArray(value) ? value[0] : value;
  }
  return out;
}

function tokenFromRequest(req, query) {
  if (query.token) return String(query.token);

  const auth = header(req.headers, 'authorization');
  if (auth.toLowerCase().startsWith('bearer ')) {
    return auth.slice(7).trim();
  }

  const path = req.rawPath || req.path || '';
  const parts = path.split('/').filter(Boolean);
  const pulseIndex = parts.indexOf('pulse');
  if (pulseIndex >= 0 && parts[pulseIndex + 1]) {
    return parts[pulseIndex + 1];
  }
  const rulesIndex = parts.indexOf('rules');
  if (rulesIndex >= 0 && parts[rulesIndex + 1]) {
    return parts[rulesIndex + 1].replace(/\.ya?ml$/i, '');
  }
  return '';
}

function wantsYaml(req) {
  const path = req.rawPath || req.path || '';
  return path.includes('/rules/') || /\.ya?ml$/i.test(path);
}

function getClientIp(req) {
  const xff = header(req.headers, 'x-forwarded-for');
  if (xff) {
    return xff.split(',')[0].trim();
  }

  const xRealIp = header(req.headers, 'x-real-ip');
  if (xRealIp) return xRealIp.trim();

  const xClientIp = header(req.headers, 'x-client-ip');
  if (xClientIp) return xClientIp.trim();

  const ctx = req.requestContext || {};
  return ctx.clientIp || ctx.sourceIp || ctx.http?.sourceIp || '';
}

function isPublicIpv4(ip) {
  const parts = ip.split('.');
  if (parts.length !== 4) return false;
  const nums = parts.map((part) => {
    if (!/^(0|[1-9][0-9]{0,2})$/.test(part)) return NaN;
    return Number(part);
  });
  if (nums.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;

  const [a, b] = nums;
  if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
  if (a === 100 && b >= 64 && b <= 127) return false;
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 198 && (b === 18 || b === 19)) return false;
  return true;
}

async function postRelay(payload) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), RELAY_TIMEOUT_MS);
  try {
    const resp = await fetch(RELAY_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-relay-token': RELAY_TOKEN,
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    const text = await resp.text();
    let body;
    try {
      body = text ? JSON.parse(text) : {};
    } catch {
      body = { raw: text };
    }
    return { status: resp.status, body };
  } finally {
    clearTimeout(timer);
  }
}

exports.handler = async function handler(event) {
  if (!CLIENT_TOKEN || !RELAY_URL || !RELAY_TOKEN) {
    return response(500, { ok: false, error: 'missing_fc_environment' });
  }

  let req;
  try {
    req = parseEvent(event);
  } catch {
    return response(400, { ok: false, error: 'invalid_event' });
  }

  const method = req.requestContext?.http?.method || req.httpMethod || 'GET';
  if (!['GET', 'POST', 'HEAD'].includes(method)) {
    return response(405, { ok: false, error: 'method_not_allowed' });
  }

  const query = parseQuery(req.queryParameters || req.queryStringParameters);
  const token = tokenFromRequest(req, query);
  if (token !== CLIENT_TOKEN) {
    return response(403, { ok: false, error: 'forbidden' });
  }

  const ip = getClientIp(req);
  if (!isPublicIpv4(ip)) {
    return response(400, { ok: false, error: 'invalid_client_ip', ip });
  }

  const mode = query.mode === 'wait' ? 'wait' : 'fast';
  const device = String(query.device || 'default').slice(0, 64);
  const yamlResponse = wantsYaml(req);

  try {
    const relay = await postRelay({ ip, mode, device, ts: Math.floor(Date.now() / 1000) });
    const accepted = relay.status >= 200 && relay.status < 300;
    if (yamlResponse && accepted) {
      return response(200, 'payload: []\n', 'application/yaml; charset=utf-8');
    }
    return response(accepted ? 200 : 502, {
      ok: accepted,
      ip,
      mode,
      relay_status: relay.status,
      relay: relay.body,
    });
  } catch (err) {
    return response(504, {
      ok: false,
      error: 'relay_timeout_or_error',
      detail: err && err.name ? err.name : String(err),
      ip,
      mode,
    });
  }
};




