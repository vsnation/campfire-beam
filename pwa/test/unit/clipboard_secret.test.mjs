// A key or code copied to the clipboard is taken out again (audit A-5): copyText left the owner
// key, the Ethereum private key and airdrop codes there for good, for every desktop program, the
// keyboard's clipboard history, Win+V (synced to the cloud) and Universal Clipboard. lib/ui.js
// copySecret (ported from the Firo wallet): emptied after a minute, when the page is back in front
// or at the next tap if the browser would not let it write before, and at the lock; only when it
// still holds the secret where the page can check; the toast says so. Only its hash is kept.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { copySecret, copyText, clearSecretClipboard, secretOnClipboard } from '../../src/lib/ui.js';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function env({ readable = false, focused = true } = {}) {
  const listeners = new Map();
  const on = (t, f) => listeners.set(t, [...(listeners.get(t) || []), f]);
  const off = (t, f) => listeners.set(t, (listeners.get(t) || []).filter((x) => x !== f));
  const fire = (t) => (listeners.get(t) || []).forEach((f) => f());
  const said = [];
  const e = {
    clip: null,
    focused,
    said,
    fire,
    count: () => [...listeners.values()].reduce((n, l) => n + l.length, 0),
    nav: {
      clipboard: {
        writeText: async (t) => {
          if (!e.focused) throw new Error('Document is not focused.');
          e.clip = t;
        },
        readText: async () => e.clip,
      },
      permissions: { query: async ({ name }) => ({ state: readable && name === 'clipboard-read' ? 'granted' : 'prompt' }) },
    },
    doc: { visibilityState: 'visible', addEventListener: on, removeEventListener: off },
    win: { addEventListener: on, removeEventListener: off },
    say: (m) => said.push(m),
  };
  return e;
}

test('emptied once due, and the toast says so; nothing is waiting afterwards', async () => {
  const e = env();
  assert.equal(await copySecret('OWNERKEY', 'Owner key copied', { clearMs: 30, nav: e.nav, doc: e.doc, win: e.win, say: e.say }), true);
  assert.equal(e.clip, 'OWNERKEY');
  assert.equal(e.said[0], 'Owner key copied. Beam PWA empties the clipboard in 1 minute (clipboard history apps may keep it).');
  assert.equal(secretOnClipboard(), true);
  await sleep(120);
  assert.equal(e.clip, '');
  assert.equal(secretOnClipboard(), false);
  assert.equal(e.count(), 0, 'every listener removed');
});

test('not in front when due (the browser refuses): emptied at the next tap', async () => {
  const e = env();
  await copySecret('ABCD-EFGH-JKLM-NPQR', 'Code copied', { clearMs: 20, nav: e.nav, doc: e.doc, win: e.win, say: e.say });
  e.focused = false;
  await sleep(80);
  assert.equal(e.clip, 'ABCD-EFGH-JKLM-NPQR', 'the write was refused while away');
  assert.equal(secretOnClipboard(), true);
  e.focused = true;
  e.fire('pointerdown');
  await sleep(10);
  assert.equal(e.clip, '');
  assert.equal(secretOnClipboard(), false);
});

test('where the page may read it: something copied since is left alone', async () => {
  const e = env({ readable: true });
  await copySecret('ABCD-EFGH-JKLM-NPQR', 'Code copied', { clearMs: 10, nav: e.nav, doc: e.doc, win: e.win, say: e.say });
  e.clip = 'an address the person copied since';
  await sleep(80);
  assert.equal(e.clip, 'an address the person copied since');
  assert.equal(secretOnClipboard(), false);
});

test('the lock empties it at once; a lock out of sight empties it at the next return, without the minute', async () => {
  const e = env();
  const app = { lockHooks: new Set() };
  await copySecret('0xKEY', 'Private key copied', { app, clearMs: 60000, nav: e.nav, doc: e.doc, win: e.win, say: e.say });
  assert.equal(app.lockHooks.size, 1);
  for (const f of app.lockHooks) f();
  await sleep(10);
  assert.equal(e.clip, '');
  assert.equal(app.lockHooks.size, 0);
  assert.equal(await clearSecretClipboard({ nav: e.nav }), true, 'nothing left to clear');
  // Out of sight when it locks: the browser refuses the write; back in front, it goes at once.
  await copySecret('0xKEY', 'Private key copied', { app, clearMs: 60000, nav: e.nav, doc: e.doc, win: e.win, say: e.say });
  e.focused = false;
  for (const f of app.lockHooks) f();
  await sleep(10);
  assert.equal(e.clip, '0xKEY');
  e.focused = true;
  e.fire('visibilitychange');
  await sleep(10);
  assert.equal(e.clip, '');
  assert.equal(secretOnClipboard(), false);
});

test('a copy that fails says so and leaves nothing waiting', async () => {
  const e = env({ focused: false });
  assert.equal(await copySecret('x', 'Code copied', { nav: e.nav, doc: e.doc, win: e.win, say: e.say }), false);
  assert.match(e.said[0], /Couldn't copy/);
  assert.equal(secretOnClipboard(), false);
  assert.equal(e.count(), 0);
});

test('the screens copy keys and codes with copySecret (and the lock clears them); no recovery word is ever copied', () => {
  for (const f of ['screens/owner_key.js', 'screens/eth_settings.js', 'screens/airdrop_codes.js']) {
    const t = readFileSync(join(src, f), 'utf8');
    assert.ok(/copySecret\([^)]*\{ app \}\)/.test(t), f);
    assert.ok(!/copyText\(/.test(t), f);
  }
  for (const f of ['screens/backup.js', 'screens/eth_words.js', 'screens/confirm_words.js']) assert.ok(!/copy(Text|Secret)\(|clipboard/.test(readFileSync(join(src, f), 'utf8')), f);
});

test('BM-5: something copied since (an address, with copyText) cancels the wipe: it is never emptied later', async () => {
  const e = env();
  await copySecret('OWNERKEY', 'Owner key copied', { clearMs: 30, nav: e.nav, doc: e.doc, win: e.win, say: e.say });
  assert.equal(secretOnClipboard(), true);
  assert.equal(await copyText('0x70997970C51812dc3A010C7d01b50e0d17dc79C8', 'Address copied', { nav: e.nav, say: e.say }), true);
  assert.equal(e.said.at(-1), 'Address copied');
  assert.equal(secretOnClipboard(), false, 'nothing waits to be emptied');
  assert.equal(e.count(), 0, 'every listener removed');
  await sleep(120);
  e.fire('pointerdown');
  assert.equal(e.clip, '0x70997970C51812dc3A010C7d01b50e0d17dc79C8', 'the address is still there to paste');
  // A copy that fails leaves the secret where it was: its wipe still runs.
  const f = env();
  await copySecret('CODE-1234', 'Code copied', { clearMs: 30, nav: f.nav, doc: f.doc, win: f.win, say: f.say });
  f.focused = false;
  assert.equal(await copyText('0xabc', 'Address copied', { nav: f.nav, say: f.say }), false);
  assert.equal(secretOnClipboard(), true);
  f.focused = true;
  await sleep(120);
  assert.equal(f.clip, '');
  assert.equal(secretOnClipboard(), false);
});
