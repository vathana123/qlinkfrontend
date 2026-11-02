import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../presentation/theme/chat_appearance.dart';
import '../../presentation/theme/chat_background_config.dart';

/// Global conversation appearance for one local account. The versioned payload
/// leaves room for a separate conversation-override layer in a future phase.
class ChatAppearanceStore {
  ChatAppearanceStore(this.preferences);
  final SharedPreferences preferences;
  static String key(String account) =>
      'qlink.chat-appearance.v1.${base64Url.encode(utf8.encode(account))}';
  ChatAppearance read(String account) {
    try {
      final raw = preferences.getString(key(account));
      if (raw == null) return const ChatAppearance();
      final data = jsonDecode(raw);
      if (data is! Map || data['version'] != 1) return const ChatAppearance();
      T value<T extends Enum>(List<T> options, Object? name, T fallback) =>
          options.where((v) => v.name == name).firstOrNull ?? fallback;
      return ChatAppearance(
        bubbleStyle: value(
          ChatBubbleStyle.values,
          data['bubble'],
          ChatBubbleStyle.standard,
        ),
        outgoingColor: value(
          OutgoingBubbleColor.values,
          data['color'],
          OutgoingBubbleColor.qlinkBlue,
        ),
        fontSize: value(
          MessageFontSize.values,
          data['font'],
          MessageFontSize.medium,
        ),
        chatBackground: ChatBackgroundConfig(
          style: value(
            ChatBackgroundStyle.values,
            data['background'],
            ChatBackgroundStyle.theme,
          ),
          tone: value(
            ChatBackgroundTone.values,
            data['tone'],
            ChatBackgroundTone.blue,
          ),
          pattern: value(
            ChatBackgroundPattern.values,
            data['pattern'],
            ChatBackgroundPattern.dots,
          ),
        ),
      );
    } catch (_) {
      return const ChatAppearance();
    }
  }

  Future<void> save(String account, ChatAppearance value) async {
    final saved = await preferences.setString(
      key(account),
      jsonEncode({
        'version': 1,
        'bubble': value.bubbleStyle.name,
        'color': value.outgoingColor.name,
        'font': value.fontSize.name,
        'background': value.chatBackground.style.name,
        'tone': value.chatBackground.tone.name,
        'pattern': value.chatBackground.pattern.name,
      }),
    );
    if (!saved) throw StateError('Appearance could not be saved');
  }
}
