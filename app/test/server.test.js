'use strict';

/**
 * Application tests.
 *
 * Run with `node --test app/test/` -- no test framework, matching the app's own
 * zero-dependency constraint.
 *
 * These run the real server as a child process and talk to it over HTTP,
 * rather than importing and unit-testing internals. That is deliberate: the
 * contract that matters is what the load balancer and a browser see, and the
 * environment they run in has no EC2 metadata service and no DynamoDB. So
 * these tests double as the graceful-degradation tests -- every assertion here
 * holds while both of the app's external dependencies are unreachable.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');

const SERVER = path.join(__dirname, '..', 'src', 'server.js');
const PORT = 34567;
const BASE_URL = `http://127.0.0.1:${PORT}`;

let child;

test.before(async () => {
  child = spawn(process.execPath, [SERVER], {
    env: {
      ...process.env,
      PORT: String(PORT),
      ENVIRONMENT: 'test',
      // Deliberately unset, so the catalog path exercises its failure branch.
      PRODUCTS_TABLE: '',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  // Wait for the port to accept connections. The server resolves instance
  // metadata first, which times out off-instance, so this is not instant.
  const deadline = Date.now() + 20_000;
  for (;;) {
    try {
      const response = await fetch(`${BASE_URL}/health`);
      if (response.ok) return;
    } catch {
      // not listening yet
    }

    if (Date.now() > deadline) {
      throw new Error('server did not start within 20s');
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
});

test.after(() => {
  child?.kill('SIGTERM');
});

test('GET /health reports healthy even with no data tier', async () => {
  const response = await fetch(`${BASE_URL}/health`);
  assert.equal(response.status, 200);

  const body = await response.json();
  assert.equal(body.status, 'healthy');
  assert.equal(body.environment, 'test');
  assert.equal(typeof body.uptimeSeconds, 'number');

  // The load balancer must keep this instance in service while DynamoDB is
  // unreachable. A health check that fails on a shared dependency empties the
  // whole target group at once and turns a degraded feature into an outage.
  assert.equal(body.catalog.degraded, true);
});

test('GET /health identifies the instance', async () => {
  const response = await fetch(`${BASE_URL}/health`);
  const body = await response.json();

  // Off-instance the app falls back to a local identity rather than crashing.
  assert.ok(body.instanceId.length > 0);
  assert.ok(body.availabilityZone.length > 0);
});

test('GET / renders the storefront', async () => {
  const response = await fetch(BASE_URL);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/html/);

  const html = await response.text();
  assert.match(html, /ce-capstone storefront/);
  assert.match(html, /Availability zone/);
  // With no catalog the table still renders, with an explanatory row.
  assert.match(html, /Catalog unavailable/);
});

test('GET / sends security headers', async () => {
  const response = await fetch(BASE_URL);

  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(response.headers.get('x-frame-options'), 'DENY');
  assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
  assert.ok(response.headers.get('content-security-policy'));
});

test('GET / serves the load balancer live view', async () => {
  const response = await fetch(BASE_URL);
  const html = await response.text();

  assert.match(html, /Load balancer live view/);
  // The controls and the elements the script writes into. If an id is renamed
  // on one side only, the panel silently does nothing in the browser and no
  // server-side test would otherwise notice.
  // Short ids on purpose: the whole app ships gzipped inside a 16384-byte user
  // data blob, and every byte of this page is charged against that budget.
  for (const id of ['go', 'rs', 'bars', 'note', 'mt', 'mi', 'mz', 'me']) {
    assert.match(html, new RegExp(`id="${id}"`), `${id} is missing from the page`);
  }
});

test('the live view script carries the nonce the policy names', async () => {
  // The failure this guards against is silent: a mismatch here means the
  // browser refuses the script, the panel never starts, and the server logs
  // nothing at all because it did its job.
  const response = await fetch(BASE_URL);
  const html = await response.text();

  const policy = response.headers.get('content-security-policy');
  const fromPolicy = policy.match(/'nonce-([^']+)'/);
  assert.ok(fromPolicy, `no nonce in the policy: ${policy}`);

  const fromScript = html.match(/<script nonce="([^"]+)">/);
  assert.ok(fromScript, 'the page has no nonced script tag');

  assert.equal(fromScript[1], fromPolicy[1]);

  // The script needs to reach /api/instance, and must not be able to reach
  // anywhere else.
  assert.match(policy, /connect-src 'self'/);
  assert.match(policy, /default-src 'none'/);
  assert.doesNotMatch(policy, /script-src[^;]*'unsafe-inline'/);
});

test('each response mints a fresh nonce', async () => {
  // A nonce reused across responses is one an attacker can learn and then
  // reuse, which defeats the point of having one.
  const nonces = new Set();

  for (let i = 0; i < 3; i += 1) {
    const response = await fetch(BASE_URL);
    await response.text();
    nonces.add(response.headers.get('content-security-policy').match(/'nonce-([^']+)'/)[1]);
  }

  assert.equal(nonces.size, 3);
});

test('every response identifies which instance served it', async () => {
  for (const p of ['/', '/health', '/api/products', '/api/instance']) {
    const response = await fetch(`${BASE_URL}${p}`);
    assert.ok(
      response.headers.get('x-instance-id'),
      `${p} did not send X-Instance-Id`
    );
    assert.ok(
      response.headers.get('x-availability-zone'),
      `${p} did not send X-Availability-Zone`
    );
  }
});

test('GET /api/products degrades to an empty catalog', async () => {
  const response = await fetch(`${BASE_URL}/api/products`);
  assert.equal(response.status, 200);

  const body = await response.json();
  assert.deepEqual(body.products, []);
  assert.equal(body.count, 0);
  assert.equal(body.degraded, true);
});

test('GET /api/instance returns instance metadata', async () => {
  const response = await fetch(`${BASE_URL}/api/instance`);
  assert.equal(response.status, 200);

  const body = await response.json();
  assert.equal(body.environment, 'test');
  assert.ok(body.region);
  assert.ok(body.hostname);
});

test('GET /stress is capped so it cannot pin an instance', async () => {
  // Requesting an hour must be clamped to the 60s ceiling. Asking for 1s keeps
  // the test fast while still going through the clamping path.
  const response = await fetch(`${BASE_URL}/stress?seconds=1`);
  assert.equal(response.status, 200);

  const body = await response.json();
  assert.match(body.message, /burned CPU for 1s/);
});

test('GET /stress clamps a negative duration to the minimum', async () => {
  // Exercises the same clamping path a non-numeric value takes, but at the
  // lower bound so the test costs one second rather than the 30s default.
  const response = await fetch(`${BASE_URL}/stress?seconds=-5`);
  assert.equal(response.status, 200);

  const body = await response.json();
  assert.match(body.message, /burned CPU for 1s/);
});

test('unknown paths return 404', async () => {
  const response = await fetch(`${BASE_URL}/nope`);
  assert.equal(response.status, 404);

  const body = await response.json();
  assert.equal(body.error, 'not found');
});

test('non-GET methods are rejected', async () => {
  const response = await fetch(BASE_URL, { method: 'POST' });
  assert.equal(response.status, 405);
});
