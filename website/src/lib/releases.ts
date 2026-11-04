// What the download buttons and Other ways to install point at, checked once per build and shared by every page.

export const GH = 'https://github.com/Somafet/qnotch';
export const DL = `${GH}/releases/latest`;

const token = () => import.meta.env.GITHUB_TOKEN ?? process.env.GITHUB_TOKEN;
const github = (path: string) => fetch(`https://api.github.com/repos/${path}`, {
  headers: { accept: 'application/vnd.github+json', ...(token() ? { authorization: `Bearer ${token()}` } : {}) },
  signal: AbortSignal.timeout(8000),
});

// Mac downloads come from the newest stable macos-v* release. Never /releases/latest: that one is Windows.
// Resolved at build time; if GitHub can't be reached, the last known release still downloads.
const MAC_FALLBACK = { url: `${GH}/releases/download/macos-v0.1.1/QNotch-macos-arm64.dmg`, mb: 3 };
async function macDownload() {
  try {
    const res = await github('Somafet/qnotch/releases?per_page=40');
    if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
    const releases: { tag_name: string; draft: boolean; prerelease: boolean; assets: { name: string; size: number; browser_download_url: string }[] }[] = await res.json();
    for (const r of releases) {
      if (r.draft || r.prerelease || !/^macos-v\d+\.\d+\.\d+$/.test(r.tag_name)) continue;
      const dmg = r.assets.find(a => a.name === 'QNotch-macos-arm64.dmg');
      if (dmg) return { url: dmg.browser_download_url, mb: Math.max(1, Math.round(dmg.size / 1048576)) };
    }
    throw new Error('no stable Mac release with a disk image');
  } catch (e) {
    console.warn(`Mac download: using ${MAC_FALLBACK.url} (${(e as Error).message})`);
    return MAC_FALLBACK;
  }
}

// winget, Scoop and Chocolatey show up only once they carry QNotch, so every command on the site works.
// If a source can't be reached, the channel stays hidden until the next build.
async function liveOnGitHub(name: string, path: string) {
  try {
    const res = await github(path);
    if (res.ok) return true;
    if (res.status !== 404) throw new Error(`GitHub answered ${res.status}`);
    console.info(`${name}: not published yet, left out of Other ways to install`);
  } catch (e) {
    console.warn(`${name}: left out of Other ways to install (${(e as Error).message})`);
  }
  return false;
}
// The community feed lists a package only after moderators approve it, not while it waits for review.
async function liveOnChocolatey() {
  try {
    const res = await fetch("https://community.chocolatey.org/api/v2/FindPackagesById()?id='qnotch'&$top=1", {
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) throw new Error(`Chocolatey answered ${res.status}`);
    if ((await res.text()).includes('<entry')) return true;
    console.info('Chocolatey: not approved yet, left out of Other ways to install');
  } catch (e) {
    console.warn(`Chocolatey: left out of Other ways to install (${(e as Error).message})`);
  }
  return false;
}

let checked: ReturnType<typeof check> | undefined;
async function check() {
  const [mac, winget, scoop, chocolatey] = await Promise.all([
    macDownload(),
    liveOnGitHub('winget', 'microsoft/winget-pkgs/contents/manifests/s/Somafet/QNotch'),
    liveOnGitHub('Scoop', 'Somafet/scoop-bucket/contents/bucket/qnotch.json'),
    liveOnChocolatey(),
  ]);
  return { mac, winget, scoop, chocolatey };
}
export const releases = () => (checked ??= check());
