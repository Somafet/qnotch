<!-- /founder:validate-idea · 2026-10-17 · input: A hosted sync between notches. this would make sense for me as I have a mac and windows PC, interaction between these computers through the notch would be good -->

# Validate idea: hosted sync between QNotch on Mac and Windows

Assumption: "Hosted" means a server you run that relays clipboard, files, notes, and notifications between QNotch installs, with accounts.
Assumption: The goal is a better QNotch, possibly with a paid tier, not a separate sync company.

Context from the repo: QNotch is free, MIT, and "no account required". The Mac port is a development milestone with no public download. The GitHub repo shows 3 stars and 14 release downloads (checked 2026-10-17). Setup codes already move preferences between Mac and Windows, and Windows already has a LAN phone-share server.

## The 30-second assessment

The pain is real but small: moving a snippet or a file between your own Mac and PC is mildly annoying, and free tools already fix it. "Hosted" is the wrong word. It adds accounts, server bills, and a liability (other people's clipboards on your server) to a product whose main promise is "local, free, no account". As a feature that makes QNotch the only notch app on both OSes, it is interesting. As a hosted business, it is a solution looking for a problem.

## The five fatal questions

**Q1: Who is the customer, and would they pay today?**
A developer or designer with a Mac laptop and a Windows desktop (often a gaming or GPU PC) on one desk, who already runs a notch or menu-bar utility. Today that person is you, plus near zero QNotch users, because there is no Mac release. Willingness to pay for sync alone is low: LocalSend, KDE Connect, CrossPaste, and Deskflow do it for free. Pushbullet charged $4.99/month or $39.99/year for universal clipboard in 2015, and it is not a growing business. Answer: maybe, so no.

**Q2: Why hasn't someone built this already?**
Many have. Sync is solved; notch-native sync across OSes is not.
- [LocalSend](https://localsend.org/): free, open source, Windows/macOS/Linux/mobile file transfer, LAN only, no account. Won because it is free and needs no server.
- [KDE Connect](https://apps.kde.org/kdeconnect): free, runs on macOS and Windows, shared clipboard and file sharing. Phone-first.
- [CrossPaste](https://alternativeto.net/software/cross-paste-clipboard-sync/) and [Clipp](https://apps.apple.com/us/app/clipp-net/id6773113533): free, LAN-first, encrypted clipboard sync with no cloud. Clipp says cross-network use needs a VPN.
- [Deskflow / Synergy](https://symless.com/synergy?lang=en): shared keyboard, mouse, and clipboard across Mac and Windows. Synergy is the paid layer on top of the free Deskflow.
- [Pushbullet](https://electronic.partners/news/pushbullet-introduces-a-pro-plan-will-soon-require-5-a-month-or-40-a-year-for-some-of-the-currently-free-features/): hosted, account-based, moved clipboard sync behind a paywall in 2015 and drew backlash.
- [1Clipboard](https://alternativeto.net/software/cross-paste-clipboard-sync/) was discontinued in 2023, per a directory listing.
- Notch apps are Mac-only: [NotchNook](https://www.macworld.com/article/2406934/notfhnook-macbook-dynamic-island-widgets-files-tray.html) ($25 one-time or $3/month) and [boring.notch](https://gittrend.io/repo/TheBoredTeam/boring.notch) (about 9k GitHub stars, free).

The pattern: the winners are free and LAN-first. Hosted relays become a cost center and a trust problem. What is new: QNotch is the only notch app with a Windows build and a native Mac port. That is the real gap, and it does not need a server.

**Q3: What's the distribution advantage?**
There is a built-in loop, which is the best part of this idea: every Windows user who owns a Mac gets a reason to install the Mac build, and the reverse. But a loop multiplies an installed base, and yours is 14 downloads. The first 100 users will come from Show HN, r/macapps, and r/Windows posts with a 20-second video of a file dragged into the PC notch appearing in the Mac notch. That is manual effort, not a loop.

**Q4: Can this be a big business, or is it a feature?**
A feature. Apple will not build Mac to Windows sync, but LocalSend and KDE Connect already cover it for free. For $1M ARR at $3/month you need about 27,800 paying subscribers (Estimate: $1,000,000 / $36 a year). If 5% of active users pay, that is about 556,000 active users who own both a Mac and a Windows PC and use QNotch on both. Not realistic. The ceiling as a paid add-on is closer to a few hundred dollars a month.

**Q5: Can the founder actually build this?**
Yes, technically. You have shipped a WPF app, a native Swift port, a cross-OS setup-code format, and a LAN transfer server. The hard parts are not the code:
- Security: end-to-end encryption, device pairing, and key rotation. Clipboards hold passwords and tokens. One leak ends trust in a privacy-first app.
- Operations: uptime, abuse (a free file relay gets used for piracy and malware), storage costs, account recovery.
- Mac release: sync is useless until the Mac build ships signed and notarized. That is the real blocker.

## Idea scorecard

| Dimension | Score | Notes |
|-----------|-------|-------|
| Problem severity | 2 | Mild friction, solved for free today |
| Market size | 2 | People with both OSes on one desk who also use a notch app |
| Willingness to pay | 1 | Free LAN tools set the price at $0 |
| Competition gap | 2 | Sync is crowded; notch on both OSes is open |
| Distribution | 2 | Real cross-install loop, but on a near-zero base |
| Timing | 3 | Good moment as the Mac port lands, but Mac is not released |
| Founder fit | 4 | Built both ports and the transfer pieces already |
| **Total** | **16/35** | Significant concerns as a hosted product |

## Validation experiments

**1. Do you use it every day?**
- Test: you would move something between your Mac and PC through the notch at least 5 times a day.
- How: install LocalSend and CrossPaste on both machines for 7 days. Every time you move something, write one line in a note: what (text, image, file, URL), which direction, and whether you were already looking at the notch.
- Success: 5 or more moves a day on average, and one type (likely text snippets or screenshots) is 60% or more of them. That type is your MVP.
- Time and cost: 7 days, $0.

**2. Do other QNotch users own both?**
- Test: at least 30% of interested users own a Mac and a Windows PC.
- How: add a "Mac and Windows sync" section to qnot.ch with a mocked 20-second video and a one-question form ("Which computers do you use daily?"). Post it on r/macapps, r/Windows, and a QNotch GitHub Discussion.
- Success: 50 signups in 14 days, with 30% or more saying both.
- Time and cost: 2 days of work, $0.

**3. Is "hosted" worth anything?**
- Test: people pay for sync that works off the home network.
- How: on the same page, offer two buttons: "Free, same Wi-Fi only" and "$3/month, works anywhere". The paid button goes to a Lemon Squeezy or Stripe pre-order for $10 (3 months), refundable.
- Success: 5 or more pre-orders, or 20% or more of signups pick the paid option.
- Time and cost: 1 day, about $20 in fees.

## The honest verdict

**Pivot it.** Drop "hosted". Build "QNotch Link": LAN-first, end-to-end encrypted, no account, pairing by a code or QR shown in the notch. Start with one thing that matches your Experiment 1 result (probably drag a file or snippet onto the other machine's notch). Your phone-share server and setup-code format already cover half of it. Position it as "the only notch that works across your Mac and your PC", the reason a Windows user installs the Mac build. Add an optional relay only if Experiment 3 gets 5 pre-orders.

This week: run Experiment 1 on your own two machines, and keep shipping the signed Mac build. Without a Mac release, sync has no users.

What I can't judge from here: how many of your 14 downloaders own a Mac. Do you have any way to reach them, such as GitHub issues, email, or a Discord?
