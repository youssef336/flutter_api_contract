import 'package:json_annotation/json_annotation.dart';

part 'product_model.g.dart';

enum ProductKind {
  @JsonValue('physical')
  physical,
  @JsonValue('digital')
  digital,
  unknown,
}

@JsonSerializable()
class ProductModel {
  ProductModel({
    required this.productId,
    required this.title,
    required this.price,
    required this.kind,
    required this.sku,
    required this.legacy,
    this.stockCount = 0,
    this.thumbnail,
    this.localOnly,
  });

  factory ProductModel.fromJson(Map<String, dynamic> json) =>
      _$ProductModelFromJson(json);

  final int productId;
  final String title;
  final int price;
  final int stockCount;

  @JsonKey(unknownEnumValue: ProductKind.unknown)
  final ProductKind kind;

  final String sku;

  @JsonKey(name: 'legacy_code', defaultValue: '')
  final String legacy;

  @JsonKey(name: 'thumb')
  final String? thumbnail;

  @JsonKey(includeFromJson: false, includeToJson: false)
  final String? localOnly;
}
