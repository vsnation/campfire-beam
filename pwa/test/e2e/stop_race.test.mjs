// Stopping the engine while answers are still on their way to the page.
//
// BEAM's wasm client queued every API answer and event with a strong reference
// to the wallet; StopWallet asserts it holds the only one, so a stop while an
// answer was still queued aborted the whole WebAssembly runtime ("Assertion
// failed: wp.use_count() == 1 ... StopWallet") and no wallet could run in that
// page again: it reached no node and saw no payment (engine patch 0107). Here a
// new wallet (mainnet, no money) is locked again and again with a burst of
// requests in flight; the engine must never abort, and after each unlock the
// wallet must answer and reach its node.
import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, launch, recordedPage, waitScreen, sleep } from './harness.mjs';
import { createWallet, waitHome, waitSynced, unlockWithPassword } from './flows.mjs';

const PORT = 8800;
const ROUNDS = Number(process.env.STOP_RACE_ROUNDS || 16);
const tid = (id) => `[data-testid="${id}"]`;

test('locking with answers in flight never aborts the engine, and the wallet works after each unlock', { timeout: 30 * 60000 }, async () => {
  const srv = await startServer({ port: PORT });
  const browser = await launch();
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const { page, rec } = await recordedPage(ctx, { label: 'race' });
  try {
    const aborted = () => rec.console.filter((c) => /Aborted\(|use_count|runtime exited or application aborted|RuntimeError|out of bounds/.test(c.text)).map((c) => c.text.slice(0, 200));
    const password = `race-${Math.random().toString(36).slice(2, 10)}`;
    await page.goto(srv.url);
    await createWallet(page, { password });
    await waitHome(page, { timeout: 10 * 60000 });
    await waitSynced(page, 10 * 60000);
    for (let i = 1; i <= ROUNDS; i++) {
      // A burst of requests, then Lock while their answers are still coming back.
      // Lock in the same task as the burst: the wallet thread is still answering when the stop begins.
      await page.evaluate((n) => {
        for (let k = 0; k < n; k++) window.__campfire.addresses().catch(() => {});
        document.querySelector('[data-testid="lock"]').click();
      }, 200 * i);
      await waitScreen(page, 'unlock', 60000);
      await sleep(500);
      assert.deepEqual(aborted(), [], `round ${i}: the engine aborted`);
      await unlockWithPassword(page, password);
      await waitHome(page, { timeout: 5 * 60000 });
      // The wallet reaches its node again and answers (a move to another node
      // meanwhile cancels a request: asked again).
      await page.waitForFunction(() => window.__campfire.sync().state === 'synced', null, { timeout: 180000, polling: 1000 }).catch(async (e) => {
        console.log(`round ${i}: node switches ${JSON.stringify(await page.evaluate(() => window.__campfire.nodeSwitches()))}`);
        throw e;
      });
      let addrs = [];
      for (let k = 0; k < 3 && !addrs.length; k++) addrs = await page.evaluate(() => window.__campfire.addresses().catch(() => []));
      assert.ok(addrs.length >= 1, `round ${i}: no answer from the wallet after unlock`);
    }
    assert.deepEqual(aborted(), []);
    console.log(`node switches: ${JSON.stringify(await page.evaluate(() => window.__campfire.nodeSwitches()))}`);
  } catch (e) {
    console.log(rec.console.filter((c) => !/Password field|^\t|Rules signature/.test(c.text)).slice(-60).map((c) => `[console] ${c.text.slice(0, 220)}`).join('\n'));
    throw e;
  } finally {
    await browser.close();
    srv.stop();
  }
});

// BEAM's wallet database commits a change 50 ms after making it; a save right
// after an action used to run before that commit, so an app closed at once lost
// what was just done (a payment, an address). Make a new address, close the page
// the moment it shows, open again: the address must still be there.
test('what was just done survives the app being closed at once', { timeout: 20 * 60000 }, async () => {
  const srv = await startServer({ port: PORT + 1 });
  const browser = await launch();
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  try {
    let { page } = await recordedPage(ctx, { label: 'close' });
    const password = `close-${Math.random().toString(36).slice(2, 10)}`;
    await page.goto(srv.url);
    await createWallet(page, { password });
    await waitHome(page, { timeout: 10 * 60000 });
    await waitSynced(page, 10 * 60000);
    for (let i = 1; i <= 3; i++) {
      await page.evaluate(() => window.__campfire.go('receive'));
      await waitScreen(page, 'receive');
      await page.waitForFunction(() => document.querySelector('[data-testid="receive-address"]').textContent.length > 20, null, { timeout: 60000 });
      const before = await page.textContent(tid('receive-address'));
      await page.click(tid('new-address'));
      await page.waitForFunction((b) => {
        const t = document.querySelector('[data-testid="receive-address"]').textContent;
        return t.length > 20 && t !== b;
      }, before, { timeout: 60000 });
      const made = await page.textContent(tid('receive-address'));
      await page.close(); // at once, as a phone may
      ({ page } = await recordedPage(ctx, { label: 'close' }));
      await page.goto(srv.url);
      await unlockWithPassword(page, password);
      await waitHome(page, { timeout: 3 * 60000 }).catch(async (e) => {
        const what = await page.evaluate(() => ({ screen: window.__campfire.screen(), text: document.getElementById('app').innerText.slice(0, 400) }));
        throw new Error(`round ${i}: ${e.message}; on screen ${JSON.stringify(what)}`);
      });
      const addrs = await page.evaluate(() => window.__campfire.addresses());
      assert.ok(addrs.includes(made), `round ${i}: the address made just before closing is gone`);
    }
  } finally {
    await browser.close();
    srv.stop();
  }
});
