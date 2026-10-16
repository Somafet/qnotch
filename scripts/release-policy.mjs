import { appendFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';

export const repository = 'Somafet/qnotch';
export const windowsAssets = ['QNotch.exe', 'QNotch-self-contained.zip'];
export const maxWindowsAssetSize = 256 * 1024 * 1024;

// Keep vX.Y.Z reserved for Windows: already-installed clients parse these tags.
export function releasePolicy(tag, platform) {
  const match = /^(v|macos-v)(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(?:alpha|beta|rc)\.(0|[1-9]\d*))?$/.exec(tag);
  if (!match) throw new Error(`Unsupported release tag: ${tag}`);
  const actualPlatform = match[1] === 'v' ? 'windows' : 'macos';
  const parts = match.slice(2, 5).map(Number);
  if (parts.some(n => !Number.isSafeInteger(n) || n > 65534)) throw new Error('Version components must be at most 65534.');
  if (actualPlatform === 'windows' && match[5]) throw new Error('Windows release tags must be stable vX.Y.Z versions.');
  if (platform !== actualPlatform) throw new Error(`Tag ${tag} belongs to ${actualPlatform}, not ${platform}.`);
  return { tag, platform, version: parts.join('.'), prerelease: Boolean(match[5]), latest: platform === 'windows' };
}

export function validateAssetNames(policy, names) {
  if (new Set(names).size !== names.length) throw new Error('Duplicate release asset names.');
  if (policy.platform === 'windows') {
    if (names.length !== windowsAssets.length || !windowsAssets.every(name => names.includes(name))) {
      throw new Error('Windows releases require exactly QNotch.exe and QNotch-self-contained.zip.');
    }
  } else if (!names.length || names.some(name => !/^QNotch-macos-(arm64|x64|universal)\.(dmg|zip)$/.test(name))) {
    throw new Error('Mac assets must be named QNotch-macos-{arm64,x64,universal}.{dmg,zip}.');
  }
}

export function validateLatest(policy, latest) {
  if (policy.platform !== 'windows' || latest === null) return;
  const previous = releasePolicy(latest.tag_name, 'windows');
  const nextParts = policy.version.split('.').map(Number);
  const previousParts = previous.version.split('.').map(Number);
  const difference = nextParts.map((n, i) => n - previousParts[i]).find(n => n !== 0) ?? 0;
  if (difference <= 0) throw new Error('Refusing to replace the Windows latest release with the same or an older version.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { values } = parseArgs({ options: { tag: { type: 'string' }, platform: { type: 'string' } } });
    const policy = releasePolicy(values.tag, values.platform);
    if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `version=${policy.version}\n`);
    console.log(JSON.stringify(policy));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
