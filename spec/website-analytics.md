# Website analytics

qnot.ch counts visits and a fixed set of clicks with PostHog, in the same EU Cloud project as the apps' [usage events](analytics.md). This page is the contract. The event list in code is [`website/src/lib/stats.ts`](../website/src/lib/stats.ts), `website/src/scripts/stats.ts` sends events, and [`tests/repository/website-stats.test.mjs`](../tests/repository/website-stats.test.mjs) keeps the code and this page in line. The [privacy policy](../website/src/pages/privacy.astro) describes the same thing for visitors; change it in the same PR as anything here, and move its date.

This is website-only. The apps' events are unchanged.

## Delivery

- **Library:** `posthog-js`, version pinned in `website/package.json`, bundled into the site from its `dist/module.slim.no-external.js` build. That build has no autocapture, feature flags, replay or surveys, and loads no other scripts. It loads after the page's `load` event, when the browser is idle. Events sent before that wait in a short in-memory queue (50).
- **Relay:** requests go to `https://qnot.ch/qn/e/`. A Cloudflare Worker on `qnot.ch/qn/*` ([website/edge](../website/edge/README.md)) forwards POSTs to PostHog's capture paths at `eu.i.posthog.com` with the visitor's IP. It forwards no cookies and answers 404 to anything else.
- **Where it runs:** only on `qnot.ch`. A build sets `PUBLIC_STATS_HOST` to try it on another host, for example `localhost`; only such a trial build turns off PostHog's bot filter.
- **Not counted at all:** browsers that send Do Not Track or Global Privacy Control. posthog-js never loads there and no banner appears.

## Consent

`cookieless_mode: 'on_reject'` with `opt_out_capturing_by_default: true`:

| Visitor | Counted | Stored on the device |
| --- | --- | --- |
| Hasn't answered | Cookieless: PostHog recognizes the visitor for one day from a salted hash of IP and browser. No country | Nothing |
| Chose **No thanks** | Cookieless, as above | PostHog's consent record (`__ph_opt_in_out_<token>` in local storage) |
| Chose **Accept** | With PostHog's first-party cookie `ph_<token>_posthog` and its local storage copy, for 365 days, not shared with subdomains. Country from the IP | The cookie, its local storage copy and the consent record |

The project setting **Discard client IP data** stays on, so no event stores an IP. The project's **cookieless tracking** setting must be on, or PostHog drops the cookieless events.

### Banner

`ConsentBanner.astro`, in `Base.astro`, so it is on every page. It appears once posthog-js has loaded and the visitor hasn't answered. It never appears where analytics doesn't run.

- Not modal: it doesn't block the page or take focus. Bottom left, 380 px wide; on screens up to 560 px, full width with 12 px margins.
- Title: **Can qnot.ch use a cookie?**
- Text: *It shows me which pages bring people to QNotch and where they come from. No ads, and nothing follows you to other sites. If you say no, your visit still counts, without a cookie.* followed by a **Privacy policy** link to `/privacy#site`.
- Two buttons of equal weight, in this order: **Accept**, **No thanks**. Either one hides the banner and records `consent_answered` once.
- **Cookie settings** (`[data-cookie-settings]`) opens the banner again. One is in the site footer's About column and one is in the privacy policy's "This website" section. Both are hidden where analytics doesn't run.

## Events

Each event, `$pageview` and `$pageleave` included, carries:

- `site_os`: `win` or `mac`, the version the page is showing
- `page_kind`: `home`, `windows`, `mac`, `guides`, `guide`, `developers`, `privacy` or `not_found`
- `is_phone`: boolean

posthog-js adds its standard properties: URL and path, referrer, `utm_*` campaign tags, browser, OS, device type, screen and viewport size, browser language and time zone, and scroll depth on `$pageleave`. No text a visitor types or copies is ever sent. Every value comes from the fixed lists below.

| Event | Properties | Sent when |
| --- | --- | --- |
| `$pageview`, `$pageleave` | standard | A page opens or closes |
| `download_clicked` | `platform` `windows`/`mac`; `channel` `store`/`zip`/`dmg`; `placement` | A link to the Microsoft Store listing, the Windows ZIP or the Mac disk image is clicked |
| `install_dialog_opened` | `placement` | **Other ways to install** opens |
| `install_channel_viewed` | `channel` `download`/`winget`/`scoop`/`chocolatey` | A different tab is chosen in that dialog |
| `install_command_copied` | `channel` `winget`/`scoop`/`chocolatey` | An install command is copied |
| `os_switched` | `to` `win`/`mac`; `method` `switch` (the Windows/Mac switch on `/`), `link` ("Also on Mac/Windows" on `/`), `page` (the switch on `/windows/` or `/mac/`, which opens the other page) | The page changes platform |
| `demo_interacted` | `first_control` `pill`/`scenario`/`desktop` | The first pointer press in the demo, or the first hover over its notch, once per page view |
| `demo_scenario_played` | `scenario` `open`/`agent`/`notify`/`files`/`clipboard`/`search`/`game` | A demo moment chip is clicked |
| `send_link_used` | `method` `share`/`copy`/`mailto` | The phone-only **Send the link to my computer** button hands the link on |
| `outbound_clicked` | `target` `github`/`releases`/`issues`/`docs` (a file in the repo)/`sponsor`; optional `placement` | A link to the QNotch repository or GitHub Sponsors is clicked |
| `faq_opened` | `question`: the question's own words, lowercased and joined with dashes | An FAQ answer is opened |
| `consent_answered` | `choice` `accept`/`decline` | The banner is answered with a different choice than before |

`placement` is where the clicked button sits: `header`, `hero`, `final` (the closing call to action), `guide` (a guide's Get QNotch box), `install` (the Other ways to install dialog) or `other`. It comes from the closest `[data-placement]`.

Clicks that leave the page (Store, GitHub, the mailto fallback, a switch to the other platform page) are sent with `sendBeacon`. A click made before posthog-js has loaded can be lost when the page unloads.

## Microsoft Store campaigns

Every link to the Store listing has `?cid=qnotch-site-<placement>` (`storeCampaign()` in `stats.ts`), so Partner Center's acquisition report shows which button a Store visit came from. The JSON-LD `installUrl` keeps the plain listing URL.

## Out of scope

No autocapture, heatmaps, dead-click or rage-click capture, session recording, surveys, feature flags, web vitals, exception capture or `identify`. The site creates no person profiles. Nothing links a website visitor to an app install.
