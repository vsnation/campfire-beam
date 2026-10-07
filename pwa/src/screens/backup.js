/* Backup words (create, step 1 of 3)
 * Spec: ONE job: write down the 12 words.
 *       Primary CTA: "I wrote them down" (enabled after the words are shown).
 *       Taps from app open: 1 (Welcome -> Create).
 * Exit-intent reasons and answers:
 *   - "Why do I need this?" -> one sentence: the words are the wallet; they bring it back on any device.
 *   - "Someone could see my screen" -> words stay blurred until tapped.
 *   - "Can I screenshot it?" -> we say no, and why (photos sync to the cloud).
 */
import { h, put } from '../lib/dom.js';
import { icon } from '../lib/icons.js';
import { screen, primary, notice } from '../lib/ui.js';
import { generatePhrase } from '../lib/engine.js';

export default function backup(app) {
  const grid = h('div', { class: 'words hidden-words', 'data-testid': 'words' });
  const cta = primary('I wrote them down', () => app.go('confirmWords'), { disabled: true, 'data-testid': 'wrote-down' });
  const cover = h('div', { class: 'cover' }, h('button', { class: 'btn btn-secondary btn-small', 'data-testid': 'reveal' }, icon('eye'), 'Tap to show the words'));
  const reveal = h('div', { class: 'reveal' }, grid, cover);
  const status = h('p', { class: 'small', text: 'Making your words…' });

  cover.querySelector('button').addEventListener('click', () => {
    grid.classList.remove('hidden-words');
    cover.remove();
    cta.disabled = false;
  });

  (async () => {
    try {
      if (!app.setup || app.setup.mode !== 'create') app.setup = { mode: 'create' };
      if (!app.setup.words) app.setup.words = await generatePhrase();
      put(grid, ...app.setup.words.map((w, i) => h('div', { class: 'word' }, h('span', { class: 'n', text: String(i + 1) }), h('span', { text: w }))));
      status.textContent = '';
    } catch (e) {
      status.textContent = `The wallet engine did not start: ${e.message}. Reload the page to try again.`;
    }
  })();

  const el = screen(
    {
      title: 'Your 12 words',
      back: () => {
        app.setup = null;
        app.go('welcome');
      },
      actions: [cta],
    },
    h('p', { class: 'step', text: 'Step 1 of 3' }),
    h('p', { class: 'lead', text: 'These words are your wallet. With them you can open it on any device, even if this phone is lost.' }),
    notice('warn', h('strong', { text: 'Write them on paper, in order. ' }), 'Anyone who sees them can take your money. No screenshots: photos sync to the cloud.'),
    reveal,
    status,
  );
  return { el };
}
