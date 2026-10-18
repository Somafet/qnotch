import { createPrivateKey, createPublicKey } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { releasePolicy, repository } from '../release-policy.mjs';

// The Sparkle appcast for QNotch for Mac. The release workflow adds the published version, then
// signs the whole feed with sign_update (SURequireSignedFeed), so this script never sees a key.
export const updateAsset = 'QNotch-macos-arm64.zip';
export const minimumSystemVersion = '13.0';
export const maxItems = 30;

export function emptyFeed() {
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<title>QNotch for Mac</title>
<link>https://github.com/${repository}</link>
</channel>
</rss>
`;
}

function escape(text) {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

export function appcastItem({ tag, build, length, signature, notes = '', date = new Date() }) {
  const policy = releasePolicy(tag, 'macos');
  if (!/^[1-9]\d{0,9}$/.test(String(build))) throw new Error('The build number must be a positive integer.');
  if (!Number.isSafeInteger(length) || length <= 0) throw new Error('The update length must be a positive integer.');
  if (!/^[A-Za-z0-9+/]{86}==$/.test(signature)) throw new Error('The update signature is not an EdDSA signature.');
  const url = `https://github.com/${repository}/releases/download/${encodeURIComponent(tag)}/${updateAsset}`;
  const lines = [
    '<item>',
    `<title>QNotch ${escape(policy.version)}${policy.prerelease ? ` (${escape(tag.split('-')[2])})` : ''}</title>`,
    `<pubDate>${date.toUTCString()}</pubDate>`,
    `<sparkle:version>${build}</sparkle:version>`,
    `<sparkle:shortVersionString>${escape(policy.version)}</sparkle:shortVersionString>`,
    `<sparkle:minimumSystemVersion>${minimumSystemVersion}</sparkle:minimumSystemVersion>`,
    '<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>',
  ];
  if (policy.prerelease) lines.push('<sparkle:channel>beta</sparkle:channel>');
  lines.push(`<sparkle:fullReleaseNotesLink>https://github.com/${repository}/releases/tag/${encodeURIComponent(tag)}</sparkle:fullReleaseNotesLink>`);
  if (notes.trim()) lines.push(`<description sparkle:format="markdown">${escape(notes.trim())}</description>`);
  lines.push(`<enclosure url="${url}" length="${length}" type="application/octet-stream" sparkle:edSignature="${signature}"/>`, '</item>');
  return lines.join('\n');
}

// The EdDSA public key for a Sparkle private key (generate_keys -x: base64 of the 32-byte seed).
export function publicKeyFor(privateKey) {
  const seed = Buffer.from(privateKey.trim(), 'base64');
  if (seed.length !== 32 && seed.length !== 96) throw new Error('This is not a Sparkle EdDSA private key.');
  const der = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed.subarray(0, 32)]);
  const key = createPublicKey(createPrivateKey({ key: der, format: 'der', type: 'pkcs8' }));
  return key.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
}

export function plistPublicKey(plist) {
  const match = /<key>SUPublicEDKey<\/key>\s*<string>([A-Za-z0-9+/]{43}=)<\/string>/.exec(plist);
  if (!match) throw new Error('Info.plist has no SUPublicEDKey.');
  return match[1];
}

// Adds an item as the newest, replacing one with the same build (a rerun) and keeping at most
// maxItems. The embedded signature is dropped: the feed must be signed again after this.
export function addItem(feed, item, build) {
  let body = feed.replace(/<!--\s*sparkle-signatures:[\s\S]*?-->\s*$/, '').trimEnd() + '\n';
  if (!/<channel>[\s\S]*<\/channel>/.test(body)) throw new Error('The appcast has no channel.');
  const items = [...body.matchAll(/<item>[\s\S]*?<\/item>/g)].map(match => match[0]);
  const kept = items.filter(existing => !existing.includes(`<sparkle:version>${build}</sparkle:version>`))
    .slice(0, maxItems - 1);
  body = body.replace(/\s*<item>[\s\S]*?<\/item>/g, '');
  return body.replace(/\s*<\/channel>/, `\n${[item, ...kept].join('\n')}\n</channel>`);
}

// add: put a published release into the feed. check-key: SPARKLE_PRIVATE_KEY must belong to the
// app's SUPublicEDKey, or every installed copy would reject the update.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { values, positionals } = parseArgs({ allowPositionals: true, options: {
      feed: { type: 'string' }, tag: { type: 'string' }, build: { type: 'string' }, length: { type: 'string' },
      signature: { type: 'string' }, notes: { type: 'string' }, plist: { type: 'string' },
    } });
    if (positionals[0] === 'check-key') {
      if (!process.env.SPARKLE_PRIVATE_KEY) throw new Error('SPARKLE_PRIVATE_KEY is missing.');
      if (publicKeyFor(process.env.SPARKLE_PRIVATE_KEY) !== plistPublicKey(readFileSync(values.plist, 'utf8'))) {
        throw new Error("SPARKLE_PRIVATE_KEY does not match Info.plist's SUPublicEDKey.");
      }
      console.log('The Sparkle key matches SUPublicEDKey.');
    } else if (positionals[0] === 'add') {
      if (!values.feed) throw new Error('--feed is required.');
      const notes = values.notes && existsSync(values.notes) ? readFileSync(values.notes, 'utf8') : '';
      const item = appcastItem({ tag: values.tag, build: values.build, length: Number(values.length), signature: values.signature, notes });
      const feed = existsSync(values.feed) ? readFileSync(values.feed, 'utf8') : emptyFeed();
      writeFileSync(values.feed, addItem(feed, item, values.build));
      console.log(`Added ${values.tag} (build ${values.build}) to ${values.feed}.`);
    } else {
      throw new Error('Usage: appcast.mjs add --feed … --tag … --build … --length … --signature … [--notes …] | check-key --plist …');
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
