import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { checkDirectory, checkOutline } from '../../scripts/check-snapshots.mjs';

const outline = [
  '[Tab] "Home" #tab-home selected',
  '"Focus"',
  '[Button] "Start" #timer-start',
  '[Toggle] "Sounds" #timer-sounds checked disabled',
  '[Slider] "Volume" 40 of 100',
  '[Field] "Search" #search-field value="say \\"hi\\"" focused',
  '[Item] "Weather" #card-ai.usage selected',
  '  "Budapest"',
  '    "12°"',
  '  [Link] "yr.no"',
  '[SecureField] "Token"',
  '',
].join('\n');

function directory(views, report = ['version: 0.1.0', 'done']) {
  const dir = mkdtempSync(join(tmpdir(), 'qnotch-snapshots-'));
  for (const view of views) {
    writeFileSync(join(dir, view + '.png'), 'png');
    writeFileSync(join(dir, view + '.txt'), outline);
  }
  writeFileSync(join(dir, 'snapshot.txt'), report.join('\n') + '\n');
  return dir;
}

const required = ['pill', 'tab-home', 'tab-home-edit', 'settings-general',
  'onboarding-welcome', 'onboarding-open', 'onboarding-features', 'onboarding-connect', 'onboarding-finish'];

test('outline grammar accepts every documented line form', () => {
  assert.deepEqual(checkOutline(outline), []);
});

test('outline grammar rejects unknown roles, misplaced states, bad indentation and raw quotes', () => {
  for (const bad of ['[ToggleButton] "Sounds"', '[Button] "Start" disabled checked', '    "deep"',
    '[Button] "a"b"', ' "odd"', '[Button] #Tab_Home', 'plain text', '"x"\r\n']) {
    assert.notDeepEqual(checkOutline(bad), [], bad);
  }
  assert.notDeepEqual(checkOutline('"a"\n    "too deep"'), []);
});

test('a complete directory passes', () => {
  const dir = directory([...required, 'pill-peek', 'tab-timer', 'card-ai.usage', 'gamebar-corner']);
  try { assert.deepEqual(checkDirectory(dir), []); } finally { rmSync(dir, { recursive: true }); }
});

test('a report that failed or did not finish fails', () => {
  for (const report of [['version: 0.1.0'], ['FAILED: tab-media: missing', 'done']]) {
    const dir = directory(required, report);
    try { assert.notDeepEqual(checkDirectory(dir), []); } finally { rmSync(dir, { recursive: true }); }
  }
});

test('missing outlines, orphan outlines, unknown states and missing required views fail', () => {
  const dir = directory(required.filter(v => v !== 'tab-home-edit'));
  writeFileSync(join(dir, 'tab-ai.png'), 'png');
  writeFileSync(join(dir, 'placement.txt'), 'camera_housing=true');
  writeFileSync(join(dir, 'pill-sleeping.png'), 'png');
  writeFileSync(join(dir, 'pill-sleeping.txt'), outline);
  try {
    const problems = checkDirectory(dir).join('\n');
    assert.match(problems, /tab-ai\.png has no outline/);
    assert.match(problems, /placement\.txt has no placement\.png/);
    assert.match(problems, /unknown pill state sleeping/);
    assert.match(problems, /tab-home-edit\.png is missing/);
  } finally { rmSync(dir, { recursive: true }); }
});

test('an --only run does not require the full set', () => {
  const dir = directory(['tab-timer'], ['only: tab-*', 'tab-timer: ok', 'done']);
  try { assert.deepEqual(checkDirectory(dir), []); } finally { rmSync(dir, { recursive: true }); }
});
