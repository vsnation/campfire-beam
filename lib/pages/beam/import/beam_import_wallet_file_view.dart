/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  bring a BEAM wallet you already have as a wallet.db file (and its
//         password) into BEAM Campfire — no recovery phrase needed.
//   CTA:  "Import my wallet".
//   Taps: My Campfire → Import wallet.db (1) → Choose the file (2) →
//         password → Import my wallet (3).
//
// Exit-intent: "will this change or break my original file?" → said
// first: it is copied, the original is only read; "which password?" → the
// field says it is the one set in the BEAM wallet the file comes from;
// "where is my wallet.db?" → the usual places are listed under the button;
// "what if I lose it later?" → stated plainly: no recovery phrase here, the
// file and its password are the backup; "it failed" → every error says what
// to do next and never blames the person.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../pages_desktop_specific/desktop_home_view.dart';
import '../../../providers/db/main_db_provider.dart';
import '../../../providers/global/node_service_provider.dart';
import '../../../providers/global/prefs_provider.dart';
import '../../../providers/global/secure_store_provider.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import '../../../wallets/beam/wallet/beam_wallet_file_import.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../add_wallet_views/restore_wallet_view/restore_wallet_view.dart';
import '../../home_view/home_view.dart';

/// Picks a file. Tests replace it.
typedef BeamWalletFilePicker = Future<String?> Function();

/// Runs the import. Tests replace it.
typedef BeamWalletFileImport =
    Future<BeamWallet> Function({
      required String name,
      required String sourcePath,
      required String password,
    });

/// "Import wallet.db": a BEAM wallet from its file and password.
class BeamImportWalletFileView extends ConsumerStatefulWidget {
  const BeamImportWalletFileView({
    super.key,
    this.pickFile,
    this.import,
    this.nameTaken,
  });

  static const routeName = '/beamImportWalletFile';
  static const title = 'Import a BEAM wallet file';

  /// The button that leads here, in My Campfire's wallet list.
  static const entryLabel = 'Import wallet.db';

  final BeamWalletFilePicker? pickFile;
  final BeamWalletFileImport? import;

  /// Whether a wallet already has this name; defaults to the app's wallets.
  final bool Function(String name)? nameTaken;

  @override
  ConsumerState<BeamImportWalletFileView> createState() =>
      _BeamImportWalletFileViewState();
}

/// The texts of this screen, kept together (and tested).
abstract final class BeamImportText {
  static const intro =
      'Already have a BEAM wallet as a wallet.db file? Choose it and enter '
      'its password. BEAM Campfire makes its own copy; your file is not '
      'changed.';
  static const choose = 'Choose wallet.db';
  static const change = 'Choose another file';
  static const where =
      'Usually: BEAM desktop wallet → its data folder (wallet.db); BEAM Light '
      'Wallet → wallets/<name>/wallet.db. Close that wallet app first.';
  static const nameLabel = 'Wallet name';
  static const passwordLabel = 'Wallet password';
  static const passwordHelper =
      'The password you set in the BEAM wallet this file comes from.';
  static const noPhrase =
      'This wallet will have no recovery phrase in BEAM Campfire. Keep the '
      'original file and its password safe: they are how you get it back.';
  static const cta = 'Import my wallet';
  static const busy = 'Importing…';
  static const pickFailed =
      "BEAM Campfire couldn't open the file picker. Try again.";
  static const nameTaken = 'You already have a wallet with this name.';
}

class _BeamImportWalletFileViewState
    extends ConsumerState<BeamImportWalletFileView> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  String? _path;
  String? _problem;
  bool _busy = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<String?> _pick() async {
    final picker = widget.pickFile;
    if (picker != null) return picker();
    // Any file: BEAM names it wallet.db, but a copy may be renamed, and
    // phones filter unknown extensions badly.
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a BEAM wallet.db',
      type: FileType.any,
      lockParentWindow: true,
    );
    return result?.paths.firstOrNull;
  }

  Future<void> _choose() async {
    final String? path;
    try {
      path = await _pick();
    } catch (_) {
      if (mounted) setState(() => _problem = BeamImportText.pickFailed);
      return;
    }
    if (path == null || !mounted) return;
    setState(() {
      _path = path;
      _problem = null;
      if (_name.text.trim().isEmpty) _name.text = _suggestName(path!);
    });
  }

  /// The wallet's folder name when it says something ("alice" for
  /// wallets/alice/wallet.db), else "BEAM wallet".
  static String _suggestName(String path) {
    final folder = p.basename(p.dirname(path)).trim();
    const generic = {'', '.', 'wallets', 'beam', 'documents', 'downloads'};
    if (generic.contains(folder.toLowerCase()) || folder.length > 32) {
      return 'BEAM wallet';
    }
    return folder;
  }

  bool get _ready =>
      _path != null &&
      _password.text.isNotEmpty &&
      _name.text.trim().isNotEmpty &&
      !_busy;

  Future<void> _import() async {
    final path = _path;
    if (path == null || !_ready) return;
    final name = _name.text.trim();
    final taken =
        widget.nameTaken?.call(name) ??
        ref
            .read(pWallets)
            .wallets
            .any((w) => w.info.name.toLowerCase() == name.toLowerCase());
    if (taken) {
      setState(() => _problem = BeamImportText.nameTaken);
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final run =
          widget.import ??
          ({
            required String name,
            required String sourcePath,
            required String password,
          }) => importBeamWalletFile(
            name: name,
            sourcePath: sourcePath,
            password: password,
            mainDB: ref.read(mainDBProvider),
            secureStorage: ref.read(secureStoreProvider),
            nodeService: ref.read(nodeServiceChangeNotifierProvider),
            prefs: ref.read(prefsChangeNotifierProvider),
          );
      final wallet = await run(
        name: name,
        sourcePath: path,
        password: _password.text,
      );
      if (!mounted) return;
      _password.clear();
      ref.read(pWallets).addWallet(wallet);
      _open(wallet);
    } on BeamWalletException catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } catch (_) {
      if (mounted) setState(() => _problem = BeamImportMessages.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(BeamWallet wallet) {
    if (BeamLayoutScope.isDesktop(context)) {
      final container = ProviderScope.containerOf(context, listen: false);
      Navigator.of(context).popUntil(
        (r) => r.settings.name == DesktopHomeView.routeName || r.isFirst,
      );
      RestoreWalletView.openOnDesktop(container, wallet.walletId);
      return;
    }
    final nav = Navigator.of(context);
    unawaited(
      nav.pushNamedAndRemoveUntil(HomeView.routeName, (route) => false),
    );
    unawaited(RestoreWalletView.openRestoredWallet(nav, wallet));
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    return BeamPageScaffold(
      title: BeamImportWalletFileView.title,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(BeamImportText.intro, style: STextStyles.itemSubtitle(context)),
          const BeamGap(16),
          if (path == null) ...[
            BeamCtaBar(
              primaryKey: const ValueKey('import-choose'),
              label: BeamImportText.choose,
              onPressed: _busy ? null : _choose,
            ),
            const BeamGap(8),
            Text(BeamImportText.where, style: STextStyles.label(context)),
          ] else ...[
            BeamDetailCard(
              children: [
                BeamDetailRow(label: 'File', value: p.basename(path)),
                BeamDetailRow(label: 'Folder', value: p.dirname(path)),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: CustomTextButton(
                key: const ValueKey('import-change'),
                text: BeamImportText.change,
                enabled: !_busy,
                onTap: _choose,
              ),
            ),
            const BeamGap(),
            BeamTextField(
              fieldKey: const ValueKey('import-name'),
              controller: _name,
              label: BeamImportText.nameLabel,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
            ),
            const BeamGap(),
            BeamTextField(
              fieldKey: const ValueKey('import-password'),
              controller: _password,
              label: BeamImportText.passwordLabel,
              helper: BeamImportText.passwordHelper,
              obscureText: !_showPassword,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => unawaited(_import()),
              suffix: IconButton(
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () =>
                    setState(() => _showPassword = !_showPassword),
              ),
            ),
            const BeamGap(16),
            const BeamNotice(
              kind: BeamNoticeKind.warning,
              message: BeamImportText.noPhrase,
            ),
          ],
          if (_problem != null) ...[
            const BeamGap(),
            BeamNotice(
              key: const ValueKey('import-problem'),
              kind: BeamNoticeKind.danger,
              message: _problem!,
            ),
          ],
        ],
      ),
      bottom: path == null
          ? null
          : BeamCtaBar(
              primaryKey: const ValueKey('import-cta'),
              label: BeamImportText.cta,
              busy: _busy,
              busyLabel: BeamImportText.busy,
              onPressed: _ready ? _import : null,
            ),
    );
  }
}

