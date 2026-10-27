// System back - Android's back button and gesture, the edge swipe in an iPhone
// Home Screen app, the browser's Back - does what the screen's own Back does:
// it closes an open sheet, else a layer over the screen (a running dApp) by its
// own close button ([data-back]), else taps the top bar's Back, which follows
// the app's history (lib/nav.js), else a tab goes to Wallet (Activity,
// Settings, and the Ethereum side). Any other screen without a Back (Wallet,
// Welcome, Unlock, a payment's status, a step that must finish) stays. On a
// screen still loading, it waits for its Back. The Back is found by data-nav,
// never by its label, which is translated.
//
// The browser's history holds one entry for each step a Back can take: the
// screens of the app's history, Wallet under a tab, and each sheet or layer
// open over the screen. Opening one adds an entry; going back, by the app's
// own Back too, goes back over them. The address never changes and nothing
// about a screen is kept in the browser. This is for the swipe: Safari shows a
// picture of the entry it goes back to, taken as that entry was left, so the
// picture is the screen the Back opens. (With entries added once, at the first
// touch, it showed the screen of that touch, often Unlock: owner, 2026-10-27.)
//
// Wallet, Welcome and Unlock are the first entry: a Back there leaves the app
// in a browser tab, and has nothing to go back to in a Home Screen app. Unless
// entries of an earlier page of this app lie under it (a reload keeps them),
// where a Back would start the app again at Unlock: then one entry is kept
// under the first screen, a Back onto it stays, and its picture is kept that
// screen's own. Chrome skips entries a page adds before the person has touched
// it, so they are added from the first tap or key.
import { isRoot } from './nav.js';

const TABS = new Set(['activity', 'settings', 'ethHome', 'ethStart']);

/** What a Back means on the current screen: 'sheet' | 'layer' | 'button' | 'home' | 'stay'. */
export function backAction({ overlays, layerBack = null, backButton, screenName }) {
  if (overlays.length) return 'sheet';
  if (layerBack) return 'layer';
  if (backButton) return 'button';
  if (TABS.has(screenName)) return 'home';
  return 'stay';
}

/**
 * How many entries above the first the screen on show has: Wallet under a tab, each screen Back
 * returns through (trail: lib/nav.js, oldest first), a layer, and each sheet.
 */
export function stepsFor({ name, params = {}, trail = [], layer = false, sheets = 0 }) {
  const first = trail[0] || { name, params };
  const underTab = TABS.has(first.name) && isRoot(first.name, first.params || {}) ? 1 : 0;
  return underTab + trail.length + (layer ? 1 : 0) + sheets;
}

/** Whether the app runs as a Home Screen app (no browser around it). */
export function inStandalone(win) {
  try {
    return Boolean((win.navigator && win.navigator.standalone) || (win.matchMedia && win.matchMedia('(display-mode: standalone)') /* i18n-ignore: a media query */.matches));
  } catch {
    return false;
  }
}

/**
 * Whether an entry lies under the page's own that a Back on the first screen must not reach. In a
 * Home Screen app, any (the app is all there is: an earlier page of it, which a Back would load
 * again). In a browser tab, an earlier page of this app, which the Navigation API tells apart
 * from other sites; without it, none is assumed (a Back leaves, as in any site).
 */
export function entriesUnder(win) {
  if (inStandalone(win)) return win.history.length > 1;
  try {
    const cur = win.navigation && win.navigation.currentEntry;
    return Boolean(cur && typeof cur.index === 'number' && cur.index > 0);
  } catch {
    return false; // no Navigation API
  }
}

export function installBack(app, win = window) {
  const hist = win.history;
  if (!hist || typeof hist.pushState !== 'function') return;
  const doc = Math.random().toString(36).slice(2);
  let armed = false;
  let floor = 0; // 1: one entry kept under the first screen
  let at = 0; // the entry on show, counted from this page's own
  let travelling = 0; // traversals the app asked for that have not arrived yet
  let waiting = false; // a Back waits for a screen still loading
  const shot = []; // the screen each entry showed when it was left: the swipe's picture of it
  const ours = (s) => Boolean(s && s.campfire === 'back' && s.doc === doc && Number.isInteger(s.n));

  const LOADING = ':scope > main[aria-busy="true"]'; // i18n-ignore: a CSS selector
  const view = () => {
    const d = win.document;
    const root = d.getElementById('app');
    return { overlays: [...d.querySelectorAll('.overlay')], root, layerBack: root && root.querySelector('[data-back]') };
  };
  const wanted = () => {
    const { overlays, layerBack } = view();
    const trail = app.nav && typeof app.nav.entries === 'function' ? app.nav.entries() : [];
    return floor + stepsFor({ name: app.currentName, params: app.params || {}, trail, layer: Boolean(layerBack), sheets: overlays.length });
  };
  const travel = (d) => {
    travelling++;
    at += d;
    hist.go(d);
  };

  /** Brings the entries to what is on show: adds the missing ones, goes back over the rest. */
  function sync() {
    if (!armed || travelling || waiting) return;
    const want = wanted();
    if (want < at) return travel(want - at);
    while (at < want) {
      shot[at] = app.currentName;
      at++;
      hist.pushState({ campfire: 'back', doc, n: at }, '');
    }
    if (floor && at === floor && shot[floor - 1] !== app.currentName) retake();
  }

  // The entry under the first screen pictures the screen of its last leaving (Unlock, before
  // Wallet): once the screen on show is painted, stepping onto it and off again takes it anew.
  let retaking = false;
  const retake = () => {
    if (retaking) return;
    retaking = true;
    const later = () =>
      (win.setTimeout || setTimeout)(() => {
        retaking = false;
        if (!armed || travelling || waiting || at !== floor || wanted() !== floor || shot[floor - 1] === app.currentName) return;
        travel(-1);
      }, 0);
    if (typeof win.requestAnimationFrame === 'function') win.requestAnimationFrame(later);
    else later();
  };

  const arm = () => {
    if (armed) return;
    armed = true;
    floor = entriesUnder(win) ? 1 : 0;
    hist.replaceState({ campfire: 'back', doc, n: 0 }, '');
    at = 0;
    sync();
  };
  const onFirst = () => {
    win.removeEventListener('pointerdown', onFirst, true);
    win.removeEventListener('keydown', onFirst, true);
    arm();
  };
  win.addEventListener('pointerdown', onFirst, true);
  win.addEventListener('keydown', onFirst, true);

  // A screen, sheet or layer opened or closed (the app's own Back and its tabs too): the entries follow.
  if (typeof win.MutationObserver === 'function' && win.document && win.document.body) {
    new win.MutationObserver(() => sync()).observe(win.document.body, { childList: true, subtree: true });
  }

  // A screen still loading its code (a spinner, no top bar yet) has no Back:
  // the Back waits for that screen, a few seconds at most. More Backs meanwhile count once.
  const whenLoaded = (root) => {
    if (waiting) return;
    waiting = true;
    const t0 = Date.now();
    const screen = app.current;
    const tick = () => {
      if (app.current !== screen) {
        waiting = false;
        sync();
      } else if (!root.querySelector(LOADING)) {
        waiting = false;
        run();
      } else if (Date.now() - t0 < 5000) setTimeout(tick, 50);
      else {
        waiting = false;
        sync();
      }
    };
    setTimeout(tick, 50);
  };

  /** Does what a Back means now; returns the action. */
  function run() {
    const { overlays, root, layerBack } = view();
    if (!overlays.length && root && root.querySelector(LOADING)) {
      whenLoaded(root);
      return 'wait';
    }
    const backButton = root && root.querySelector('.topbar button[data-nav="back"]');
    const action = backAction({ overlays, layerBack, backButton, screenName: app.currentName });
    if (action === 'sheet') {
      const top = overlays[overlays.length - 1];
      // A sheet that holds a payment decides (lib/ui.js openSheet): its way out while that is
      // offered, nothing while it signs or sends.
      top.dispatchEvent(new Event(top.dataset.dismissable !== '0' ? 'campfire:dismiss' : 'campfire:beside'));
    } else if (action === 'layer') layerBack.click();
    else if (action === 'button') backButton.click();
    else if (action === 'home') app.go('home');
    // What the Back opened is on show (or nothing moved: the entry comes back).
    sync();
    return action;
  }

  win.addEventListener('popstate', () => {
    if (!armed || !ours(hist.state)) return; // the browser's own, or not this page's
    const n = hist.state.n;
    if (travelling) {
      travelling--;
      at = n;
      if (!travelling) sync();
      return;
    }
    const back = n < at;
    at = n;
    if (back) run();
    else sync(); // Forward: there is nothing ahead, back to the screen on show
  });
}
