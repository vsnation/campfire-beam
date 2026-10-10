// Shared by the tests that drive lib/contracts.js without the WebAssembly engine.
import assert from 'node:assert/strict';

export const TXID = 'ab'.repeat(16);

/**
 * A stand-in for the engine's WasmWalletClient and its app API, shaped like
 * wasmclient.cpp: createAppAPI(id, name, cb(err, api)); api.callWalletApi(json);
 * api.setHandler(fn); approve handlers get (request, info, amounts, cb).
 */
export function fakeEngine({ respond } = {}) {
  const engine = { apis: [], handlerSets: { contract: 0, send: 0 }, contractHandler: null, sendHandler: null, deleted: 0, answers: [] };
  engine.respond =
    respond ||
    ((req, api) => {
      if (req.method === 'invoke_contract') {
        if (req.params.args.includes('bPredictOnly=0') || req.params.args.includes('action=tx')) return api.reply(req.id, { output: '', raw_data: [1, 2, 3] });
        return api.reply(req.id, { output: '{"res": {"ok": 1}}' });
      }
      if (req.method === 'process_invoke_data') return engine.askContract(api, req, { comment: 'Amm trade', fee: '0.011', isEnough: true, isSpend: true }, [{ amount: '0.01', assetID: 0, spend: true }, { amount: '371.76133894', assetID: 174, spend: false }]);
      if (req.method === 'tx_send') return engine.askSend(api, req, { comment: '', fee: '0.001', token: 'f'.repeat(66), isOnline: true, isSpend: true, isEnough: true, amount: '1.5', assetID: 0 });
      return api.reply(req.id, { echo: req.method });
    });
  engine.askContract = (api, req, info, amounts) => {
    const text = JSON.stringify(req);
    setImmediate(() => engine.contractHandler(text, JSON.stringify(info), JSON.stringify(amounts), engine.callback(api, text)));
  };
  engine.askSend = (api, req, info) => {
    const text = JSON.stringify(req);
    setImmediate(() => engine.sendHandler(text, JSON.stringify(info), engine.callback(api, text)));
  };
  engine.callback = (api, original) => {
    const answer = (approved) => (request) => {
      assert.equal(request, original, 'the engine gets back the request it sent');
      engine.answers.push(approved ? 'approved' : 'rejected');
      const id = JSON.parse(request).id;
      if (approved) api.reply(id, { txid: TXID });
      else api.replyError(id, { code: -32021, message: 'Call is rejected by user' });
    };
    return { contractInfoApproved: answer(true), contractInfoRejected: answer(false), sendApproved: answer(true), sendRejected: answer(false), delete() {} };
  };
  engine.client = {
    setApproveContractInfoHandler(fn) {
      engine.handlerSets.contract++;
      engine.contractHandler = fn;
    },
    setApproveSendHandler(fn) {
      engine.handlerSets.send++;
      engine.sendHandler = fn;
    },
    createAppAPI(appId, appName, cb) {
      const api = {
        appId,
        appName,
        handler: null,
        sent: [],
        setHandler(fn) {
          this.handler = fn;
        },
        callWalletApi(s) {
          const req = JSON.parse(s);
          this.sent.push(req);
          engine.respond(req, this);
        },
        reply(id, result) {
          setImmediate(() => this.handler && this.handler(JSON.stringify({ jsonrpc: '2.0', id, result })));
        },
        replyError(id, error) {
          setImmediate(() => this.handler && this.handler(JSON.stringify({ jsonrpc: '2.0', id, error })));
        },
        event(id, result) {
          this.handler && this.handler(JSON.stringify({ jsonrpc: '2.0', id, result }));
        },
        delete() {
          engine.deleted++;
        },
      };
      engine.apis.push(api);
      setImmediate(() => cb(undefined, api));
    },
  };
  engine.session = { client: engine.client, M: { WasmWalletClient: { GenerateAppID: (n, u) => `appid:${n}|${u}` } } };
  return engine;
}
