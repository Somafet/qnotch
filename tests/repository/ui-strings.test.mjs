import assert from 'node:assert/strict';
import test from 'node:test';
import { checkCatalog, extract, readCatalogs } from '../../scripts/ui-strings.mjs';

test('every interface text of the Windows app is marked readably and translated in every catalog', () => {
    const { texts, problems } = extract();
    assert.ok(texts.size > 0);
    const catalogs = readCatalogs();
    assert.ok(catalogs.some((c) => c.code === 'it'));
    assert.deepEqual([...problems, ...catalogs.flatMap((c) => checkCatalog(c, texts))], []);
});
