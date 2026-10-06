/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Campfire's Send screen for a BEAM wallet (phone: the SendView route;
// desktop: the Send tab of the wallet view).
//
// Spec (USER_PSYCHOLOGY §6):
//   1. Job: pay someone BEAM (or a BEAM asset) — to an address or to a name
//      typed straight into the recipient field.
//   2. Primary CTA: "Send" (pinned on a phone, visible at 375 px without
//      scrolling); it opens Campfire's confirmation with the exact numbers.
//   3. Taps from app open: wallet → Send → "Send" → "Send …" + PIN (3 + PIN).
//
// Exit-intent (§1.7), and the answer to each:
//   * "Did that name resolve to the right person?" → a visible card with
//     the owner key and expiry; never resolved silently.
//   * "Why is Send grey?" → every block says why under its field, and the
//     sync banner says when sending comes back.
//   * "What will it cost?" → the fee is shown before the next screen; a
//     name payment says it is at least 0.011 BEAM, exact on confirm.
//   * "Is my comment public?" → the hint under it says who sees it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/isar/models/contact_entry.dart';
import '../../../models/send_view_auto_fill_data.dart';
import '../../../pages/address_book_views/address_book_view.dart';
import '../../../pages/send_view/confirm_transaction_view.dart';
import '../../../pages/send_view/sub_widgets/building_transaction_dialog.dart';
import '../../../pages_desktop_specific/desktop_home_view.dart';
import '../../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/address_book_address_chooser/address_book_address_chooser.dart';
import '../../../providers/global/barcode_scanner_provider.dart';
import '../../../providers/global/locale_provider.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../route_generator.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/logger.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../background.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/qr_code_scanner_dialog.dart';
import '../../stack_dialog.dart';
import 'beam_confirm_content.dart';
import 'beam_send_backend.dart';
import 'beam_send_form.dart';
import 'beam_send_model.dart';
import 'beam_send_review.dart';
import 'beam_send_widgets.dart';

/// The BEAM Send screen for [walletId], wired to the real wallet. Used by
/// `SendView` (phone) and `DesktopSend` (desktop) for a BEAM wallet.
class BeamSendScreen extends ConsumerStatefulWidget {
  const BeamSendScreen({
    super.key,
    required this.walletId,
    this.autoFillData,
    this.clipboard = const ClipboardWrapper(),
  });

  final String walletId;
  final SendViewAutoFillData? autoFillData;
  final ClipboardInterface clipboard;

  @override
  ConsumerState<BeamSendScreen> createState() => _BeamSendScreenState();
}

class _BeamSendScreenState extends ConsumerState<BeamSendScreen> {
  late final BeamWallet _wallet;
  late final BeamSendBackend _backend;
  final _balances = _Ticker();

  @override
  void initState() {
    super.initState();
    _wallet = ref.read(pWallets).getWallet(widget.walletId) as BeamWallet;
    _backend = BeamWalletSendBackend(_wallet);
  }

  @override
  void dispose() {
    _balances.dispose();
    super.dispose();
  }

  Future<String?> _scan(BuildContext context) async {
    try {
      if (BeamSendLayout.isDesktop(context)) {
        return await showDialog<String>(
          context: context,
          builder: (_) => const QrCodeScannerDialog(),
        );
      }
      final r = await ref.read(pBarcodeScanner).scan(context: context);
      return r.rawContent;
    } catch (e, s) {
      Logging.instance.w('BEAM send: QR scan failed', error: e, stackTrace: s);
      return null;
    }
  }

  Future<String?> _addressBook(BuildContext context) async {
    if (!BeamSendLayout.isDesktop(context)) {
      // Campfire's phone address book opens its own send flow per contact.
      await Navigator.of(
        context,
      ).pushNamed(AddressBookView.routeName, arguments: _wallet.cryptoCurrency);
      return null;
    }
    final entry = await showDialog<ContactAddressEntry?>(
      context: context,
      builder: (context) => DesktopDialog(
        maxWidth: 696,
        maxHeight: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Text(
                    'Address book',
                    style: STextStyles.desktopH3(context),
                  ),
                ),
                const DesktopDialogCloseButton(),
              ],
            ),
            Expanded(
              child: AddressBookAddressChooser(coin: _wallet.cryptoCurrency),
            ),
          ],
        ),
      ),
    );
    return entry?.address;
  }

  @override
  Widget build(BuildContext context) {
    // Balances live in Campfire's wallet cache; any change re-reads them.
    ref.listen(pWalletInfo(widget.walletId), (_, _) => _balances.tick());
    final auto = widget.autoFillData;
    return BeamSendPage(
      backend: _backend,
      coin: _wallet.cryptoCurrency,
      walletName: ref.watch(pWalletName(widget.walletId)),
      walletId: widget.walletId,
      locale: ref.watch(
        localeServiceChangeNotifierProvider.select((l) => l.locale),
      ),
      clipboard: widget.clipboard,
      balancesChanged: _balances,
      onScanQr: _scan,
      onAddressBook: _addressBook,
      initialRecipient: auto?.address,
      initialAmount: auto?.amount == null
          ? null
          : Amount.fromDecimal(auto!.amount!, fractionDigits: 8).raw,
    );
  }
}

class _Ticker extends ChangeNotifier {
  void tick() => notifyListeners();
}

/// The BEAM Send screen over any [BeamSendBackend]: the phone page (Campfire
/// app bar, scrolling form, "Send" pinned at the bottom) or the desktop
/// Send tab (the form with "Send" under it).
class BeamSendPage extends StatefulWidget {
  const BeamSendPage({
    super.key,
    required this.backend,
    required this.coin,
    required this.walletId,
    required this.locale,
    this.walletName,
    this.clipboard = const ClipboardWrapper(),
    this.balancesChanged,
    this.onScanQr,
    this.onAddressBook,
    this.initialRecipient,
    this.initialAmount,
    this.nameDebounce = const Duration(milliseconds: 400),
    this.minimumBuildTime = const Duration(milliseconds: 2500),
    this.routeOnSuccessName,
  });

  final BeamSendBackend backend;
  final CryptoCurrency coin;
  final String walletId;
  final String locale;
  final String? walletName;
  final ClipboardInterface clipboard;

  /// Fires when the wallet's cached balances change.
  final Listenable? balancesChanged;
  final BeamPickRecipient? onScanQr;
  final BeamPickRecipient? onAddressBook;
  final String? initialRecipient;
  final BigInt? initialAmount;
  final Duration nameDebounce;

  /// Campfire keeps its "Generating transaction" dialog up at least this
  /// long so it never flashes.
  final Duration minimumBuildTime;

  /// Where a sent payment returns to; Campfire's wallet view by default.
  final String? routeOnSuccessName;

  @override
  State<BeamSendPage> createState() => BeamSendPageState();
}

class BeamSendPageState extends State<BeamSendPage> {
  late final BeamSendModel model;
  final _form = GlobalKey<BeamSendFormState>();

  @override
  void initState() {
    super.initState();
    model = BeamSendModel(widget.backend, nameDebounce: widget.nameDebounce);
    widget.balancesChanged?.addListener(model.balancesChanged);
  }

  @override
  void dispose() {
    widget.balancesChanged?.removeListener(model.balancesChanged);
    model.dispose();
    super.dispose();
  }

  bool _desktop(BuildContext context) => BeamSendLayout.isDesktop(context);

  Future<void> _review() async {
    FocusScope.of(context).unfocus();
    final desktop = _desktop(context);
    var cancelled = false;
    unawaited(
      showDialog<void>(
        context: context,
        useSafeArea: false,
        barrierDismissible: false,
        builder: (context) {
          final dialog = BuildingTransactionDialog(
            coin: widget.coin,
            isSpark: false,
            onCancel: () {
              cancelled = true;
              if (desktop) Navigator.of(context).pop();
            },
          );
          return desktop
              ? DesktopDialog(
                  maxWidth: 400,
                  maxHeight: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: dialog,
                  ),
                )
              : dialog;
        },
      ),
    );

    BeamSendReview? review;
    Object? failure;
    try {
      final results = await Future.wait<Object?>([
        model.prepare(widget.coin),
        Future<void>.delayed(widget.minimumBuildTime),
      ]);
      review = results.first! as BeamSendReview;
    } catch (e, s) {
      failure = e;
      Logging.instance.w('BEAM send: not prepared', error: e, stackTrace: s);
    }
    if (!mounted) {
      review?.dispose();
      return;
    }
    if (cancelled) {
      review?.dispose();
      return;
    }
    Navigator.of(context, rootNavigator: true).pop(); // the building dialog

    if (failure != null || review == null) {
      await _showNotPrepared(failure ?? StateError('not prepared'), desktop);
      return;
    }
    final ready = review;
    final confirm = ConfirmTransactionView(
      txData: ready.txData,
      walletId: widget.walletId,
      beamReview: ready,
      routeOnSuccessName:
          widget.routeOnSuccessName ??
          (desktop ? DesktopHomeView.routeName : null),
      onSuccess: () => _form.currentState?.clear(),
    );
    if (desktop) {
      await showDialog<void>(
        context: context,
        builder: (context) => DesktopDialog(
          maxHeight: MediaQuery.of(context).size.height - 64,
          maxWidth: 580,
          child: confirm,
        ),
      );
    } else {
      await Navigator.of(context).push(
        RouteGenerator.getRoute<void>(
          shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
          builder: (_) => confirm,
          settings: const RouteSettings(name: ConfirmTransactionView.routeName),
        ),
      );
    }
    // Back on the form without sending: let the node switch go, and look
    // the name up again (it may have changed owner while on confirm).
    ready.dispose();
    if (mounted && ready.isName) model.recheckName();
  }

  Future<void> _showNotPrepared(Object e, bool desktop) {
    final message = BeamSendModel.describeError(e);
    const title = 'Nothing was sent';
    if (desktop) {
      return showDialog<void>(
        context: context,
        builder: (context) => DesktopDialog(
          maxWidth: 450,
          maxHeight: double.infinity,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: STextStyles.desktopH3(context)),
                const SizedBox(height: 12),
                Text(
                  message,
                  key: const Key('beamSendNotPreparedMessage'),
                  style: STextStyles.desktopTextExtraExtraSmall(context),
                ),
                const SizedBox(height: 32),
                PrimaryButton(
                  label: 'Back to the payment',
                  buttonHeight: ButtonHeight.l,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return showDialog<void>(
      context: context,
      builder: (context) => StackDialog(
        title: title,
        message: message,
        rightButton: TextButton(
          style: Theme.of(context)
              .extension<StackColors>()!
              .getPrimaryEnabledButtonStyle(context),
          child: Text(
            'Back to the payment',
            style: STextStyles.button(context),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = _desktop(context);
    final form = BeamSendForm(
      key: _form,
      model: model,
      locale: widget.locale,
      desktop: desktop,
      walletName: widget.walletName,
      clipboard: widget.clipboard,
      onScanQr: widget.onScanQr,
      onAddressBook: widget.onAddressBook,
      initialRecipient: widget.initialRecipient,
      initialAmount: widget.initialAmount,
    );
    final cta = ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final enabled = model.canReview;
        if (desktop) {
          return PrimaryButton(
            key: const Key('beamSendReviewButton'),
            buttonHeight: ButtonHeight.l,
            label: 'Send',
            enabled: enabled,
            onPressed: enabled ? _review : null,
          );
        }
        final colors = Theme.of(context).extension<StackColors>()!;
        return TextButton(
          key: const Key('beamSendReviewButton'),
          onPressed: enabled ? _review : null,
          style: enabled
              ? colors.getPrimaryEnabledButtonStyle(context)
              : colors.getPrimaryDisabledButtonStyle(context),
          child: Text('Send', style: STextStyles.button(context)),
        );
      },
    );

    if (desktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 4),
          form,
          const SizedBox(height: 36),
          cta,
        ],
      );
    }

    final colors = Theme.of(context).extension<StackColors>()!;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: BeamBackButton(
            desktop: false,
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            'Send ${widget.coin.ticker}',
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: const Key('beamSendScroll'),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: form,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(height: 48, child: cta),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
