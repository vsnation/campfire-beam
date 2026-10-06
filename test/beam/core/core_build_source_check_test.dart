/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// scripts/beam/core build reproducibility (security review finding 9):
// `check_source_tree` from common.sh against a small git repository shaped
// like the BEAM checkout (a superproject, a submodule, a patch series that
// touches both), the manifest guard, and the base image pin.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final String _common = p.absolute('scripts/beam/core/common.sh');

Future<ProcessResult> _git(String dir, List<String> args) async {
  final r = await Process.run('git', [
    '-c',
    'user.name=t',
    '-c',
    'user.email=t@example.invalid',
    '-c',
    'protocol.file.allow=always',
    '-c',
    'commit.gpgsign=false',
    ...args,
  ], workingDirectory: dir);
  if (r.exitCode != 0) {
    throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }
  return r;
}

void expectCheck(
  ({int code, List<String> paths}) r,
  int code,
  List<String> paths,
) {
  expect(r.paths, paths);
  expect(r.code, code);
}

void main() {
  late Directory tmp;
  late String src;
  late String patches;

  /// Runs `check_source_tree <src> <patches> sub` in bash: its exit code
  /// and the paths it printed.
  Future<({int code, List<String> paths})> check() async {
    final r = await Process.run('bash', [
      '-c',
      'set -euo pipefail; source "\$1"; check_source_tree "\$2" "\$3" sub',
      'bash',
      _common,
      src,
      patches,
    ]);
    final out = '${r.stdout}'.trim();
    return (
      code: r.exitCode,
      paths: out.isEmpty ? <String>[] : out.split('\n'),
    );
  }

  Future<void> applyPatch(String name) async {
    final r = await Process.run('bash', [
      '-c',
      'patch -p1 --forward -s < "\$1"',
      'bash',
      p.join(patches, name),
    ], workingDirectory: src);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('beam_core_src_');
    final sub = p.join(tmp.path, 'sub-origin');
    await Directory(sub).create();
    await _git(sub, ['init', '-q']);
    await File(p.join(sub, 'CMakeLists.txt')).writeAsString('sub v1\n');
    await _git(sub, ['add', '.']);
    await _git(sub, ['commit', '-q', '-m', 'sub']);

    src = p.join(tmp.path, 'beam');
    await Directory(p.join(src, 'wallet')).create(recursive: true);
    await _git(src, ['init', '-q']);
    await File(p.join(src, 'CMakeLists.txt')).writeAsString('a\nb\nc\n');
    await File(p.join(src, 'wallet', 'api.cpp')).writeAsString('bind any\n');
    await File(p.join(src, 'README')).writeAsString('readme\n');
    await _git(src, ['submodule', 'add', '-q', sub, 'sub']);
    await _git(src, ['add', '.']);
    await _git(src, ['commit', '-q', '-m', 'pinned']);

    patches = p.join(tmp.path, 'patches');
    await Directory(patches).create();
    // 0001 touches a file 0002 touches too, as 0003/0004 do in the real
    // series (CMakeLists.txt), and 0002 reaches into the submodule as 0004
    // does (3rdparty/re2).
    await File(p.join(patches, '0001-bind.patch')).writeAsString(
      '--- a/wallet/api.cpp\n'
      '+++ b/wallet/api.cpp\n'
      '@@ -1 +1 @@\n'
      '-bind any\n'
      '+bind loopback\n'
      '--- a/CMakeLists.txt\n'
      '+++ b/CMakeLists.txt\n'
      '@@ -1,3 +1,3 @@\n'
      '-a\n'
      '+A\n'
      ' b\n'
      ' c\n',
    );
    await File(p.join(patches, '0002-flags.patch')).writeAsString(
      '--- a/CMakeLists.txt\n'
      '+++ b/CMakeLists.txt\n'
      '@@ -1,3 +1,3 @@\n'
      ' A\n'
      ' b\n'
      '-c\n'
      '+C\n'
      '--- a/sub/CMakeLists.txt\n'
      '+++ b/sub/CMakeLists.txt\n'
      '@@ -1 +1 @@\n'
      '-sub v1\n'
      '+sub v1 patched\n',
    );
  });

  tearDown(() => tmp.delete(recursive: true));

  group('check_source_tree', () {
    test('the pinned commit, as cloned: clean', () async {
      expectCheck(await check(), 0, []);
    });

    test('every patch applied, or only the first of the series: clean',
        () async {
      await applyPatch('0001-bind.patch');
      expect((await check()).code, 0, reason: 'first patch only');
      await applyPatch('0002-flags.patch');
      expectCheck(await check(), 0, []);
    });

    test('an edit to a file no patch touches is reported', () async {
      await applyPatch('0001-bind.patch');
      await applyPatch('0002-flags.patch');
      await File(p.join(src, 'README')).writeAsString('edited\n');
      expectCheck(await check(), 1, ['README']);
    });

    test('an extra edit inside a patched file is reported', () async {
      await applyPatch('0001-bind.patch');
      await File(
        p.join(src, 'wallet', 'api.cpp'),
      ).writeAsString('bind loopback\nbackdoor()\n');
      final r = await check();
      expect(r.code, 1);
      expect(r.paths.single, startsWith('wallet/api.cpp'));
    });

    test('an untracked file is reported (CMake would read it)', () async {
      await File(p.join(src, 'wallet', 'extra.cpp')).writeAsString('x\n');
      expectCheck(await check(), 1, ['wallet/extra.cpp']);
    });

    test('a deleted file is reported', () async {
      await File(p.join(src, 'README')).delete();
      final r = await check();
      expect(r.code, 1);
      expect(r.paths.single, startsWith('README'));
    });

    test('edits and untracked files inside the submodule are reported',
        () async {
      await applyPatch('0001-bind.patch');
      await applyPatch('0002-flags.patch');
      expect((await check()).code, 0, reason: 'patched submodule file');
      await File(p.join(src, 'sub', 'new.c')).writeAsString('x\n');
      expectCheck(await check(), 1, ['sub/new.c']);
    });

    test('a submodule moved off its pinned commit is reported', () async {
      await File(p.join(src, 'sub', 'CMakeLists.txt')).writeAsString('v2\n');
      await _git(p.join(src, 'sub'), ['commit', '-q', '-am', 'moved']);
      final r = await check();
      expect(r.code, 1);
      expect(r.paths.single, startsWith('sub (at '));
    });

    test('it never changes the tree', () async {
      await File(p.join(src, 'README')).writeAsString('edited\n');
      final before = (await _git(src, ['status', '--porcelain'])).stdout;
      await check();
      expect((await _git(src, ['status', '--porcelain'])).stdout, before);
      expect(
        await File(p.join(src, 'README')).readAsString(),
        'edited\n',
      );
    });
  }, skip: Platform.isWindows ? 'bash and git' : false);

  test('prepare_source fails on a modified tree unless explicitly allowed, '
      'and make_manifest then refuses to pin', () {
    final common = File(_common).readAsStringSync();
    expect(common, contains('if ! modified="\$(check_source_tree'));
    expect(common, contains('BEAM_ALLOW_MODIFIED_SOURCE'));
    expect(
      RegExp(r'die "\$BEAM_SRC differs from').hasMatch(common),
      isTrue,
    );
    final manifest = File(
      'scripts/beam/core/make_manifest.sh',
    ).readAsStringSync();
    expect(manifest, contains('.modified_source'));
  });

  test('make_manifest.sh refuses out/ built from a modified tree', () async {
    final root = p.join(tmp.path, 'build-root');
    await Directory(p.join(root, 'out')).create(recursive: true);
    await File(
      p.join(root, 'out', '.modified_source'),
    ).writeAsString('README\n');
    final before = File('scripts/beam/core/manifest.json').readAsStringSync();
    final r = await Process.run(
      'bash',
      [p.absolute('scripts/beam/core/make_manifest.sh')],
      environment: {'BEAM_CORE_BUILD_ROOT': root},
    );
    expect(r.exitCode, isNot(0));
    expect('${r.stderr}', contains('modified BEAM tree'));
    expect(
      File('scripts/beam/core/manifest.json').readAsStringSync(),
      before,
    );
  }, skip: Platform.isWindows ? 'bash' : false);

  test('the Linux builder image is pinned by digest, never a tag', () {
    final docker = File(
      'scripts/beam/core/docker/Dockerfile',
    ).readAsStringSync();
    final arg = RegExp(
      r'^ARG BASE_IMAGE=(.+)$',
      multiLine: true,
    ).firstMatch(docker)!.group(1)!;
    expect(arg, matches(RegExp(r'^ubuntu@sha256:[0-9a-f]{64}$')));
    expect(docker, contains(r'FROM ${BASE_IMAGE}'));

    final build = File('scripts/beam/core/build_linux.sh').readAsStringSync();
    for (final m in RegExp(
      r'^UBUNTU_2204_\w+="([^"]+)"$',
      multiLine: true,
    ).allMatches(build)) {
      expect(m.group(1), matches(RegExp(r'@sha256:[0-9a-f]{64}$')));
    }
    expect(build, contains('is not pinned by digest'));
    expect(build, contains('--build-arg BASE_IMAGE="\$base"'));
  });
}
