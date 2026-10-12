import 'address_model.dart';

enum UserStatus { active, banned }

class UserModel {
  UserModel({
    required this.id,
    required this.userName,
    required this.displayName,
    required this.createdAt,
    required this.status,
    required this.age,
    required this.score,
    this.email,
    this.address,
    this.tags = const [],
    this.phone,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] as int,
      userName: json['username'] as String,
      displayName: json['display_name'] as String,
      email: json['email'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      status: UserStatus.values.byName(json['status'] as String),
      age: json['age'] as int,
      score: json['score'] as double,
      address: json['address'] == null
          ? null
          : AddressModel.fromJson(json['address'] as Map<String, dynamic>),
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
          const [],
      phone: json['phone'] as String?,
    );
  }

  final int id;
  final String userName;
  final String displayName;
  final String? email;
  final DateTime createdAt;
  final UserStatus status;
  final int age;
  final double score;
  final AddressModel? address;
  final List<String> tags;
  final String? phone;
}
