import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:stackwallet/models/isar/models/contact_entry.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/pages/address_book_views/subviews/contact_popup.dart';
import 'package:stackwallet/providers/global/address_book_service_provider.dart';
import 'package:stackwallet/services/address_book_service.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/util.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/widgets/address_book_card.dart';

import '../app_config_test_utils.dart';
import '../sample_data/theme_json.dart';
import 'address_book_card_test.mocks.dart';

class MockedFunctions extends Mock {
  void showDialog();
}

@GenerateMocks([AddressBookService])
void main() {
  testWidgets('test returns Contact Address Entry', (widgetTester) async {
    final service = MockAddressBookService();
    const applicationThemesDirectoryPath = "";
    // Contacts only ever hold coins the build ships (a backup restore drops
    // the others), so the fixture uses one: Bitcoin Cash where it exists, as
    // upstream wrote it, otherwise a configured coin.
    final coin = configuredCoinOr(Bitcoincash(CryptoCurrencyNetwork.main));

    when(service.getContactById("default")).thenAnswer(
      (realInvocation) => ContactEntry(
        name: "John Doe",
        addresses: [
          ContactAddressEntry()
            ..coinName = coin.identifier
            ..address = "some ${coin.ticker} address"
            ..label = "Bills"
            ..other = null,
        ],
        isFavorite: true,
        customId: '',
      ),
    );

    await widgetTester.pumpWidget(
      ProviderScope(
        overrides: [
          addressBookServiceProvider.overrideWithValue(
            service,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: [
              StackColors.fromStackColorTheme(
                StackTheme.fromJson(
                  json: lightThemeJsonMap,
                ),
              ),
            ],
          ),
          home: const AddressBookCard(
            contactId: "default",
          ),
        ),
      ),
    );

    expect(find.text("John Doe"), findsOneWidget);
    expect(find.text(coin.ticker), findsOneWidget);

    if (Platform.isIOS || Platform.isAndroid) {
      await widgetTester.tap(find.byType(RawMaterialButton));
      expect(find.byType(ContactPopUp), findsOneWidget);
    } else if (Util.isDesktop) {
      expect(find.byType(RawMaterialButton), findsNothing);
    }
  });
}
