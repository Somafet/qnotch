import { execFileSync } from 'node:child_process';
import { createReadStream, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { basename, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { maxWindowsAssetSize, releasePolicy, repository, validateAssetNames, validateLatest } from './release-policy.mjs';

function gh(args) {
  return execFileSync('gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

function getRelease(run, endpoint) {
  try { return JSON.parse(run(['api', `repos/${repository}/releases/${endpoint}`])); }
  catch (error) {
    // Only an actual 404 means there is no release. Authentication/rate-limit failures must stop publication.
    if (/\bHTTP 404\b/.test(String(error.stderr))) return null;
    throw error;
  }
}

async function describeAsset(path) {
  const size = statSync(path).size;
  if (size <= 0) throw new Error(`Empty release asset: ${basename(path)}`);
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return { path: resolve(path), name: basename(path), size, digest: `sha256:${hash.digest('hex')}` };
}

export function verifyUploadedRelease(release, policy, assets) {
  if (!release?.draft || release.tag_name !== policy.tag || release.prerelease !== policy.prerelease) {
    throw new Error('Expected a draft release with the matching tag and channel.');
  }
  validateAssetNames(policy, release.assets.map(asset => asset.name));
  for (const local of assets) {
    const remote = release.assets.find(asset => asset.name === local.name);
    const url = `https://github.com/${repository}/releases/download/${encodeURIComponent(policy.tag)}/${local.name}`;
    if (remote?.state !== 'uploaded' || remote.size !== local.size || remote.digest?.toLowerCase() !== local.digest
      || remote.browser_download_url !== url) throw new Error(`Uploaded asset verification failed: ${local.name}`);
  }
}

// The same entry point must be used by the future Mac workflow. Callers cannot override latest.
export async function publishRelease({ tag, platform, paths }, run = gh) {
  const policy = releasePolicy(tag, platform);
  validateAssetNames(policy, paths.map(path => basename(path)));
  const assets = await Promise.all(paths.map(describeAsset));
  if (platform === 'windows' && assets.some(asset => asset.size > maxWindowsAssetSize)) {
    throw new Error('A Windows asset exceeds the installed updater download limit.');
  }
  const latest = getRelease(run, 'latest');
  validateLatest(policy, latest);
  const existing = getRelease(run, `tags/${encodeURIComponent(tag)}`);
  if (existing && !existing.draft) throw new Error('Refusing to modify a published release.');
  if (existing) {
    run(['release', 'upload', tag, ...assets.map(asset => asset.path), '--repo', repository, '--clobber']);
  } else {
    const args = ['release', 'create', tag, ...assets.map(asset => asset.path), '--repo', repository,
      '--draft', '--latest=false', `--prerelease=${policy.prerelease}`, '--verify-tag', '--generate-notes',
      '--title', `QNotch ${platform === 'macos' ? 'macOS ' : ''}${policy.version}`];
    if (platform === 'windows' && latest) args.push('--notes-start-tag', latest.tag_name);
    run(args);
  }
  verifyUploadedRelease(getRelease(run, `tags/${encodeURIComponent(tag)}`), policy, assets);
  // Recheck immediately before promotion, including when resuming a failed draft upload.
  validateLatest(policy, getRelease(run, 'latest'));
  run(['release', 'edit', tag, '--repo', repository, '--draft=false', `--latest=${policy.latest}`,
    `--prerelease=${policy.prerelease}`]);
  const published = getRelease(run, `tags/${encodeURIComponent(tag)}`);
  if (!published || published.draft || published.prerelease !== policy.prerelease) throw new Error('Release was not published as requested.');
  const latestAfter = getRelease(run, 'latest');
  const expectedLatest = policy.latest ? tag : latest?.tag_name;
  if (latestAfter?.tag_name !== expectedLatest) throw new Error('The global latest release does not match the platform policy.');
  return policy;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { values } = parseArgs({ options: {
      tag: { type: 'string' }, platform: { type: 'string' }, asset: { type: 'string', multiple: true },
    } });
    if (process.env.GITHUB_REPOSITORY && process.env.GITHUB_REPOSITORY !== repository) throw new Error('Official release publishing is disabled in forks.');
    await publishRelease({ tag: values.tag, platform: values.platform, paths: values.asset ?? [] });
    console.log(`Published ${values.platform} release ${values.tag}.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
