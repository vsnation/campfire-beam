// A wallet is never created on an address other sites share (audit E-3): on <user>.github.io
// every Pages project of that user is one origin, so any of them could read the wallet's storage
// and use its passkeys. The Pages copy is an update source; pwa.buybeam.my is where the wallet is
// used. A wallet already on such a copy keeps working.
// Audit UPD-2: refusing restore and import too stranded web restores if pwa.buybeam.my is lost,
// and its only button sent people to that one hard-coded domain. Restore and import stay possible
// there behind an explicit warning; desktop and Android are named; the button says what to do if
// pwa.buybeam.my looks wrong. UPD-9: GitLab and Codeberg Pages share origins the same way.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isSharedOrigin, sharedOriginRefusal, HOME_HOST, HOME_URL, SHARED_TEXT } from '../../src/lib/shared_origin.js';
import { createWallet, importWallet, prepareImport } from '../../src/lib/session.js';

const pwa = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

test('which addresses are shared with other sites', () => {
  for (const h of ['vsnation.github.io', 'VSNATION.GITHUB.IO', 'vsnation.github.io.', 'someone-else.github.io', 'someone.gitlab.io', 'SOMEONE.GITLAB.IO.', 'someone.codeberg.page']) assert.equal(isSharedOrigin(h), true, h);
  for (const h of ['pwa.buybeam.my', 'wallet.example.org', 'localhost', '127.0.0.1', 'github.io.example.com', 'mygithub.io', 'mygitlab.io', 'codeberg.page.example.com', 'codeberg.org', '']) assert.equal(isSharedOrigin(h), false, h);
  assert.equal(HOME_HOST, 'pwa.buybeam.my');
  assert.equal(HOME_URL, 'https://pwa.buybeam.my/');
});

test('the rule: on a shared address Create is refused; Restore and Import only after the warning; elsewhere all go', () => {
  for (const host of ['vsnation.github.io', 'x.gitlab.io', 'x.codeberg.page']) {
    assert.equal(sharedOriginRefusal('create', false, host), 'shared_origin', host);
    assert.equal(sharedOriginRefusal('create', true, host), 'shared_origin', `${host}: no warning makes Create possible`);
    for (const kind of ['restore', 'import']) {
      assert.equal(sharedOriginRefusal(kind, false, host), 'shared_origin_unconfirmed', `${host} ${kind}`);
      assert.equal(sharedOriginRefusal(kind, true, host), null, `${host} ${kind} after the warning`);
    }
  }
  for (const kind of ['create', 'restore', 'import']) assert.equal(sharedOriginRefusal(kind, false, 'pwa.buybeam.my'), null, kind);
  assert.equal(sharedOriginRefusal('anything else', true, 'vsnation.github.io'), 'shared_origin', 'an unknown kind is treated as Create');
});

test('on a shared address: creating is refused, restoring and importing wait for the warning; nothing is touched first', async () => {
  const prev = globalThis.location;
  globalThis.location = { hostname: 'vsnation.github.io', href: 'https://vsnation.github.io/beam-campfire-pwa/' };
  try {
    const words = Array.from({ length: 12 }, () => 'abandon');
    const created = { setup: { mode: 'create', words: [...words] }, record: null, dbPass: null, wallet: {}, sharedOriginOk: true };
    await assert.rejects(createWallet(created, 'a long password'), (e) => e.code === 'shared_origin' && e.message.includes(HOME_HOST) && /desktop/.test(e.message));
    assert.deepEqual(created.setup.words, words, 'the words are left as they were: nothing ran');
    const app = { setup: { mode: 'restore', words: [...words] }, record: null, dbPass: null, wallet: {} };
    const unconfirmed = (e) => e.code === 'shared_origin_unconfirmed';
    await assert.rejects(createWallet(app, 'a long password'), unconfirmed);
    assert.deepEqual(app.setup.words, words, 'the words are left as they were: nothing ran');
    await assert.rejects(prepareImport({ setup: null, record: null }), unconfirmed);
    await assert.rejects(importWallet({ setup: null, record: null }, 'a long password'), unconfirmed);
    // After the warning, the guard lets them through to the next check (here: no 12 words / a wallet exists).
    const short = { setup: { mode: 'restore', words: words.slice(0, 11) }, record: null, dbPass: null, wallet: {}, sharedOriginOk: true };
    await assert.rejects(createWallet(short, 'a long password'), /No recovery words/);
    await assert.rejects(prepareImport({ setup: null, record: { id: 'x' }, sharedOriginOk: true }), (e) => e.code === 'exists');
  } finally {
    if (prev === undefined) delete globalThis.location;
    else globalThis.location = prev;
  }
});

test('the shared-address screen: why, the way on, the warning, and the other places the words open', () => {
  const host = 'vsnation.github.io';
  assert.match(SHARED_TEXT.why(host), /vsnation\.github\.io/);
  assert.match(SHARED_TEXT.why(host), /other websites share/);
  assert.equal(SHARED_TEXT.go, `Go to ${HOME_HOST}`);
  assert.equal(SHARED_TEXT.unexpected, "If pwa.buybeam.my shows anything unexpected, don't enter your words there.");
  assert.match(SHARED_TEXT.elsewhere, /BEAM Campfire for desktop and Android/);
  assert.match(SHARED_TEXT.elsewhere, /any other BEAM wallet/);
  for (const kind of ['restore', 'import']) {
    assert.ok(SHARED_TEXT.warnTitle[kind] && SHARED_TEXT.confirm[kind], kind);
    assert.match(SHARED_TEXT.warn(host, kind), /vsnation\.github\.io/);
    assert.match(SHARED_TEXT.warn(host, kind), /shared with other websites|other websites/);
  }
  assert.match(SHARED_TEXT.warnWhen, /desktop and Android/);
  const all = JSON.stringify(SHARED_TEXT) + SHARED_TEXT.why(host) + SHARED_TEXT.warn(host, 'restore') + SHARED_TEXT.warn(host, 'import');
  assert.ok(!/\bsubmit\b|\borigin\b|passkey/i.test(all), 'plain words: no "origin" or "passkey" on screen');
});

test('the READMEs name pwa.buybeam.my as the place to use the wallet; the Pages copy only as an update source', () => {
  for (const f of [join(pwa, '..', 'README.md'), join(pwa, 'deploy', 'hosting_README.md')]) {
    const s = readFileSync(f, 'utf8');
    assert.ok(s.includes('https://pwa.buybeam.my/'), `${f}: names the address`);
    for (const line of s.split('\n').filter((l) => l.includes('vsnation.github.io'))) {
      assert.match(line, /update/i, `${f}: the Pages copy is mentioned only as an update source: ${line}`);
      assert.ok(!/open it|open https:\/\/vsnation|^\*\*open/i.test(line), `${f}: never as a place to open: ${line}`);
    }
  }
});
