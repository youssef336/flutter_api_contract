import 'category_model.dart';

enum PetStatus { available, pending, sold }

class PetModel {
  PetModel({
    required this.name,
    required this.photoUrls,
    this.id,
    this.category,
    this.status,
  });

  factory PetModel.fromJson(Map<String, dynamic> json) => PetModel(
    id: json['id'] as int?,
    name: json['name'] as String,
    // Drift 1: the backend calls it photoUrls.
    photoUrls: (json['photo_urls'] as List).cast<String>(),
    category: json['category'] == null
        ? null
        : CategoryModel.fromJson(json['category'] as Map<String, dynamic>),
    status: json['status'] == null
        ? null
        : PetStatus.values.byName(json['status'] as String),
  );

  final int? id;
  final String name;
  final List<String> photoUrls;
  final CategoryModel? category;
  final PetStatus? status;
}
