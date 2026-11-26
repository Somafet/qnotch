// qnot.ch/qn/*: passes the site's analytics events on to PostHog's EU Cloud, so they come from qnot.ch itself.
// It forwards only event POSTs and nothing else, so it can't be used as an open proxy. See README.md here and
// spec/website-analytics.md.

export const PREFIX = '/qn';
// posthog-js with flags and remote config off sends events to /e/; the others are the ingestion's capture paths.
const CAPTURE = ['/e/', '/i/v0/e/', '/batch/', '/capture/'];
const UPSTREAM = 'https://eu.i.posthog.com';

/** Handles one request. `send` is fetch, swapped out in tests. */
export async function proxy(request, { upstream = UPSTREAM, send = fetch } = {}) {
  const url = new URL(request.url);
  if (!url.pathname.startsWith(`${PREFIX}/`)) return new Response('Not found', { status: 404 });
  const path = url.pathname.slice(PREFIX.length);
  if (!CAPTURE.includes(path)) return new Response('Not found', { status: 404 });
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: { allow: 'POST, OPTIONS' } });
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: { allow: 'POST, OPTIONS' } });

  const headers = new Headers();
  for (const name of ['content-type', 'content-encoding', 'user-agent', 'accept-language', 'origin', 'referer']) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  // PostHog's cookieless count and the country come from the visitor's IP, which Cloudflare passes here.
  const ip = request.headers.get('cf-connecting-ip');
  if (ip) headers.set('x-forwarded-for', ip);

  return send(`${upstream}${path}${url.search}`, {
    method: 'POST',
    headers,
    body: await request.arrayBuffer(),
    redirect: 'manual',
  });
}

export default {
  fetch: request => proxy(request),
};
