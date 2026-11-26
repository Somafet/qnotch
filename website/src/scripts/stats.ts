/* Site analytics: PostHog, EU Cloud, through qnot.ch/qn (website/edge/worker.js). spec/website-analytics.md
   describes what is sent and when; lib/stats.ts lists every event and value.

   Nothing loads on other hosts (dev, preview), or when the browser sends Do Not Track or Global Privacy
   Control. Otherwise posthog-js loads after the page has finished loading. Until the visitor accepts the
   cookie, it counts without cookies or storage (cookieless_mode 'on_reject' with opt-out by default): PostHog
   recognizes a visitor for one day from a hash of IP and browser, then drops the IP. Accepting turns on its
   first-party cookie; declining keeps counting cookieless. ConsentBanner.astro asks. */

import { currentOS } from './platform';
import { PAGE_KINDS, PLACEMENTS, type StatsEvent, type StatsEvents } from '../lib/stats';

const KEY = 'phc_yAB7esHozLZxDgr9XUpoH38bgtu6CK6YcnCkk4nkThAd';
// The host the site counts on. A local build can set PUBLIC_STATS_HOST=localhost to try the whole path.
const HOST = import.meta.env.PUBLIC_STATS_HOST || 'qnot.ch';
const PATH = '/qn';

type PostHog = typeof import('posthog-js/dist/module.slim.no-external.js').default;

export type Consent = 'granted' | 'denied' | 'pending';

const browserSaysNo = () =>
  navigator.doNotTrack === '1' || (window as { doNotTrack?: string }).doNotTrack === '1' ||
  (navigator as { globalPrivacyControl?: boolean }).globalPrivacyControl === true;

/** Whether this page counts visits at all. */
export const statsOn = () => location.hostname === HOST && !browserSaysNo();

function pageKind(): (typeof PAGE_KINDS)[number] {
  const p = location.pathname.replace(/\/index\.html$/, '/').replace(/\/?$/, '/');
  if (p === '/') return 'home';
  if (p === '/windows/') return 'windows';
  if (p === '/mac/') return 'mac';
  if (p === '/guides/') return 'guides';
  if (p.startsWith('/guides/')) return 'guide';
  if (p === '/developers/') return 'developers';
  if (p === '/privacy/') return 'privacy';
  return 'not_found';
}

let ph: PostHog | undefined;
let loading = false;
const queue: (() => void)[] = [];
const ready: ((ph: PostHog) => void)[] = [];

/** Runs fn once posthog-js has loaded, or never on a page that doesn't count. */
function withPostHog(fn: (ph: PostHog) => void) {
  if (!statsOn()) return;
  if (ph) fn(ph);
  else if (queue.length < 50) queue.push(() => fn(ph!));
}

export function track<E extends StatsEvent>(event: E, props: StatsEvents[E], leaving = false) {
  // A click that leaves the page sends with sendBeacon, which survives the navigation.
  withPostHog(p => p.capture(event, props, leaving ? { transport: 'sendBeacon' } : undefined));
}

export function onStatsReady(fn: (ph: PostHog) => void) {
  if (!statsOn()) return;
  if (ph) fn(ph);
  else ready.push(fn);
}

export const consentStatus = (): Consent => (ph ? ph.get_explicit_consent_status() : 'pending');

export function setConsent(choice: 'accept' | 'decline') {
  withPostHog(p => {
    const before = p.get_explicit_consent_status();
    if (choice === 'accept') p.opt_in_capturing({ captureEventName: null });
    else p.opt_out_capturing();
    if (before !== (choice === 'accept' ? 'granted' : 'denied')) p.capture('consent_answered', { choice });
  });
}

async function load() {
  const { default: posthog } = await import('posthog-js/dist/module.slim.no-external.js');
  posthog.init(KEY, {
    api_host: location.origin + PATH,
    ui_host: 'https://eu.posthog.com',
    cookieless_mode: 'on_reject',
    // Until the visitor answers, count them the way a decline does: cookieless.
    opt_out_capturing_by_default: true,
    person_profiles: 'identified_only',
    cross_subdomain_cookie: false,
    capture_pageview: true,
    capture_pageleave: true,
    autocapture: false,
    rageclick: false,
    capture_dead_clicks: false,
    capture_heatmaps: false,
    capture_exceptions: false,
    capture_performance: false,
    disable_session_recording: true,
    disable_surveys: true,
    disable_conversations: true,
    disable_product_tours: true,
    disable_web_experiments: true,
    advanced_disable_flags: true,
    disable_external_dependency_loading: true,
    // Bots are dropped on qnot.ch; a local trial build runs in whatever browser drives it.
    opt_out_useragent_filter: HOST !== 'qnot.ch',
    before_send: event => {
      if (event) Object.assign(event.properties, {
        site_os: currentOS(),
        page_kind: pageKind(),
        is_phone: document.documentElement.hasAttribute('data-phone'),
      });
      return event;
    },
    loaded: () => {
      ph = posthog;
      queue.splice(0).forEach(fn => fn());
      ready.splice(0).forEach(fn => fn(posthog));
    },
  });
}

// Download and outbound links are told apart by where they point; the closest [data-placement] says which
// button it was. The Store, the ZIP and the disk image are downloads; GitHub pages are outbound.
const REPO = 'https://github.com/Somafet/qnotch';
function linkClick(e: MouseEvent) {
  const a = (e.target as Element | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
  if (!a || a.hasAttribute('data-install-open')) return;
  const raw = a.closest<HTMLElement>('[data-placement]')?.dataset.placement;
  const placement = PLACEMENTS.find(p => p === raw);
  const url = new URL(a.href, location.href);
  if (url.hostname === 'apps.microsoft.com') return track('download_clicked', { platform: 'windows', channel: 'store', placement: placement ?? 'other' }, true);
  if (url.hostname !== 'github.com') return;
  if (url.pathname.endsWith('.zip')) return track('download_clicked', { platform: 'windows', channel: 'zip', placement: placement ?? 'other' });
  if (url.pathname.endsWith('.dmg')) return track('download_clicked', { platform: 'mac', channel: 'dmg', placement: placement ?? 'other' });
  if (url.pathname.startsWith('/sponsors/')) return track('outbound_clicked', { target: 'sponsor', placement }, true);
  if (!a.href.startsWith(REPO)) return;
  const rest = url.pathname.slice('/Somafet/qnotch'.length);
  const target = rest.startsWith('/issues') ? 'issues' : rest.startsWith('/releases') ? 'releases' : rest.startsWith('/blob/') ? 'docs' : 'github';
  track('outbound_clicked', { target, placement }, true);
}

/** Called once per page, from ConsentBanner.astro. */
export function startStats() {
  if (!statsOn() || loading) return;
  loading = true;
  document.addEventListener('click', linkClick, { capture: true });
  const later = () => ('requestIdleCallback' in window ? requestIdleCallback(() => void load(), { timeout: 3000 }) : setTimeout(() => void load(), 1000));
  if (document.readyState === 'complete') later();
  else addEventListener('load', later, { once: true });
}
