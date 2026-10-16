import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import test from 'node:test';
import { parseDocument } from 'yaml';

const root = resolve(import.meta.dirname, '../..');
function yaml(path) {
  const document = parseDocument(readFileSync(resolve(root, path), 'utf8'), { uniqueKeys: true });
  assert.deepEqual(document.errors, [], path);
  return document.toJS();
}

test('the required build check waits for every independent job, including failure or cancellation', () => {
  const ci = yaml('.github/workflows/ci.yml');
  assert.ok(Object.hasOwn(ci.on, 'pull_request'));
  assert.deepEqual(ci.on.push.branches, ['main']);
  assert.ok(!ci.on.push.paths && !ci.on.pull_request?.paths);
  assert.equal(ci.jobs.build.name, 'build');
  assert.equal(ci.jobs.build.if, 'always()');
  const jobs = Object.keys(ci.jobs).filter(name => name !== 'build');
  assert.deepEqual([...ci.jobs.build.needs].sort(), jobs.sort());
  const gate = ci.jobs.build.steps[0];
  for (const job of jobs) {
    assert.equal(gate.env[`${job.toUpperCase()}_RESULT`], `\u0024{{ needs.${job}.result }}`);
    assert.ok(gate.run.includes(`test "\u0024${job.toUpperCase()}_RESULT" = success`));
    assert.ok(!ci.jobs[job].if, `Do not silently skip ${job} without updating the gate.`);
  }
  assert.equal(ci.jobs.windows['runs-on'], 'windows-latest');
  const snapshot = ci.jobs.windows.steps.find(step => step.name === 'Snapshot smoke test');
  assert.equal(snapshot.env.DOTNET_DISABLE_GUI_ERRORS, '1');
  assert.ok(snapshot.run.includes('$p.ExitCode -ne 0'));
  assert.equal(ci.jobs.website.defaults.run['working-directory'], 'website');
});

test('Windows release workflow validates tags and both packages before guarded publication', () => {
  const release = yaml('.github/workflows/release.yml');
  assert.deepEqual(release.on.push.tags, ['v*']);
  assert.equal(release.concurrency.group, 'qnotch-release');
  assert.equal(release.concurrency['cancel-in-progress'], false);
  assert.equal(release.permissions.contents, 'read');
  assert.equal(release.jobs.release.permissions.contents, 'write');
  const runs = release.jobs.release.steps.filter(step => step.run).map(step => step.run);
  const policy = runs.findIndex(run => run.includes('scripts/release-policy.mjs'));
  const publish = runs.findIndex(run => run.includes('dotnet publish'));
  const verify = runs.findIndex(run => run.includes('--verify-publish'));
  const promote = runs.findIndex(run => run.includes('scripts/publish-release.mjs'));
  assert.ok(policy >= 0 && publish > policy && verify > publish && promote > verify);
  assert.ok(runs[policy].includes('--platform windows'));
  assert.ok(runs[promote].includes('--platform windows'));
  assert.ok(!runs.some(run => run.includes('gh release create') || run.includes('gh release edit')));
  assert.ok(runs[publish].includes('win-x64-self-contained') && runs[publish].includes('dist/QNotch-self-contained.zip'));
  assert.ok(runs.some(run => run.includes('npm test')));
});

test('Mac validation builds a real native app, runs regressions and UI smoke, without signing secrets or publishing', () => {
  const mac = yaml('.github/workflows/ci.yml').jobs.macos;
  assert.equal(mac['runs-on'], 'macos-14');
  const runs = mac.steps.filter(step => step.run).map(step => step.run);
  assert.deepEqual(runs, ['bash scripts/macos/build.sh', 'bash scripts/macos/test.sh', 'bash scripts/macos/smoke.sh']);
  assert.ok(!JSON.stringify(mac).includes('secrets.'));
  assert.ok(!JSON.stringify(mac).includes('publish-release'));
  const artifact = mac.steps.find(step => step.uses?.startsWith('actions/upload-artifact@'));
  assert.equal(artifact.with.name, 'macos-smoke');
  assert.equal(artifact.with['if-no-files-found'], 'error');
  assert.ok(existsSync(resolve(root, 'src/QNotch.Mac/Package.swift')));
  assert.ok(existsSync(resolve(root, 'src/QNotch.Mac/Sources/QNotchMacApp/main.swift')));
  const build = readFileSync(resolve(root, 'scripts/macos/build.sh'), 'utf8');
  assert.ok(build.includes('-warnings-as-errors'));
  assert.ok(build.includes('--arch arm64'));
  assert.ok(!build.includes('dist/QNotch.exe'));
});

test('issue forms and labels are valid YAML and use existing managed label names', () => {
  const labels = yaml('.github/labels.yml').map(label => label.name);
  for (const path of ['.github/ISSUE_TEMPLATE/bug_report.yml', '.github/ISSUE_TEMPLATE/feature_request.yml']) {
    const form = yaml(path);
    for (const label of form.labels) assert.ok(labels.includes(label));
    assert.ok(form.body.some(field => field.id === 'platform'));
  }
});

test('relative Markdown file links resolve across the repository', () => {
  const paths = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '--', '*.md'],
    { cwd: root, encoding: 'utf8' }).trim().split(/\r?\n/).filter(Boolean);
  for (const path of paths) {
    const content = readFileSync(resolve(root, path), 'utf8').replace(/```[\s\S]*?```/g, '');
    for (const match of content.matchAll(/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
      const target = match[1].split('#')[0];
      if (!target || /^[a-z][a-z\d+.-]*:/i.test(target) || target.startsWith('/')) continue;
      assert.ok(existsSync(resolve(root, dirname(path), decodeURIComponent(target))), `${path}: ${target}`);
    }
  }
});
