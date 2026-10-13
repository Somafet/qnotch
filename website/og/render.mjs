// Renders og/og.html to src/assets/og.png (1200x630) with headless Edge or Chrome.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';

const browsers = [
  process.env.CHROME,
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
].filter(Boolean);
const browser = browsers.find(existsSync);
if (!browser) throw new Error('No Chrome or Edge found; set CHROME to its path.');

const html = pathToFileURL(fileURLToPath(new URL('og.html', import.meta.url))).href;
const out = fileURLToPath(new URL('../src/assets/og.png', import.meta.url));
execFileSync(browser, [
  '--headless', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
  '--window-size=1200,630', '--virtual-time-budget=2000', `--screenshot=${out}`, html,
], { stdio: 'inherit' });
console.log(`Wrote ${out}`);
