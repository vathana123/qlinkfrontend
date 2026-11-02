import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/theme/theme_cubit.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../bloc/chat_appearance_cubit.dart';
import '../theme/chat_appearance.dart';
import '../theme/chat_background_config.dart';
import '../widgets/chat_appearance_preview.dart';

class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const BlurAppBar(title: 'Appearance'),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Theme', style: Theme.of(context).textTheme.titleMedium),
        BlocBuilder<ThemeCubit, ThemeMode>(
          builder: (context, mode) => Wrap(
            spacing: 8,
            children: [
              for (final value in ThemeMode.values)
                ChoiceChip(
                  label: Text(switch (value) {
                    ThemeMode.system => 'System',
                    ThemeMode.light => 'Light',
                    ThemeMode.dark => 'Dark',
                  }),
                  selected: value == mode,
                  onSelected: (_) async {
                    try {
                      await context.read<ThemeCubit>().setTheme(value);
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Theme could not be saved.'),
                          ),
                        );
                      }
                    }
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ListTile(
          leading: const Icon(Icons.chat_bubble_outline),
          title: const Text('Chat Appearance'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/profile/appearance/chat'),
        ),
      ],
    ),
  );
}

class ChatAppearanceScreen extends StatelessWidget {
  const ChatAppearanceScreen({super.key});
  Widget _choices<T>(
    BuildContext context,
    String label,
    List<T> values,
    T selected,
    String Function(T) name,
    void Function(T) change,
  ) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final value in values)
              ChoiceChip(
                label: Text(name(value)),
                selected: value == selected,
                onSelected: (_) => change(value),
              ),
          ],
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const BlurAppBar(title: 'Chat Appearance'),
    body: BlocBuilder<ChatAppearanceCubit, ChatAppearanceState>(
      builder: (context, state) {
        if (state.account == null) return const SizedBox.shrink();
        final cubit = context.read<ChatAppearanceCubit>(),
            appearance = state.appearance;
        return ListView(
          key: ValueKey(state.account),
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Live preview',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            ChatAppearancePreview(appearance: appearance, showMedia: true),
            const SizedBox(height: 8),
            const Text(
              'Applies to all your personal and group chats on this device.',
            ),
            if (state.error != null) ...[
              Text(
                state.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: () => cubit.update(appearance),
                child: const Text('Retry saving'),
              ),
            ],
            _choices(
              context,
              'Message bubble style',
              ChatBubbleStyle.values,
              appearance.bubbleStyle,
              (v) => switch (v) {
                ChatBubbleStyle.standard => 'Default',
                ChatBubbleStyle.rounded => 'Rounded',
                ChatBubbleStyle.compact => 'Compact',
              },
              (v) => cubit.update(appearance.copyWith(bubbleStyle: v)),
            ),
            _choices(
              context,
              'Outgoing bubble color',
              OutgoingBubbleColor.values,
              appearance.outgoingColor,
              (v) => switch (v) {
                OutgoingBubbleColor.qlinkBlue => 'QLink Blue',
                OutgoingBubbleColor.ocean => 'Ocean',
                OutgoingBubbleColor.purple => 'Purple',
                OutgoingBubbleColor.emerald => 'Emerald',
              },
              (v) => cubit.update(appearance.copyWith(outgoingColor: v)),
            ),
            _choices(
              context,
              'Message font size',
              MessageFontSize.values,
              appearance.fontSize,
              (v) => switch (v) {
                MessageFontSize.small => 'Small',
                MessageFontSize.medium => 'Medium',
                MessageFontSize.large => 'Large',
              },
              (v) => cubit.update(appearance.copyWith(fontSize: v)),
            ),
            _choices(
              context,
              'Chat background',
              ChatBackgroundStyle.values,
              appearance.chatBackground.style,
              (v) => switch (v) {
                ChatBackgroundStyle.theme => 'Theme default',
                ChatBackgroundStyle.solid => 'Solid',
                ChatBackgroundStyle.gradient => 'Gradient',
                ChatBackgroundStyle.pattern => 'Pattern',
              },
              (v) => cubit.update(
                appearance.copyWith(
                  chatBackground: appearance.chatBackground.copyWith(style: v),
                ),
              ),
            ),
            if (appearance.chatBackground.style != ChatBackgroundStyle.theme)
              _choices(
                context,
                'Background tone',
                ChatBackgroundTone.values,
                appearance.chatBackground.tone,
                (v) => switch (v) {
                  ChatBackgroundTone.blue => 'Blue',
                  ChatBackgroundTone.lavender => 'Lavender',
                  ChatBackgroundTone.mint => 'Mint',
                },
                (v) => cubit.update(
                  appearance.copyWith(
                    chatBackground: appearance.chatBackground.copyWith(tone: v),
                  ),
                ),
              ),
            if (appearance.chatBackground.style == ChatBackgroundStyle.pattern)
              _choices(
                context,
                'Decorative pattern',
                ChatBackgroundPattern.values,
                appearance.chatBackground.pattern,
                (v) => v == ChatBackgroundPattern.dots ? 'Dots' : 'Diagonal',
                (v) => cubit.update(
                  appearance.copyWith(
                    chatBackground: appearance.chatBackground.copyWith(
                      pattern: v,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              icon: const Icon(Icons.restore),
              label: const Text('Reset to Defaults'),
              onPressed: () async {
                final account = state.account;
                final reset = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Reset chat appearance?'),
                    content: const Text(
                      'Restore default bubbles, colors, text size and background for this account on this device.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                );
                if (reset == true &&
                    !cubit.isClosed &&
                    cubit.state.account == account) {
                  await cubit.reset();
                }
              },
            ),
          ],
        );
      },
    ),
  );
}
