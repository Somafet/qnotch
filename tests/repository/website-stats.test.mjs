// The website's analytics: the relay Worker forwards only event POSTs, and the site sends only events the
// catalog (website/src/lib/stats.ts) and the spec (spec/website-analytics.md) list.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { proxy } from '../../website/edge/worker.js';

const root = new URL('../../', import.meta.url);
const read = path => readFileSync(new URL(path, root), 'utf8');

function sources(dir) {
  return readdirSync(dir).flatMap(name => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? sources(path) : /\.(astro|ts)$/.test(name) ? [path] : [];
  });
}
const site = sources(new URL('website/src', root).pathname.replace(/^\/([A-Za-z]:)/, '$1'))
  .map(path => ({ path, text: readFileSync(path, 'utf8') }));

const catalog = read('website/src/lib/stats.ts');
const events = [...catalog.match(/interface StatsEvents \{([\s\S]*?)\n\}/)[1].matchAll(/^\s+(\w+): \{/gm)].map(m => m[1]);
const list = name => [...catalog.match(new RegExp(`${name} = \\[([^\\]]*)\\]`))[1].matchAll(/'(\w+)'/g)].map(m => m[1]);

function relay(path, init = {}) {
  const calls = [];
  const send = async (url, options) => {
    calls.push({ url, options });
    return new Response('{"status":"Ok"}', { status: 200 });
  };
  const response = proxy(new Request(`https://qnot.ch${path}`, init), { upstream: 'https://upstream.test', send });
  return response.then(r => ({ response: r, calls }));
}

test('relay forwards an event POST to PostHog without the prefix, with the visitor IP and no cookie', async () => {
  const body = new Uint8Array([31, 139, 8, 0, 1, 2, 3]);
  const { response, calls } = await relay('/qn/e/?compression=gzip-js&ver=1.447.12', {
    method: 'POST',
    body,
    headers: {
      'content-type': 'text/plain',
      'user-agent': 'Mozilla/5.0',
      cookie: 'ph_phc_x_posthog=secret',
      authorization: 'Basic abc',
      'cf-connecting-ip': '203.0.113.7',
    },
  });
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  const [{ url, options }] = calls;
  assert.equal(url, 'https://upstream.test/e/?compression=gzip-js&ver=1.447.12');
  assert.equal(options.method, 'POST');
  assert.equal(options.redirect, 'manual');
  assert.equal(options.headers.get('x-forwarded-for'), '203.0.113.7');
  assert.equal(options.headers.get('user-agent'), 'Mozilla/5.0');
  assert.equal(options.headers.get('content-type'), 'text/plain');
  assert.equal(options.headers.get('cookie'), null);
  assert.equal(options.headers.get('authorization'), null);
  assert.deepEqual(new Uint8Array(options.body), body);
});

test('relay forwards only the capture paths, and only POST', async () => {
  for (const path of ['/qn/i/v0/e/', '/qn/batch/', '/qn/capture/']) {
    const { response, calls } = await relay(path, { method: 'POST', body: '{}' });
    assert.equal(response.status, 200, path);
    assert.equal(calls.length, 1, path);
  }
  for (const path of ['/qn/', '/qn/flags/?v=2', '/qn/decide/', '/qn/array/phc_x/config.js', '/qn/static/array.js',
    '/qn/api/projects/', '/qn/e', '/qn/e/../flags/', '/e/', '/qnx/e/']) {
    const { response, calls } = await relay(path, { method: 'POST', body: '{}' });
    assert.equal(response.status, 404, path);
    assert.equal(calls.length, 0, path);
  }
  for (const method of ['GET', 'PUT', 'DELETE']) {
    const { response, calls } = await relay('/qn/e/', { method });
    assert.equal(response.status, 405, method);
    assert.equal(calls.length, 0, method);
  }
});

test('every event the site sends is in the catalog and the spec, and every cataloged event is sent', () => {
  const spec = read('spec/website-analytics.md');
  const sent = new Set();
  for (const { path, text } of site) {
    for (const m of text.matchAll(/\btrack\(\s*'(\w+)'/g)) {
      assert.ok(events.includes(m[1]), `${path} sends ${m[1]}, which website/src/lib/stats.ts doesn't list`);
      sent.add(m[1]);
    }
  }
  sent.add('consent_answered'); // stats.ts captures it directly, after the consent change
  for (const event of events) {
    assert.ok(sent.has(event), `${event} is cataloged but never sent`);
    assert.match(spec, new RegExp('`' + event + '`'), `spec/website-analytics.md doesn't describe ${event}`);
  }
});

test('the demo scenarios the catalog allows are the demo chips', () => {
  const chips = read('website/src/components/Demo.astro').match(/const chips = \[([\s\S]*?)\] as const;/)[1];
  const ids = [...chips.matchAll(/id: '(\w+)'/g)].map(m => m[1]);
  assert.deepEqual([...list('SCENARIOS')].sort(), [...ids].sort());
});

test('every Microsoft Store button carries a campaign id', () => {
  for (const { path, text } of site) {
    if (path.endsWith('releases.ts')) continue;
    for (const m of text.matchAll(/href=\{STORE\}|href: STORE\b|store=\{STORE\}/g)) {
      assert.fail(`${path}: Store link without storeCampaign(): ${m[0]}`);
    }
  }
});
