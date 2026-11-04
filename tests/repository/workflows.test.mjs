import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import test from 'node:test';
import { parseDocument } from 'yaml';
import { affectedPlatforms, outputs } from '../../scripts/ci-platforms.mjs';

const root = resolve(import.meta.dirname, '../..');
function yaml(path) {
  const document = parseDocument(readFileSync(resolve(root, path), 'utf8'), { uniqueKeys: true });
  assert.deepEqual(document.errors, [], path);
  return document.toJS();
}

const PLATFORM_JOBS = ['windows', 'macos'];

test('the required build check waits for every independent job, including failure or cancellation', () => {
  const ci = yaml('.github/workflows/ci.yml');
  assert.ok(Object.hasOwn(ci.on, 'pull_request'));
  assert.deepEqual(ci.on.push.branches, ['main']);
  assert.ok(!ci.on.push.paths && !ci.on.pull_request?.paths && !ci.on.push['paths-ignore'] && !ci.on.pull_request?.['paths-ignore']);
  assert.equal(ci.jobs.build.name, 'build');
  assert.equal(ci.jobs.build.if, 'always()');
  const jobs = Object.keys(ci.jobs).filter(name => name !== 'build');
  assert.deepEqual([...ci.jobs.build.needs].sort(), jobs.sort());
  const gate = ci.jobs.build.steps[0];
  for (const job of jobs) {
    assert.equal(gate.env[`${job.toUpperCase()}_RESULT`], `\u0024{{ needs.${job}.result }}`);
    if (PLATFORM_JOBS.includes(job)) {
      // The only allowed skip: the changes job decided this platform is unaffected, and the gate checks that decision.
      assert.equal(ci.jobs[job].needs, 'changes');
      assert.equal(ci.jobs[job].if, `needs.changes.outputs.${job} == 'true'`);
      assert.equal(gate.env[`${job.toUpperCase()}_AFFECTED`], `\u0024{{ needs.changes.outputs.${job} }}`);
      assert.equal(ci.jobs.changes.outputs[job], `\u0024{{ steps.platforms.outputs.${job} }}`);
    } else {
      assert.ok(gate.run.includes(`test "\u0024${job.toUpperCase()}_RESULT" = success`));
      assert.ok(!ci.jobs[job].if, `Do not silently skip ${job} without updating the gate.`);
    }
  }
  const choose = ci.jobs.changes.steps.find(step => step.id === 'platforms');
  assert.equal(choose.shell, 'bash');
  assert.ok(choose.run.includes('git diff --name-only --no-renames HEAD^1 HEAD'));
  assert.ok(choose.run.includes('node scripts/ci-platforms.mjs --all'), 'Pushes to main run every platform.');
  assert.equal(ci.jobs.changes.steps[0].with['fetch-depth'], 2);
  assert.equal(ci.jobs.windows['runs-on'], 'windows-latest');
  const snapshot = ci.jobs.windows.steps.find(step => step.name === 'Snapshot smoke test');
  assert.equal(snapshot.env.DOTNET_DISABLE_GUI_ERRORS, '1');
  assert.ok(snapshot.run.includes('$p.ExitCode -ne 0'));
  assert.equal(ci.jobs.website.defaults.run['working-directory'], 'website');
});

test('the build gate accepts a skipped platform only when the changes job skipped it on purpose', () => {
  const gate = yaml('.github/workflows/ci.yml').jobs.build.steps[0];
  const passing = { CHANGES_RESULT: 'success', REPOSITORY_RESULT: 'success', WEBSITE_RESULT: 'success',
    WINDOWS_RESULT: 'success', WINDOWS_AFFECTED: 'true', MACOS_RESULT: 'success', MACOS_AFFECTED: 'true' };
  const passes = changes => {
    const result = spawnSync('bash', ['-e', '-c', gate.run], { env: { ...process.env, ...passing, ...changes }, encoding: 'utf8' });
    assert.equal(result.error, undefined);
    return result.status === 0;
  };
  assert.ok(passes({}));
  assert.ok(passes({ MACOS_RESULT: 'skipped', MACOS_AFFECTED: 'false' }));
  assert.ok(passes({ WINDOWS_RESULT: 'skipped', WINDOWS_AFFECTED: 'false', MACOS_RESULT: 'skipped', MACOS_AFFECTED: 'false' }));
  for (const result of ['failure', 'cancelled', 'skipped']) {
    assert.ok(!passes({ MACOS_RESULT: result }), `macos ${result} while affected`);
    assert.ok(!passes({ WINDOWS_RESULT: result }), `windows ${result} while affected`);
    assert.ok(!passes({ REPOSITORY_RESULT: result }), `repository ${result}`);
    assert.ok(!passes({ WEBSITE_RESULT: result }), `website ${result}`);
    assert.ok(!passes({ CHANGES_RESULT: result }), `changes ${result}`);
  }
  assert.ok(!passes({ MACOS_RESULT: 'failure', MACOS_AFFECTED: 'false' }));
  assert.ok(!passes({ MACOS_RESULT: 'cancelled', MACOS_AFFECTED: 'false' }));
  assert.ok(!passes({ MACOS_RESULT: 'skipped', MACOS_AFFECTED: '' }), 'A missing decision is not a deliberate skip.');
});

test('pull requests run the platforms their changes affect, and both for shared or unknown paths', () => {
  const run = (...paths) => affectedPlatforms(paths);
  const both = { windows: true, macos: true };
  assert.deepEqual(run('src/QNotch.Mac/Sources/QNotchMac/Application.swift'), { windows: false, macos: true });
  assert.deepEqual(run('scripts/macos/build.sh', 'docs/macos/README.md'), { windows: false, macos: true });
  assert.deepEqual(run('src/QNotch/App.xaml.cs', 'tests/QNotch.WindowsTests/Program.cs', 'docs/windows/development.md', 'QNotch.sln'),
    { windows: true, macos: false });
  assert.deepEqual(run('website/src/pages/index.astro', 'README.md', 'ARCHITECTURE.md', 'docs/releases.md'), { windows: false, macos: false });
  assert.deepEqual(run(), { windows: false, macos: false });
  // The Mac build copies the Windows weather icons.
  assert.deepEqual(run('src/QNotch/Modules/Weather/Icons/LICENSE'), both);
  for (const shared of ['.github/workflows/ci.yml', '.github/pull_request_template.md', 'scripts/check-snapshots.mjs', 'spec/diagnostics.md',
    'tests/fixtures/release-tags.json', 'tests/repository/workflows.test.mjs', 'package.json', 'artifacts/new/outline.txt', 'NEW.txt']) {
    assert.deepEqual(run(shared), both, shared);
  }
  assert.deepEqual(run('src/QNotch/App.xaml.cs', 'src/QNotch.Mac/Package.swift'), both);
  assert.equal(outputs({ windows: true, macos: false }), 'windows=true\nmacos=false\n');
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

test('Mac validation builds a real native app, runs regressions and UI smoke, checks its snapshots, without signing secrets or publishing', () => {
  const mac = yaml('.github/workflows/ci.yml').jobs.macos;
  assert.equal(mac['runs-on'], 'macos-15');
  const runs = mac.steps.filter(step => step.run).map(step => step.run);
  assert.deepEqual(runs, ['bash scripts/macos/build.sh', 'bash scripts/macos/test.sh', 'bash scripts/macos/smoke.sh',
    'node scripts/check-snapshots.mjs dist/macos/smoke']);
  assert.ok(mac.steps.some(step => step.uses?.startsWith('actions/setup-node@') && step.with['node-version'] === '24'));
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

test('Mac release workflow tests, signs, notarizes and publishes only through the guarded Mac channel', () => {
  const release = yaml('.github/workflows/release-macos.yml');
  assert.deepEqual(release.on.push.tags, ['macos-v*']);
  assert.equal(release.concurrency.group, 'qnotch-release');
  assert.equal(release.concurrency['cancel-in-progress'], false);
  assert.equal(release.permissions.contents, 'read');
  const job = release.jobs.release;
  assert.equal(job['runs-on'], 'macos-15');
  assert.equal(release.jobs.appcast['runs-on'], 'macos-15');
  assert.equal(job.if, "github.repository == 'Somafet/qnotch'");
  assert.equal(job.permissions.contents, 'write');
  const runs = job.steps.filter(step => step.run).map(step => step.run);
  const order = ['scripts/release-policy.mjs', 'npm test', 'scripts/macos/build.sh', 'scripts/macos/test.sh',
    'scripts/macos/smoke.sh', 'security import', 'scripts/macos/release.sh', 'scripts/publish-release.mjs']
    .map(text => runs.findIndex(run => run.includes(text)));
  assert.ok(order.every((index, i) => index >= 0 && (i === 0 || index > order[i - 1])), JSON.stringify(order));
  assert.ok(runs[order[0]].includes('--platform macos'));
  assert.ok(runs[order[7]].includes('--platform macos') && runs[order[7]].includes('QNotch-macos-arm64.dmg')
    && runs[order[7]].includes('QNotch-macos-arm64.zip'));
  const sign = job.steps.findIndex(step => step.id === 'update');
  assert.ok(sign > job.steps.findIndex(step => step.run?.includes('scripts/macos/release.sh')) && job.steps[sign].run.includes('check-key') && job.steps[sign].run.includes('--verify'));
  assert.ok(sign < job.steps.findIndex(step => step.run?.includes('scripts/publish-release.mjs')));
  assert.ok(!job.steps[sign].run.includes('GITHUB_TOKEN') && !job.steps[sign].env.GH_TOKEN);
  const secretSteps = job.steps.filter(step => JSON.stringify(step).includes('SPARKLE_PRIVATE_KEY')).map(step => step.id);
  assert.deepEqual(secretSteps, ['update']);
  assert.ok(!runs.some(run => run.includes('gh release create') || run.includes('gh release edit') || run.includes('--latest')));
  const cleanup = job.steps.at(-1);
  assert.equal(cleanup.if, 'always()');
  assert.ok(cleanup.run.includes('delete-keychain') && cleanup.run.includes('AuthKey.p8'));
  const script = readFileSync(resolve(root, 'scripts/macos/release.sh'), 'utf8');
  for (const text of ['--options runtime', '--timestamp', 'QNotch.entitlements', 'notarytool submit', 'stapler staple', 'spctl --assess',
    'Contents/Frameworks/Sparkle.framework', 'Versions/B/Autoupdate', 'Versions/B/Updater.app', 'QNotch-macos-arm64.zip']) {
    assert.ok(script.includes(text), text);
  }
  // Sparkle's helpers are signed before the app, and the update is zipped only after stapling.
  assert.ok(script.indexOf('Updater.app') < script.indexOf('--entitlements "$entitlements" "$app"'));
  assert.ok(script.indexOf('stapler staple "$app"') < script.indexOf('ditto -c -k --sequesterRsrc --keepParent "$app" "$update"'));
  const appcast = release.jobs.appcast;
  assert.equal(appcast.needs, 'release');
  assert.equal(appcast.if, "github.repository == 'Somafet/qnotch'");
  assert.equal(appcast.permissions.contents, 'write');
  const publish = appcast.steps.find(step => step.run?.includes('scripts/macos/publish-appcast.sh'));
  assert.equal(publish.env.SIGNATURE, '${{ needs.release.outputs.signature }}');
  assert.equal(publish.env.BUILD, '${{ github.run_number }}');
  const feed = readFileSync(resolve(root, 'scripts/macos/publish-appcast.sh'), 'utf8');
  for (const text of ['check-key', 'releases/tags/$tag', 'sign_update" --ed-key-file - "$feed"', '--verify "$feed"', 'branch=macos-appcast']) {
    assert.ok(feed.includes(text), text);
  }
  assert.ok(!feed.includes('releases/latest'));
  const entitlements = readFileSync(resolve(root, 'src/QNotch.Mac/QNotch.entitlements'), 'utf8');
  assert.ok(entitlements.includes('com.apple.security.automation.apple-events'));
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
