// A tiny zip writer for tests: stored or deflated entries, with knobs to
// produce the broken archives the reader must refuse.
import { deflateRawSync } from 'node:zlib';
import { crc32 } from '../../../src/lib/dapps/zip.js';

const u16 = (v) => [v & 0xff, (v >>> 8) & 0xff];
const u32 = (v) => [v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff];

/**
 * entries: [{name, data (Uint8Array|string), method: 0|8, flags, externalAttr, creator,
 *            crc (override), size (override), localName (override)}]
 */
export function makeZip(entries, { zip64Locator = false, countOverride = null } = {}) {
  const local = [];
  const central = [];
  let offset = 0;
  for (const e of entries) {
    const data = typeof e.data === 'string' ? new TextEncoder().encode(e.data) : e.data || new Uint8Array(0);
    const method = e.method ?? 8;
    const packed = method === 8 ? new Uint8Array(deflateRawSync(data)) : data;
    const name = new TextEncoder().encode(e.name);
    const lname = new TextEncoder().encode(e.localName ?? e.name);
    const crc = e.crc ?? crc32(data);
    const size = e.size ?? data.length;
    const flags = (e.flags ?? 0) | 0x0800;
    const lh = [...u32(0x04034b50), ...u16(20), ...u16(flags), ...u16(method), ...u16(0), ...u16(0), ...u32(crc), ...u32(packed.length), ...u32(size), ...u16(lname.length), ...u16(0), ...lname, ...packed];
    local.push(...lh);
    const creator = e.creator ?? 3;
    const ext = e.externalAttr ?? (e.name.endsWith('/') ? 0o040755 << 16 : 0o100644 << 16);
    central.push(...u32(0x02014b50), creator === null ? 20 : 20, creator, ...u16(20), ...u16(flags), ...u16(method), ...u16(0), ...u16(0), ...u32(crc), ...u32(packed.length), ...u32(size), ...u16(name.length), ...u16(0), ...u16(0), ...u16(0), ...u16(0), ...u32(ext >>> 0), ...u32(offset), ...name);
    offset += lh.length;
  }
  const count = countOverride ?? entries.length;
  const loc = zip64Locator ? [...u32(0x07064b50), ...u32(0), ...u32(0), ...u32(0), ...u32(1)] : [];
  const end = [...u32(0x06054b50), ...u16(0), ...u16(0), ...u16(count), ...u16(count), ...u32(central.length), ...u32(offset), ...u16(0)];
  return new Uint8Array([...local, ...central, ...loc, ...end]);
}
