import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { releasePolicy, repository } from './release-policy.mjs';

// winget, Scoop and Chocolatey install the self-contained ZIP from a published Windows release. They never change
// release assets, names or the latest endpoint; they only point at what the guarded publisher verified.
export const wingetId = 'Somafet.QNotch';
export const scoopName = 'qnotch';
export const scoopBucket = 'Somafet/scoop-bucket';
export const chocolateyId = 'qnotch';
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

const xml = text => text.replace(/[<>&"']/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[c]);
const ps = text => `'${text.replace(/'/g, "''")}'`;

// A portable ZIP package. Chocolatey extracts QNotch.exe into the package's tools folder and shims it as
// qnotch; the shim waits for the exe, so `qnotch usage --json` prints and returns its exit code. The
// Start menu shortcut points at the exe itself, so the app starts without a console.
export function chocolateyPackage({ tag, version, url, sha256, commit }) {
  // The icon comes from the tagged commit, so it cannot change underneath a published package.
  if (!/^[0-9a-f]{40}$/.test(commit ?? '')) throw new Error(`${tag} has no resolved commit for the Chocolatey icon.`);
  const fields = {
    id: chocolateyId,
    version,
    title: 'QNotch',
    authors: 'Soma Somorjai',
    owners: 'Somafet',
    copyright: 'Copyright (c) 2026 Soma Somorjai',
    projectUrl: 'https://qnot.ch',
    iconUrl: `https://cdn.jsdelivr.net/gh/${repository}@${commit}/src/QNotch/Assets/AppIcon.svg`,
    licenseUrl: `https://github.com/${repository}/blob/main/LICENSE`,
    requireLicenseAcceptance: 'false',
    projectSourceUrl: `https://github.com/${repository}`,
    packageSourceUrl: `https://github.com/${repository}/blob/main/scripts/package-managers.mjs`,
    docsUrl: `https://github.com/${repository}#readme`,
    bugTrackerUrl: `https://github.com/${repository}/issues`,
    tags: 'qnotch notch clipboard clipboard-history system-monitor media productivity claude-code codex foss',
    summary: 'A notch for your Windows desktop.',
    description: [
      description,
      'The package adds the `qnotch` command and a Start menu shortcut. Run `qnotch usage --json` or `qnotch agents --json` while QNotch runs.',
      'Requires 64-bit Windows 10 version 2004 or later.',
    ].join('\n\n'),
    releaseNotes: `https://github.com/${repository}/releases/tag/${tag}`,
  };
  const metadata = Object.entries(fields).map(([key, value]) => `    <${key}>${xml(value)}</${key}>`).join('\n');
  const nuspec = `<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
${metadata}
  </metadata>
  <files>
    <file src="tools\\**" target="tools" />
  </files>
</package>
`;
  const header = `$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$shortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'QNotch.lnk'
`;
  return {
    [`${chocolateyId}.nuspec`]: nuspec,
    'tools/chocolateyinstall.ps1': `${header}
$packageArgs = @{
  packageName    = $env:ChocolateyPackageName
  unzipLocation  = $toolsDir
  url64bit       = ${ps(url)}
  checksum64     = ${ps(sha256)}
  checksumType64 = 'sha256'
}
Install-ChocolateyZipPackage @packageArgs
Install-ChocolateyShortcut -ShortcutFilePath $shortcut -TargetPath (Join-Path $toolsDir 'QNotch.exe') -WorkingDirectory $toolsDir
`,
    // A running QNotch locks its exe, so upgrades and uninstalls stop this package's copy first.
    'tools/chocolateybeforemodify.ps1': `${header}
Get-Process -Name QNotch -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -and $_.Path.StartsWith($toolsDir, [StringComparison]::OrdinalIgnoreCase) } |
  Stop-Process -Force
`,
    'tools/chocolateyuninstall.ps1': `${header}
if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
`,
  };
}

// winget: <out>/winget/*.yaml, ready for `wingetcreate submit`. Scoop: <out>/scoop/bucket/qnotch.json.
// Chocolatey: <out>/chocolatey/qnotch.nuspec and its tools, ready for `choco pack`.
export function writeManifests(source, out) {
  const winget = join(out, 'winget');
  mkdirSync(winget, { recursive: true });
  for (const [name, text] of Object.entries(wingetManifests(source))) writeFileSync(join(winget, name), text);
  const bucket = join(out, 'scoop', 'bucket');
  mkdirSync(bucket, { recursive: true });
  writeFileSync(join(bucket, `${scoopName}.json`), scoopManifest(source));
  const chocolatey = join(out, 'chocolatey');
  for (const [name, text] of Object.entries(chocolateyPackage(source))) {
    mkdirSync(dirname(join(chocolatey, name)), { recursive: true });
    writeFileSync(join(chocolatey, name), text);
  }
  return { winget, scoop: join(bucket, `${scoopName}.json`), chocolatey: join(chocolatey, `${chocolateyId}.nuspec`) };
}

export function fetchSource(tag, run = gh) {
  const release = JSON.parse(run(['api', `repos/${repository}/releases/tags/${encodeURIComponent(tag)}`]));
  const latest = JSON.parse(run(['api', `repos/${repository}/releases/latest`]));
  const source = releaseSource(release, latest, tag);
  const commit = JSON.parse(run(['api', `repos/${repository}/commits/${encodeURIComponent(tag)}`])).sha?.toLowerCase();
  if (!/^[0-9a-f]{40}$/.test(commit ?? '')) throw new Error(`Could not resolve ${tag} to a commit.`);
  return { ...source, commit };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { values } = parseArgs({ options: { tag: { type: 'string' }, out: { type: 'string' } } });
    if (!values.out) throw new Error('--out is required.');
    const source = fetchSource(values.tag);
    const paths = writeManifests(source, values.out);
    console.log(`Wrote winget manifests to ${paths.winget}, the Scoop manifest to ${paths.scoop} and the Chocolatey package to ${paths.chocolatey} for ${source.version}.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
