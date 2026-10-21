// An iPhone Safari tab is told why and how to add BEAM Campfire to the Home Screen (owner,
// 2026-10-21): Safari deletes a site's data after 7 days without a visit; the Home Screen app keeps
// its data. Since iOS 26 Safari hides Share behind ••• (or ☰) next to the address, so step 1 says so.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { HOME_SCREEN_TEXT } from '../../src/screens/home_screen_guide.js';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');
const read = (f) => readFileSync(join(src, f), 'utf8');

test('the words: the reason first, then where Share is, Add to Home Screen, and where to open the wallet', () => {
  assert.match(HOME_SCREEN_TEXT.why, /7 days without a visit.*Home Screen app keeps its data/);
  assert.match(HOME_SCREEN_TEXT.share, /\{share\}.*\{more\} or \{menu\} next to the address/);
  assert.match(HOME_SCREEN_TEXT.add, /"Add to Home Screen".*"Open as Web App", leave it on/);
  assert.match(HOME_SCREEN_TEXT.open.start, /start your wallet there/);
  assert.match(HOME_SCREEN_TEXT.open.words, /with your 12 words/);
  assert.match(HOME_SCREEN_TEXT.open.file, /wallet\.db file/);
});

test('every language has every sentence, with the same placeholders', () => {
  const keys = [HOME_SCREEN_TEXT.title, HOME_SCREEN_TEXT.why, HOME_SCREEN_TEXT.notMoved, HOME_SCREEN_TEXT.share, HOME_SCREEN_TEXT.add, ...Object.values(HOME_SCREEN_TEXT.open), HOME_SCREEN_TEXT.showMe, HOME_SCREEN_TEXT.gotIt];
  for (const lang of ['ru', 'zh-Hans', 'ja']) {
    const cat = JSON.parse(read(`i18n/${lang}.json`));
    for (const k of keys) {
      assert.equal(typeof cat[k], 'string', `${lang}: ${k}`);
      assert.deepEqual((cat[k].match(/\{\w+\}/g) || []).sort(), (k.match(/\{\w+\}/g) || []).sort(), `${lang} placeholders: ${k}`);
    }
  }
});

test('wired: the setup screen shows the steps under the progress, Welcome and Home open them', () => {
  const install = read('screens/install.js');
  assert.match(install, /isIosSafariTab\(\)\s*\?\s*h\(/);
  assert.match(install, /homeScreenSteps\('start'\)/);
  assert.ok(install.indexOf('    tip,') < install.indexOf("This happens once. Keep this screen open."), 'the steps come before the setup notes');
  assert.match(read('screens/welcome.js'), /openHomeScreenGuide\('start'\)/);
  assert.match(read('screens/storage_warning.js'), /openHomeScreenGuide\(app\.record\.imported \? 'file' : 'words'\)/);
  assert.match(read('lib/icons.js'), /\n  menu: \[/);
});
