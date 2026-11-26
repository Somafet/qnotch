// The site's analytics events: every name and every value they can carry. spec/website-analytics.md is the
// contract; scripts/stats.ts sends only what this file allows, and tests/repository/website-stats.test.mjs
// checks the two against each other. No free text: a value that isn't listed here is never sent.

/** Where a button sits. Also the Microsoft Store campaign id (cid) of that button's Store link. */
export const PLACEMENTS = ['header', 'hero', 'final', 'guide', 'install', 'other'] as const;
export type Placement = (typeof PLACEMENTS)[number];

export const SCENARIOS = ['open', 'agent', 'notify', 'files', 'clipboard', 'search', 'game'] as const;
export const INSTALL_CHANNELS = ['download', 'winget', 'scoop', 'chocolatey'] as const;
export const OUTBOUND_TARGETS = ['github', 'releases', 'issues', 'sponsor', 'docs'] as const;
export const PAGE_KINDS = ['home', 'windows', 'mac', 'guides', 'guide', 'developers', 'privacy', 'not_found'] as const;

export interface StatsEvents {
  download_clicked: { platform: 'windows' | 'mac'; channel: 'store' | 'zip' | 'dmg'; placement: Placement };
  install_dialog_opened: { placement: Placement };
  install_channel_viewed: { channel: (typeof INSTALL_CHANNELS)[number] };
  install_command_copied: { channel: Exclude<(typeof INSTALL_CHANNELS)[number], 'download'> };
  os_switched: { to: 'win' | 'mac'; method: 'switch' | 'link' | 'page' };
  demo_interacted: { first_control: 'pill' | 'scenario' | 'desktop' };
  demo_scenario_played: { scenario: (typeof SCENARIOS)[number] };
  send_link_used: { method: 'share' | 'copy' | 'mailto' };
  outbound_clicked: { target: (typeof OUTBOUND_TARGETS)[number]; placement?: Placement };
  faq_opened: { question: string };
  consent_answered: { choice: 'accept' | 'decline' };
}
export type StatsEvent = keyof StatsEvents;

/** The Store link for one button: the cid shows up as a campaign in Partner Center's acquisition reports. */
export const storeCampaign = (store: string, placement: Placement) => `${store}?cid=qnotch-site-${placement}`;

/** A FAQ question's id: its words, lowercased and joined with dashes. Built from the page's own fixed list. */
export const faqId = (question: string) =>
  question.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60);
