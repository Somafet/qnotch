import { execFileSync, spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { wingetId } from './package-managers.mjs';
import { releasePolicy } from './release-policy.mjs';

// Keeps one open winget-pkgs pull request for QNotch at a time. Until the first one merges, every release opens
// another "new package" PR, and a rerun of the package-managers job would open a duplicate of its own version.
const upstream = 'microsoft/winget-pkgs';
const titleVersion = new RegExp(`\\b${wingetId.replace('.', '\\.')} (?:version |v)(\\d+\\.\\d+\\.\\d+)\\b`);

const parts = version => version.split('.').map(Number);
function compare(a, b) {
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}

// openPulls: this account's open PRs on winget-pkgs, as { number, title }. Submits only when none already carries
// this version or a newer one. The open PRs for older versions are closed in favour of the new or existing one,
// so a rerun also retries a cleanup that failed.
export function wingetPlan(openPulls, version) {
  const ours = openPulls
    .map(pull => ({ ...pull, version: titleVersion.exec(pull.title)?.[1] }))
    .filter(pull => pull.version);
  const current = ours.find(pull => compare(pull.version, version) >= 0);
  const supersede = ours.filter(pull => compare(pull.version, version) < 0).map(pull => pull.number);
  return current ? { submit: false, current: current.number, supersede } : { submit: true, supersede };
}

export function pullUrl(output) {
  return /https:\/\/github\.com\/microsoft\/winget-pkgs\/pull\/\d+/.exec(output)?.[0];
}

export function submit({ version, manifests, wingetcreate, token }, run = args => execFileSync('gh', args, {
  encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, GH_TOKEN: token },
}), create = args => spawnSync(wingetcreate, args, { encoding: 'utf8' })) {
  try {
    run(['api', `repos/${upstream}/contents/manifests/${wingetId[0].toLowerCase()}/${wingetId.replace('.', '/')}/${version}`]);
    console.log(`${wingetId} ${version} is already in winget-pkgs; skipped the winget submission.`);
    return 0;
  } catch (error) {
    if (!/HTTP 404/.test(error.message)) throw error; // Only a 404 means not merged yet; anything else may hide a merge.
  }
  const open = JSON.parse(run(['pr', 'list', '-R', upstream, '--author', '@me', '--state', 'open', '--search', `${wingetId} in:title`, '--json', 'number,title']));
  const plan = wingetPlan(open, version);
  let url = `https://github.com/${upstream}/pull/${plan.current}`;
  if (plan.submit) {
    const result = create(['submit', '--token', token, '--prtitle', `New version: ${wingetId} v${version}`, manifests]);
    process.stdout.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    if (result.status !== 0) return result.status ?? 1;
    url = pullUrl(result.stdout ?? '');
  } else {
    console.log(`::warning::winget-pkgs#${plan.current} already submits ${wingetId} ${version} or newer; skipped the winget submission.`);
  }
  if (plan.supersede.length && !url) {
    console.log(`::warning::wingetcreate printed no pull request address; left winget-pkgs#${plan.supersede.join(', #')} open.`);
    return 0;
  }
  for (const number of plan.supersede) {
    try {
      run(['pr', 'close', String(number), '-R', upstream, '--comment', `Superseded by ${url}.`]);
      console.log(`Closed winget-pkgs#${number}, superseded by ${version}.`);
    } catch (error) {
      console.log(`::warning::Could not close winget-pkgs#${number}: ${error.message.split('\n')[0]}`);
    }
  }
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { values } = parseArgs({ options: { tag: { type: 'string' }, manifests: { type: 'string' }, wingetcreate: { type: 'string' } } });
    if (!values.manifests || !values.wingetcreate) throw new Error('--tag, --manifests and --wingetcreate are required.');
    if (!process.env.WINGET_TOKEN) throw new Error('WINGET_TOKEN is not set.');
    const { version } = releasePolicy(values.tag, 'windows');
    process.exitCode = submit({ version, manifests: values.manifests, wingetcreate: values.wingetcreate, token: process.env.WINGET_TOKEN });
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
