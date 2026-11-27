import assert from 'node:assert/strict';
import test from 'node:test';
import { pullUrl, submit, wingetPlan } from '../../scripts/winget-submit.mjs';

// Titles as the release workflow and the first manual submission wrote them on microsoft/winget-pkgs.
const open = [
  { number: 469477, title: 'New package: Somafet.QNotch version 0.8.4' },
  { number: 486453, title: 'New version: Somafet.QNotch v0.10.0' },
  { number: 489605, title: 'New version: Somafet.QNotch v0.11.0' },
  { number: 1, title: 'New version: Other.Somafet.QNotchy v9.9.9' },
];

test('winget submits a new version and supersedes the older open PRs', () => {
  assert.deepEqual(wingetPlan(open.slice(0, 2), '0.11.0'), { submit: true, supersede: [469477, 486453] });
});

test('winget skips a rerun whose version already has an open PR, and still supersedes the older ones', () => {
  assert.deepEqual(wingetPlan(open, '0.11.0'), { submit: false, current: 489605, supersede: [469477, 486453] });
});

test('winget compares versions numerically and ignores other packages', () => {
  assert.deepEqual(wingetPlan([open[1], open[3]], '0.9.2'), { submit: false, current: 486453, supersede: [] });
  assert.deepEqual(wingetPlan([open[0], open[1]], '0.9.2'), { submit: false, current: 486453, supersede: [469477] });
  assert.deepEqual(wingetPlan([open[3]], '0.12.0'), { submit: true, supersede: [] });
});

test('winget reads the new PR address from wingetcreate', () => {
  assert.equal(pullUrl('Pull request can be found here: https://github.com/microsoft/winget-pkgs/pull/491000\n'), 'https://github.com/microsoft/winget-pkgs/pull/491000');
  assert.equal(pullUrl('nothing'), undefined);
});

function fake(pulls, created = { status: 0, stdout: 'Pull request can be found here: https://github.com/microsoft/winget-pkgs/pull/491000\n' }, merged = []) {
  const calls = [];
  const run = args => {
    calls.push(args);
    if (args[0] === 'api' && !merged.some(version => args[1].endsWith(`/manifests/s/Somafet/QNotch/${version}`))) throw new Error('HTTP 404');
    return args[1] === 'list' ? JSON.stringify(pulls) : '';
  };
  const create = args => { calls.push(['wingetcreate', ...args]); return created; };
  return { calls, run, create };
}
const options = { version: '0.12.0', manifests: 'dist/package-managers/winget', wingetcreate: 'wingetcreate.exe', token: 't' };

test('winget submission closes superseded PRs with a link to the new one', () => {
  const { calls, run, create } = fake(open);
  assert.equal(submit(options, run, create), 0);
  assert.deepEqual(calls.find(c => c[0] === 'wingetcreate'), ['wingetcreate', 'submit', '--token', 't', '--prtitle', 'New version: Somafet.QNotch v0.12.0', 'dist/package-managers/winget']);
  assert.deepEqual(calls.filter(c => c[1] === 'close').map(c => [c[2], c.at(-1)]), [469477, 486453, 489605].map(n => [String(n), 'Superseded by https://github.com/microsoft/winget-pkgs/pull/491000.']));
});

test('winget submission leaves older PRs open when wingetcreate fails', () => {
  const { calls, run, create } = fake(open, { status: 1, stdout: '' });
  assert.equal(submit(options, run, create), 1);
  assert.equal(calls.filter(c => c[1] === 'close').length, 0);
});

test('winget rerun does not call wingetcreate, and retries closing older PRs against the open one', () => {
  const { calls, run, create } = fake(open);
  assert.equal(submit({ ...options, version: '0.11.0' }, run, create), 0);
  assert.equal(calls.some(c => c[0] === 'wingetcreate'), false);
  assert.deepEqual(calls.filter(c => c[1] === 'close').map(c => [c[2], c.at(-1)]), [469477, 486453].map(n => [String(n), 'Superseded by https://github.com/microsoft/winget-pkgs/pull/489605.']));
});

test('winget rerun after the version merged does nothing', () => {
  const { calls, run, create } = fake(open, undefined, ['0.12.0']);
  assert.equal(submit(options, run, create), 0);
  assert.deepEqual(calls, [['api', 'repos/microsoft/winget-pkgs/contents/manifests/s/Somafet/QNotch/0.12.0']]);
});

test('winget stops when it cannot tell whether the version merged', () => {
  const calls = [];
  const run = args => { calls.push(args); throw new Error('gh: Server Error (HTTP 502)'); };
  assert.throws(() => submit(options, run, () => assert.fail('wingetcreate must not run')), /HTTP 502/);
  assert.equal(calls.length, 1);
});

test('winget leaves older PRs open when wingetcreate prints no address', () => {
  const { calls, run, create } = fake(open, { status: 0, stdout: 'done' });
  assert.equal(submit(options, run, create), 0);
  assert.equal(calls.filter(c => c[1] === 'close').length, 0);
});
