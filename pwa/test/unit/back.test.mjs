// What system back means on a screen (lib/back.js).
import test from 'node:test';
import assert from 'node:assert/strict';
import { backAction } from '../../src/lib/back.js';

test('a sheet first, then the screen\'s own Back, then tabs to Wallet; only roots leave', () => {
  const btn = {};
  assert.equal(backAction({ overlays: [{}], backButton: btn, screenName: 'send' }), 'sheet');
  assert.equal(backAction({ overlays: [{}], backButton: null, screenName: 'home' }), 'sheet');
  assert.equal(backAction({ overlays: [], backButton: btn, screenName: 'about' }), 'button');
  assert.equal(backAction({ overlays: [], backButton: null, screenName: 'settings' }), 'home');
  assert.equal(backAction({ overlays: [], backButton: null, screenName: 'activity' }), 'home');
  for (const s of ['home', 'welcome', 'unlock']) assert.equal(backAction({ overlays: [], backButton: null, screenName: s }), 'leave');
  // A screen with no Back of its own (a payment's status, a setup step) stays put.
  for (const s of ['txStatus', 'install', 'fastStart', 'backup', 'problem']) assert.equal(backAction({ overlays: [], backButton: null, screenName: s }), 'stay');
});
