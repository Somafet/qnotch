# qnot.ch analytics relay

A Cloudflare Worker on `qnot.ch/qn/*`. The site's analytics script (`src/scripts/stats.ts`) sends PostHog events to `https://qnot.ch/qn/e/`. The Worker forwards `POST`s to PostHog's capture paths at `eu.i.posthog.com`, removes the `/qn` prefix, and passes on the visitor's IP from `CF-Connecting-IP`, which PostHog's cookieless count and country lookup need. It forwards a short list of headers and no cookies. Anything else gets a 404, so it is not an open proxy. [The website analytics spec](../../spec/website-analytics.md) describes what the site sends.

The Worker runs on Cloudflare's network in front of the site, so the server that hosts the site needs no change. It fits easily in the Workers Free plan's 100,000 requests a day. Set the route to **fail open**: if that limit is ever reached, the site keeps working and events are lost until midnight UTC.

## Deploy

Deploy the Worker before a site build that loads analytics, or those events have nowhere to go:

```bash
cd website/edge
npx wrangler deploy        # needs CLOUDFLARE_ACCOUNT_ID and a Cloudflare login or API token
```

Then turn on **Enable cookieless tracking** in the PostHog project's Web analytics settings. Without it, PostHog discards the events of visitors who haven't accepted the cookie.

## Check

```bash
curl -i https://qnot.ch/qn/anything      # 404 from the Worker
curl -i https://qnot.ch/qn/e/            # 405: only POST is forwarded
```

On the site, the browser's Network tab shows `POST /qn/e/` returning `200`.

`tests/repository/website-stats.test.mjs` runs the Worker against a fake upstream.
