import 'package:flutter/material.dart';

import '../theme/chat_appearance.dart';
import 'chat_background.dart';
import 'chat_bubble.dart';

/// Bounded, noninteractive preview reusable by a future settings screen.
/// It requires no account, repository, downloads or chat session.
class ChatAppearancePreview extends StatelessWidget {
  const ChatAppearancePreview({
    super.key,
    required this.appearance,
    this.showMedia = false,
  });
  final ChatAppearance appearance;
  final bool showMedia;
  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(
      extensions: [
        ...Theme.of(context).extensions.values
            .where((extension) => extension is! ChatAppearance),
        appearance,
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 300,
        child: ChatBackground(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: ChatBubble(
                    outgoing: false,
                    child: Text('សួស្តី! Hello from QLink.'),
                  ),
                ),
                const Align(
                  alignment: Alignment.centerRight,
                  child: ChatBubble(
                    outgoing: true,
                    child: Text('A little color for your conversations.'),
                  ),
                ),
                if (showMedia) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ChatBubble(
                      outgoing: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            label: 'Sample photo',
                            child: const SizedBox(
                              width: 150,
                              height: 56,
                              child: Icon(
                                Icons.landscape_outlined,
                                size: 48,
                              ),
                            ),
                          ),
                          const Text('Weekend photo'),
                          const Text('👍 2   ❤️ 1'),
                        ],
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ChatBubble(
                      outgoing: true,
                      child: Semantics(
                        label: 'Sample voice message, twelve seconds',
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.play_arrow),
                            SizedBox(width: 8),
                            Flexible(
                              child: Text('▂ ▄ ▆ ▃ ▅ ▂  0:12'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
