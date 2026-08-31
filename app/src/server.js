'use strict';

/**
 * ce-capstone storefront
 *
 * A deliberately small Node.js service. The capstone is graded on
 * infrastructure, not application features, so this exists to make the
 * infrastructure observable:
 *
 *   GET /              storefront page showing which instance and AZ served it
 *   GET /health        ALB health check target
 *   GET /api/products  product catalog, read from DynamoDB
 *   GET /api/instance  instance identity as JSON
 *   GET /stress        burns CPU on purpose, to demonstrate auto scaling
 *
 * Two constraints shaped the implementation:
 *
 *   1. No npm dependencies. Every dependency is a package that has to be
 *      downloaded through the NAT Gateway while an instance boots, and a
 *      registry hiccup would mean instances joining the target group
 *      unhealthy. The only imports are Node built-ins.
 *
 *   2. DynamoDB is read through the AWS CLI, which is preinstalled on
 *      Amazon Linux 2023 and picks up the EC2 instance role automatically.
 *      That avoids both an SDK install and any credential handling in
 *      application code.
 */

const http = require('node:http');
const { execFile } = require('node:child_process');
const os = require('node:os');

const PORT = Number(process.env.PORT || 3000);
const AWS_REGION = process.env.AWS_REGION || 'us-east-1';
const PRODUCTS_TABLE = process.env.PRODUCTS_TABLE || '';
const ENVIRONMENT = process.env.ENVIRONMENT || 'unknown';

// The catalog is refreshed on a timer and served from memory. Requests never
// block on DynamoDB, so a data-tier blip degrades to stale data rather than to
// failed health checks and an emptied target group.
const CATALOG_REFRESH_MS = 60_000;
const IMDS_BASE = 'http://169.254.169.254';
const STARTED_AT = Date.now();

const state = {
  instanceId: 'unknown',
  availabilityZone: 'unknown',
  instanceType: 'unknown',
  products: [],
  catalogLoadedAt: null,
  catalogError: null,
};

/** Structured single-line JSON, so CloudWatch Logs Insights can query fields. */
function log(level, message, extra = {}) {
  process.stdout.write(
    JSON.stringify({
      ts: new Date().toISOString(),
      level,
      message,
      instanceId: state.instanceId,
      az: state.availabilityZone,
      ...extra,
    }) + '\n'
  );
}

// ---------------------------------------------------------------------------
// Instance identity (IMDSv2)
// ---------------------------------------------------------------------------

function imdsRequest(path, { method = 'GET', headers = {}, timeoutMs = 2000 } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(`${IMDS_BASE}${path}`, { method, headers }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        body += chunk;
      });
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(body.trim());
        } else {
          reject(new Error(`IMDS ${path} returned ${res.statusCode}`));
        }
      });
    });

    req.setTimeout(timeoutMs, () => req.destroy(new Error(`IMDS ${path} timed out`)));
    req.on('error', reject);
    req.end();
  });
}

/**
 * IMDSv2 only. The launch template sets http_tokens = "required", which blocks
 * the unauthenticated v1 endpoint and with it the SSRF-to-credential-theft
 * path that made IMDSv1 a recurring cloud breach cause.
 */
async function loadInstanceIdentity() {
  try {
    const token = await imdsRequest('/latest/api/token', {
      method: 'PUT',
      headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '300' },
    });

    const headers = { 'X-aws-ec2-metadata-token': token };
    const [instanceId, az, instanceType] = await Promise.all([
      imdsRequest('/latest/meta-data/instance-id', { headers }),
      imdsRequest('/latest/meta-data/placement/availability-zone', { headers }),
      imdsRequest('/latest/meta-data/instance-type', { headers }),
    ]);

    state.instanceId = instanceId;
    state.availabilityZone = az;
    state.instanceType = instanceType;
    log('info', 'instance identity resolved', { instanceType });
  } catch (err) {
    // Off-instance (local development, container tests) this is expected.
    state.instanceId = `local-${os.hostname()}`;
    state.availabilityZone = 'local';
    log('warn', 'instance metadata unavailable, using local identity', {
      error: err.message,
    });
  }
}

// ---------------------------------------------------------------------------
// Product catalog
// ---------------------------------------------------------------------------

function awsCli(args, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    execFile(
      'aws',
      args,
      { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err) {
          reject(new Error(stderr?.trim() || err.message));
          return;
        }
        resolve(stdout);
      }
    );
  });
}

/** Unwrap DynamoDB attribute-value JSON into plain values. */
function fromDynamoItem(item) {
  const out = {};
  for (const [key, value] of Object.entries(item)) {
    if ('S' in value) out[key] = value.S;
    else if ('N' in value) out[key] = Number(value.N);
    else if ('BOOL' in value) out[key] = value.BOOL;
    else out[key] = null;
  }
  return out;
}

async function refreshCatalog() {
  if (!PRODUCTS_TABLE) {
    state.catalogError = 'PRODUCTS_TABLE is not configured';
    return;
  }

  try {
    // The catalog is a handful of rows, so a scan is the honest choice here.
    // A real storefront would query a partition key or front this with a
    // search index; see ARCHITECTURE.md.
    const stdout = await awsCli([
      'dynamodb',
      'scan',
      '--table-name',
      PRODUCTS_TABLE,
      '--region',
      AWS_REGION,
      '--output',
      'json',
    ]);

    const parsed = JSON.parse(stdout);
    state.products = (parsed.Items || [])
      .map(fromDynamoItem)
      .sort((a, b) => String(a.name).localeCompare(String(b.name)));
    state.catalogLoadedAt = new Date().toISOString();
    state.catalogError = null;
    log('info', 'catalog refreshed', { productCount: state.products.length });
  } catch (err) {
    // Keep serving the previous snapshot rather than emptying the storefront.
    state.catalogError = err.message;
    log('error', 'catalog refresh failed', { error: err.message });
  }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Instance-Id': state.instanceId,
    'X-Availability-Zone': state.availabilityZone,
    // Defence in depth for the HTML response below.
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(body);
}

function sendHtml(res, statusCode, html) {
  res.writeHead(statusCode, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(html),
    'Cache-Control': 'no-store',
    'X-Instance-Id': state.instanceId,
    'X-Availability-Zone': state.availabilityZone,
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'",
  });
  res.end(html);
}

function escapeHtml(value) {
  return String(value).replace(
    /[&<>"']/g,
    (ch) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]
  );
}

/**
 * The health check the ALB polls. Deliberately shallow: it reports whether
 * this process can serve traffic, and does NOT fail on a DynamoDB error.
 *
 * A deep health check that fails when a shared dependency is down takes every
 * instance out of the target group simultaneously and turns a degraded
 * feature into a total outage. Catalog health is surfaced as a field and
 * alarmed on separately.
 */
function handleHealth(res) {
  sendJson(res, 200, {
    status: 'healthy',
    instanceId: state.instanceId,
    availabilityZone: state.availabilityZone,
    instanceType: state.instanceType,
    environment: ENVIRONMENT,
    uptimeSeconds: Math.round((Date.now() - STARTED_AT) / 1000),
    catalog: {
      productCount: state.products.length,
      lastLoadedAt: state.catalogLoadedAt,
      degraded: state.catalogError !== null,
    },
  });
}

function handleInstance(res) {
  sendJson(res, 200, {
    instanceId: state.instanceId,
    availabilityZone: state.availabilityZone,
    instanceType: state.instanceType,
    environment: ENVIRONMENT,
    region: AWS_REGION,
    hostname: os.hostname(),
    uptimeSeconds: Math.round((Date.now() - STARTED_AT) / 1000),
  });
}

function handleProducts(res) {
  sendJson(res, 200, {
    products: state.products,
    count: state.products.length,
    servedBy: state.instanceId,
    availabilityZone: state.availabilityZone,
    lastLoadedAt: state.catalogLoadedAt,
    degraded: state.catalogError !== null,
  });
}

/**
 * Burns CPU in a tight loop so the target-tracking scaling policy has
 * something to react to during the demo. Capped at 60 seconds so a stray
 * request cannot pin an instance indefinitely.
 */
function handleStress(res, url) {
  const requested = Number(url.searchParams.get('seconds') || 30);
  const seconds = Math.min(Math.max(Number.isFinite(requested) ? requested : 30, 1), 60);

  log('warn', 'cpu stress requested', { seconds });

  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    // Intentional busy loop.
  }

  sendJson(res, 200, {
    message: `burned CPU for ${seconds}s`,
    instanceId: state.instanceId,
    availabilityZone: state.availabilityZone,
  });
}

function renderStorefront() {
  const rows =
    state.products.length > 0
      ? state.products
          .map(
            (p) => `
        <tr>
          <td>${escapeHtml(p.name ?? '-')}</td>
          <td>${escapeHtml(p.category ?? '-')}</td>
          <td class="num">${escapeHtml(p.price ?? '-')}</td>
          <td class="num">${escapeHtml(p.stock ?? '-')}</td>
        </tr>`
          )
          .join('')
      : `<tr><td colspan="4" class="empty">Catalog unavailable${
          state.catalogError ? ` &mdash; ${escapeHtml(state.catalogError)}` : ''
        }</td></tr>`;

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ce-capstone storefront</title>
  <style>
    :root { color-scheme: light dark; }
    body { font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, sans-serif;
           margin: 0; padding: 2rem 1.5rem; line-height: 1.5; }
    main { max-width: 52rem; margin: 0 auto; }
    h1 { font-size: 1.5rem; margin: 0 0 0.25rem; }
    .sub { opacity: 0.7; margin: 0 0 2rem; font-size: 0.95rem; }
    .cards { display: grid; gap: 0.75rem; grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
             margin-bottom: 2rem; }
    .card { border: 1px solid rgba(128,128,128,0.35); border-radius: 0.5rem; padding: 0.85rem 1rem; }
    .card .label { font-size: 0.7rem; letter-spacing: 0.06em; text-transform: uppercase; opacity: 0.65; }
    .card .value { font-size: 1.05rem; font-weight: 600; font-variant-numeric: tabular-nums;
                   word-break: break-all; margin-top: 0.15rem; }
    .ok { color: #15803d; }
    table { width: 100%; border-collapse: collapse; font-size: 0.95rem; }
    th, td { text-align: left; padding: 0.55rem 0.6rem; border-bottom: 1px solid rgba(128,128,128,0.25); }
    th { font-size: 0.72rem; letter-spacing: 0.06em; text-transform: uppercase; opacity: 0.65; }
    td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
    .empty { opacity: 0.6; font-style: italic; }
    footer { margin-top: 2rem; font-size: 0.8rem; opacity: 0.6; }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  </style>
</head>
<body>
<main>
  <h1>ce-capstone storefront</h1>
  <p class="sub">Reload the page &mdash; the instance below changes as the load balancer
     spreads requests across availability zones.</p>

  <div class="cards">
    <div class="card"><div class="label">Served by</div><div class="value">${escapeHtml(state.instanceId)}</div></div>
    <div class="card"><div class="label">Availability zone</div><div class="value">${escapeHtml(state.availabilityZone)}</div></div>
    <div class="card"><div class="label">Instance type</div><div class="value">${escapeHtml(state.instanceType)}</div></div>
    <div class="card"><div class="label">Health</div><div class="value ok">healthy</div></div>
    <div class="card"><div class="label">Environment</div><div class="value">${escapeHtml(ENVIRONMENT)}</div></div>
    <div class="card"><div class="label">Uptime</div><div class="value">${Math.round((Date.now() - STARTED_AT) / 1000)}s</div></div>
  </div>

  <table>
    <thead>
      <tr><th>Product</th><th>Category</th><th class="num">Price (USD)</th><th class="num">Stock</th></tr>
    </thead>
    <tbody>${rows}
    </tbody>
  </table>

  <footer>
    Catalog served from DynamoDB via a VPC gateway endpoint.
    Endpoints: <code>/health</code> &middot; <code>/api/products</code> &middot;
    <code>/api/instance</code> &middot; <code>/stress?seconds=30</code>
  </footer>
</main>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const startedAt = process.hrtime.bigint();

  res.on('finish', () => {
    const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    // The ALB health check fires every 15s per instance; logging it would
    // dominate the log group and the CloudWatch ingestion bill.
    if (url.pathname !== '/health') {
      log('info', 'request', {
        method: req.method,
        path: url.pathname,
        status: res.statusCode,
        durationMs: Math.round(durationMs * 100) / 100,
      });
    }
  });

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    sendJson(res, 405, { error: 'method not allowed' });
    return;
  }

  switch (url.pathname) {
    case '/health':
      return handleHealth(res);
    case '/api/instance':
      return handleInstance(res);
    case '/api/products':
      return handleProducts(res);
    case '/stress':
      return handleStress(res, url);
    case '/':
      return sendHtml(res, 200, renderStorefront());
    default:
      return sendJson(res, 404, { error: 'not found', path: url.pathname });
  }
});

// Give the load balancer time to drain a connection before the process exits,
// so a deployment or scale-in does not surface as a 5xx to a user.
function shutdown(signal) {
  log('info', 'shutting down', { signal });
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 10_000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

async function main() {
  await loadInstanceIdentity();

  // Start listening before the first catalog load completes. The instance
  // passes its health check promptly and the storefront fills in a moment
  // later, instead of the ASG killing a slow-starting instance.
  server.listen(PORT, '0.0.0.0', () => {
    log('info', 'listening', { port: PORT, environment: ENVIRONMENT });
  });

  await refreshCatalog();
  setInterval(refreshCatalog, CATALOG_REFRESH_MS).unref();
}

main().catch((err) => {
  log('error', 'startup failed', { error: err.message });
  process.exit(1);
});
