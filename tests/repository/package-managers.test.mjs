import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { parse, parseDocument } from 'yaml';
import { chocolateyPackage, fetchSource, releaseSource, scoopManifest, wingetId, wingetManifests, writeManifests } from '../../scripts/package-managers.mjs';
import { repository } from '../../scripts/release-policy.mjs';

const root = resolve(import.meta.dirname, '../..');
const sha = 'ab'.repeat(32);
const commit = '0123456789abcdef'.repeat(2) + '01234567';
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
    if (args[1].includes('/commits/')) return JSON.stringify({ sha: commit.toUpperCase() });
    return JSON.stringify(args[1].endsWith('/latest') ? { tag_name: 'v0.9.0' } : release());
  });
  assert.equal(source.version, '0.9.0');
  assert.equal(source.commit, commit);
  assert.deepEqual(calls, [`repos/${repository}/releases/tags/v0.9.0`, `repos/${repository}/releases/latest`, `repos/${repository}/commits/v0.9.0`]);
});

test('the release is refused when its tag does not resolve to a commit', () => {
  assert.throws(() => fetchSource('v0.9.0', args => JSON.stringify(
    args[1].includes('/commits/') ? {} : args[1].endsWith('/latest') ? { tag_name: 'v0.9.0' } : release())));
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

test('Chocolatey gets a portable ZIP package with a pinned checksum, a shortcut and clean removal', () => {
  const files = chocolateyPackage({ ...releaseSource(release(), { tag_name: 'v0.9.0' }, 'v0.9.0'), commit });
  assert.deepEqual(Object.keys(files).sort(), ['qnotch.nuspec', 'tools/chocolateybeforemodify.ps1', 'tools/chocolateyinstall.ps1', 'tools/chocolateyuninstall.ps1']);
  const nuspec = files['qnotch.nuspec'];
  const field = name => new RegExp(`<${name}>([^<]*)</${name}>`).exec(nuspec)?.[1];
  assert.equal(field('id'), 'qnotch');
  assert.equal(field('version'), '0.9.0');
  assert.equal(field('releaseNotes'), `https://github.com/${repository}/releases/tag/v0.9.0`);
  for (const name of ['title', 'authors', 'copyright', 'projectUrl', 'iconUrl', 'licenseUrl', 'packageSourceUrl', 'summary']) assert.ok(field(name), name);
  // The icon is pinned to the tagged commit so it cannot change underneath the package.
  assert.equal(field('iconUrl'), `https://cdn.jsdelivr.net/gh/${repository}@${commit}/src/QNotch/Assets/AppIcon.svg`);
  assert.throws(() => chocolateyPackage(releaseSource(release(), { tag_name: 'v0.9.0' }, 'v0.9.0')));
  // Chocolatey tags are space separated and lowercase.
  assert.ok(field('tags').split(' ').every(tag => /^[a-z0-9-]+$/.test(tag)));
  assert.ok(field('description').length >= 30 && !/[<>]/.test(field('description')));
  assert.ok(nuspec.includes('<file src="tools\\**" target="tools" />'));
  const install = files['tools/chocolateyinstall.ps1'];
  assert.ok(install.includes(`url64bit       = '${url('v0.9.0')}'`));
  assert.ok(install.includes(`checksum64     = '${sha}'`) && install.includes("checksumType64 = 'sha256'"));
  assert.ok(install.includes('Install-ChocolateyZipPackage') && install.includes('Install-ChocolateyShortcut'));
  assert.ok(files['tools/chocolateyuninstall.ps1'].includes('Remove-Item -LiteralPath $shortcut'));
  // Only the copy inside this package's folder is stopped, never a QNotch.exe run from elsewhere.
  assert.ok(files['tools/chocolateybeforemodify.ps1'].includes('$_.Path.StartsWith($toolsDir'));
  for (const [name, text] of Object.entries(files)) assert.ok(/^[\x09\x0a\x20-\x7e]*$/.test(text), `${name} is plain ASCII`);
});

test('manifests are written where wingetcreate and the bucket expect them', t => {
  const out = mkdtempSync(join(tmpdir(), 'qnotch package managers ü '));
  t.after(() => rmSync(out, { recursive: true }));
  writeManifests({ ...releaseSource(release(), { tag_name: 'v0.9.0' }, 'v0.9.0'), commit }, out);
  assert.equal(readdirSync(join(out, 'winget')).length, 3);
  assert.equal(JSON.parse(readFileSync(join(out, 'scoop', 'bucket', 'qnotch.json'), 'utf8')).version, '0.9.0');
  assert.ok(readFileSync(join(out, 'chocolatey', 'qnotch.nuspec'), 'utf8').includes('<version>0.9.0</version>'));
  assert.deepEqual(readdirSync(join(out, 'chocolatey', 'tools')).sort(), ['chocolateybeforemodify.ps1', 'chocolateyinstall.ps1', 'chocolateyuninstall.ps1']);
});

test('package managers run after publication, with each token only in its own step', () => {
  const workflow = parse(readFileSync(resolve(root, '.github/workflows/release.yml'), 'utf8'));
  const job = workflow.jobs['package-managers'];
  assert.equal(job.needs, 'release');
  assert.equal(job.if, "github.repository == 'Somafet/qnotch'");
  assert.ok(!job.permissions, 'The job only reads; the release token stays read-only.');
  const steps = job.steps.filter(step => step.run);
  assert.ok(steps[0].run.includes('scripts/package-managers.mjs') && steps[0].run.includes('GITHUB_REF_NAME'));
  for (const [secret, text] of [['WINGET_TOKEN', 'wingetcreate.exe" submit'], ['SCOOP_BUCKET_TOKEN', 'Somafet/scoop-bucket'], ['CHOCOLATEY_API_KEY', 'push.chocolatey.org']]) {
    const using = job.steps.filter(step => JSON.stringify(step).includes(secret));
    assert.equal(using.length, 1, secret);
    assert.ok(using[0].run.includes(text) && using[0].run.includes(`if (-not $env:${secret})`), secret);
  }
  for (const secret of ['WINGET_TOKEN', 'SCOOP_BUCKET_TOKEN', 'CHOCOLATEY_API_KEY']) assert.ok(!JSON.stringify(workflow.jobs.release).includes(secret), secret);
});
