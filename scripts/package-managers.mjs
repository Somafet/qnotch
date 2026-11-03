import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { releasePolicy, repository } from './release-policy.mjs';

// winget and Scoop install the self-contained ZIP from a published Windows release. They never change
// release assets, names or the latest endpoint; they only point at what the guarded publisher verified.
export const wingetId = 'Somafet.QNotch';
export const scoopName = 'qnotch';
export const scoopBucket = 'Somafet/scoop-bucket';
const asset = 'QNotch-self-contained.zip';
const manifestVersion = '1.10.0';
const description = 'A small notch at the top of your desktop for music, system stats, files, clipboard history, and coding agents. Hover it to open the panel.';

function gh(args) {
  return execFileSync('gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

// The release must be the published global latest Windows release, so a rerun of an old tag can never
// downgrade either package manager. Its digest is the one the publisher compared with the local build.
export function releaseSource(release, latest, tag) {
  const policy = releasePolicy(tag, 'windows');
  if (!release || release.draft || release.prerelease || release.tag_name !== tag) throw new Error(`${tag} is not a published stable release.`);
  if (latest?.tag_name !== tag) throw new Error(`${tag} is not the latest Windows release; refusing to point package managers at it.`);
  const zip = release.assets?.find(item => item.name === asset);
  const url = `https://github.com/${repository}/releases/download/${tag}/${asset}`;
  const sha256 = /^sha256:([0-9a-f]{64})$/i.exec(zip?.digest ?? '')?.[1];
  if (zip?.state !== 'uploaded' || !(zip.size > 0) || zip.browser_download_url !== url || !sha256) {
    throw new Error(`${tag} has no verified ${asset}.`);
  }
  const releaseDate = /^\d{4}-\d{2}-\d{2}/.exec(release.published_at ?? '')?.[0];
  if (!releaseDate) throw new Error(`${tag} has no publication date.`);
  return { tag, version: policy.version, url, sha256: sha256.toLowerCase(), releaseDate };
}

// JSON strings are valid YAML double-quoted scalars, so no YAML library is needed at release time.
function yaml(schema, fields) {
  const lines = [`# yaml-language-server: $schema=https://aka.ms/winget-manifest.${schema}.${manifestVersion}.schema.json`, ''];
  const scalar = value => typeof value === 'string' ? JSON.stringify(value) : String(value);
  for (const [key, value] of Object.entries(fields)) {
    if (!Array.isArray(value)) { lines.push(`${key}: ${scalar(value)}`); continue; }
    lines.push(`${key}:`);
    for (const item of value) {
      if (typeof item !== 'object') { lines.push(`- ${scalar(item)}`); continue; }
      Object.entries(item).forEach(([k, v], i) => lines.push(`${i ? '  ' : '- '}${k}: ${scalar(v)}`));
    }
  }
  return `${lines.join('\n')}\n`;
}

export function wingetManifests({ tag, version, url, sha256, releaseDate }) {
  const id = { PackageIdentifier: wingetId, PackageVersion: version };
  return {
    [`${wingetId}.yaml`]: yaml('version', { ...id, DefaultLocale: 'en-US', ManifestType: 'version', ManifestVersion: manifestVersion }),
    [`${wingetId}.installer.yaml`]: yaml('installer', {
      ...id,
      InstallerType: 'zip',
      NestedInstallerType: 'portable',
      NestedInstallerFiles: [{ RelativeFilePath: 'QNotch.exe', PortableCommandAlias: 'qnotch' }],
      // Windows 10 2004, the oldest version the app supports.
      MinimumOSVersion: '10.0.19041.0',
      ReleaseDate: releaseDate,
      Installers: [{ Architecture: 'x64', InstallerUrl: url, InstallerSha256: sha256.toUpperCase() }],
      ManifestType: 'installer',
      ManifestVersion: manifestVersion,
    }),
    [`${wingetId}.locale.en-US.yaml`]: yaml('defaultLocale', {
      ...id,
      PackageLocale: 'en-US',
      Publisher: 'Soma Somorjai',
      PublisherUrl: 'https://github.com/Somafet',
      PublisherSupportUrl: `https://github.com/${repository}/issues`,
      Author: 'Soma Somorjai',
      PackageName: 'QNotch',
      PackageUrl: 'https://qnot.ch',
      License: 'MIT',
      LicenseUrl: `https://github.com/${repository}/blob/main/LICENSE`,
      ShortDescription: 'A notch for your Windows desktop.',
      Description: description,
      Moniker: 'qnotch',
      Tags: ['notch', 'clipboard', 'clipboard-history', 'system-monitor', 'media', 'productivity', 'claude-code', 'codex'],
      ReleaseNotesUrl: `https://github.com/${repository}/releases/tag/${tag}`,
      ManifestType: 'defaultLocale',
      ManifestVersion: manifestVersion,
    }),
  };
}

export function scoopManifest({ version, url, sha256 }) {
  const manifest = {
    version,
    description,
    homepage: 'https://qnot.ch',
    license: 'MIT',
    notes: 'QNotch can also update itself from Settings, About. Run `qnotch usage --json` or `qnotch agents --json` while it runs.',
    architecture: { '64bit': { url, hash: sha256 } },
    bin: [['QNotch.exe', 'qnotch']],
    shortcuts: [['QNotch.exe', 'QNotch']],
    checkver: { github: `https://github.com/${repository}` },
    autoupdate: { architecture: { '64bit': { url: `https://github.com/${repository}/releases/download/v$version/${asset}` } } },
  };
  return `${JSON.stringify(manifest, null, 4)}\n`;
}

// winget: <out>/winget/*.yaml, ready for `wingetcreate submit`. Scoop: <out>/scoop/bucket/qnotch.json.
export function writeManifests(source, out) {
  const winget = join(out, 'winget');
  mkdirSync(winget, { recursive: true });
  for (const [name, text] of Object.entries(wingetManifests(source))) writeFileSync(join(winget, name), text);
  const bucket = join(out, 'scoop', 'bucket');
  mkdirSync(bucket, { recursive: true });
  writeFileSync(join(bucket, `${scoopName}.json`), scoopManifest(source));
  return { winget, scoop: join(bucket, `${scoopName}.json`) };
}

export function fetchSource(tag, run = gh) {
  const release = JSON.parse(run(['api', `repos/${repository}/releases/tags/${encodeURIComponent(tag)}`]));
  const latest = JSON.parse(run(['api', `repos/${repository}/releases/latest`]));
  return releaseSource(release, latest, tag);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { values } = parseArgs({ options: { tag: { type: 'string' }, out: { type: 'string' } } });
    if (!values.out) throw new Error('--out is required.');
    const source = fetchSource(values.tag);
    const paths = writeManifests(source, values.out);
    console.log(`Wrote winget manifests to ${paths.winget} and the Scoop manifest to ${paths.scoop} for ${source.version}.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
