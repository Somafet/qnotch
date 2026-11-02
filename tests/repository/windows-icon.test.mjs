import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);

test('Windows app embeds the multi-size brand icon', () => {
  const csproj = readFileSync(new URL('src/QNotch/QNotch.csproj', root), 'utf8');
  assert.match(csproj, /<ApplicationIcon>Assets[\\/]AppIcon\.ico<\/ApplicationIcon>/);

  const ico = readFileSync(new URL('src/QNotch/Assets/AppIcon.ico', root));
  assert.equal(ico.readUInt16LE(0), 0);
  assert.equal(ico.readUInt16LE(2), 1);
  const count = ico.readUInt16LE(4);
  const sizes = [];
  for (let i = 0; i < count; i++) {
    const entry = 6 + i * 16;
    const size = ico[entry] || 256;
    sizes.push(size);
    const offset = ico.readUInt32LE(entry + 12);
    const png = ico.subarray(offset, offset + 4).toString('latin1') === '\x89PNG';
    assert.equal(png, size === 256, `${size}px entry format`);
  }
  assert.deepEqual(sizes, [16, 20, 24, 32, 40, 48, 64, 128, 256]);
});
