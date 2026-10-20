class PublicUser {
  const PublicUser(this.id, this.displayName, {this.username, this.avatarUrl});
  final String id, displayName;
  final String? username, avatarUrl;
  factory PublicUser.fromJson(Map<String, dynamic> j) => PublicUser(
    j['id'] as String,
    j['displayName'] as String? ?? 'qLink member',
    username: j['username'] as String?,
    avatarUrl: j['avatarUrl'] as String?,
  );
}

enum Delivery { sending, sent, failed }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.clientMessageId,
    required this.content,
    required this.createdAt,
    this.delivery = Delivery.sent,
    this.senderDisplayName,
    this.type = 'TEXT',
    this.fileId,
    this.durationMs,
    this.attachment,
    this.audioSizeBytes,
    this.localPath,
    this.uploadProgress = 0,
  });
  final String id, senderId, clientMessageId, content;
  final DateTime createdAt;
  final Delivery delivery;
  final String? senderDisplayName;
  final String type;
  final String? fileId, localPath;
  final int? durationMs, audioSizeBytes;
  final double uploadProgress;
  final AttachmentMetadata? attachment;
  bool get isAttachment => type == 'IMAGE' || type == 'FILE';
  bool get isVoice => type == 'VOICE';
  ChatMessage withDelivery(
    Delivery value, {
    String? fileId,
    double? progress,
  }) => ChatMessage(
    id: id,
    senderId: senderId,
    clientMessageId: clientMessageId,
    content: content,
    createdAt: createdAt,
    delivery: value,
    senderDisplayName: senderDisplayName,
    type: type,
    fileId: fileId ?? this.fileId,
    durationMs: durationMs,
    attachment: attachment,
    audioSizeBytes: audioSizeBytes,
    localPath: localPath,
    uploadProgress: progress ?? uploadProgress,
  );
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: j['id'] as String,
    senderId: j['senderId'] as String,
    senderDisplayName: j['senderDisplayName'] as String?,
    clientMessageId: j['clientMessageId'] as String,
    content: j['content'] as String? ?? '',
    type: j['type'] as String? ?? 'TEXT',
    fileId: j['fileId'] as String?,
    durationMs: j['durationMs'] as int?,
    attachment: j['attachment'] == null
        ? null
        : AttachmentMetadata.fromJson(j['attachment'] as Map<String, dynamic>),
    audioSizeBytes: j['audioSizeBytes'] as int?,
    createdAt: DateTime.parse(j['createdAt'] as String),
  );
}

class ChatRoom {
  const ChatRoom(
    this.id,
    this.participant, {
    this.lastMessage,
    this.lastMessageAt,
    this.type = 'PERSONAL',
    this.name,
    this.memberCount,
  });
  final String id;
  final PublicUser? participant;
  final String type;
  final String? name;
  final int? memberCount;
  bool get isGroup => type != 'PERSONAL';
  String get title => isGroup
      ? name ?? 'Group'
      : participant?.displayName ?? 'Unavailable user';
  String? get avatarUrl => isGroup ? null : participant?.avatarUrl;
  final ChatMessage? lastMessage;
  final DateTime? lastMessageAt;
  ChatRoom withMessage(ChatMessage message) => ChatRoom(
    id,
    participant,
    type: type,
    name: name,
    memberCount: memberCount,
    lastMessage: message,
    lastMessageAt: message.createdAt,
  );
  factory ChatRoom.fromJson(Map<String, dynamic> j) => ChatRoom(
    j['id'] as String,
    j['participant'] == null
        ? null
        : PublicUser.fromJson(j['participant'] as Map<String, dynamic>),
    type: j['type'] as String? ?? 'PERSONAL',
    name: j['name'] as String?,
    memberCount: j['memberCount'] as int?,
    lastMessage: j['lastMessage'] == null
        ? null
        : ChatMessage.fromJson(j['lastMessage'] as Map<String, dynamic>),
    lastMessageAt: DateTime.tryParse(j['lastMessageAt'] as String? ?? ''),
  );
}

class Conversation {
  const Conversation(
    this.recipient, {
    this.roomId,
    this.groupName,
    this.memberCount,
  });
  factory Conversation.fromRoom(ChatRoom room) => Conversation(
    room.participant,
    roomId: room.id,
    groupName: room.isGroup ? room.title : null,
    memberCount: room.memberCount,
  );
  final PublicUser? recipient;
  final String? groupName;
  final int? memberCount;
  bool get isGroup => groupName != null;
  String get title => groupName ?? recipient?.displayName ?? 'Unavailable user';
  String? get avatarUrl => isGroup ? null : recipient?.avatarUrl;
  final String? roomId;
}

class ResultPage<T> {
  const ResultPage(this.items, this.hasMore);
  final List<T> items;
  final bool hasMore;
}

class MessagePage {
  const MessagePage(this.items, this.cursor);
  final List<ChatMessage> items;
  final String? cursor;
}

class SendResult {
  const SendResult(this.room, this.message);
  final ChatRoom room;
  final ChatMessage message;
}

String messageTime(DateTime time) {
  final t = time.toLocal();
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String? parseUserQr(String raw) {
  final match = RegExp(
    r'^qlink://user/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$',
  ).firstMatch(raw);
  return match?.group(1)?.toLowerCase();
}

String? validateUsername(String raw) {
  final name = raw.toLowerCase();
  if (!RegExp(r'^[a-z0-9_]{3,30}$').hasMatch(name)) {
    return 'Use 3–30 letters, numbers or underscores.';
  }
  if ({'admin', 'system', 'support'}.contains(name)) {
    return 'This username is reserved.';
  }
  return null;
}

class AttachmentMetadata {
  const AttachmentMetadata(this.originalName, this.contentType, this.sizeBytes);
  final String originalName, contentType;
  final int sizeBytes;
  factory AttachmentMetadata.fromJson(Map<String, dynamic> json) =>
      AttachmentMetadata(
        json['originalName'] as String,
        json['contentType'] as String,
        json['sizeBytes'] as int,
      );
}
