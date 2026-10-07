/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A /bin/sh stand-in for beam-node and a fixture around it, shared by the
// node process and coordinator tests. No real key or password: the values
// below are made up.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_binaries.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_process.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';

/// Owner keys are base64 (`KeyString::Export`). Made up, never a real key.
const fakeOwnerKey =
    'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5'
    'ejAxMjM0NTY3ODkrL0FCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFla+/==';
const fakePassword = 'Fake-Node-Pass-For-Tests-42';

Matcher nodeError(BeamNodeError kind) =>
    isA<BeamNodeException>().having((e) => e.kind, 'kind', kind);

/// A beam-node stand-in. It reads its config the way BEAM does (open, then
/// print the path), records argv / CWD / pid and whether the file was
/// unlinked while it ran, then behaves per `mode` and replays `script`
/// (`sleep N` and `exit N` lines are commands). It stays a /bin/sh process
/// (no `exec`), so its command line keeps `beam-node --storage=node.db`.
const fakeNode = r'''#!/bin/sh
# beam-node stand-in
here=$(cd "$(dirname "$0")" && pwd)
mode=$(cat "$here/mode" 2>/dev/null)
# Record the pid before anything else in this mode: the test gives the node
# one second to read its config, and under full-suite load the steps below
# could outlast it, leaving pids.log empty.
if [ "$mode" = noconfig ]; then
  case " $* " in *" --config_file="*)
    echo "$$" >> "$here/pids.log"; sleep 30; exit 0 ;;
  esac
fi
cfg=""; port=""
for a in "$@"; do
  case "$a" in
    --config_file=*) cfg="${a#--config_file=}" ;;
    --port=*) port="${a#--port=}" ;;
  esac
done
case " $* " in *" --orphan "*) while :; do sleep 1; done ;; esac
printf 'I 2026-10-06.12:00:00.000 Rules signature: network=mainnet\n'
printf '\t3928666-96df3f33ee02ad9e\n'
if [ -z "$cfg" ]; then echo "Port must be specified"; exit 0; fi
printf '%s\n' "$*" >> "$here/argv.log"
pwd >> "$here/cwd.log"
echo "$$" >> "$here/pids.log"
content=$(cat "$cfg")
echo "Reading config from $cfg"
i=0
while [ -f "$cfg" ] && [ $i -lt 60 ]; do sleep 0.05; i=$((i+1)); done
if [ -f "$cfg" ]; then echo cfg-kept >> "$here/evidence.log"
else echo cfg-unlinked >> "$here/evidence.log"; fi
key=$(printf '%s\n' "$content" | sed -n 's/^owner_key=//p')
pass=$(printf '%s\n' "$content" | sed -n 's/^pass=//p')
if [ -n "$key" ] && [ -n "$pass" ]; then
  echo cfg-has-key-and-pass >> "$here/evidence.log"
fi
mkdir -p logs
echo "W 2026-10-06.12:00:00.000 own file log" > logs/node_26_10_06.log
echo "I 2026-10-06.12:00:00.001 starting a node on $port port..."
case "$mode" in
  badkey) echo "E 2026-10-06.12:00:00.002 key import failed"; exit 0 ;;
  echokey)
    echo "I 2026-10-06.12:00:00.002 debug $key"
    echo "I 2026-10-06.12:00:00.002 owner_key=$key"
    echo "I 2026-10-06.12:00:00.002 typed $pass" ;;
esac
echo "I 2026-10-06.12:00:00.003 Initial Tip: 0-0000000000000000"
echo "I 2026-10-06.12:00:00.003 Tx replication is OFF"
echo "I 2026-10-06.12:00:00.003 Owned accounts :"
if [ "$mode" != noowners ]; then
  printf '\tFakeEndpointEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE\n'
fi
echo ""
if [ -f "$here/script" ]; then
  while IFS= read -r line; do
    case "$line" in
      "sleep "*) sleep "${line#sleep }" ;;
      "exit "*) exit "${line#exit }" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$here/script"
fi
if [ "$mode" = ignoreterm ]; then trap '' TERM; fi
while :; do sleep 1; done
''';

Future<String> writeExe(String path, String body) async {
  await File(path).writeAsString(body);
  await Process.run('chmod', ['755', path]);
  return path;
}

Future<bool> running(int pid) async {
  final r = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
  return r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty;
}

Future<int> deadPid() async {
  final proc = await Process.start('true', const []);
  await proc.exitCode;
  return proc.pid;
}

/// Test fixture: a temp root, the stand-in, and a BeamBinaries trusting it.
class NodeFixture {
  NodeFixture._(this.tmp, this.binDir, this.binaries);

  static Future<NodeFixture> create() async {
    final tmp = await Directory.systemTemp.createTemp('beam_node_proc_');
    final binDir = p.join(tmp.path, 'bin');
    await Directory(binDir).create();
    final exe = await writeExe(p.join(binDir, 'beam-node'), fakeNode);
    final binaries = BeamBinaries(
      binDir: binDir,
      platform: 'fake',
      manifest: {
        'fake': {'beam-node': await BeamBinaries.sha256OfFile(exe)},
      },
    );
    return NodeFixture._(tmp, binDir, binaries);
  }

  final Directory tmp;
  final String binDir;
  final BeamBinaries binaries;

  String get root => p.join(tmp.path, 'beam');
  String get nodeDir => p.join(root, 'node');

  final hostLog = <String>[];

  BeamNodeProcess node({
    Duration configReadTimeout = const Duration(seconds: 5),
    Duration stopGrace = const Duration(seconds: 2),
    int maxLogBytes = 8 * 1024 * 1024,
  }) => BeamNodeProcess(
    rootDir: root,
    binaries: binaries,
    log: hostLog.add,
    configReadTimeout: configReadTimeout,
    startupWindow: const Duration(seconds: 3),
    stopGrace: stopGrace,
    maxLogBytes: maxLogBytes,
  );

  Future<void> mode(String m) =>
      File(p.join(binDir, 'mode')).writeAsString(m);

  Future<void> script(List<String> lines) =>
      File(p.join(binDir, 'script')).writeAsString('${lines.join('\n')}\n');

  Future<List<String>> lines(String name) async {
    final f = File(p.join(binDir, name));
    return await f.exists() ? f.readAsLines() : <String>[];
  }

  Future<List<String>> secretEntries() async {
    if (!await Directory(nodeDir).exists()) return [];
    return (await Directory(nodeDir).list().toList())
        .map((e) => p.basename(e.path))
        .where((n) => n.startsWith(kSecretPrefix) || n.endsWith('.cfg'))
        .toList();
  }

  Future<String> campfireLog() async {
    final dir = Directory(p.join(nodeDir, 'logs'));
    final files = await dir
        .list()
        .where((e) => p.basename(e.path).startsWith('campfire-node-'))
        .cast<File>()
        .toList();
    final out = StringBuffer();
    for (final f in files) {
      // The node may rotate a file away between the listing and the read
      // (the rollover test polls while it writes): a vanished file is
      // simply not there any more.
      try {
        out.writeln(await f.readAsString());
      } on PathNotFoundException {
        continue;
      }
    }
    return out.toString();
  }
}
