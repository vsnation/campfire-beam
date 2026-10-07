/* Welcome
 * Spec: ONE job: start a wallet on this device.
 *       Primary CTA: "Create a new wallet" (secondary: "Restore with 12 words").
 *       Taps from app open: 0 (first screen for a new device).
 * Exit-intent reasons and answers:
 *   - "Is this a scam / who holds my money?" -> the line under the buttons: no account, the
 *     12 words never leave this device.
 *   - "Will I lose it if Safari clears data?" -> the Home Screen guide says when that happens.
 *   - "What does it cost?" -> nothing to install or sign up; network fees are shown before paying.
 */
import { h } from '../lib/dom.js';
import { icon } from '../lib/icons.js';
import { screen, primary, secondary } from '../lib/ui.js';

export function isIosSafariTab() {
  const ua = navigator.userAgent;
  const ios = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const standalone = navigator.standalone === true || window.matchMedia('(display-mode: standalone)').matches;
  return ios && !standalone;
}

export default function welcome(app) {
  const guide = isIosSafariTab() && !app.prefs.a2hsDismissed ? a2hsGuide(app) : null;
  const el = screen(
    {
      topbar: false,
      actions: [
        primary('Create a new wallet', () => {
          app.setup = { mode: 'create' };
          app.go('backup');
        }, { 'data-testid': 'create' }),
        secondary('Restore with 12 words', () => {
          app.setup = { mode: 'restore' };
          app.go('restore');
        }, { 'data-testid': 'restore' }),
        h('p', { class: 'small center', text: 'No account, no sign-up. Your 12 words and keys stay on this device.' }),
      ],
    },
    h(
      'div',
      { class: 'hero' },
      h('img', { src: 'img/logo.svg', alt: '' }),
      h('h1', { text: 'BEAM Campfire' }),
      h('p', { text: 'Your privacy. Your wallet. Your BEAM.' }),
    ),
    guide,
  );
  return { el };
}

function a2hsGuide(app) {
  const card = h(
    'div',
    { class: 'card', 'data-testid': 'a2hs' },
    h(
      'div',
      { class: 'banner' },
      h('h3', { class: 'grow', text: 'First, add BEAM Campfire to your Home Screen' }),
      h('button', {
        class: 'icon-btn',
        'aria-label': 'Hide this tip',
        onclick: async () => {
          await app.setPrefs({ a2hsDismissed: true });
          card.remove();
        },
      }, icon('close')),
    ),
    h('ol', { class: 'steps-list' }, h('li', {}, 'Tap Share ', icon('share', 'inline-icon'), ' in Safari.'), h('li', { text: 'Choose "Add to Home Screen".' }), h('li', { text: 'Open BEAM Campfire from the Home Screen.' })),
    h('p', { class: 'small', text: 'Home Screen apps keep their data. Safari tabs may lose it after 7 days without use, and a wallet made in a Safari tab does not move to the Home Screen app.' }),
  );
  return card;
}
