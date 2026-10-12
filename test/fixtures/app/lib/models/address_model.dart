class AddressModel {
  AddressModel(this.city, this.lat, this.lng);

  factory AddressModel.fromJson(Map<String, dynamic> json) {
    final geo = json['geo'] as Map<String, dynamic>;
    return AddressModel(
      json['city'] as String,
      (geo['lat'] as num).toDouble(),
      (json['geo']['long'] as num?)?.toDouble(),
    );
  }

  final String city;
  final double lat;
  final double? lng;
}
