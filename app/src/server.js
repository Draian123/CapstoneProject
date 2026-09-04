'use strict';

/**
 * ce-capstone storefront
 *
 * A deliberately small Node.js service. The capstone is graded on
 * infrastructure, not application features, so this exists to make the
 * infrastructure observable:
 *
 *   GET /              storefront page, with a live view that polls /api/instance
 *                      and tallies which instance and AZ answered each request
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
const crypto = require('node:crypto');
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

/**
 * The storefront's only HTML response, and the only one that needs a script.
 *
 * `script-src` names a single-use nonce rather than allowing 'unsafe-inline',
 * so the live view runs and nothing else does -- an injected script tag has no
 * nonce and is refused. `connect-src 'self'` lets that script call
 * /api/instance on this origin and nowhere else, which is what stops a
 * compromised page from exfiltrating anything it reads.
 */
function sendHtml(res, statusCode, html, nonce) {
  res.writeHead(statusCode, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(html),
    'Cache-Control': 'no-store',
    'X-Instance-Id': state.instanceId,
    'X-Availability-Zone': state.availabilityZone,
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': [
      "default-src 'none'",
      "style-src 'unsafe-inline'",
      `script-src 'nonce-${nonce}'`,
      "connect-src 'self'",
      "base-uri 'none'",
      "form-action 'none'",
    ].join('; '),
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

/**
 * The storefront page.
 *
 * Server-rendered, with one progressive enhancement: the live view polls
 * `/api/instance` from the browser and tallies which instance answered. That
 * turns three claims the architecture makes into something an audience can
 * watch happen rather than three bullet points on a slide -- the load
 * balancer spreading requests, the fleet spanning availability zones, and the
 * recovery window from docs/incident-reports/2026-08-31-failover-502-window.md
 * appearing on screen when an instance is killed.
 *
 * The markup and the inline assets here are kept terse on purpose. The whole
 * application ships gzipped into EC2 user data, which is capped at 16384
 * bytes, and this page is the largest single thing in the file. See
 * ARCHITECTURE.md.
 *
 * The `nonce` is minted per response. The page's Content-Security-Policy
 * admits exactly this one script tag, so an injected `<script>` still cannot
 * run -- which is why this takes a nonce instead of relaxing the policy to
 * `script-src 'unsafe-inline'`.
 */
function renderStorefront(nonce) {
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
    h2 { font-size: 0.95rem; margin: 0 0 0.2rem; }
    .sub { opacity: 0.7; margin: 0 0 2rem; font-size: 0.95rem; }
    .cards { display: grid; gap: 0.75rem; grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
             margin-bottom: 2rem; }
    .card { border: 1px solid rgba(128,128,128,0.35); border-radius: 0.5rem; padding: 0.85rem 1rem; }
    .label { font-size: 0.7rem; letter-spacing: 0.06em; text-transform: uppercase; opacity: 0.65; }
    .value { font-size: 1.05rem; font-weight: 600; font-variant-numeric: tabular-nums;
             word-break: break-all; margin-top: 0.15rem; }
    .ok { color: #15803d; }
    .bad { color: #b91c1c; }
    table { width: 100%; border-collapse: collapse; font-size: 0.95rem; }
    th, td { text-align: left; padding: 0.55rem 0.6rem; border-bottom: 1px solid rgba(128,128,128,0.25); }
    th { font-size: 0.72rem; letter-spacing: 0.06em; text-transform: uppercase; opacity: 0.65; }
    td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
    .empty { opacity: 0.6; font-style: italic; }
    footer { margin-top: 2rem; font-size: 0.8rem; opacity: 0.6; }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .panel { border: 1px solid rgba(128,128,128,0.35); border-radius: 0.5rem;
             padding: 1rem 1.15rem 1.15rem; margin-bottom: 2rem; }
    .hint { font-size: 0.85rem; opacity: 0.7; margin: 0 0 1rem; }
    .btn { font: inherit; font-size: 0.875rem; font-weight: 600; cursor: pointer;
           padding: 0.4rem 0.95rem; margin-right: 0.5rem; border-radius: 0.375rem;
           border: 1px solid rgba(128,128,128,0.45); background: transparent; color: inherit; }
    .btn.go { background: #2563eb; border-color: #2563eb; color: #fff; }
    .btn.on { background: #b91c1c; border-color: #b91c1c; color: #fff; }
    .panel .cards { margin: 1rem 0 0; }
    .bars { display: grid; grid-template-columns: minmax(8rem, auto) 1fr minmax(5rem, auto);
            gap: 0.55rem 0.8rem; align-items: center; margin-top: 1rem; }
    .bn { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.8rem; }
    .bz { font-size: 0.7rem; opacity: 0.6; font-family: inherit; }
    .bt { background: rgba(128,128,128,0.18); border-radius: 999px; height: 0.7rem; overflow: hidden; }
    .bf { height: 100%; border-radius: 999px; width: 0; transition: width 0.18s linear; }
    .bc { font-size: 0.8rem; font-variant-numeric: tabular-nums; text-align: right; opacity: 0.85; }
    .stale { opacity: 0.35; }
    .gone { display: block; font-size: 0.68rem; font-weight: 600; color: #b91c1c;
            font-family: ui-sans-serif, system-ui, sans-serif; }
    .note { font-size: 0.8rem; opacity: 0.7; margin: 1rem 0 0; min-height: 1.2em; }
  </style>
</head>
<body>
<main>
  <h1>ce-capstone storefront</h1>
  <p class="sub">This page was rendered by the instance named below. The live view
     underneath keeps asking, and shows you who answers.</p>

  <div class="cards">
    <div class="card"><div class="label">Served by</div><div class="value">${escapeHtml(state.instanceId)}</div></div>
    <div class="card"><div class="label">Availability zone</div><div class="value">${escapeHtml(state.availabilityZone)}</div></div>
    <div class="card"><div class="label">Instance type</div><div class="value">${escapeHtml(state.instanceType)}</div></div>
    <div class="card"><div class="label">Health</div><div class="value ok">healthy</div></div>
    <div class="card"><div class="label">Environment</div><div class="value">${escapeHtml(ENVIRONMENT)}</div></div>
    <div class="card"><div class="label">Uptime</div><div class="value">${Math.round((Date.now() - STARTED_AT) / 1000)}s</div></div>
  </div>

  <section class="panel">
    <h2>Load balancer live view</h2>
    <p class="hint">Calls <code>/api/instance</code> three times a second and tallies who
       answered. Leave it running and kill an instance with
       <code>scripts/demo-failover.sh dev</code> to watch the platform heal itself.</p>

    <button id="go" class="btn go" type="button">Start</button>
    <button id="rs" class="btn" type="button">Reset</button>

    <div class="cards">
      <div class="card"><div class="label">Requests</div><div class="value" id="mt">0</div></div>
      <div class="card"><div class="label">Instances</div><div class="value" id="mi">0</div></div>
      <div class="card"><div class="label">Zones</div><div class="value" id="mz">0</div></div>
      <div class="card"><div class="label">Failed</div><div class="value" id="me">0</div></div>
    </div>

    <div class="bars" id="bars"></div>
    <p class="note" id="note">Idle &mdash; press Start.</p>
  </section>

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

<script nonce="${nonce}">
(function () {
  'use strict';
  var MS = 300, STALE = 6000;
  var COLORS = ['#2563eb', '#16a34a', '#d97706', '#9333ea', '#0891b2', '#db2777'];
  var $ = function (id) { return document.getElementById(id); };
  var go = $('go'), bars = $('bars'), note = $('note');
  var on = false, timer = null, busy = false, total = 0, fails = 0;
  var seen = new Map(), rows = new Map();

  // Instance ids and zone names come from the API, so they are written with
  // textContent and never parsed as markup.
  function row(id, e) {
    var n = document.createElement('div');
    n.className = 'bn';
    n.textContent = id;
    var z = document.createElement('span');
    z.className = 'bz';
    z.textContent = ' ' + e.az;
    var g = document.createElement('span');
    g.className = 'gone';
    n.appendChild(z);
    n.appendChild(g);

    var t = document.createElement('div');
    t.className = 'bt';
    var f = document.createElement('div');
    f.className = 'bf';
    f.style.background = e.color;
    t.appendChild(f);

    var c = document.createElement('div');
    c.className = 'bc';

    bars.appendChild(n);
    bars.appendChild(t);
    bars.appendChild(c);
    return { n: n, g: g, t: t, f: f, c: c };
  }

  function draw() {
    var now = Date.now(), zones = {}, nz = 0, max = 1;
    seen.forEach(function (e) {
      if (!zones[e.az]) { zones[e.az] = 1; nz++; }
      if (e.n > max) max = e.n;
    });

    seen.forEach(function (e, id) {
      var r = rows.get(id) || rows.set(id, row(id, e)).get(id);
      r.f.style.width = Math.round((e.n / max) * 100) + '%';
      r.c.textContent = e.n + ' (' + Math.round((e.n / total) * 100) + '%)';
      var stale = on && now - e.seen > STALE;
      r.g.textContent = stale ? 'no longer answering' : '';
      r.n.classList.toggle('stale', stale);
      r.t.classList.toggle('stale', stale);
      r.c.classList.toggle('stale', stale);
    });

    $('mt').textContent = total;
    $('mi').textContent = seen.size;
    $('mz').textContent = nz;
    $('me').textContent = fails;
    $('me').classList.toggle('bad', fails > 0);
  }

  function say(msg, bad) {
    note.textContent = msg || (on ? 'Polling every ' + MS + 'ms.' : 'Stopped after ' + total + ' requests.');
    note.classList.toggle('bad', Boolean(msg && bad));
  }

  // One request in flight at a time. Without that, a stalled request during a
  // failover queues hundreds of retries behind it and the failure count ends
  // up describing the browser rather than the platform.
  function tick() {
    if (!on || busy) return;
    busy = true;
    fetch('/api/instance', { cache: 'no-store' })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (d) {
        var id = d.instanceId || 'unknown', e = seen.get(id);
        if (!e) {
          e = { n: 0, az: d.availabilityZone || '-', color: COLORS[seen.size % COLORS.length], seen: 0 };
          seen.set(id, e);
        }
        e.n++;
        e.seen = Date.now();
        total++;
        say('');
      })
      // These are the requests worth watching: during an ungraceful failure the
      // load balancer keeps sending traffic to a target it has not yet marked
      // unhealthy, and this counts that window.
      .catch(function (err) { total++; fails++; say('Request failed: ' + err.message, true); })
      .then(function () { busy = false; draw(); });
  }

  go.addEventListener('click', function () {
    on = !on;
    go.textContent = on ? 'Stop' : 'Start';
    go.classList.toggle('on', on);
    go.classList.toggle('go', !on);
    if (on) { timer = setInterval(tick, MS); tick(); }
    else { clearInterval(timer); timer = null; }
    say('');
    draw();
  });

  $('rs').addEventListener('click', function () {
    total = fails = 0;
    seen.clear();
    rows.clear();
    bars.textContent = '';
    say('');
    draw();
  });

  // A forgotten tab should not sit generating requests and log volume all day.
  document.addEventListener('visibilitychange', function () {
    if (document.hidden && on) go.click();
  });

  draw();
})();
</script>
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
    case '/': {
      // 128 bits of randomness per response. A nonce that repeated across
      // responses would be one an attacker could learn and reuse.
      const nonce = crypto.randomBytes(16).toString('base64');
      return sendHtml(res, 200, renderStorefront(nonce), nonce);
    }
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
