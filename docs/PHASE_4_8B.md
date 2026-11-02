# Phase 4.8B — Chat backgrounds

Implemented on `phase_4/phase_4.8`, 2026-11-01. The existing uncommitted Phase 4.8A work was preserved. No commits, dependencies, image assets or animations were added.

## Options and implementation

- Default: the active theme's exact scaffold background.
- Solid: Blue, Lavender or Mint, blended subtly with the theme background.
- Gradient: the same three tones fading diagonally toward the theme surface.
- Pattern: lightweight dots or diagonal lines over any of the three tones. Pattern opacity adapts to brightness.

`ChatBackgroundConfig` is immutable, supports equality and `copyWith`, and is part of the existing `ChatAppearance` theme extension. `appearance.restoreBackground()` restores the default while retaining bubble style, outgoing color and font size.

`ChatBackground` draws a stationary viewport layer behind the chat body, including the area behind the existing BlurAppBar. It works with both personal and group conversations. Decoration ignores pointers and semantics. A repaint boundary isolates it from scrolling; the custom painter repaints only when its resolved color or pattern changes. Rendering uses flat colors, a two-color gradient or a sparse canvas pattern, independent of history length. Message bubbles remain opaque and keep Phase 4.8A colors and typography.

`ChatAppearancePreview` is a bounded, scrollable, bilingual sample conversation using the same background and bubble widgets. It needs no authenticated session, repository or media downloads. It preserves other theme extensions and can be embedded in the future settings screen.

## Files changed in this phase

- New `lib/features/chat/presentation/theme/chat_background_config.dart`.
- Updated `lib/features/chat/presentation/theme/chat_appearance.dart` with background configuration and restoration.
- New `lib/features/chat/presentation/widgets/chat_background.dart`.
- New `lib/features/chat/presentation/widgets/chat_appearance_preview.dart`.
- Updated `lib/features/chat/presentation/screens/chat_screen.dart` to wrap the existing body in the background layer.
- New `test/chat_background_test.dart`.

Backend, messaging logic, Firebase, WebSocket, BlurAppBar and photo/voice cache implementations were not changed. Settings and persistence remain for 4.8C.

## Preview instructions

For an isolated developer preview, import the appearance/configuration/preview files and embed:

```dart
ChatAppearancePreview(
  appearance: const ChatAppearance(
    bubbleStyle: ChatBubbleStyle.rounded,
    chatBackground: ChatBackgroundConfig(
      style: ChatBackgroundStyle.pattern,
      tone: ChatBackgroundTone.mint,
      pattern: ChatBackgroundPattern.dots,
    ),
  ),
)
```

For a real-conversation preview, temporarily pass that `ChatAppearance` to the existing `AppTheme` extensions registration, run the app and hot reload. Try `theme`, `solid`, `gradient`, `pattern`; `blue`, `lavender`, `mint`; and `dots`, `diagonal`. Switch light/dark/system themes, scroll a long personal or group chat and test a photo and playing voice message. Restore `ChatAppearance()` afterward. To reset only the background programmatically, use the current appearance's `restoreBackground()` result in the theme extension.

## Verification

- Focused Flutter suite: **128 tests passed**. Includes background and Phase 4.8A appearance matrices, message actions/forwarding/reactions, search, media cache/voice regressions, routing, system themes and realtime scrolling.
- Five new tests cover restoring defaults without losing bubble preferences; all background/tone/pattern combinations in both themes at 2× scaling; readable incoming/outgoing bubbles across all outgoing presets; gradient/pattern selection; painter invalidation; and retained list scroll position/taps while changing backgrounds on a 1,000-row lazy list.
- `flutter analyze`: clean after fixing brace-style lint.
- `git diff --check`: passed.

Command:

```text
flutter test test/chat_background_test.dart test/chat_appearance_test.dart test/realtime_test.dart test/attachments_test.dart test/media_cache_test.dart test/voice_test.dart test/message_actions_test.dart test/message_interactions_test.dart test/chat_search_test.dart test/chat_test.dart test/router_widget_test.dart --reporter expanded
```

No screenshots, physical-device tests or Android builds were performed. Preview on target devices to assess subjective pattern subtlety and real scrolling performance. Configuration is currently programmatic and session-only, with no per-conversation persistence or settings UI.
