// STAND-IN, TO BE REPLACED: src/lib/contracts.js is being built separately
// with this exact interface:
//   openApp({appId, appName}) -> {call(method, params), view(args, shader), transact(args, shader), close()}
//   setConsentPresenter(async (req) => boolean), req = {appName, comment, fee, isEnough, spends, receives, kind}
// When it lands, delete this file and import those two from '../contracts.js'
// in runner.js and screens/dapps.js. Nothing else uses this file.
//
// What it does: one BEAM engine app API per dApp (WasmWalletClient.createAppAPI,
// privilege 0, create_tx:false calls), and the engine's two consent
// handlers routed to one presenter. The engine asks before tx_send and
// process_invoke_data run and executes exactly the request it asked about.
// No presenter set means every request is rejected.
// Extra beyond the interface: onEvent(fn) for the app API's ev_* events
// (the runner uses it when present).

import { wallet } from '../wallet.js';

let presenter = null;
let handlersOn = null;
const requestOwner = new Map(); // exact request string -> app name

export function setConsentPresenter(fn) {
  presenter = typeof fn === 'function' ? fn : null;
}

// BEAM's wasm client hands consent amounts over as display strings in whole
// coins ("0.011"), not groth (wasmclient/wasm_beamapi.cpp beamAmountToUIString).
export function coinsToGroth(v) {
  const s = String(v ?? '').trim();
  const m = /^(\d+)(?:\.(\d{1,8}))?$/.exec(s);
  if (!m) throw new Error(`not an amount: ${s.slice(0, 32)}`);
  return BigInt(m[1]) * 100000000n + BigInt(((m[2] || '') + '00000000').slice(0, 8));
}

function amountsOf(list) {
  const spends = [];
  const receives = [];
  for (const a of Array.isArray(list) ? list : []) {
    const row = { assetId: Number(a.assetID) || 0, amount: coinsToGroth(a.amount) };
    (a.spend ? spends : receives).push(row);
  }
  return { spends, receives };
}

async function ask(req) {
  if (!presenter) return false;
  try {
    return (await presenter(req)) === true;
  } catch {
    return false;
  }
}

function installHandlers(client) {
  if (handlersOn === client) return;
  handlersOn = client;
  // Anything that cannot be read in full is rejected, never shown half-read and never left hanging.
  const answer = (cb, request, ok, yes, no) => {
    try {
      if (ok) cb[yes](request);
      else cb[no](request);
    } catch {
      /* the app API is gone */
    }
  };
  client.setApproveContractInfoHandler((request, info, amounts, cb) => {
    let req;
    try {
      const i = JSON.parse(info);
      const { spends, receives } = amountsOf(JSON.parse(amounts));
      req = { kind: 'contract', appName: requestOwner.get(request) || 'An app', comment: String(i.comment || ''), fee: coinsToGroth(i.fee), isEnough: i.isEnough !== false, spends, receives };
    } catch {
      return answer(cb, request, false, 'contractInfoApproved', 'contractInfoRejected');
    }
    ask(req).then((ok) => answer(cb, request, ok, 'contractInfoApproved', 'contractInfoRejected'));
  });
  client.setApproveSendHandler((request, info, cb) => {
    let req;
    try {
      const i = JSON.parse(info);
      const params = JSON.parse(request).params || {};
      const spends = [{ assetId: Number(i.assetID) || 0, amount: BigInt(params.value) }];
      req = { kind: 'send', appName: requestOwner.get(request) || 'An app', comment: String(i.comment || ''), fee: coinsToGroth(i.fee), isEnough: true, spends, receives: [], address: String(i.token || params.address || '') };
    } catch {
      return answer(cb, request, false, 'sendApproved', 'sendRejected');
    }
    ask(req).then((ok) => answer(cb, request, ok, 'sendApproved', 'sendRejected'));
  });
}

export async function openApp({ appId, appName, apiVersion = 'current', minApiVersion = '' }) {
  const session = wallet.session;
  if (!session || !session.client) throw new Error('The wallet is locked.');
  const client = session.client;
  installHandlers(client);
  const api = await new Promise((resolve, reject) => {
    client.createAppAPI(apiVersion, minApiVersion, appId, appName, (err, a) => (err ? reject(new Error(String(err))) : resolve(a)));
  });
  let nextId = 1;
  let closed = false;
  const pending = new Map();
  const eventFns = new Set();
  api.setHandler((s) => {
    let m;
    try {
      m = JSON.parse(s);
    } catch {
      return;
    }
    if (typeof m.id === 'string' && m.id.startsWith('ev_')) {
      for (const fn of eventFns) fn(m.id, m.result);
      return;
    }
    const p = pending.get(m.id);
    if (!p) return;
    pending.delete(m.id);
    requestOwner.delete(p.text);
    clearTimeout(p.timer);
    if (m.error) {
      const e = new Error(m.error.message || 'wallet error');
      e.rpc = m.error;
      p.reject(e);
    } else p.resolve(m.result);
  });

  function call(method, params, { timeoutMs = method === 'tx_send' || method === 'process_invoke_data' ? 0 : 180000 } = {}) {
    if (closed) return Promise.reject(Object.assign(new Error('closed'), { code: 'stopped' }));
    const id = `cf-${nextId++}`;
    const text = JSON.stringify({ jsonrpc: '2.0', id, method, params: params || {} });
    return new Promise((resolve, reject) => {
      const timer = timeoutMs
        ? setTimeout(() => {
            pending.delete(id);
            requestOwner.delete(text);
            reject(Object.assign(new Error(`no answer (${method})`), { code: 'timeout' }));
          }, timeoutMs)
        : null;
      pending.set(id, { resolve, reject, timer, text });
      requestOwner.set(text, appName);
      try {
        api.callWalletApi(text);
      } catch (e) {
        pending.delete(id);
        requestOwner.delete(text);
        clearTimeout(timer);
        reject(e);
      }
    });
  }

  return {
    call,
    view: (args, shader) => call('invoke_contract', { args, contract: Array.from(shader), create_tx: false }),
    async transact(args, shader) {
      const r = await call('invoke_contract', { args, contract: Array.from(shader), create_tx: false });
      return call('process_invoke_data', { data: r.raw_data });
    },
    onEvent(fn) {
      eventFns.add(fn);
      return () => eventFns.delete(fn);
    },
    close() {
      if (closed) return;
      closed = true;
      for (const p of pending.values()) {
        clearTimeout(p.timer);
        requestOwner.delete(p.text);
        p.reject(Object.assign(new Error('closed'), { code: 'stopped' }));
      }
      pending.clear();
      eventFns.clear();
      try {
        api.delete();
      } catch {
        /* already released */
      }
    },
  };
}
