import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { parse, parseDocument } from 'yaml';
import { fetchSource, releaseSource, scoopManifest, wingetId, wingetManifests, writeManifests } from '../../scripts/package-managers.mjs';
import { repository } from '../../scripts/release-policy.mjs';

const root = resolve(import.meta.dirname, '../..');
const sha = 'ab'.repeat(32);
const url = tag => `https://github.com/${repository}/releases/download/${tag}/QNotch-self-contained.zip`;
function release(tag = 'v0.9.0', overrides = {}, zip = {}) {
  return {
    tag_name: tag, draft: false, prerelease: false, published_at: '2026-11-03T10:00:00Z', ...overrides,
    assets: [
      { name: 'QNotch.exe', state: 'uploaded', size: 10, digest: `sha256:${'cd'.repeat(32)}`, browser_download_url: url(tag).replace('QNotch-self-contained.zip', 'QNotch.exe') },
      { name: 'QNotch-self-contained.zip', state: 'uploaded', size: 20, digest: `sha256:${sha}`, browser_download_url: url(tag), ...zip },
    ],
  };
}

test('package managers point at the verified self-contained ZIP of the latest Windows release', () => {
  const source = releaseSource(release(), { tag_name: 'v0.9.0' }, 'v0.9.0');
  assert.deepEqual(source, { tag: 'v0.9.0', version: '0.9.0', url: url('v0.9.0'), sha256: sha, releaseDate: '2026-11-03' });
});

for (const [name, args] of Object.entries({
  'a draft': [release('v0.9.0', { draft: true }), { tag_name: 'v0.9.0' }],
  'an older tag than latest, which would downgrade users': [release(), { tag_name: 'v0.9.1' }],
  'a ZIP without a digest': [release('v0.9.0', {}, { digest: null }), { tag_name: 'v0.9.0' }],
  'a ZIP served from an untagged draft address': [release('v0.9.0', {}, { browser_download_url: url('untagged-0123abcd') }), { tag_name: 'v0.9.0' }],
  'a ZIP still uploading': [release('v0.9.0', {}, { state: 'starter' }), { tag_name: 'v0.9.0' }],
})) {
  test(`package managers refuse ${name}`, () => assert.throws(() => releaseSource(...args, 'v0.9.0')));
}

test('package managers refuse Mac tags', () => {
  assert.throws(() => releaseSource(release('macos-v0.9.0'), { tag_name: 'macos-v0.9.0' }, 'macos-v0.9.0'));
});

test('the release is read from GitHub by tag and compared with latest', () => {
  const calls = [];
  const source = fetchSource('v0.9.0', args => {
    calls.push(args[1]);
    return JSON.stringify(args[1].endsWith('/latest') ? { tag_name: 'v0.9.0' } : release());
  });
  assert.equal(source.version, '0.9.0');
  assert.deepEqual(calls, [`repos/${repository}/releases/tags/v0.9.0`, `repos/${repository}/releases/latest`]);
});

test('winget gets a portable ZIP manifest set for one version', () => {
  const source = releaseSource(release(), { tag_name: 'v0.9.0' }, 'v0.9.0');
  const files = wingetManifests(source);
  assert.deepEqual(Object.keys(files).sort(), [`${wingetId}.installer.yaml`, `${wingetId}.locale.en-US.yaml`, `${wingetId}.yaml`]);
  const docs = Object.fromEntries(Object.entries(files).map(([name, text]) => {
    const document = parseDocument(text, { uniqueKeys: true });
    assert.deepEqual(document.errors, [], name);
    return [name, document.toJS()];
  }));
  for (const doc of Object.values(docs)) {
    assert.equal(doc.PackageIdentifier, wingetId);
    assert.equal(doc.PackageVersion, '0.9.0');
  }
  const installer = docs[`${wingetId}.installer.yaml`];
  assert.equal(installer.InstallerType, 'zip');
  assert.equal(installer.NestedInstallerType, 'portable');
  assert.deepEqual(installer.NestedInstallerFiles, [{ RelativeFilePath: 'QNotch.exe', PortableCommandAlias: 'qnotch' }]);
  assert.deepEqual(installer.Installers, [{ Architecture: 'x64', InstallerUrl: url('v0.9.0'), InstallerSha256: sha.toUpperCase() }]);
  assert.equal(installer.ReleaseDate, '2026-11-03');
  const locale = docs[`${wingetId}.locale.en-US.yaml`];
  assert.equal(locale.License, 'MIT');
  assert.equal(locale.ReleaseNotesUrl, `https://github.com/${repository}/releases/tag/v0.9.0`);
  assert.ok(locale.Tags.length <= 16 && locale.Tags.every(tag => /^[a-z0-9-]{1,40}$/.test(tag)));
});

test('Scoop gets an x64 manifest with a shim, a shortcut and autoupdate', () => {
  const manifest = JSON.parse(scoopManifest(releaseSource(release(), { tag_name: 'v0.9.0' }, 'v0.9.0')));
  assert.equal(manifest.version, '0.9.0');
  assert.deepEqual(manifest.architecture, { '64bit': { url: url('v0.9.0'), hash: sha } });
  assert.deepEqual(manifest.bin, [['QNotch.exe', 'qnotch']]);
  assert.deepEqual(manifest.shortcuts, [['QNotch.exe', 'QNotch']]);
  assert.equal(manifest.autoupdate.architecture['64bit'].url.replace('$version', '0.9.0'), url('v0.9.0'));
});

test('manifests are written where wingetcreate and the bucket expect them', t => {
  const out = mkdtempSync(join(tmpdir(), 'qnotch package managers ü '));
  t.after(() => rmSync(out, { recursive: true }));
  writeManifests(releaseSource(release(), { tag_name: 'v0.9.0' }, 'v0.9.0'), out);
  assert.equal(readdirSync(join(out, 'winget')).length, 3);
  assert.equal(JSON.parse(readFileSync(join(out, 'scoop', 'bucket', 'qnotch.json'), 'utf8')).version, '0.9.0');
});

test('package managers run after publication, with each token only in its own step', () => {
  const workflow = parse(readFileSync(resolve(root, '.github/workflows/release.yml'), 'utf8'));
  const job = workflow.jobs['package-managers'];
  assert.equal(job.needs, 'release');
  assert.equal(job.if, "github.repository == 'Somafet/qnotch'");
  assert.ok(!job.permissions, 'The job only reads; the release token stays read-only.');
  const steps = job.steps.filter(step => step.run);
  assert.ok(steps[0].run.includes('scripts/package-managers.mjs') && steps[0].run.includes('GITHUB_REF_NAME'));
  for (const [secret, text] of [['WINGET_TOKEN', 'wingetcreate.exe" submit'], ['SCOOP_BUCKET_TOKEN', 'Somafet/scoop-bucket']]) {
    const using = job.steps.filter(step => JSON.stringify(step).includes(secret));
    assert.equal(using.length, 1, secret);
    assert.ok(using[0].run.includes(text) && using[0].run.includes(`if (-not $env:${secret})`), secret);
  }
  assert.ok(!JSON.stringify(workflow.jobs.release).includes('WINGET_TOKEN') && !JSON.stringify(workflow.jobs.release).includes('SCOOP_BUCKET_TOKEN'));
});
