class ProfileModel {
  ProfileModel({required this.nickname, required this.bio, this.avatar});

  factory ProfileModel.fromJson(Map<String, dynamic> json) => ProfileModel(
    nickname: json['nickname'] as String,
    bio: json['bio'] as String,
    avatar: json['avatar'] as String,
  );

  final String nickname;
  final String bio;
  final String? avatar;
}
