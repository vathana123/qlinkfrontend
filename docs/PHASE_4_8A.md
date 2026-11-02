# Phase 4.8A — Message Bubble Appearance

Implemented 2026-11-01 on `phase_4/phase_4.8`. The frontend working tree was clean at the start, with Phase 4.7 committed as `a177c3a`. No commits were created by this task.

## Changes

- Added immutable `ChatAppearance`, a Flutter theme extension containing bubble style, outgoing color and message font size. It supports value equality, `copyWith` and theme interpolation, with a default fallback for widgets using an ordinary `ThemeData`.
- Default (`ChatBubbleStyle.standard`) retains the existing asymmetric 20/6 corners and padding. Rounded uses 26-pixel corners and more padding. Compact uses 12/6 corners, smaller padding and tighter vertical spacing. Incoming/outgoing alignment and the existing width cap remain unchanged.
- Outgoing colors: QLink Blue (default), Ocean, Purple and Emerald. The default uses QLink's existing light/dark color scheme; other presets use brightness-aware Material color schemes. Generated preset palettes are reused.
- Message font sizes: Small 14, Medium 16 (default), Large 18 logical pixels. Caption sizes are 11/12/13. Message typography uses a 1.5 line height, inherits the platform's font fallback and respects Flutter's text scaler without clamping.
- Added a reusable `ChatBubble` visual shell. Text, quotes, forwarded labels, attachment names and voice labels inherit the bubble's typography and foreground. Timestamp/edit/delivery captions use the same configuration. Photo clipping follows the selected style.
- Preserved message keys, action callbacks, reaction controls, search highlighting, reply navigation, photo cache entries and audio sources. The confirmed-message action sheet now scrolls when its contents exceed the available height, fixing a small overflow found during testing.
- AppTheme registers the default extension in both light and dark themes. ThemeMode/system behavior is retained.

Changed/new files:

- `lib/features/chat/presentation/theme/chat_appearance.dart` — new configuration and visual metrics.
- `lib/features/chat/presentation/widgets/chat_bubble.dart` — new visual shell.
- `lib/features/chat/presentation/screens/chat_screen.dart` — applies the shell and caption style; scrollable action sheet.
- `lib/features/chat/presentation/widgets/attachment_bubble.dart` — appearance-aware photo corners/captions and inherited icon foreground.
- `lib/app/theme/app_theme.dart` — default extension registration.
- `test/chat_appearance_test.dart` — new appearance and integration tests.

No backend, message business logic, WebSocket, Firebase, authentication, BlurAppBar or dependency files were changed. Settings, persistence and backgrounds remain outside this phase.

## Preview instructions

The shipped appearance is Default / QLink Blue / Medium. There is no settings screen in this phase.

For a development preview, temporarily replace `extensions: const [ChatAppearance()]` in `AppTheme._build` with:

```dart
extensions: const [
  ChatAppearance(
    bubbleStyle: ChatBubbleStyle.rounded,
    outgoingColor: OutgoingBubbleColor.ocean,
    fontSize: MessageFontSize.large,
  ),
],
```

Run the existing Flutter app and hot reload. Open a conversation with incoming/outgoing text, Khmer text, a reply, reactions, a photo and a voice message. Cycle `standard`, `rounded`, `compact`; `qlinkBlue`, `ocean`, `purple`, `emerald`; and `small`, `medium`, `large`. Preview both themes and system font scaling. Revert the preview values to `ChatAppearance()` afterward. A local `Theme` with this extension can also wrap a ChatScreen for an isolated preview.

## Automated verification

- `flutter analyze`: no issues.
- Focused suite: **124 tests passed**.
- Seven new tests include 144 rendered matrix cases: 3 styles × 4 colors × 3 sizes × 2 themes × 2 text scales. They exercise Khmer/English wrapping at a 320-pixel viewport, outgoing text contrast of at least 4.5:1, width constraints, incoming/search-highlight rendering and style geometry.
- Actual ChatScreen tests cover forwarded/reply/reaction/edit metadata, action-menu availability and selecting Reply in each style.
- A media regression test changes appearance around mounted photo/voice widgets and verifies identical photo state/cache objects, one audio-source load, continued playback and no additional download requests.
- Existing interaction, search/navigation, receipts, media aspect-ratio, caching, scroll and light/dark/system routing tests passed.
- `git diff --check`: passed.

Command:

```text
flutter test test/chat_appearance_test.dart test/message_actions_test.dart test/message_interactions_test.dart test/attachments_test.dart test/media_cache_test.dart test/voice_test.dart test/chat_search_test.dart test/realtime_test.dart test/receipt_test.dart test/chat_test.dart test/router_widget_test.dart --reporter expanded
```

## Limits and manual verification

No device testing, Android builds or screenshot capture was performed. Widget tests verify layout/text structure and calculated contrast; they do not verify the Khmer glyph shaping of each device's installed fonts. Confirm Khmer rendering, real audio playback, large accessibility text and appearance changes on target devices before release. Configuration is available programmatically only until Phase 4.8C adds settings and persistence; chat backgrounds belong to Phase 4.8B.
