import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { releasePolicy, repository, validateAssetNames, validateLatest } from '../../scripts/release-policy.mjs';
import { publishRelease } from '../../scripts/publish-release.mjs';

const fixtures = JSON.parse(readFileSync(new URL('../fixtures/release-tags.json', import.meta.url)));
for (const fixture of fixtures) {
  test(`release channel: ${fixture.tag}`, () => {
    if (fixture.platform === null) {
      assert.throws(() => releasePolicy(fixture.tag, 'windows'));
      assert.throws(() => releasePolicy(fixture.tag, 'macos'));
      return;
    }
    const policy = releasePolicy(fixture.tag, fixture.platform);
    assert.equal(policy.version, fixture.version);
    assert.equal(policy.prerelease, fixture.prerelease ?? false);
    assert.equal(policy.latest, fixture.platform === 'windows');
    assert.throws(() => releasePolicy(fixture.tag, fixture.platform === 'windows' ? 'macos' : 'windows'));
  });
}

test('Windows artifact names cannot be renamed, omitted, duplicated, or mixed with Mac downloads', () => {
  const policy = releasePolicy('v0.5.0', 'windows');
  for (const names of [['QNotch.exe'], ['QNotch-windows-x64.exe', 'QNotch-self-contained.zip'],
    ['QNotch.exe', 'QNotch.exe'], ['QNotch.exe', 'QNotch-self-contained.zip', 'QNotch-macos-arm64.dmg']]) {
    assert.throws(() => validateAssetNames(policy, names));
  }
});

test('Windows latest cannot go backwards or point at another platform', () => {
  const policy = releasePolicy('v0.5.0', 'windows');
  validateLatest(policy, null);
  validateLatest(policy, { tag_name: 'v0.4.9' });
  for (const tag_name of ['v0.5.0', 'v0.6.0', 'macos-v0.1.0']) assert.throws(() => validateLatest(policy, { tag_name }));
});

// Exercise the publishing transaction with local files and a fake gh transport. No releases are created by tests.
function scenario(t, { platform = 'windows', tag = 'v0.5.0', corrupt = false, missing = false,
  existingPublished = false, existingDraft = false, newerDuringUpload = false, apiError = null } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'qnotch release ü '));
  t.after(() => rmSync(dir, { recursive: true }));
  const names = platform === 'windows' ? ['QNotch.exe', 'QNotch-self-contained.zip'] : ['QNotch-macos-arm64.dmg'];
  const paths = names.map(name => join(dir, name));
  paths.forEach(path => writeFileSync(path, 'test artifact'));
  const digest = 'sha256:' + createHash('sha256').update('test artifact').digest('hex');
  let currentLatest = { tag_name: 'v0.4.0' };
  let release = existingDraft || existingPublished ? { draft: !existingPublished } : null;
  const calls = [];
  const run = args => {
    calls.push(args);
    if (args[0] === 'api') {
      if (apiError) throw Object.assign(new Error('API failure'), { stderr: `gh: failure (HTTP ${apiError})` });
      const value = args[1].endsWith('/latest') ? currentLatest : release;
      if (!value) throw Object.assign(new Error('Not found'), { stderr: 'gh: Not Found (HTTP 404)' });
      return JSON.stringify(value);
    }
    if (args[1] === 'create' || args[1] === 'upload') {
      release = { tag_name: tag, draft: true, prerelease: tag.includes('-beta.'), assets: names.map(name => ({
        name, size: 13, state: 'uploaded', digest: corrupt ? 'sha256:' + '0'.repeat(64) : digest,
        browser_download_url: `https://github.com/${repository}/releases/download/${tag}/${name}`,
      })) };
      if (missing) release.assets.pop();
      if (newerDuringUpload) currentLatest = { tag_name: 'v0.6.0' };
    }
    if (args[1] === 'edit') {
      release.draft = false;
      if (args.includes('--latest=true')) currentLatest = release;
    }
    return '';
  };
  return { calls, run, options: { tag, platform, paths } };
}

test('Windows publishes verified downloads from a draft, then explicitly promotes latest', async t => {
  const s = scenario(t);
  await publishRelease(s.options, s.run);
  const create = s.calls.find(args => args[1] === 'create');
  const edit = s.calls.find(args => args[1] === 'edit');
  assert.ok(create.includes('--draft') && create.includes('--latest=false') && create.includes('--verify-tag'));
  assert.ok(create.includes('--notes-start-tag') && create.includes('v0.4.0'));
  assert.ok(edit.includes('--draft=false') && edit.includes('--latest=true'));
});

for (const tag of ['macos-v0.1.0', 'macos-v0.1.0-beta.1']) {
  test(`${tag} never promotes GitHub latest or changes the Windows channel`, async t => {
    const s = scenario(t, { platform: 'macos', tag });
    await publishRelease(s.options, s.run);
    assert.ok(!s.calls.some(args => args.includes('--latest=true')));
    assert.ok(s.calls.find(args => args[1] === 'edit').includes('--latest=false'));
  });
}

for (const failure of ['corrupt', 'missing', 'existingPublished', 'newerDuringUpload']) {
  test(`publication stops before promotion: ${failure}`, async t => {
    const s = scenario(t, { [failure]: true });
    await assert.rejects(publishRelease(s.options, s.run));
    assert.ok(!s.calls.some(args => args[1] === 'edit'));
    if (failure === 'existingPublished') assert.ok(!s.calls.some(args => args[0] === 'release'));
  });
}

test('a failed draft can be resumed without recreating a release', async t => {
  const s = scenario(t, { existingDraft: true });
  await publishRelease(s.options, s.run);
  assert.ok(s.calls.some(args => args[1] === 'upload'));
  assert.ok(!s.calls.some(args => args[1] === 'create'));
});

for (const apiError of [401, 403, 429, 500]) {
  test(`HTTP ${apiError} is not mistaken for an absent release`, async t => {
    const s = scenario(t, { apiError });
    await assert.rejects(publishRelease(s.options, s.run));
    assert.ok(!s.calls.some(args => args[0] === 'release'));
  });
}
