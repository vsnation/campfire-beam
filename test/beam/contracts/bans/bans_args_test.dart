// Exact args strings for every BANS app-shader action (`app.cpp:21-85`).

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_args.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_exceptions.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_name.dart';

void main() {
  const a = BansArgs.mainnet;
  const cid = kBansCid;
  final zero = '00' * 33;
  const key =
      '72e368c016bec94e0aa0274aae5b6e9ef4bbb64d0ce1436acb134488570d51ef01';
  final alice = BansName('alice');

  test('read-only actions', () {
    expect(a.myKey(), 'role=user,action=my_key,cid=$cid');
    expect(a.userView(), 'role=user,action=view,cid=$cid');
    expect(a.viewParams(), 'role=manager,action=view_params,cid=$cid');
    expect(
      a.viewName(alice),
      'role=manager,action=view_name,cid=$cid,name=alice',
    );
    expect(
      a.viewDomain(),
      'role=manager,action=view_domain,cid=$cid,pk=$zero',
    );
    expect(
      a.viewDomain(ownerKey: key),
      'role=manager,action=view_domain,cid=$cid,pk=$key',
    );
  });

  test('writes', () {
    expect(
      a.register(alice, 1),
      'role=user,action=domain_register,cid=$cid,name=alice,nPeriods=1',
    );
    expect(
      a.extend(alice, 50),
      'role=user,action=domain_extend,cid=$cid,name=alice,nPeriods=50',
    );
    expect(
      a.setOwner(alice, key),
      'role=user,action=domain_set_owner,cid=$cid,name=alice,pkOwner=$key',
    );
    expect(
      a.setPrice(alice, 0, BigInt.from(50000000000)),
      'role=user,action=domain_set_price,cid=$cid,name=alice,aid=0,'
      'amount=50000000000',
    );
    expect(
      a.setPrice(alice, 7, BigInt.zero),
      'role=user,action=domain_set_price,cid=$cid,name=alice,aid=7,amount=0',
    );
    expect(a.buy(alice), 'role=user,action=domain_buy,cid=$cid,name=alice');
    expect(
      a.pay(alice, 174, BigInt.from(12345)),
      'role=manager,action=pay,cid=$cid,name=alice,aid=174,amount=12345',
    );
  });

  test('claims always pass every argument the shader reads', () {
    expect(
      a.receive(assetId: 0),
      'role=user,action=receive,cid=$cid,pkOwner=$zero,aid=0,amount=0',
    );
    expect(
      a.receive(assetId: 3, amount: BigInt.from(9), oneTimeKey: key),
      'role=user,action=receive,cid=$cid,pkOwner=$key,aid=3,amount=9',
    );
    expect(
      a.receiveList([
        (oneTimeKey: key, assetId: 0),
        (oneTimeKey: null, assetId: 3),
      ]),
      'role=user,action=receive_list,cid=$cid,key_1=$key,aid_1=0,'
      'key_2=$zero,aid_2=3',
    );
    expect(a.receiveAll(), 'role=user,action=receive_all,cid=$cid');
  });

  test('out-of-range values never reach the shader', () {
    expect(() => a.register(alice, 0), throwsRangeError);
    expect(() => a.register(alice, 51), throwsRangeError);
    expect(() => a.extend(alice, -1), throwsRangeError);
    expect(() => a.pay(alice, 0, BigInt.zero), throwsArgumentError);
    expect(() => a.pay(alice, -1, BigInt.one), throwsRangeError);
    expect(() => a.pay(alice, 0x100000000, BigInt.one), throwsRangeError);
    expect(
      () => a.pay(alice, 0, BigInt.parse('18446744073709551616')),
      throwsArgumentError,
    );
    expect(
      a.pay(alice, 0, BigInt.parse('18446744073709551615')),
      endsWith('amount=18446744073709551615'),
    );
    expect(() => a.setOwner(alice, 'x$key'), throwsA(isA<BansInvalidKey>()));
    expect(() => a.setOwner(alice, zero), throwsA(isA<BansInvalidKey>()));
    expect(() => a.receiveList(const []), throwsArgumentError);
  });

  test('a name cannot inject arguments', () {
    // Only a validated BansName reaches a builder, and ',' / '=' are not in
    // the charset.
    expect(
      () => a.viewName(BansName('x,cid=evil')),
      throwsA(isA<BansInvalidName>()),
    );
  });
}
