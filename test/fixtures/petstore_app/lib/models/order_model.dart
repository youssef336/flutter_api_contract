import 'package:freezed_annotation/freezed_annotation.dart';

part 'order_model.freezed.dart';
part 'order_model.g.dart';

// Drift 3: the schema also sends "delivered".
enum OrderStatus { placed, approved }

@freezed
abstract class OrderModel with _$OrderModel {
  const factory OrderModel({
    int? id,
    int? petId,
    int? quantity,
    DateTime? shipDate,
    OrderStatus? status,
    @Default(false) bool complete,
  }) = _OrderModel;

  factory OrderModel.fromJson(Map<String, dynamic> json) =>
      _$OrderModelFromJson(json);
}
