/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. Job: open a BEAM dApp, or install one of the checked dApps first.
// 2. Primary action: "Open" on an installed dApp (the whole card opens it);
//    "Install" on a bundled one. "Install from a file" is secondary.
// 3. Taps from app open: wallet → dApps → Open = 3 (4 the first time,
//    with Install).
//
// Exit-intent (§1.7) — what would make an impatient person close the app:
// * "Is this safe?" The first line says a dApp cannot move money without
//   asking; bundled dApps say they are checked against a pinned
//   fingerprint; a dApp from a file says plainly that Campfire did not
//   check it.
// * Waiting with no feedback: a row being installed says what is happening.
// * Errors that blame them or end nowhere: every failure says what
//   happened and the next step, and the list stays usable.
// * Platforms without the dApp window: the page says so up front instead
//   of failing on Open.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/dapps/dapp_installer.dart';
import '../../../wallets/beam/dapps/dapp_package.dart';
import '../../../wallets/beam/dapps/host/dapp_host.dart';
import '../../../wallets/beam/dapps/host/dapp_store_controller.dart';
import '../../../widgets/background.dart';
import '../../../widgets/beam/dapps/dapp_avatar.dart';
import '../../../widgets/beam/dapps/dapp_webview.dart';
import '../../../widgets/conditional_parent.dart';
import '../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../widgets/desktop/desktop_app_bar.dart';
import '../../../widgets/desktop/desktop_dialog.dart';
import '../../../widgets/desktop/desktop_scaffold.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/desktop/secondary_button.dart';
import '../../../widgets/rounded_container.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/stack_dialog.dart';
import 'dapp_browser_view.dart';

/// Picks a `.dapp` file; null when the user cancelled.
typedef DappFilePicker = Future<String?> Function();

/// The file picker's filter for a .dapp file. Phones get every file: iOS
/// has no type for ".dapp" (nothing declares one), so a ".dapp" filter
/// greys out every file there, and Android cannot map it to a MIME type
/// either. Whatever is picked is checked as a package when it is read
/// (DappStoreController.readFile).
({FileType type, List<String>? allowedExtensions}) dappFilePickerFilter({
  required bool phone,
}) => phone
    ? (type: FileType.any, allowedExtensions: null)
    : (type: FileType.custom, allowedExtensions: const ['dapp']);

class DappStoreView extends ConsumerStatefulWidget {
  const DappStoreView({
    super.key,
    required this.host,
    this.controller,
    this.pickFile,
    this.desktop,
    this.webviewAvailable,
  });

  static const String routeName = "/beamDappStore";
  static const String title = "dApps";

  final DappHost host;

  /// A ready controller (tests); otherwise one is made from [host].
  final DappStoreController? controller;
  final DappFilePicker? pickFile;

  /// Overrides `Util.isDesktop` (tests).
  final bool? desktop;

  /// Overrides the platform check for the dApp window (tests).
  final bool? webviewAvailable;

  @override
  ConsumerState<DappStoreView> createState() => _DappStoreViewState();
}

class _DappStoreViewState extends ConsumerState<DappStoreView> {
  DappStoreController? _controller;
  bool _ownsController = false;
  bool _setupFailed = false;

  bool get _desktop => widget.desktop ?? Util.isDesktop;

  @override
  void initState() {
    super.initState();
    unawaited(_setup());
  }

  Future<void> _setup() async {
    try {
      final c =
          widget.controller ??
          DappStoreController(
            installer: await widget.host.installer(),
            fetcher: widget.host.fetcher,
          );
      _ownsController = widget.controller == null;
      if (!mounted) {
        if (_ownsController) c.dispose();
        return;
      }
      c.addListener(_changed);
      setState(() {
        _controller = c;
        _setupFailed = false;
      });
      if (widget.controller == null || c.status == DappStoreStatus.loading) {
        await c.refresh();
      }
    } catch (_) {
      if (mounted) setState(() => _setupFailed = true);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    if (_ownsController) _controller?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- actions

  void _open(DappInstallation installation) {
    unawaited(
      Navigator.of(context).pushNamed(
        DappBrowserView.routeName,
        arguments: (host: widget.host, installation: installation),
      ),
    );
  }

  Future<void> _install(DappStoreItem item) async {
    final c = _controller;
    final entry = item.bundled;
    if (c == null || entry == null) return;
    try {
      await c.installBundled(entry);
      if (mounted) {
        unawaited(
          showFloatingFlushBar(
            type: FlushBarType.success,
            message: "${item.name} is installed",
            context: context,
          ),
        );
      }
    } catch (e) {
      if (mounted) _problem(dappInstallErrorText(e, name: item.name));
    }
  }

  Future<String?> _pickFile() async {
    final picker = widget.pickFile;
    if (picker != null) return picker();
    final filter = dappFilePickerFilter(
      phone: Platform.isAndroid || Platform.isIOS,
    );
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: "Choose a .dapp file",
      type: filter.type,
      allowedExtensions: filter.allowedExtensions,
      lockParentWindow: true,
    );
    return result?.paths.firstOrNull;
  }

  Future<void> _installFromFile() async {
    final c = _controller;
    if (c == null) return;
    final String? path;
    try {
      path = await _pickFile();
    } catch (_) {
      if (mounted) {
        _problem("Campfire couldn't open the file picker. Try again.");
      }
      return;
    }
    if (path == null || !mounted) return;
    final DappPackage package;
    try {
      package = await c.readFile(path);
    } catch (e) {
      if (mounted) _problem(dappInstallErrorText(e, name: "this dApp"));
      return;
    }
    if (!mounted) return;
    final existing = c.existingFor(package);
    final ok = await _confirmFromFile(
      package,
      existing,
      copies: c.bundledNameCopiedBy(package),
    );
    if (ok != true || !mounted) return;
    try {
      await c.installPackage(package, replace: existing != null);
      if (mounted) {
        unawaited(
          showFloatingFlushBar(
            type: FlushBarType.success,
            message: "${package.manifest.name} is installed",
            context: context,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        _problem(dappInstallErrorText(e, name: package.manifest.name));
      }
    }
  }

  Future<void> _remove(DappStoreItem item) async {
    final c = _controller;
    if (c == null) return;
    final ok = await _confirm(
      title: "Remove ${item.name}?",
      message:
          "Its files and the data it saved on this device are deleted. "
          "Your funds and transactions are not affected.",
      confirm: "Remove",
    );
    if (ok != true) return;
    try {
      await c.uninstall(item.guid);
    } catch (_) {
      if (mounted) {
        _problem(
          "Campfire couldn't remove ${item.name}. Nothing was changed. "
          "Try again.",
        );
      }
    }
  }

  void _problem(String message) => unawaited(
    showFloatingFlushBar(
      type: FlushBarType.warning,
      message: message,
      context: context,
    ),
  );

  Future<bool?> _confirmFromFile(
    DappPackage package,
    DappInstallation? existing, {
    String? copies,
  }) {
    final m = package.manifest;
    final lines = [
      "Version ${m.version ?? "not given"} · "
          "${m.publisher == null ? "unknown publisher" : "by ${m.publisher}"}",
      if (existing != null)
        "Replaces the installed version "
            "${existing.manifest.version ?? "(no version)"}.",
      if (copies != null)
        "Its name matches $copies, one of the dApps Campfire checks, but it "
            "is a different app.",
      "Campfire did not check this dApp: it is not one of the bundled "
          "dApps. Install it only if you trust where it came from. Payments, "
          "contract calls and signatures it asks for still come to Campfire "
          "for your approval, but it can read some wallet details without "
          "asking, and what you approve can't be undone.",
    ];
    return _confirm(
      title: "Install ${m.name}?",
      message: lines.join("\n\n"),
      confirm: existing == null ? "Install" : "Replace",
    );
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirm,
  }) {
    if (_desktop) {
      return showDialog<bool>(
        context: context,
        builder: (context) => DesktopDialog(
          maxWidth: 520,
          maxHeight: double.infinity,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: STextStyles.desktopH3(context)),
                const SizedBox(height: 16),
                Text(message, style: STextStyles.desktopTextSmall(context)),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: SecondaryButton(
                        label: "Cancel",
                        buttonHeight: ButtonHeight.l,
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: PrimaryButton(
                        label: confirm,
                        buttonHeight: ButtonHeight.l,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    final colors = Theme.of(context).extension<StackColors>()!;
    return showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        title: title,
        message: message,
        leftButton: TextButton(
          style: colors.getSecondaryEnabledButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            "Cancel",
            style: STextStyles.button(context)
                .copyWith(color: colors.accentColorDark),
          ),
        ),
        rightButton: TextButton(
          style: colors.getPrimaryEnabledButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirm, style: STextStyles.button(context)),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final desktop = _desktop;
    final content = _content(context, desktop);
    return ConditionalParent(
      condition: desktop,
      builder: (child) => DesktopScaffold(
        appBar: DesktopAppBar(
          isCompactHeight: true,
          useSpacers: false,
          background: Theme.of(context).extension<StackColors>()!.popupBG,
          leading: Expanded(
            child: Row(
              children: [
                const SizedBox(width: 32),
                AppBarIconButton(
                  size: 32,
                  color: Theme.of(context)
                      .extension<StackColors>()!
                      .textFieldDefaultBG,
                  shadows: const [],
                  icon: SvgPicture.asset(
                    Assets.svg.arrowLeft,
                    width: 18,
                    height: 18,
                    colorFilter: ColorFilter.mode(
                      Theme.of(context)
                          .extension<StackColors>()!
                          .topNavIconPrimary,
                      BlendMode.srcIn,
                    ),
                  ),
                  onPressed: Navigator.of(context).pop,
                ),
                const SizedBox(width: 12),
                Text(
                  DappStoreView.title,
                  style: STextStyles.desktopH3(context),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: child,
          ),
        ),
      ),
      child: ConditionalParent(
        condition: !desktop,
        builder: (child) => Background(
          child: Scaffold(
            backgroundColor: Theme.of(context)
                .extension<StackColors>()!
                .background,
            appBar: AppBar(
              automaticallyImplyLeading: false,
              leading: AppBarBackButton(
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                DappStoreView.title,
                style: STextStyles.navBarTitle(context),
              ),
            ),
            body: SafeArea(child: child),
          ),
        ),
        child: content,
      ),
    );
  }

  Widget _content(BuildContext context, bool desktop) {
    final c = _controller;
    final colors = Theme.of(context).extension<StackColors>()!;
    final pad = desktop ? 24.0 : 16.0;

    if (_setupFailed || c?.status == DappStoreStatus.failed) {
      return Padding(
        padding: EdgeInsets.all(pad),
        child: _Notice(
          title: "Campfire couldn't read your installed dApps",
          body:
              "Nothing was changed. Try again; if it keeps happening, "
              "restart Campfire.",
          action: PrimaryButton(
            label: "Try again",
            buttonHeight: desktop ? ButtonHeight.l : null,
            height: desktop ? null : 46,
            onPressed: () {
              setState(() => _setupFailed = false);
              if (c == null) {
                unawaited(_setup());
              } else {
                unawaited(c.refresh());
              }
            },
          ),
        ),
      );
    }
    if (c == null || c.status == DappStoreStatus.loading) {
      return Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text("Loading your dApps…", style: STextStyles.smallMed14(context)),
          ],
        ),
      );
    }

    final installed = c.installed;
    final available = c.available;
    final windowAvailable = widget.webviewAvailable ?? dappWebviewAvailable();
    return ListView(
      padding: EdgeInsets.all(pad),
      children: [
        Text(
          "Apps that run on BEAM. A dApp can't move your money: every "
          "payment or contract call comes to Campfire for your approval "
          "first.",
          style: STextStyles.smallMed14(context)
              .copyWith(color: colors.textDark),
        ),
        if (!windowAvailable) ...[
          const SizedBox(height: 12),
          RoundedContainer(
            color: colors.textFieldDefaultBG,
            child: Text(
              "$dappWindowPlatformsSentence On this computer you can "
              "install and manage them.",
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.textDark3),
            ),
          ),
        ],
        const SizedBox(height: 20),
        const _SectionLabel(text: "Installed"),
        const SizedBox(height: 8),
        if (installed.isEmpty)
          const _Notice(
            title: "No dApps installed yet",
            body:
                "Pick one under Available to install it. It takes a few "
                "seconds, and Campfire checks every byte against a pinned "
                "fingerprint.",
          ),
        for (final item in installed)
          _DappRow(
            item: item,
            busy: c.isBusy(item.guid),
            onTap: () => _open(item.installed!),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SecondaryButton(
                  key: Key("dappOpen_${item.guid}"),
                  label: "Open",
                  width: 76,
                  buttonHeight: desktop ? ButtonHeight.s : ButtonHeight.l,
                  enabled: !c.isBusy(item.guid),
                  onPressed: () => _open(item.installed!),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: Key("dappRemove_${item.guid}"),
                  tooltip: "Remove",
                  onPressed: c.isBusy(item.guid) ? null : () => _remove(item),
                  icon: SvgPicture.asset(
                    Assets.svg.trash,
                    width: 16,
                    height: 16,
                    colorFilter: ColorFilter.mode(
                      colors.textSubtitle1,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        const _SectionLabel(text: "Available"),
        const SizedBox(height: 8),
        if (available.isEmpty)
          const _Notice(
            title: "Every bundled dApp is installed",
            body: "You can still add another one from a .dapp file below.",
          ),
        for (final item in available)
          _DappRow(
            item: item,
            busy: c.isBusy(item.guid),
            trailing: SecondaryButton(
              key: Key("dappInstall_${item.guid}"),
              label: "Install",
              width: 88,
              buttonHeight: desktop ? ButtonHeight.s : ButtonHeight.l,
              enabled: !c.isBusy(item.guid),
              onPressed: () => _install(item),
            ),
          ),
        const SizedBox(height: 20),
        RoundedWhiteContainer(
          child: Flex(
            direction: desktop ? Axis.horizontal : Axis.vertical,
            crossAxisAlignment: desktop
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.stretch,
            children: [
              Text(
                "Have a .dapp file from a dApp's publisher?",
                style: STextStyles.smallMed12(context),
              ),
              if (desktop) const Spacer() else const SizedBox(height: 10),
              SecondaryButton(
                key: const Key("dappInstallFromFile"),
                label: "Install from file",
                width: desktop ? 200 : null,
                buttonHeight: desktop ? ButtonHeight.s : null,
                // 40 clipped the label by 2 px on phones; 46 as the other
                // phone buttons here.
                height: desktop ? null : 46,
                onPressed: _installFromFile,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: STextStyles.sectionLabelMedium12(context));
}

class _Notice extends StatelessWidget {
  const _Notice({required this.title, required this.body, this.action});

  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: STextStyles.w600_14(context)
                .copyWith(color: colors.textDark),
          ),
          const SizedBox(height: 4),
          Text(body, style: STextStyles.smallMed12(context)),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

class _DappRow extends StatelessWidget {
  const _DappRow({
    required this.item,
    required this.busy,
    required this.trailing,
    this.onTap,
  });

  final DappStoreItem item;
  final bool busy;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final installed = item.installed;
    final String meta;
    if (busy) {
      meta = installed == null
          ? "Downloading and checking the package…"
          : "Working…";
    } else if (installed == null) {
      meta = "${item.downloadLabel} · checked against a pinned fingerprint";
    } else {
      final v = installed.manifest.version;
      final version = v == null ? "No version" : "Version $v";
      meta = item.isPinned
          ? "$version · the checked bundled package"
          : "$version · installed from a file, not checked by Campfire";
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RoundedWhiteContainer(
        onPressed: busy ? null : onTap,
        child: Row(
          children: [
            DappAvatar(
              name: item.name,
              iconFile: item.iconFile,
              iconAsset: item.iconAsset,
              size: 40,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: STextStyles.w600_14(context)
                        .copyWith(color: colors.textDark),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.description!,
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (busy) ...[
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          meta,
                          style: STextStyles.w500_10(context).copyWith(
                            color: item.isPinned || busy
                                ? colors.textSubtitle2
                                : colors.warningForeground,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}
