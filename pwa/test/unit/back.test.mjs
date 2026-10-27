// What system back means on a screen (lib/back.js), and what it does to the browser's history.
import test from 'node:test';
import assert from 'node:assert/strict';
import { backAction, stepsFor, entriesUnder, installBack } from '../../src/lib/back.js';
import { navHistory } from '../../src/lib/nav.js';

test('a sheet first, then a layer, then the screen\'s own Back, then tabs to Wallet; every other screen stays', () => {
  const btn = {};
  assert.equal(backAction({ overlays: [{}], backButton: btn, screenName: 'send' }), 'sheet');
  assert.equal(backAction({ overlays: [{}], backButton: null, screenName: 'home' }), 'sheet');
  assert.equal(backAction({ overlays: [{}], layerBack: btn, backButton: btn, screenName: 'bridge' }), 'sheet');
  assert.equal(backAction({ overlays: [], layerBack: btn, backButton: btn, screenName: 'bridge' }), 'layer');
  assert.equal(backAction({ overlays: [], backButton: btn, screenName: 'about' }), 'button');
  assert.equal(backAction({ overlays: [], backButton: btn, screenName: 'ethStart' }), 'button');
  for (const s of ['settings', 'activity', 'ethHome', 'ethStart']) assert.equal(backAction({ overlays: [], backButton: null, screenName: s }), 'home', s);
  // Wallet, Welcome and Unlock are the first entry; a screen with no Back of its own (a payment's
  // status, a setup step) stays put.
  for (const s of ['home', 'welcome', 'unlock', 'txStatus', 'install', 'fastStart', 'backup', 'problem']) assert.equal(backAction({ overlays: [], backButton: null, screenName: s }), 'stay', s);
});

test('the steps above the first entry: Wallet under a tab, each screen Back returns through, a layer, each sheet', () => {
  assert.equal(stepsFor({ name: 'home' }), 0);
  assert.equal(stepsFor({ name: 'unlock' }), 0);
  assert.equal(stepsFor({ name: 'settings' }), 1);
  assert.equal(stepsFor({ name: 'ethStart' }), 1, 'the Ethereum side itself');
  assert.equal(stepsFor({ name: 'ethStart', params: { from: 'settings' }, trail: [{ name: 'settings' }] }), 2, 'a step of Settings');
  assert.equal(stepsFor({ name: 'send', trail: [{ name: 'home' }] }), 1);
  assert.equal(stepsFor({ name: 'about', trail: [{ name: 'settings' }] }), 2);
  assert.equal(stepsFor({ name: 'ownNode', trail: [{ name: 'settings' }, { name: 'nodeSettings' }], layer: true, sheets: 2 }), 6);
});

test('entries under the page: in a Home Screen app any; in a tab an earlier page of this app, by the Navigation API', () => {
  const win = (o) => ({ history: { length: 3 }, matchMedia: () => ({ matches: false }), ...o });
  assert.equal(entriesUnder(win({ navigation: { currentEntry: { index: 2 } } })), true);
  assert.equal(entriesUnder(win({ navigation: { currentEntry: { index: 0 } } })), false, 'the pages before are other sites');
  assert.equal(entriesUnder(win({})), false, 'no Navigation API: a Back leaves, as in any site');
  assert.equal(entriesUnder(win({ navigator: { standalone: true } })), true);
  assert.equal(entriesUnder(win({ navigator: { standalone: true }, navigation: { currentEntry: { index: 0 } } })), true);
  assert.equal(entriesUnder(win({ matchMedia: (q) => ({ matches: q === '(display-mode: standalone)' }) })), true);
  assert.equal(entriesUnder(win({ navigator: { standalone: true }, history: { length: 1 } })), false, 'opened from its icon: nothing under it');
});

/**
 * A browser and an app, with just what installBack touches. The history is the browser's: entries
 * of other pages, this page's own, then what the app adds; traversals arrive later (settle()), as
 * in a browser. Like Safari, each entry keeps a picture of what was painted when it was left, and
 * a swipe shows the picture of the entry it goes to.
 */
function world({ before = 1, standalone = false, navigationApi = false, fallback = {} } = {}) {
  const on = {};
  const observers = [];
  const entries = [...Array.from({ length: before }, (_, i) => ({ page: `before ${i}`, state: null })), { page: 'app', state: null }];
  let idx = before;
  let left = false;
  const queue = [];
  const later = []; // what runs after the next frame
  let painted = null;
  const nav = navHistory();
  const ui = { overlays: [], layer: null, loading: false };
  const shown = () => (app.currentName || '') + (ui.layer ? '+layer' : '') + '+sheet'.repeat(ui.overlays.length);
  const mutate = () => observers.forEach((f) => f([]));
  const fire = (t) => [...(on[t] || [])].forEach((f) => f({}));
  const arrive = (i) => {
    entries[idx].picture = painted;
    idx = i;
    if (entries[idx].page === 'app') fire('popstate');
    else left = true;
  };
  const app = {
    currentName: null,
    params: {},
    current: null,
    nav,
    go(name, params = {}, opts = {}) {
      nav.move(this.currentName ? { name: this.currentName, params: this.params } : null, { name, params }, opts);
      ui.overlays = [];
      ui.layer = null;
      this.currentName = name;
      this.params = params;
      this.current = {};
      mutate();
    },
    back(f = 'home') {
      const t = nav.backTarget(f);
      this.go(t.name, t.params, t.opts);
    },
  };
  const backButton = () => (fallback[app.currentName] ? { click: () => app.back(fallback[app.currentName]) } : null);
  const win = {
    history: {
      get state() {
        return entries[idx].state;
      },
      get length() {
        return entries.length;
      },
      pushState(state) {
        entries[idx].picture = painted;
        entries.splice(idx + 1);
        entries.push({ page: 'app', state });
        idx++;
      },
      replaceState(state) {
        entries[idx].state = state;
      },
      go(d) {
        queue.push(d);
      },
    },
    navigator: { standalone },
    matchMedia: () => ({ matches: false }),
    // The pages before are this site's (an earlier page of the app).
    navigation: navigationApi ? { currentEntry: { index: before } } : undefined,
    requestAnimationFrame: (f) => f(),
    setTimeout: (f) => later.push(f),
    document: {
      body: {},
      querySelectorAll: (sel) => (sel === '.overlay' ? ui.overlays : []),
      getElementById: () => ({
        querySelector: (sel) => (sel === '[data-back]' ? ui.layer : sel === '.topbar button[data-nav="back"]' ? backButton() : sel.includes('aria-busy') ? (ui.loading ? {} : null) : null),
      }),
    },
    MutationObserver: class {
      constructor(f) {
        this.f = f;
      }
      observe() {
        observers.push(this.f);
      }
    },
    addEventListener: (t, f) => (on[t] = on[t] || []).push(f),
    removeEventListener: (t, f) => (on[t] = (on[t] || []).filter((x) => x !== f)),
  };
  if (!navigationApi) delete win.navigation;
  const w = {
    app,
    ui,
    win,
    fire,
    mutate,
    /** A frame: what is on show is painted. */
    paint() {
      painted = shown();
    },
    /** Traversals the page asked for arrive, one after another, then a frame; until all is still. */
    settle() {
      for (let i = 0; i < 20; i++) {
        while (queue.length) arrive(idx + queue.shift());
        w.paint();
        if (!later.length) return;
        later.splice(0).forEach((f) => f());
      }
      throw new Error('never still');
    },
    /** The person's Back: the picture the swipe showed, and the screen it ended on. */
    swipe() {
      const picture = idx > 0 ? entries[idx - 1].picture : null;
      arrive(idx - 1);
      w.settle();
      return { picture, landed: shown() };
    },
    go(name, params, opts) {
      app.go(name, params, opts);
      w.settle();
    },
    sheet(dismissable = true) {
      const s = { dataset: { dismissable: dismissable ? '1' : '0' }, events: [] };
      s.dispatchEvent = (e) => {
        s.events.push(e.type);
        if (e.type === 'campfire:dismiss') {
          ui.overlays = ui.overlays.filter((o) => o !== s);
          mutate();
        }
      };
      ui.overlays = [...ui.overlays, s];
      mutate();
      w.settle();
      return s;
    },
    /** The entry on show, counted from the page's own, and how many lie ahead of it. */
    at: () => (entries[idx].state ? entries[idx].state.n : null),
    ahead: () => entries.length - 1 - idx,
    left: () => left,
    /** The traversals asked for are lost. */
    drop: () => queue.splice(0),
  };
  installBack(app, win);
  return w;
}

const FALLBACK = { send: 'home', about: 'settings', nodeSettings: 'settings', ownNode: 'nodeSettings' };

test('nothing is added before the first touch; then one entry for each step a Back can take', () => {
  const w = world({ fallback: FALLBACK });
  w.go('home');
  w.go('settings');
  assert.equal(w.ahead(), 0);
  assert.equal(w.at(), null, 'no entry before a touch: Chrome would skip it');
  w.fire('pointerdown');
  w.settle();
  assert.equal(w.at(), 1, 'Settings: one step, back to Wallet');
  w.go('about');
  assert.equal(w.at(), 2);
  w.go('home');
  assert.equal(w.at(), 0, 'the Wallet tab goes back over the entries');
  w.fire('keydown');
  w.go('send');
  assert.equal(w.at(), 1);
  assert.equal(w.ahead(), 0, 'nothing ahead for Forward');
});

test('each swipe shows the screen it opens, and ends on it', () => {
  const w = world({ fallback: FALLBACK });
  w.go('unlock');
  w.fire('pointerdown'); // the first touch: on Unlock
  w.settle();
  w.go('home', {}, { reset: true });
  w.go('settings');
  w.go('nodeSettings');
  w.go('ownNode');
  assert.equal(w.at(), 3);
  for (const want of ['nodeSettings', 'settings', 'home']) assert.deepEqual(w.swipe(), { picture: want, landed: want });
  assert.equal(w.left(), false);
  w.swipe();
  assert.equal(w.left(), true, 'a Back on Wallet leaves, in a browser tab');
});

test('the app\'s own Back goes back over the entries too, so a later swipe still shows the right screen', () => {
  const w = world({ fallback: FALLBACK });
  w.go('home');
  w.fire('pointerdown');
  w.go('settings');
  w.go('nodeSettings');
  w.go('ownNode');
  w.app.back('nodeSettings'); // the top bar's Back
  w.settle();
  assert.equal(w.at(), 2);
  assert.deepEqual(w.swipe(), { picture: 'settings', landed: 'settings' });
  w.go('about');
  assert.equal(w.ahead(), 0);
  assert.deepEqual(w.swipe(), { picture: 'settings', landed: 'settings' });
});

test('a sheet has its own entry: a swipe closes it and shows the screen under it', () => {
  const w = world({ fallback: FALLBACK });
  w.go('home');
  w.fire('pointerdown');
  w.go('send');
  const s = w.sheet();
  assert.equal(w.at(), 2);
  assert.deepEqual(w.swipe(), { picture: 'send', landed: 'send' });
  assert.deepEqual(s.events, ['campfire:dismiss']);
  assert.equal(w.at(), 1);
  // Closed by its own button: the entry goes too.
  w.sheet();
  w.ui.overlays = [];
  w.mutate();
  w.settle();
  assert.equal(w.at(), 1);
  assert.deepEqual(w.swipe(), { picture: 'home', landed: 'home' });
});

test('a sheet that holds a payment is asked instead, and while it stays its entry comes back', () => {
  const w = world({ fallback: FALLBACK });
  w.go('home');
  w.fire('pointerdown');
  w.go('send');
  const s = w.sheet(false);
  w.swipe();
  w.swipe();
  assert.deepEqual(s.events, ['campfire:beside', 'campfire:beside'], 'the sheet decides (its way out, or nothing while it signs)');
  assert.equal(w.app.currentName, 'send', 'the screen underneath did not move');
  assert.equal(w.at(), 2, 'its entry is back');
});

test('a layer closes before the screen goes back; a tab goes to Wallet; a screen with no Back stays', () => {
  const w = world({ fallback: FALLBACK });
  w.go('home');
  w.fire('pointerdown');
  w.go('send');
  let closed = 0;
  w.ui.layer = {
    click: () => {
      closed++;
      w.ui.layer = null;
      w.mutate();
    },
  };
  w.mutate();
  w.settle();
  assert.equal(w.at(), 2);
  assert.deepEqual(w.swipe(), { picture: 'send', landed: 'send' });
  assert.equal(closed, 1);
  w.go('home');
  w.go('activity');
  assert.deepEqual(w.swipe(), { picture: 'home', landed: 'home' });
  w.go('send');
  w.go('txStatus');
  assert.equal(w.at(), 2);
  const r = w.swipe();
  assert.equal(r.landed, 'txStatus', 'a payment status stays');
  assert.equal(w.at(), 2, 'its entry is back');
});

test('in a Home Screen app with no earlier page under it, Wallet is the first entry: nothing to go back to', () => {
  const w = world({ before: 0, standalone: true, fallback: FALLBACK });
  w.go('home');
  w.fire('pointerdown');
  w.settle();
  assert.equal(w.at(), 0);
  w.go('settings');
  assert.deepEqual(w.swipe(), { picture: 'home', landed: 'home' });
  assert.equal(w.left(), false);
});

test('after a reload (an earlier page under it), a Back on Wallet stays, and its picture is Wallet, not Unlock', () => {
  for (const opts of [{ standalone: true }, { navigationApi: true }]) {
    // The earlier page of the app lies under this one.
    const w = world({ before: 2, ...opts, fallback: FALLBACK });
    w.go('unlock');
    w.fire('pointerdown'); // the first touch: Face ID on Unlock
    w.settle();
    assert.equal(w.at(), 1, 'one entry kept under the first screen');
    w.go('home', {}, { reset: true });
    for (let i = 0; i < 3; i++) assert.deepEqual(w.swipe(), { picture: 'home', landed: 'home' }, JSON.stringify(opts));
    assert.equal(w.left(), false, 'never reaches the earlier page, which started the app again at Unlock');
    w.go('settings');
    w.go('about');
    for (const want of ['settings', 'home', 'home']) assert.deepEqual(w.swipe(), { picture: want, landed: want });
    assert.equal(w.left(), false);
  }
});

test('rapid Backs step one screen at a time, even two the page has not handled yet', () => {
  const w = world({ fallback: FALLBACK });
  w.go('home');
  w.fire('pointerdown');
  w.go('settings');
  w.go('nodeSettings');
  w.go('ownNode');
  // Two Backs before the page handled the first.
  const { app } = w;
  w.win.history.go(-1);
  w.win.history.go(-1);
  // Not the app's own traversals: arrive as the person's.
  w.settle();
  assert.equal(app.currentName, 'settings', 'two screens back, one at a time');
  assert.equal(w.at(), 1);
  assert.equal(w.left(), false);
});

test('on a screen still loading, Back waits for its Back; more Backs meanwhile count once', async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const w = world({ fallback: FALLBACK });
  w.go('home');
  w.fire('pointerdown');
  w.go('settings');
  w.go('about');
  w.ui.loading = true;
  w.swipe();
  w.swipe();
  await sleep(120);
  assert.equal(w.app.currentName, 'about', 'nothing while it loads');
  w.ui.loading = false;
  await sleep(120);
  w.settle();
  assert.equal(w.app.currentName, 'settings', 'its Back, once');
  assert.equal(w.at(), 1);
  assert.equal(w.left(), false);
});

test('a traversal the browser dropped does not stop the entries following the screens', async () => {
  const w = world({ fallback: FALLBACK });
  w.go('home');
  w.fire('pointerdown');
  w.go('settings');
  w.go('about');
  w.app.back('settings'); // the app asks to go back over About's entry...
  w.drop(); // ...and the browser drops it
  await new Promise((r) => setTimeout(r, 2100));
  w.settle();
  assert.equal(w.at(), 1, 'read back and followed again');
  w.go('about');
  assert.equal(w.at(), 2);
  assert.deepEqual(w.swipe(), { picture: 'settings', landed: 'settings' });
});
