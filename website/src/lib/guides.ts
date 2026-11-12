// The guides under /guides/: one entry per page in src/pages/guides/. The index, the footer, each guide's
// "More guides" list and llms.txt are built from this list, so add a guide here and as a page with the same slug.

export interface GuideInfo {
  slug: string;
  /** The page's <h1> and its link text on the index. */
  title: string;
  /** Meta description, and the summary on the index. */
  description: string;
  /** Short link text for the footer. */
  short: string;
  /** ISO date of the last change to the guide's claims. */
  updated: string;
}

export const guides: GuideInfo[] = [
  {
    slug: 'claude-code-waiting',
    title: 'See when Claude Code or Codex is waiting for you',
    description: 'Stop finding terminals that sat on a yes/no question for 20 minutes. QNotch shows every Claude Code and Codex session at the top of your screen and tells you when one needs an answer.',
    short: 'See when an agent is waiting',
    updated: '2026-11-11',
  },
  {
    slug: 'script-notifications',
    title: 'Send a desktop notification from a script, and wait for the answer',
    description: 'Post a notification from a build script, hook or scheduled job with one command, add buttons and read back which one was clicked. Works on Windows and Mac with QNotch.',
    short: 'Notify from a script',
    updated: '2026-11-11',
  },
  {
    slug: 'clipboard-history',
    title: 'Clipboard history at the top of your screen, on Windows and Mac',
    description: 'Keep the last 40 things you copied one hover away: text, code, links and images, with pins and search. How QNotch clipboard history works and what it keeps.',
    short: 'Clipboard history',
    updated: '2026-11-11',
  },
  {
    slug: 'stats-while-gaming',
    title: 'Show CPU, GPU and RAM while you game on Windows',
    description: 'A one-line status bar at the top of the screen with CPU, GPU, temperature and RAM that lets clicks pass straight through. How QNotch Game mode works.',
    short: 'Stats while gaming',
    updated: '2026-11-11',
  },
  {
    slug: 'mac-notch-apps',
    title: 'Mac notch apps compared: QNotch, NotchNook, Boring Notch and Alcove',
    description: 'What each MacBook notch app is good at, which are free or open source, and when QNotch is the right pick and when it is not.',
    short: 'Mac notch apps compared',
    updated: '2026-11-11',
  },
];

export const guideUrl = (slug: string) => `/guides/${slug}/`;
