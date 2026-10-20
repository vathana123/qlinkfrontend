import 'package:equatable/equatable.dart';

class AppUser extends Equatable {
  const AppUser({
    required this.id,
    required this.displayName,
    this.email,
    this.username,
    this.avatarUrl,
    required this.status,
  });
  final String id;
  final String displayName;
  final String? email;
  final String? username;
  final String? avatarUrl;
  final String status;
  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    displayName: (json['displayName'] as String?)?.trim().isNotEmpty == true
        ? json['displayName'] as String
        : 'qLink member',
    email: json['email'] as String?,
    username: json['username'] as String?,
    avatarUrl: json['avatarUrl'] as String?,
    status: json['status'] as String,
  );
  @override
  List<Object?> get props => [
    id,
    displayName,
    email,
    avatarUrl,
    status,
    username,
  ];
}
