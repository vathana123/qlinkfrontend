import 'chat_models.dart';

class SearchPage<T> {
  const SearchPage(this.items, this.cursor);
  final List<T> items;
  final String? cursor;
}

class MessageMatch {
  const MessageMatch(this.room, this.message);
  final ChatRoom room;
  final ChatMessage message;
  factory MessageMatch.fromJson(Map<String, dynamic> json) => MessageMatch(
    ChatRoom.fromJson(json['room'] as Map<String, dynamic>),
    ChatMessage.fromJson(json['message'] as Map<String, dynamic>),
  );
}

class MessageContext {
  const MessageContext(this.items, this.olderCursor, this.newerCursor);
  final List<ChatMessage> items;
  final String? olderCursor, newerCursor;
}
