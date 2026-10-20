// Validates a --snapshot or --smoke-test output directory against spec/diagnostics.md, on either platform.
// Usage: node scripts/check-snapshots.mjs <dir>
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const ROLES = 'Button|Toggle|Tab|Field|SecureField|Slider|Progress|PopUp|Item|Link';
const QUOTED = String.raw`"(?:[^"\\\n]|\\[\\"nt])*"`;
const NUMBER = String.raw`\d+(?:\.\d{1,2})?`;
const TEXT_LINE = new RegExp(`^${QUOTED}$`);
const CONTROL_LINE = new RegExp(
    `^\\[(?:${ROLES})\\](?: ${QUOTED})?(?: #[a-z0-9][a-z0-9._-]*)?(?: (?:${NUMBER} of ${NUMBER}|value=${QUOTED}))?` +
    '(?: checked)?(?: selected)?(?: focused)?(?: disabled)?$');
const NAME = /^[a-z0-9][a-z0-9._-]*$/;
const PILL_STATES = ['peek', 'running', 'capture', 'waiting', 'agent', 'game'];
const STEPS = ['welcome', 'open', 'features', 'connect', 'finish'];
const REPORTS = ['snapshot.txt', 'smoke.txt'];

/** Returns the problems in one outline's text, each as "line N: …". */
export function checkOutline(text) {
    const problems = [];
    if (text.includes('\r')) problems.push('uses \\r line endings');
    let depth = 0;
    text.split('\n').forEach((line, i) => {
        if (line === '' && i === text.split('\n').length - 1) return; // trailing newline
        const indent = line.match(/^ */)[0].length;
        const body = line.slice(indent);
        if (indent % 2) problems.push(`line ${i + 1}: odd indentation`);
        else if (indent / 2 > depth + 1 || (i === 0 && indent)) problems.push(`line ${i + 1}: indented more than one level past its parent`);
        else if (!TEXT_LINE.test(body) && !CONTROL_LINE.test(body)) problems.push(`line ${i + 1}: not a text or control line: ${body}`);
        depth = indent / 2;
    });
    return problems;
}

/** Returns every problem in a snapshot or smoke directory; empty when it passes. */
export function checkDirectory(dir) {
    const problems = [];
    const files = readdirSync(dir);
    const report = REPORTS.find(r => files.includes(r));
    if (!report) return [`no ${REPORTS.join(' or ')} in ${dir}`];

    const lines = readFileSync(join(dir, report), 'utf8').split(/\r?\n/);
    while (lines.length && lines.at(-1) === '') lines.pop();
    if (lines.at(-1) !== 'done') problems.push(`${report} does not end in done`);
    for (const line of lines.filter(l => l.startsWith('FAILED'))) problems.push(`${report}: ${line}`);
    const partial = lines.some(l => l.startsWith('only:'));

    const pngs = new Set(files.filter(f => f.endsWith('.png')).map(f => f.slice(0, -4)));
    const outlines = new Set(files.filter(f => f.endsWith('.txt') && !REPORTS.includes(f)).map(f => f.slice(0, -4)));
    for (const name of pngs) {
        if (!NAME.test(name)) problems.push(`${name}.png: name has characters outside a-z 0-9 . _ -`);
        if (!outlines.has(name)) problems.push(`${name}.png has no outline ${name}.txt`);
        const state = name.match(/^pill-(.+)$/)?.[1];
        if (state && !PILL_STATES.includes(state)) problems.push(`${name}.png: unknown pill state ${state}`);
        const step = name.match(/^onboarding-(.+)$/)?.[1];
        if (step && !STEPS.includes(step) && !step.includes('-')) problems.push(`${name}.png: unknown onboarding step ${step}`);
    }
    for (const name of outlines) {
        if (!pngs.has(name)) { problems.push(`${name}.txt has no ${name}.png (other text output uses .log)`); continue; }
        for (const p of checkOutline(readFileSync(join(dir, name + '.txt'), 'utf8'))) problems.push(`${name}.txt ${p}`);
    }
    if (!partial) {
        for (const name of ['pill', 'tab-home', 'tab-home-edit', ...STEPS.map(s => 'onboarding-' + s)])
            if (!pngs.has(name)) problems.push(`required view ${name}.png is missing`);
        if (![...pngs].some(n => n.startsWith('settings-'))) problems.push('no settings-*.png');
    }
    return problems;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
    const dir = process.argv[2];
    if (!dir || !existsSync(dir)) {
        console.error('Usage: node scripts/check-snapshots.mjs <snapshot or smoke directory>');
        process.exit(2);
    }
    const problems = checkDirectory(dir);
    for (const p of problems) console.error(p);
    if (problems.length) process.exit(1);
    console.log(`${dir}: ok`);
}
