import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { addItem, appcastItem, emptyFeed, maxItems, plistPublicKey, publicKeyFor } from '../../scripts/macos/appcast.mjs';

const signature = `${'A'.repeat(86)}==`;
const item = (tag, build, notes) => appcastItem({ tag, build, length: 1234, signature, notes, date: new Date(Date.UTC(2026, 9, 18)) });

test('a stable Mac release is a default-channel arm64 item pointing at its own release download', () => {
  const xml = item('macos-v0.2.0', 41);
  assert.ok(xml.includes('<sparkle:version>41</sparkle:version>'));
  assert.ok(xml.includes('<sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>'));
  assert.ok(xml.includes('<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>'));
  assert.ok(xml.includes('<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>'));
  assert.ok(xml.includes('url="https://github.com/Somafet/qnotch/releases/download/macos-v0.2.0/QNotch-macos-arm64.zip"'));
  assert.ok(xml.includes(`length="1234"`) && xml.includes(`sparkle:edSignature="${signature}"`));
  assert.ok(!xml.includes('sparkle:channel'));
  assert.ok(!xml.includes('latest'));
});

test('prereleases go to the beta channel and release notes are escaped', () => {
  const xml = item('macos-v0.3.0-rc.2', 42, '## Fixed\n\n- A & <B>');
  assert.ok(xml.includes('<sparkle:channel>beta</sparkle:channel>'));
  assert.ok(xml.includes('<title>QNotch 0.3.0 (rc.2)</title>'));
  assert.ok(xml.includes('<description sparkle:format="markdown">## Fixed\n\n- A &amp; &lt;B&gt;</description>'));
});

test('items reject Windows tags, bad build numbers, lengths and signatures', () => {
  assert.throws(() => item('v0.2.0', 1));
  for (const build of [0, -1, '1.2', '01', '1; rm']) assert.throws(() => item('macos-v0.2.0', build), String(build));
  assert.throws(() => appcastItem({ tag: 'macos-v0.2.0', build: 1, length: 0, signature }));
  assert.throws(() => appcastItem({ tag: 'macos-v0.2.0', build: 1, length: 1, signature: 'not-a-signature' }));
});

test('adding is newest first, replaces a rerun of the same build, drops the old signature and keeps a bounded history', () => {
  let feed = addItem(emptyFeed(), item('macos-v0.2.0', 41), 41);
  feed += '<!-- sparkle-signatures:\nedSignature: x\nlength: 1\n-->\n';
  feed = addItem(feed, item('macos-v0.3.0', 50), 50);
  feed = addItem(feed, item('macos-v0.3.0', 50, 'rerun'), 50);
  assert.ok(!feed.includes('sparkle-signatures'));
  const versions = [...feed.matchAll(/<sparkle:version>(\d+)<\/sparkle:version>/g)].map(match => match[1]);
  assert.deepEqual(versions, ['50', '41']);
  assert.ok(feed.includes('rerun'));
  for (let build = 100; build < 100 + maxItems + 5; build++) feed = addItem(feed, item('macos-v0.4.0', build), build);
  assert.equal([...feed.matchAll(/<item>/g)].length, maxItems);
  assert.ok(feed.trimEnd().endsWith('</rss>'));
  assert.throws(() => addItem('<rss></rss>', item('macos-v0.2.0', 1), 1));
});

test('the signing key check derives the Ed25519 public key and reads the app\'s SUPublicEDKey', () => {
  // RFC 8032, test 1.
  const seed = Buffer.from('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60', 'hex').toString('base64');
  const expected = Buffer.from('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a', 'hex').toString('base64');
  assert.equal(publicKeyFor(seed), expected);
  assert.throws(() => publicKeyFor('c2hvcnQ='));
  const plist = readFileSync(new URL('../../src/QNotch.Mac/Info.plist', import.meta.url), 'utf8');
  assert.equal(Buffer.from(plistPublicKey(plist), 'base64').length, 32);
  for (const key of ['SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction']) {
    assert.match(plist, new RegExp(`<key>${key}</key><true/>`), key);
  }
  assert.ok(!/<key>SUFeedURL<\/key>/.test(plist), 'The feed URL comes from UpdateChannel.feedURL only.');
});
