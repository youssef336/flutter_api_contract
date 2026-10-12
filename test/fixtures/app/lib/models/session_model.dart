import 'package:freezed_annotation/freezed_annotation.dart';

part 'session_model.freezed.dart';
part 'session_model.g.dart';

enum SessionRole { admin, member }

@freezed
abstract class SessionModel with _$SessionModel {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory SessionModel({
    required String token,
    required DateTime expiresAt,
    required SessionRole role,
    @JsonKey(name: 'scope') required String scope,
    String? refreshToken,
    @Default('mobile') String device,
  }) = _SessionModel;

  factory SessionModel.fromJson(Map<String, dynamic> json) =>
      _$SessionModelFromJson(json);
}
