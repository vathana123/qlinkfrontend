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

enum Delivery { sending, sent, delivered, seen, failed }

class ReplyPreview {
  const ReplyPreview(
    this.id,
    this.content, {
    this.senderDisplayName,
    this.type,
    this.unavailable = false,
  });
  final String id, content;
  final String? senderDisplayName, type;
  final bool unavailable;
  factory ReplyPreview.fromJson(Map<String, dynamic> j) => ReplyPreview(
    j['id'] as String,
    j['content'] as String? ?? 'Message unavailable',
    senderDisplayName: j['senderDisplayName'] as String?,
    type: j['type'] as String?,
    unavailable: j['unavailable'] == true,
  );
  factory ReplyPreview.fromMessage(ChatMessage m) => ReplyPreview(
    m.id,
    m.deleted || m.hidden
        ? 'Message unavailable'
        : m.type == 'TEXT'
        ? m.content
        : m.type,
    senderDisplayName: m.deleted || m.hidden ? null : m.senderDisplayName,
    type: m.type,
    unavailable: m.deleted || m.hidden,
  );
}

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
    this.sendError,
    this.localCreatedAt,
    this.replyToId,
    this.reply,
    this.editedAt,
    this.removedAt,
    this.revision = 0,
    this.hidden = false,
    this.canDeleteForEveryone = false,
  });
  final String? replyToId;
  final ReplyPreview? reply;
  final DateTime? editedAt, removedAt;
  final int revision;
  final bool hidden, canDeleteForEveryone;
  bool get deleted => removedAt != null;
  final String id, senderId, clientMessageId, content;
  final DateTime createdAt;
  final Delivery delivery;
  final String? senderDisplayName;
  final String type;
  final String? fileId, localPath;
  final int? durationMs, audioSizeBytes;
  final double uploadProgress;
  final AttachmentMetadata? attachment;
  final String? sendError;
  final DateTime? localCreatedAt;
  DateTime get displayTime => localCreatedAt ?? createdAt;
  bool get isConfirmed =>
      delivery == Delivery.sent ||
      delivery == Delivery.delivered ||
      delivery == Delivery.seen;
  String get statusText => switch (delivery) {
    Delivery.sending => 'Sending...',
    Delivery.sent => 'Sent',
    Delivery.delivered => 'Delivered',
    Delivery.seen => 'Seen',
    Delivery.failed => 'Error: ${sendError ?? 'Unable to send. Tap Retry.'}',
  };
  bool get isAttachment => !deleted && (type == 'IMAGE' || type == 'FILE');
  bool get isVoice => !deleted && type == 'VOICE';
  ChatMessage withDelivery(
    Delivery value, {
    String? fileId,
    double? progress,
    String? error,
    String? localPath,
    AttachmentMetadata? attachment,
    DateTime? localCreatedAt,
    ReplyPreview? reply,
  }) => ChatMessage(
    replyToId: replyToId,
    reply: reply ?? this.reply,
    editedAt: editedAt,
    removedAt: removedAt,
    revision: revision,
    hidden: hidden,
    canDeleteForEveryone: canDeleteForEveryone,
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
    attachment: attachment ?? this.attachment,
    audioSizeBytes: audioSizeBytes,
    localPath: localPath ?? this.localPath,
    uploadProgress: progress ?? uploadProgress,
    sendError: error,
    localCreatedAt: localCreatedAt ?? this.localCreatedAt,
  );
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    replyToId: j['replyToId'] as String?,
    reply: j['reply'] == null
        ? null
        : ReplyPreview.fromJson(Map<String, dynamic>.from(j['reply'] as Map)),
    editedAt: DateTime.tryParse(j['editedAt'] as String? ?? ''),
    removedAt: DateTime.tryParse(j['removedAt'] as String? ?? ''),
    revision: j['revision'] as int? ?? 0,
    hidden: j['hidden'] == true,
    canDeleteForEveryone: j['canDeleteForEveryone'] == true,
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

/// REST/history and socket echoes must not undo a confirmed status or local order.
ChatMessage reconcileMessage(ChatMessage previous, ChatMessage incoming) {
  if (previous.hidden ||
      (!incoming.hidden && previous.revision > incoming.revision)) {
    return previous;
  }
  if (previous.isConfirmed && !incoming.isConfirmed) return previous;
  final status =
      previous.isConfirmed &&
          incoming.isConfirmed &&
          previous.delivery.index > incoming.delivery.index
      ? previous.delivery
      : incoming.delivery;
  return incoming.withDelivery(
    status,
    error: incoming.sendError,
    reply:
        previous.reply?.unavailable == true &&
            previous.replyToId == incoming.replyToId
        ? previous.reply
        : incoming.reply,
    localCreatedAt:
        previous.localCreatedAt ??
        (!previous.isConfirmed ? previous.createdAt : null),
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
    this.groupAvatarUrl,
    this.description,
    this.myRole,
    this.membersCanSend = true,
    this.membersCanInvite = false,
    this.messageHistoryVisibility = 'VIEW_ALL_MESSAGES',
  });
  final String id;
  final PublicUser? participant;
  final String type;
  final String? name;
  final int? memberCount;
  final String? groupAvatarUrl, description, myRole;
  final bool membersCanSend, membersCanInvite;
  final String messageHistoryVisibility;
  bool get isOwner => myRole == 'OWNER';
  bool get canManage => isOwner || myRole == 'CO_OWNER';
  bool get canInvite => canManage || membersCanInvite;
  bool get canSend => !isGroup || canManage || membersCanSend;
  bool get isGroup => type != 'PERSONAL';
  String get title => isGroup
      ? name ?? 'Group'
      : participant?.displayName ?? 'Unavailable user';
  String? get avatarUrl => isGroup ? groupAvatarUrl : participant?.avatarUrl;
  final ChatMessage? lastMessage;
  final DateTime? lastMessageAt;
  ChatRoom withMessage(ChatMessage message) => ChatRoom(
    id,
    participant,
    type: type,
    name: name,
    memberCount: memberCount,
    groupAvatarUrl: groupAvatarUrl,
    description: description,
    myRole: myRole,
    membersCanSend: membersCanSend,
    membersCanInvite: membersCanInvite,
    messageHistoryVisibility: messageHistoryVisibility,
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
    groupAvatarUrl: j['avatarUrl'] as String?,
    description: j['description'] as String?,
    myRole: j['myRole'] as String?,
    membersCanSend: j['membersCanSend'] as bool? ?? true,
    membersCanInvite: j['membersCanInvite'] as bool? ?? false,
    messageHistoryVisibility:
        j['messageHistoryVisibility'] as String? ?? 'VIEW_ALL_MESSAGES',
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
    this.groupRoom,
  });
  factory Conversation.fromRoom(ChatRoom room) => Conversation(
    room.participant,
    roomId: room.id,
    groupName: room.isGroup ? room.title : null,
    memberCount: room.memberCount,
    groupRoom: room.isGroup ? room : null,
  );
  final PublicUser? recipient;
  final ChatRoom? groupRoom;
  final String? groupName;
  final int? memberCount;
  bool get isGroup => groupName != null;
  String get title => groupName ?? recipient?.displayName ?? 'Unavailable user';
  String? get avatarUrl =>
      isGroup ? groupRoom?.avatarUrl : recipient?.avatarUrl;
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
