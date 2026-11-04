// Chooses which platform jobs a pull request needs in CI (CONTRIBUTING.md, Build and check your change).
// Usage: node scripts/ci-platforms.mjs <changed-files.txt> | --all
// Prints windows=true|false and macos=true|false, one per line, for $GITHUB_OUTPUT.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const PLATFORMS = ['windows', 'macos'];

// First match wins. A path no rule matches runs both platforms, so a new or shared path is never left unchecked.
const RULES = [
  // The Mac build bundles these Windows weather icons.
  [/^src\/QNotch\/Modules\/Weather\/Icons\//, PLATFORMS],
  [/^(src\/QNotch\.Mac|scripts\/macos|docs\/macos)\//, ['macos']],
  [/^(src\/QNotch|tests\/QNotch\.[^/]+|docs\/windows)\/|^QNotch\.sln$/, ['windows']],
  // Read by neither app: the website, other guides and top-level Markdown.
  [/^(website|docs)\/|^[^/]+\.md$/, []],
];

/** Returns the platforms a set of changed repository paths affects. */
export function affectedPlatforms(paths) {
  const affected = new Set();
  for (const path of paths) {
    const rule = RULES.find(([pattern]) => pattern.test(path));
    for (const platform of rule ? rule[1] : PLATFORMS) affected.add(platform);
  }
  return Object.fromEntries(PLATFORMS.map(platform => [platform, affected.has(platform)]));
}

/** Formats the platforms as GitHub Actions step outputs. */
export function outputs(platforms) {
  return PLATFORMS.map(platform => `${platform}=${platforms[platform]}\n`).join('');
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [arg] = process.argv.slice(2);
  if (!arg) {
    console.error('Usage: node scripts/ci-platforms.mjs <changed-files.txt> | --all');
    process.exit(2);
  }
  const platforms = arg === '--all'
    ? Object.fromEntries(PLATFORMS.map(platform => [platform, true]))
    : affectedPlatforms(readFileSync(arg, 'utf8').split(/\r?\n/).filter(Boolean));
  process.stdout.write(outputs(platforms));
}
