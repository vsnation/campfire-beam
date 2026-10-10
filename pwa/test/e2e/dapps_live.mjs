// LIVE, NO FUNDS: all nine dApps on BEAM mainnet in the PWA (headless Chrome).
//
//   npm run e2e:dapps-live            (DAPP_WIDTH=1280 for the desktop layout)
//
// A fresh throwaway wallet (never funded) is created and synced. Each of the
// nine packages is downloaded from BEAM's GitHub through the dApps screen,
// checked against its pin and opened. For each dApp the script reports:
// whether its UI came up, which wallet shape it was offered, how many of its
// requests crossed the bridge and how many contract reads succeeded, the
// outside hosts it tried (refused by its frame unless granted), page errors,
// and whether its layout fits the width.
// Then, in Beam DEX, a real swap is built and submitted the way the dApp
// submits one (invoke_contract, then process_invoke_data with its raw_data,
// through the dApp's own bridge object); the approval sheet must appear with
// the dApp's name, is rejected, and the engine's code is recorded.
// Nothing is signed. Screenshots go to $CAMPFIRE_SHOTS (never committed).
import { startServer, launch, recordedPage, waitScreen, sleep, shot } from './harness.mjs';
import { createWallet, waitHome, waitSynced } from './flows.mjs';

const tid = (id) => `[data-testid="${id}"]`;
const WIDTH = Number(process.env.DAPP_WIDTH || 390);
const HEIGHT = WIDTH > 600 ? 800 : 844;
const SETTLE = Number(process.env.DAPP_SETTLE_MS || 25000);
const DEX = 'db851322f6674a6da3e84e9953db2ffd';
const DEX_CID = '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

const server = await startServer({ root: 'dist', port: 8795 });
const browser = await launch();
const ctx = await browser.newContext({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 2 });
const { page, rec } = await recordedPage(ctx, { label: 'live' });
const results = [];
try {
  await page.goto(server.url);
  await createWallet(page, { password: `dapps-${Math.random().toString(36).slice(2, 10)}` });
  await waitHome(page);
  log('synced', JSON.stringify(await waitSynced(page)));
  // Test-only: record what crosses the bridge (method and outcome), wallet side.
  await page.evaluate(async () => {
    const m = await import('./lib/dapps/session.js');
    const orig = m.DappSession.prototype.handle;
    window.__bridgeTrace = [];
    m.DappSession.prototype.handle = async function (text) {
      const out = await orig.call(this, text);
      let method = '?';
      let args = '';
      try {
        const j = JSON.parse(text);
        method = j.method;
        args = (j.params && j.params.args) || '';
      } catch {
        /* not JSON */
      }
      let ok = false;
      let code = null;
      try {
        const r = JSON.parse(out);
        ok = 'result' in r;
        code = r.error ? r.error.code : null;
      } catch {
        /* not JSON */
      }
      window.__bridgeTrace.push({ app: this.appName, method, args: String(args).slice(0, 80), ok, code });
      return out;
    };
  });
  await page.click(tid('open-dapps'));
  await waitScreen(page, 'dapps');
  const only = process.env.DAPP_ONLY ? process.env.DAPP_ONLY.split(',') : null;
  const rows = (await page.$$eval('.dapp-row', (els) => els.map((e) => ({ id: e.dataset.testid.slice(5), name: e.dataset.name })))).filter((r) => !only || only.includes(r.id));
  for (const { id, name } of rows) {
    const mark = rec.console.length;
    const errMark = rec.errors.length;
    log(`opening ${name}`);
    await page.click(tid(`dapp-${id}`));
    await page.waitForSelector(tid('dapp-go'), { timeout: 10000 });
    if (process.env.DAPP_SHOTS && id === DEX) await shot(page, `dapps-live-${WIDTH}-first-open-sheet`);
    await page.click(tid('dapp-go'));
    const t0 = Date.now();
    let state = null;
    let progressShot = false;
    while (Date.now() - t0 < 120000) {
      const st = await page.evaluate(() => window.__campfire.dapps());
      state = st[0] ? st[0].state : null;
      if (state === 'running') break;
      if (await page.$(tid('dapp-retry'))) break;
      if (!progressShot && process.env.DAPP_SHOTS && (await page.$(tid('dapp-progress')))) {
        await shot(page, `dapps-live-${WIDTH}-download-${id.slice(0, 6)}`);
        progressShot = true;
      }
      await sleep(250);
    }
    const loadedMs = Date.now() - t0;
    await sleep(SETTLE);
    const st = (await page.evaluate(() => window.__campfire.dapps()))[0] || {};
    const frame = page.frames().find((f) => f.url().includes('/dapp-run/'));
    const fit = frame ? await frame.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth, text: document.body ? document.body.innerText.trim().length : 0, ua: /QtWebEngine/.test(navigator.userAgent) ? 'Qt' : /Android|iPhone/.test(navigator.userAgent) ? 'mobile' : 'web', web: typeof window.BeamApi === 'object' })).catch(() => null) : null;
    const trace = await page.evaluate((n) => window.__bridgeTrace.filter((t) => t.app === n), st.name || name);
    const reads = trace.filter((t) => t.method === 'invoke_contract');
    const tried = new Set();
    for (const c of rec.console.slice(mark)) {
      const m = /(?:Connecting to|Loading the image|Loading the font) '(https?:\/\/[^/']+)/.exec(c.text);
      if (m) tried.add(m[1]);
    }
    await shot(page, `dapps-live-${WIDTH}-${id.slice(0, 6)}`);
    const r = {
      name,
      loads: state === 'running' && Boolean(fit && fit.text > 0),
      loadedMs,
      shape: fit ? (fit.web ? 'web-extension' : fit.ua) : st.shape,
      requests: st.requests || 0,
      reads: `${reads.filter((t) => t.ok).length}/${reads.length}`,
      readOk: reads.some((t) => t.ok),
      methods: [...new Set(trace.map((t) => t.method))].join(' '),
      failedCodes: [...new Set(trace.filter((t) => !t.ok).map((t) => `${t.method}:${t.code}`))].join(' '),
      remoteTried: [...tried].join(' '),
      pageErrors: rec.errors.slice(errMark).map((e) => e.slice(0, 120)),
      fits: fit ? fit.sw <= fit.cw + 1 : null,
      width: fit ? `${fit.sw}/${fit.cw}` : null,
    };
    results.push(r);
    log(JSON.stringify(r));

    if (id === DEX) {
      // The approval path, as the DEX dApp drives it: build the trade, then submit its raw_data.
      const before = await page.evaluate(() => window.__bridgeTrace.length);
      const built = await frame.evaluate(async (cidHex) => {
        // Results come back the way this shape delivers them: a document event (mobile) or the Qt signal.
        const waiting = new Map();
        const onJson = (json) => {
          const j = JSON.parse(json);
          if (waiting.has(j.id)) waiting.get(j.id)(j);
        };
        document.addEventListener('onCallWalletApiResult', (e) => onJson(e.detail));
        if (/QtWebEngine/.test(navigator.userAgent)) new window.QWebChannel(window.qt.webChannelTransport, (ch) => ch.objects.BEAM.api.callWalletApiResult.connect(onJson));
        await new Promise((r) => setTimeout(r, 50));
        const send = (method, params, id) =>
          new Promise((resolve) => {
            waiting.set(id, resolve);
            window.BEAM.callWalletApi(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
          });
        const trade = await send('invoke_contract', { args: `action=pool_trade,cid=${cidHex},aid1=174,aid2=0,kind=2,val1_buy=0,val2_pay=1000000,bPredictOnly=0`, create_tx: false }, 'live-trade');
        if (!trade.result || !trade.result.raw_data) return { trade };
        window.__submit = send('process_invoke_data', { data: trade.result.raw_data }, 'live-submit');
        return { rawBytes: trade.result.raw_data.length };
      }, DEX_CID);
      log('DEX trade built:', JSON.stringify(built).slice(0, 200));
      await page.waitForSelector(tid('consent'), { timeout: 60000 });
      const sheet = await page.$eval(tid('consent'), (el) => el.innerText);
      await shot(page, `dapps-live-${WIDTH}-dex-approval`);
      await page.click(tid('consent-cancel'));
      const answer = await frame.evaluate(() => window.__submit).catch(async (e) => ({ lost: e.message, states: await page.evaluate(() => window.__campfire.dapps()), stopped: await page.$eval(tid('dapp-stopped'), (x) => x.innerText).catch(() => null) }));
      const after = await page.evaluate((b) => window.__bridgeTrace.slice(b), before);
      const consent = { sheet: sheet.replace(/\s+/g, ' ').slice(0, 300), engineAnswer: answer.error || answer.result, bridge: after };
      log('DEX approval:', JSON.stringify(consent));
      results.push({ consent });
    }
    await page.click(tid('dapp-close'));
    await sleep(800);
  }
} finally {
  console.log('\nRESULTS');
  for (const r of results) console.log(JSON.stringify(r));
  await browser.close();
  server.stop();
}
