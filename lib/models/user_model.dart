class UserModel {
  final String uid;
  final String name;
  final String email;
  final String role;
  final bool isAdmin;

  final int defaultUnits;
  final int fixtureUnits;

  final String? photoUrl;
  final String? bio;

  UserModel({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.isAdmin,
    required this.defaultUnits,
    required this.fixtureUnits,
    this.photoUrl,
    this.bio,
  });

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'name': name,
      'email': email,
      'role': role,
      'isAdmin': isAdmin,
      'defaultUnits': defaultUnits,
      'fixtureUnits': fixtureUnits,
      'photoUrl': photoUrl,
      'bio': bio,
    };
  }

  factory UserModel.fromMap(
    Map<String, dynamic> map,
  ) {
    return UserModel(
      uid: map['uid'] ?? '',
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      role: map['role'] ?? 'teacher',
      isAdmin: map['isAdmin'] ?? false,
      defaultUnits: map['defaultUnits'] ?? 0,
      fixtureUnits: map['fixtureUnits'] ?? 0,
      photoUrl: map['photoUrl'],
      bio: map['bio'],
    );
  }
}
