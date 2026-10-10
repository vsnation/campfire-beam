// The snapshot download carries on after an interruption instead of starting
// the 330 MB again (a phone that slept, a network that changed).
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { downloadRecovery } from '../../src/lib/recovery.js';

const SIZE = 3 * 1024 * 1024 + 17;
const DATA = new Uint8Array(randomBytes(SIZE));
const ETAG = '"snap-1"';
const fast = { pauseMs: 1, whenVisible: async () => {} };

/** A stream of `bytes` in 64 KB chunks that errors after `cutAt` bytes (if given). */
function stream(bytes, cutAt = null) {
  let off = 0;
  return new ReadableStream({
    pull(c) {
      if (cutAt != null && off >= cutAt) return c.error(new TypeError('network connection was lost'));
      const end = Math.min(off + 65536, bytes.length, cutAt ?? Infinity);
      c.enqueue(bytes.slice(off, end));
      off = end;
      if (off >= bytes.length) c.close();
    },
  });
}

/** A fake host: ranges honoured unless noRanges; cuts[] applied to successive answers. */
function host({ noRanges = false, cuts = [], etag = ETAG, data = DATA, failStatus = null } = {}) {
  const asked = [];
  let n = 0;
  const fetchImpl = async (_url, { headers = {} } = {}) => {
    const range = headers.Range;
    asked.push({ range: range || null, ifRange: headers['If-Range'] || null });
    const cut = cuts[n++] ?? null;
    if (failStatus && n > 1) return new Response('busy', { status: failStatus });
    if (range && !noRanges && (!headers['If-Range'] || headers['If-Range'] === etag)) {
      const from = Number(/bytes=(\d+)-/.exec(range)[1]);
      const part = data.slice(from);
      return new Response(stream(part, cut), { status: 206, headers: { 'Content-Length': String(part.length), 'Content-Range': `bytes ${from}-${data.length - 1}/${data.length}`, ETag: etag } });
    }
    return new Response(stream(data, cut), { status: 200, headers: { 'Content-Length': String(data.length), ETag: etag, 'Content-Type': 'application/octet-stream' } });
  };
  return { fetchImpl, asked };
}

test('cut twice, it resumes with Range and If-Range, and every byte is right', async () => {
  const h = host({ cuts: [1_000_000, 900_000] });
  const buf = await downloadRecovery(null, null, { fetchImpl: h.fetchImpl, ...fast });
  assert.equal(buf.length, SIZE);
  assert.deepEqual(Buffer.from(buf), Buffer.from(DATA));
  assert.equal(h.asked.length, 3);
  assert.equal(h.asked[0].range, null);
  assert.match(h.asked[1].range, /^bytes=\d+-$/);
  assert.equal(h.asked[1].ifRange, ETAG);
  assert.ok(Number(/=(\d+)-/.exec(h.asked[2].range)[1]) > Number(/=(\d+)-/.exec(h.asked[1].range)[1]), 'the second resume starts further on');
});

test('a host without ranges sends it whole again: the download starts over and completes', async () => {
  const h = host({ noRanges: true, cuts: [2_000_000] });
  const buf = await downloadRecovery(null, null, { fetchImpl: h.fetchImpl, ...fast });
  assert.deepEqual(Buffer.from(buf), Buffer.from(DATA));
  assert.equal(h.asked.length, 2);
});

test('a new snapshot of another size during the download: a plain message, nothing half-read is returned', async () => {
  const other = new Uint8Array(randomBytes(SIZE + 5));
  let first = true;
  const fetchImpl = async () => {
    if (first) {
      first = false;
      return new Response(stream(DATA, 500_000), { status: 200, headers: { 'Content-Length': String(SIZE), ETag: ETAG } });
    }
    return new Response(stream(other), { status: 200, headers: { 'Content-Length': String(other.length), ETag: '"snap-2"' } });
  };
  await assert.rejects(downloadRecovery(null, null, { fetchImpl, ...fast }), (e) => e.code === 'network' && /new snapshot/.test(e.message));
});

test('it gives up after the retries, with the usual message', async () => {
  const h = host({ cuts: [400_000, 0, 0, 0] });
  await assert.rejects(downloadRecovery(null, null, { fetchImpl: h.fetchImpl, retries: 3, ...fast }), (e) => e.code === 'network' && /interrupted/.test(e.message));
  assert.equal(h.asked.length, 4);
});

test('a server error on resume is retried, then reported', async () => {
  const h = host({ cuts: [400_000], failStatus: 503 });
  await assert.rejects(downloadRecovery(null, null, { fetchImpl: h.fetchImpl, retries: 2, ...fast }), (e) => e.code === 'network');
  assert.equal(h.asked.length, 3);
});

test('Stop during a resume pause stops it', async () => {
  const h = host({ cuts: [400_000] });
  const ctl = new AbortController();
  const p = downloadRecovery(null, ctl.signal, { fetchImpl: h.fetchImpl, pauseMs: 200, whenVisible: async () => {} });
  setTimeout(() => ctl.abort(), 50);
  await assert.rejects(p, (e) => e.code === 'aborted');
});

test('progress reaches the total', async () => {
  const h = host({ cuts: [1_500_000] });
  let lastDone = 0;
  await downloadRecovery((d, t) => {
    assert.equal(t, SIZE);
    lastDone = d;
  }, null, { fetchImpl: h.fetchImpl, ...fast });
  assert.equal(lastDone, SIZE);
});
