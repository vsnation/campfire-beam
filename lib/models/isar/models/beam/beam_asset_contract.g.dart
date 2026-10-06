// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'beam_asset_contract.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetBeamAssetContractCollection on Isar {
  IsarCollection<BeamAssetContract> get beamAssetContracts => this.collection();
}

const BeamAssetContractSchema = CollectionSchema(
  name: r'BeamAssetContract',
  id: -5755083999033453891,
  properties: {
    r'address': PropertySchema(id: 0, name: r'address', type: IsarType.string),
    r'assetId': PropertySchema(id: 1, name: r'assetId', type: IsarType.long),
    r'color': PropertySchema(id: 2, name: r'color', type: IsarType.long),
    r'decimals': PropertySchema(id: 3, name: r'decimals', type: IsarType.long),
    r'iconAsset': PropertySchema(
      id: 4,
      name: r'iconAsset',
      type: IsarType.string,
    ),
    r'impersonates': PropertySchema(
      id: 5,
      name: r'impersonates',
      type: IsarType.long,
    ),
    r'metadataKnown': PropertySchema(
      id: 6,
      name: r'metadataKnown',
      type: IsarType.bool,
    ),
    r'name': PropertySchema(id: 7, name: r'name', type: IsarType.string),
    r'poolAssetA': PropertySchema(
      id: 8,
      name: r'poolAssetA',
      type: IsarType.long,
    ),
    r'poolAssetB': PropertySchema(
      id: 9,
      name: r'poolAssetB',
      type: IsarType.long,
    ),
    r'poolKind': PropertySchema(id: 10, name: r'poolKind', type: IsarType.long),
    r'symbol': PropertySchema(id: 11, name: r'symbol', type: IsarType.string),
    r'verified': PropertySchema(id: 12, name: r'verified', type: IsarType.bool),
  },

  estimateSize: _beamAssetContractEstimateSize,
  serialize: _beamAssetContractSerialize,
  deserialize: _beamAssetContractDeserialize,
  deserializeProp: _beamAssetContractDeserializeProp,
  idName: r'id',
  indexes: {
    r'address': IndexSchema(
      id: -259407546592846288,
      name: r'address',
      unique: true,
      replace: true,
      properties: [
        IndexPropertySchema(
          name: r'address',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},

  getId: _beamAssetContractGetId,
  getLinks: _beamAssetContractGetLinks,
  attach: _beamAssetContractAttach,
  version: '3.3.2',
);

int _beamAssetContractEstimateSize(
  BeamAssetContract object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.address.length * 3;
  {
    final value = object.iconAsset;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.name.length * 3;
  bytesCount += 3 + object.symbol.length * 3;
  return bytesCount;
}

void _beamAssetContractSerialize(
  BeamAssetContract object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.address);
  writer.writeLong(offsets[1], object.assetId);
  writer.writeLong(offsets[2], object.color);
  writer.writeLong(offsets[3], object.decimals);
  writer.writeString(offsets[4], object.iconAsset);
  writer.writeLong(offsets[5], object.impersonates);
  writer.writeBool(offsets[6], object.metadataKnown);
  writer.writeString(offsets[7], object.name);
  writer.writeLong(offsets[8], object.poolAssetA);
  writer.writeLong(offsets[9], object.poolAssetB);
  writer.writeLong(offsets[10], object.poolKind);
  writer.writeString(offsets[11], object.symbol);
  writer.writeBool(offsets[12], object.verified);
}

BeamAssetContract _beamAssetContractDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = BeamAssetContract(
    address: reader.readString(offsets[0]),
    assetId: reader.readLong(offsets[1]),
    color: reader.readLongOrNull(offsets[2]),
    decimals: reader.readLong(offsets[3]),
    iconAsset: reader.readStringOrNull(offsets[4]),
    impersonates: reader.readLongOrNull(offsets[5]),
    metadataKnown: reader.readBool(offsets[6]),
    name: reader.readString(offsets[7]),
    poolAssetA: reader.readLongOrNull(offsets[8]),
    poolAssetB: reader.readLongOrNull(offsets[9]),
    poolKind: reader.readLongOrNull(offsets[10]),
    symbol: reader.readString(offsets[11]),
    verified: reader.readBool(offsets[12]),
  );
  object.id = id;
  return object;
}

P _beamAssetContractDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readLong(offset)) as P;
    case 2:
      return (reader.readLongOrNull(offset)) as P;
    case 3:
      return (reader.readLong(offset)) as P;
    case 4:
      return (reader.readStringOrNull(offset)) as P;
    case 5:
      return (reader.readLongOrNull(offset)) as P;
    case 6:
      return (reader.readBool(offset)) as P;
    case 7:
      return (reader.readString(offset)) as P;
    case 8:
      return (reader.readLongOrNull(offset)) as P;
    case 9:
      return (reader.readLongOrNull(offset)) as P;
    case 10:
      return (reader.readLongOrNull(offset)) as P;
    case 11:
      return (reader.readString(offset)) as P;
    case 12:
      return (reader.readBool(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _beamAssetContractGetId(BeamAssetContract object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _beamAssetContractGetLinks(
  BeamAssetContract object,
) {
  return [];
}

void _beamAssetContractAttach(
  IsarCollection<dynamic> col,
  Id id,
  BeamAssetContract object,
) {
  object.id = id;
}

extension BeamAssetContractByIndex on IsarCollection<BeamAssetContract> {
  Future<BeamAssetContract?> getByAddress(String address) {
    return getByIndex(r'address', [address]);
  }

  BeamAssetContract? getByAddressSync(String address) {
    return getByIndexSync(r'address', [address]);
  }

  Future<bool> deleteByAddress(String address) {
    return deleteByIndex(r'address', [address]);
  }

  bool deleteByAddressSync(String address) {
    return deleteByIndexSync(r'address', [address]);
  }

  Future<List<BeamAssetContract?>> getAllByAddress(List<String> addressValues) {
    final values = addressValues.map((e) => [e]).toList();
    return getAllByIndex(r'address', values);
  }

  List<BeamAssetContract?> getAllByAddressSync(List<String> addressValues) {
    final values = addressValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'address', values);
  }

  Future<int> deleteAllByAddress(List<String> addressValues) {
    final values = addressValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'address', values);
  }

  int deleteAllByAddressSync(List<String> addressValues) {
    final values = addressValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'address', values);
  }

  Future<Id> putByAddress(BeamAssetContract object) {
    return putByIndex(r'address', object);
  }

  Id putByAddressSync(BeamAssetContract object, {bool saveLinks = true}) {
    return putByIndexSync(r'address', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByAddress(List<BeamAssetContract> objects) {
    return putAllByIndex(r'address', objects);
  }

  List<Id> putAllByAddressSync(
    List<BeamAssetContract> objects, {
    bool saveLinks = true,
  }) {
    return putAllByIndexSync(r'address', objects, saveLinks: saveLinks);
  }
}

extension BeamAssetContractQueryWhereSort
    on QueryBuilder<BeamAssetContract, BeamAssetContract, QWhere> {
  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension BeamAssetContractQueryWhere
    on QueryBuilder<BeamAssetContract, BeamAssetContract, QWhereClause> {
  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterWhereClause>
  idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(lower: id, upper: id));
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterWhereClause>
  idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterWhereClause>
  idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterWhereClause>
  idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterWhereClause>
  idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.between(
          lower: lowerId,
          includeLower: includeLower,
          upper: upperId,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterWhereClause>
  addressEqualTo(String address) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'address', value: [address]),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterWhereClause>
  addressNotEqualTo(String address) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'address',
                lower: [],
                upper: [address],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'address',
                lower: [address],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'address',
                lower: [address],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'address',
                lower: [],
                upper: [address],
                includeUpper: false,
              ),
            );
      }
    });
  }
}

extension BeamAssetContractQueryFilter
    on QueryBuilder<BeamAssetContract, BeamAssetContract, QFilterCondition> {
  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  addressEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'address',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  addressGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'address',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  addressLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'address',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  addressBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'address',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  addressStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'address',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  addressEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'address',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  addressContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'address',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  addressMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'address',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  addressIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'address', value: ''),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  addressIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'address', value: ''),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  assetIdEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'assetId', value: value),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  assetIdGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'assetId',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  assetIdLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'assetId',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  assetIdBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'assetId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  colorIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'color'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  colorIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'color'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  colorEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'color', value: value),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  colorGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'color',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  colorLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'color',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  colorBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'color',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  decimalsEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'decimals', value: value),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  decimalsGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'decimals',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  decimalsLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'decimals',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  decimalsBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'decimals',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'iconAsset'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'iconAsset'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'iconAsset',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'iconAsset',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'iconAsset',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'iconAsset',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'iconAsset',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'iconAsset',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'iconAsset',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'iconAsset',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'iconAsset', value: ''),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  iconAssetIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'iconAsset', value: ''),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'id', value: value),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  idGreaterThan(Id value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  idLessThan(Id value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'id',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  impersonatesIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'impersonates'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  impersonatesIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'impersonates'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  impersonatesEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'impersonates', value: value),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  impersonatesGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'impersonates',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  impersonatesLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'impersonates',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  impersonatesBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'impersonates',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  metadataKnownEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'metadataKnown', value: value),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  nameEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'name',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  nameGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'name',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  nameLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'name',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  nameBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'name',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  nameStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'name',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  nameEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'name',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  nameContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'name',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  nameMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'name',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  nameIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'name', value: ''),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  nameIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'name', value: ''),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetAIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'poolAssetA'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetAIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'poolAssetA'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetAEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'poolAssetA', value: value),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetAGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'poolAssetA',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetALessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'poolAssetA',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetABetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'poolAssetA',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetBIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'poolAssetB'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetBIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'poolAssetB'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetBEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'poolAssetB', value: value),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetBGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'poolAssetB',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetBLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'poolAssetB',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolAssetBBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'poolAssetB',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolKindIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'poolKind'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolKindIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'poolKind'),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolKindEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'poolKind', value: value),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolKindGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'poolKind',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolKindLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'poolKind',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  poolKindBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'poolKind',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  symbolEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'symbol',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  symbolGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'symbol',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  symbolLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'symbol',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  symbolBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'symbol',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  symbolStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'symbol',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  symbolEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'symbol',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  symbolContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'symbol',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  symbolMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'symbol',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  symbolIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'symbol', value: ''),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  symbolIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'symbol', value: ''),
      );
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterFilterCondition>
  verifiedEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'verified', value: value),
      );
    });
  }
}

extension BeamAssetContractQueryObject
    on QueryBuilder<BeamAssetContract, BeamAssetContract, QFilterCondition> {}

extension BeamAssetContractQueryLinks
    on QueryBuilder<BeamAssetContract, BeamAssetContract, QFilterCondition> {}

extension BeamAssetContractQuerySortBy
    on QueryBuilder<BeamAssetContract, BeamAssetContract, QSortBy> {
  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByAssetId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'assetId', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByAssetIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'assetId', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByColor() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'color', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByColorDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'color', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByDecimals() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'decimals', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByDecimalsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'decimals', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByIconAsset() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'iconAsset', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByIconAssetDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'iconAsset', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByImpersonates() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'impersonates', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByImpersonatesDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'impersonates', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByMetadataKnown() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataKnown', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByMetadataKnownDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataKnown', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'name', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'name', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByPoolAssetA() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolAssetA', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByPoolAssetADesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolAssetA', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByPoolAssetB() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolAssetB', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByPoolAssetBDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolAssetB', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByPoolKind() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolKind', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByPoolKindDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolKind', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortBySymbol() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'symbol', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortBySymbolDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'symbol', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByVerified() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'verified', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  sortByVerifiedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'verified', Sort.desc);
    });
  }
}

extension BeamAssetContractQuerySortThenBy
    on QueryBuilder<BeamAssetContract, BeamAssetContract, QSortThenBy> {
  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByAssetId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'assetId', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByAssetIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'assetId', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByColor() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'color', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByColorDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'color', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByDecimals() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'decimals', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByDecimalsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'decimals', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByIconAsset() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'iconAsset', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByIconAssetDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'iconAsset', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByImpersonates() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'impersonates', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByImpersonatesDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'impersonates', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByMetadataKnown() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataKnown', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByMetadataKnownDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataKnown', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'name', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'name', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByPoolAssetA() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolAssetA', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByPoolAssetADesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolAssetA', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByPoolAssetB() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolAssetB', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByPoolAssetBDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolAssetB', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByPoolKind() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolKind', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByPoolKindDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'poolKind', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenBySymbol() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'symbol', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenBySymbolDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'symbol', Sort.desc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByVerified() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'verified', Sort.asc);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QAfterSortBy>
  thenByVerifiedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'verified', Sort.desc);
    });
  }
}

extension BeamAssetContractQueryWhereDistinct
    on QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct> {
  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByAddress({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'address', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByAssetId() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'assetId');
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByColor() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'color');
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByDecimals() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'decimals');
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByIconAsset({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'iconAsset', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByImpersonates() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'impersonates');
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByMetadataKnown() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'metadataKnown');
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct> distinctByName({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'name', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByPoolAssetA() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'poolAssetA');
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByPoolAssetB() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'poolAssetB');
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByPoolKind() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'poolKind');
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctBySymbol({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'symbol', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BeamAssetContract, BeamAssetContract, QDistinct>
  distinctByVerified() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'verified');
    });
  }
}

extension BeamAssetContractQueryProperty
    on QueryBuilder<BeamAssetContract, BeamAssetContract, QQueryProperty> {
  QueryBuilder<BeamAssetContract, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<BeamAssetContract, String, QQueryOperations> addressProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'address');
    });
  }

  QueryBuilder<BeamAssetContract, int, QQueryOperations> assetIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'assetId');
    });
  }

  QueryBuilder<BeamAssetContract, int?, QQueryOperations> colorProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'color');
    });
  }

  QueryBuilder<BeamAssetContract, int, QQueryOperations> decimalsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'decimals');
    });
  }

  QueryBuilder<BeamAssetContract, String?, QQueryOperations>
  iconAssetProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'iconAsset');
    });
  }

  QueryBuilder<BeamAssetContract, int?, QQueryOperations>
  impersonatesProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'impersonates');
    });
  }

  QueryBuilder<BeamAssetContract, bool, QQueryOperations>
  metadataKnownProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'metadataKnown');
    });
  }

  QueryBuilder<BeamAssetContract, String, QQueryOperations> nameProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'name');
    });
  }

  QueryBuilder<BeamAssetContract, int?, QQueryOperations> poolAssetAProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'poolAssetA');
    });
  }

  QueryBuilder<BeamAssetContract, int?, QQueryOperations> poolAssetBProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'poolAssetB');
    });
  }

  QueryBuilder<BeamAssetContract, int?, QQueryOperations> poolKindProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'poolKind');
    });
  }

  QueryBuilder<BeamAssetContract, String, QQueryOperations> symbolProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'symbol');
    });
  }

  QueryBuilder<BeamAssetContract, bool, QQueryOperations> verifiedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'verified');
    });
  }
}
