// /llms.txt: a plain summary of QNotch for AI assistants and search (https://llmstxt.org). Built with the pages
// from the same release checks, so its install commands and download size match the site. Keep its claims in
// line with [...platform].astro and the READMEs.
import type { APIRoute } from 'astro';
import { GH, DL, releases } from '../lib/releases';

export const GET: APIRoute = async ({ site }) => {
  const { mac, winget, scoop, chocolatey } = await releases();
  const page = (path: string) => new URL(path, site).href;
  const install = [
    `- Direct download: [latest Windows release](${DL}). QNotch.exe (27 MB) needs the .NET 10 Desktop Runtime; QNotch-self-contained.zip (80 MB) runs as is.`,
    ...(winget ? ['- winget: `winget install Somafet.QNotch`'] : []),
    ...(scoop ? ['- Scoop: `scoop bucket add qnotch https://github.com/Somafet/scoop-bucket`, then `scoop install qnotch/qnotch`'] : []),
    ...(chocolatey ? ['- Chocolatey: `choco install qnotch` from an administrator terminal'] : []),
  ];

  const body = `# QNotch

> QNotch is a free, open source (MIT) notch app for Windows 11 and 10 and for Apple silicon Macs. It puts music, system stats, the weather and your Claude Code and Codex sessions in a small notch at the top of the screen. Hover over it to open a panel with clipboard history, a file tray, notes, search and more.

- Windows has no notch, so on Windows QNotch draws one: a pill at the top center of the screen, similar in spirit to the Dynamic Island on an iPhone. It is a native WPF app in a single exe, not a web view, and uses about 42 MB of memory and 0.08% of one core while idle.
- On a Mac, QNotch uses the wings beside the MacBook's notch. On Macs and displays without a notch it floats as a pill under the menu bar. It is native Swift and AppKit, signed with a Developer ID and notarized, and uses about 11 MB of memory while idle.
- It shows live Claude Code and Codex sessions by title and status, signals when an agent is waiting for you, and opens that session with one click.
- Game mode keeps it out of the way of games and fullscreen video: clicks pass through and only a line of stats stays visible.
- No account is needed. Settings, notes and clipboard history stay on the device; clipboard history is kept in memory unless you choose to save it. Usage events are shared with PostHog by default, without content, and can be turned off in Settings, General.
- QNotch is an independent project by Soma Somorjai, not affiliated with Apple or Microsoft.

## Pages

- [QNotch for Windows](${page('/windows/')}): what it does on Windows 11 and 10, requirements and install options
- [QNotch for Mac](${page('/mac/')}): what it does on a MacBook, requirements, signing and permissions
- [Home](${page('/')}): both apps, with an interactive demo
- [Privacy policy](${page('/privacy')}): what stays on the device, the usage events and identifiers sent, and every online feature

## Install on Windows

Windows 10 version 2004 or newer, or Windows 11, on x64.

${install.join('\n')}

## Install on Mac

Apple silicon (M1 or newer), macOS 13 Ventura or newer. There is no Intel build.

- [QNotch-macos-arm64.dmg](${mac.url}) (${mac.mb} MB). Updates arrive through Sparkle.

## Source and docs

- [GitHub repository](${GH}): source, issues and releases
- [Windows guide](${GH}/blob/main/docs/windows/README.md): features, hotkeys, privacy and data, performance
- [Mac guide](${GH}/blob/main/docs/macos/README.md): build, data, permissions and diagnostics
- [Contributing](${GH}/blob/main/CONTRIBUTING.md): how to add a feature as its own module
`;
  return new Response(body, { headers: { 'content-type': 'text/plain; charset=utf-8' } });
};
