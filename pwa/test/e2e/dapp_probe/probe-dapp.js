// The "dApp" the probe runs: from inside its frame, it tries what a hostile
// dApp would try, and reports through the bridge like any dApp request.
(async function () {
  var r = { origin: self.origin, href: location.href, ua: /iPhone|iPad/.test(navigator.userAgent) ? 'ios' : /Android/.test(navigator.userAgent) ? 'android-shape' : /QtWebEngine/.test(navigator.userAgent) ? 'qt-shape' : 'other' };
  var t = function (k, fn) { try { r[k] = fn(); } catch (e) { r[k] = 'throws ' + e.name; } };
  t('parentDocument', function () { return typeof parent.document.body; });
  t('parentLocalStorage', function () { return parent.localStorage.length; });
  t('parentIndexedDB', function () { return typeof parent.indexedDB.open; });
  t('parentEngine', function () { return typeof parent.BeamModule; });
  t('serviceWorker', function () { return typeof navigator.serviceWorker.controller; });
  t('ownLocalStorage', function () { localStorage.setItem('k', 'v'); return localStorage.getItem('k') + '/' + localStorage.length; });
  r.idb = await new Promise(function (resolve) {
    try {
      var q = indexedDB.open('beam-campfire-app');
      q.onsuccess = function () { resolve('opened v' + q.result.version + ' stores=' + q.result.objectStoreNames.length); };
      q.onerror = function () { resolve('error ' + q.error); };
    } catch (e) { resolve('throws ' + e.name); }
  });
  r.caches = await (async function () { try { await caches.keys(); return 'reachable'; } catch (e) { return 'refused ' + e.name; } })();
  var attempt = function (url, opts) { return fetch(url, opts).then(function (x) { return 'status ' + x.status; }, function (e) { return 'refused ' + e.name; }); };
  r.walletIndex = await attempt(location.origin + '/index.html');
  r.walletIndexNoCors = await attempt(location.origin + '/index.html', { mode: 'no-cors' });
  r.notGranted = await attempt('https://api.coingecko.com/api/v3/ping');
  r.ownFile = await fetch('./data.txt').then(function (x) { return x.text(); }, function (e) { return 'refused ' + e.name; });
  t('evalBlocked', function () { try { eval('1'); return false; } catch (e) { return true; } });
  r.walletShape = typeof window.BEAM === 'object' && typeof window.BEAM.callWalletApi === 'function';
  window.BEAM.callWalletApi(JSON.stringify({ jsonrpc: '2.0', id: 'report', method: 'invoke_contract', params: { contract: [0], args: 'report=' + JSON.stringify(r) } }));
})();
