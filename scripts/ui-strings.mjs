// Interface strings of the Windows app (spec/localization.md).
// Extracts every marked English text from src/QNotch and compares it with each catalog in src/QNotch/Localization/.
//   node scripts/ui-strings.mjs           check: every text has a non-empty translation with the same placeholders (exit 1 if not)
//   node scripts/ui-strings.mjs --sync    add missing texts with an empty translation, drop unused ones, sort the catalogs
//   node scripts/ui-strings.mjs --list    print every extracted text
// Marked text: string literals in L.T("..."), L.F("...", ...) and L.N("...") in C#, {core:T '...'} in XAML.
// L.T(value) with a variable translates at run time; mark each possible value where it is written with L.N.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(fileURLToPath(new URL('.', import.meta.url)), '..');
export const SOURCE = join(ROOT, 'src', 'QNotch');
export const CATALOGS = join(SOURCE, 'Localization');

const CS_CALL = /\bL\.([TFN])\(\s*(\$?@?)"((?:[^"\\\n]|\\.)*)"/g;
const XAML_CALL = /\{core:T\s+(?:Text=)?'((?:[^'\\]|\\.)*)'\s*\}/g;

function unescapeCs(text) {
    return text.replace(/\\(u[0-9a-fA-F]{4}|.)/g, (_, c) =>
        c[0] === 'u' ? String.fromCharCode(parseInt(c.slice(1), 16)) : ({ n: '\n', t: '\t', r: '\r', '0': '\0' })[c] ?? c);
}

function* files(dir) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (entry.isDirectory()) { if (!['obj', 'bin'].includes(entry.name)) yield* files(join(dir, entry.name)); }
        else if (/\.(cs|xaml)$/.test(entry.name)) yield join(dir, entry.name);
    }
}

/** Every marked text in the source, with where it was first seen. */
export function extract(root = SOURCE) {
    const texts = new Map();
    const problems = [];
    for (const file of files(root)) {
        const source = readFileSync(file, 'utf8');
        const where = (index) => `${relative(ROOT, file).replaceAll('\\', '/')}:${source.slice(0, index).split('\n').length}`;
        const add = (text, index) => { if (!texts.has(text)) texts.set(text, where(index)); };
        if (file.endsWith('.xaml')) {
            for (const m of source.matchAll(XAML_CALL)) add(m[1].replace(/\\(.)/g, '$1'), m.index);
            continue;
        }
        for (const m of source.matchAll(CS_CALL)) {
            if (m[2].includes('$')) { problems.push(`${where(m.index)}: interpolated text cannot be translated, use L.F("... {0} ...", value)`); continue; }
            add(m[2] === '@' ? m[3].replaceAll('""', '"') : unescapeCs(m[3]), m.index);
        }
    }
    return { texts, problems };
}

const placeholders = (text) => [...text.matchAll(/\{\d+(?:[:,][^}]*)?\}/g)].map((m) => m[0].replace(/[:,].*$/, '}')).sort();

export function readCatalogs(dir = CATALOGS) {
    return readdirSync(dir).filter((f) => f.endsWith('.json')).map((f) => ({ file: join(dir, f), ...JSON.parse(readFileSync(join(dir, f), 'utf8')) }));
}

/** The problems of one catalog against the extracted texts. */
export function checkCatalog(catalog, texts) {
    const problems = [];
    const name = relative(ROOT, catalog.file).replaceAll('\\', '/');
    for (const [text, where] of texts) {
        const translated = catalog.strings[text];
        if (translated === undefined) problems.push(`${name}: missing ${JSON.stringify(text)} (${where})`);
        else if (translated.trim() === '') problems.push(`${name}: untranslated ${JSON.stringify(text)} (${where})`);
        else if (placeholders(translated).join() !== placeholders(text).join()) problems.push(`${name}: placeholders differ in ${JSON.stringify(text)}`);
    }
    for (const text of Object.keys(catalog.strings)) if (!texts.has(text)) problems.push(`${name}: unused ${JSON.stringify(text)}`);
    return problems;
}

export function sync(catalog, texts) {
    const strings = {};
    for (const text of [...texts.keys()].sort((a, b) => a.localeCompare(b, 'en'))) strings[text] = catalog.strings[text] ?? '';
    writeFileSync(catalog.file, JSON.stringify({ code: catalog.code, name: catalog.name, strings }, null, 2) + '\n');
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
    const { texts, problems } = extract();
    if (process.argv.includes('--list')) { for (const text of texts.keys()) console.log(JSON.stringify(text)); process.exit(0); }
    const catalogs = readCatalogs();
    if (process.argv.includes('--sync')) for (const catalog of catalogs) sync(catalog, texts);
    const all = [...problems, ...readCatalogs().flatMap((c) => checkCatalog(c, texts))];
    for (const p of all) console.log(p);
    console.log(`${texts.size} texts, ${catalogs.length} catalog(s), ${all.length} problem(s)`);
    process.exit(all.length ? 1 : 0);
}
