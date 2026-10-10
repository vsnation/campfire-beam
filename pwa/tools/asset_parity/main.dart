// Runs the desktop app's asset catalogue (lib/wallets/beam/assets/
// beam_asset_catalog.dart, copied by tools/asset_parity/run.mjs into a plain Dart
// package) over every asset of the input and prints what it shows. The web
// wallet's test/unit/asset_parity.test.mjs compares lib/meta.js with this.
import 'dart:convert';
import 'dart:io';

import 'package:campfire_parity/wallets/beam/assets/beam_asset_catalog.dart';
import 'package:campfire_parity/wallets/beam/contracts/dex/beam_lp_tokens.dart';
import 'package:campfire_parity/wallets/beam/models/beam_asset_info.dart';

Map<String, Object?> look(BeamAssetDisplay d) => {
      'name': d.name,
      'symbol': d.symbol,
      'label': d.label,
      'verified': d.verified,
      'icon': d.icon,
      'framed': d.icon == null ? null : BeamAssetCatalog.frameInset(d.icon!),
      'impersonates': d.impersonates,
      'pool': d.pool == null
          ? null
          : {'aid1': d.pool!.aid1, 'aid2': d.pool!.aid2, 'kind': d.pool!.kind},
    };

void main(List<String> args) {
  final input = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final rows = [...(input['assets'] as List), ...(input['extras'] as List)];
  for (final p in [...(input['pools'] as List), ...(input['extraPools'] as List)]) {
    BeamLpTokens.learn(BeamLpPool(
      lpToken: p['lpToken'] as int,
      aid1: p['aid1'] as int,
      aid2: p['aid2'] as int,
      kind: p['kind'] as int,
    ));
  }
  final meta = <int, BeamAssetMetadata>{
    for (final r in rows)
      if (r['metadata'] != null)
        r['id'] as int: BeamAssetMetadata.parse(r['metadata'] as String),
  };
  final withMetadata = <String, Object?>{};
  final bare = <String, Object?>{};
  for (final r in rows) {
    final id = r['id'] as int;
    withMetadata['$id'] = look(BeamAssetCatalog.display(id, meta[id], metadataOf: (i) => meta[i]));
    // What a list shows before any metadata has arrived.
    bare['$id'] = look(BeamAssetCatalog.display(id, null));
  }
  stdout.write(jsonEncode({'withMetadata': withMetadata, 'bare': bare}));
}
