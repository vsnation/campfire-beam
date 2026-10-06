/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../rpc/beam_transport.dart';

/// Why a `.dapp` package was refused. The first members mirror beam-ui's
/// `DAppInstallError` (`apps_view.h:132-143`) so the UI can reuse its
/// wording; the rest are checks beam-ui does not make.
enum DappInstallError {
  /// The bytes are not a readable zip archive.
  cantOpenFile,

  /// `manifest.json` is missing, too large, not UTF-8 or not JSON.
  cantReadManifest,

  /// The manifest asks for an API version this wallet does not serve.
  unsupported,

  /// The manifest or an archive entry breaks a rule (see the message).
  invalidFile,

  /// A dApp with this `guid` and version is already installed.
  alreadyInstalled,

  /// The install directory could not be prepared.
  folderPrepFailed,

  /// Writing or verifying the extracted files failed.
  extractFailed,

  /// The package exceeds a size, count or compression limit.
  tooLarge,

  /// An entry is a symlink, device or other non-regular file.
  unsafeEntry,

  /// An entry name is absolute, escapes the package, or is otherwise not a
  /// plain relative path.
  unsafePath,

  /// A package from a file uses the `guid` of a bundled dApp but is not its
  /// pinned package. It would inherit that dApp's origin, browser storage
  /// and transaction scope, and look exactly like it.
  reservedGuid,
}

/// A `.dapp` package could not be read, installed or removed.
class DappInstallException implements Exception {
  const DappInstallException(this.error, this.message, {this.dappName});

  final DappInstallError error;

  /// For logs and support; never contains file contents.
  final String message;

  /// For [DappInstallError.reservedGuid]: the bundled dApp the file
  /// claims to be.
  final String? dappName;

  @override
  String toString() => 'DappInstallException(${error.name}): $message';
}

/// JSON-RPC error codes the dApp host answers with. Codes and messages are
/// the core's (`wallet/api/base/api_errors.h:18-43`), so dApps written for
/// the Qt and mobile wallets recognise them.
abstract final class DappRpcErrors {
  static const invalidJsonRpc = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internalError = -32603;
  static const invalidAddress = -32003;
  static const paymentProofExportError = -32007;
  static const throttle = -32014;
  static const notAllowed = -32020;
  static const userRejected = -32021;

  static const _messages = {
    invalidJsonRpc: 'Invalid JSON-RPC.',
    methodNotFound: 'Procedure not found.',
    invalidParams: 'Invalid parameters.',
    internalError: 'Internal JSON-RPC error.',
    invalidAddress: 'Invalid address.',
    paymentProofExportError: 'Cannot export payment proof',
    throttle: 'Requests limit exceeded',
    notAllowed: 'Call is not allowed',
    userRejected: 'Call is rejected by user',
  };

  /// The core's message for [code].
  static String messageFor(int code) =>
      _messages[code] ?? 'Internal JSON-RPC error.';

  /// A [BeamRpcException] with the core's message and an optional detail in
  /// `data`, as `ApiBase::formError` builds it.
  static BeamRpcException error(int code, [String? detail]) =>
      BeamRpcException(code, messageFor(code), detail);
}
