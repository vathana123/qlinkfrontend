import 'dart:convert';

class ActivityEvent {
  const ActivityEvent(
    this.type,
    this.userId, {
    this.online,
    this.lastSeenAt,
    this.roomId,
    this.typing = false,
    this.expiresAt,
    this.canMessage,
  });
  final String type, userId;
  final String? roomId;
  final bool? online;
  final bool? canMessage;
  final bool typing;
  final DateTime? lastSeenAt, expiresAt;
  static ActivityEvent? parse(String body) {
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      final user = j['userId'] as String;
      if (user.isEmpty) return null;
      if (j['type'] == 'PERMISSIONS' && j['canMessage'] is bool) {
        return ActivityEvent(
          'PERMISSIONS',
          user,
          canMessage: j['canMessage'] as bool,
        );
      }
      if (j['type'] == 'PRESENCE') {
        return ActivityEvent(
          'PRESENCE',
          user,
          online: j['online'] as bool?,
          lastSeenAt: DateTime.tryParse(j['lastSeenAt'] as String? ?? ''),
        );
      }
      if (j['type'] == 'TYPING' &&
          j['roomId'] is String &&
          j['typing'] is bool) {
        final expiry = DateTime.tryParse(j['expiresAt'] as String? ?? '');
        if (expiry == null) return null;
        return ActivityEvent(
          'TYPING',
          user,
          roomId: j['roomId'] as String,
          typing: j['typing'] as bool,
          expiresAt: expiry,
        );
      }
    } catch (_) {}
    return null;
  }
}
