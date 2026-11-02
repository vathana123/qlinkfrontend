# Phase 4.8C — Chat Appearance Settings

Completed 2026-11-01 on `phase_4/phase_4.8`. All existing uncommitted Phase 4.8A/B work was preserved. No commits, dependencies or backend changes were added.

## Completed settings

Navigation: **User Profile → Appearance → Chat Appearance**.

Appearance provides the existing Light, Dark and System theme choices. Chat Appearance provides:

- Bubble style: Default, Rounded, Compact.
- Outgoing color: QLink Blue, Ocean, Purple, Emerald.
- Message font size: Small, Medium, Large.
- Background: Theme default, Solid, Gradient, Pattern; Blue/Lavender/Mint tones and Dots/Diagonal patterns where applicable.
- A live, scrollable bilingual preview with incoming/outgoing bubbles, a synthetic photo sample, voice-message illustration and sample reactions. Samples require no network requests, media decoding or audio player.
- Reset to Defaults with confirmation, scoped to this account's chat appearance. Cancel preserves preferences; a dialog opened for an earlier account cannot reset the new account.
- Local save errors retain the immediately applied appearance and offer Retry saving.

The selected configuration applies globally to personal and group conversations immediately. It reuses the A/B theme extension, visual shell, background widget and preview instead of duplicating rendering. Applying it retains route/widget identity, chat cubits and message keys. Theme-dependent visual widgets redraw as required, without recreating the history or fetching it again.

## Persistence and account handling

The existing SharedPreferences infrastructure stores a version-1 JSON payload under `qlink.chat-appearance.v1.<base64url-account-id>`. Enum names are stored rather than numeric indexes; missing, invalid, unsupported-version or unknown values safely resolve to defaults.

Preferences are loaded synchronously from the initialized preference cache when an account becomes active. Logout applies defaults. Account switching applies that account's saved/session values immediately. Writes capture their account and value before entering a serial queue, so rapid selections and switching accounts cannot redirect an older write. Unsaved session selections remain associated only with their original account. Errors from obsolete requests do not replace the current account's state.

Existing device-wide theme-mode persistence remains unchanged. Chat appearance itself is per-account and local to this installation, without server synchronization. The store and immutable configuration are separate so a future conversation-override layer can be added without changing the global preference format in this phase. No per-conversation settings are implemented.

## Files changed in 4.8C

- New `lib/features/chat/data/repositories/chat_appearance_store.dart`: versioned per-account local persistence.
- New `lib/features/chat/presentation/bloc/chat_appearance_cubit.dart`: immediate updates, serialized saves, account switching, reset and save errors.
- New `lib/features/chat/presentation/screens/chat_appearance_screen.dart`: Appearance navigation screen and Chat Appearance controls.
- Updated `lib/features/chat/presentation/widgets/chat_appearance_preview.dart`: optional synthetic media/reaction samples, enabled by settings; the original two-message preview remains the default for existing callers.
- Updated `lib/app/app.dart`: lifecycle ownership of the cubit, account selection and a stable theme-extension wrapper around routed content.
- Updated `lib/app/router/app_router.dart`: `/profile/appearance` and `/profile/appearance/chat` routes.
- Updated `lib/app/theme/theme_cubit.dart`: exposes the existing initialized preferences instance for reuse.
- Updated `lib/features/user/presentation/screens/user_profile_screen.dart`: Appearance entry.
- Updated `lib/features/chat/presentation/theme/chat_appearance.dart`: documentation of separate persistence ownership.
- New `test/chat_appearance_settings_test.dart`: persistence/account/race/reset/navigation/theme/accessibility tests.

The prior A/B files remain uncommitted alongside these additions. BlurAppBar, WebSocket, Firebase, authentication logic, message logic and photo/voice caching implementations were not modified in this phase.

## Final Phase 4.8 automated verification

- **Flutter analysis: no issues.**
- **164 relevant tests passed**, covering all A/B appearance/background tests, new settings tests and existing chat/media/search/realtime/outbox/privacy/navigation regressions.
- Six new settings tests cover all persisted fields; a fresh cubit/store restoring saved values; logout/account isolation; malformed/unknown data; delayed writes across account switches; save failures; reset confirmation/cancel; stale reset dialogs; 2× text scaling on a 360-pixel viewport in both themes; real profile navigation; Light/Dark/System compatibility; and immediate propagation to personal/group chats while preserving their cubits and history-request counts.
- A/B regression coverage includes style/color/font combinations, Khmer/English text, contrast, backgrounds/patterns, scroll retention, media widget/cache identity and active voice-source reuse.
- `git diff --check`: passed.

Command:

```text
flutter test test/chat_appearance_settings_test.dart test/chat_appearance_test.dart test/chat_background_test.dart test/chat_management_test.dart test/storage_management_test.dart test/presence_test.dart test/privacy_test.dart test/message_interactions_test.dart test/media_cache_test.dart test/chat_search_test.dart test/chat_test.dart test/message_actions_test.dart test/receipt_test.dart test/realtime_test.dart test/outgoing_queue_test.dart test/router_widget_test.dart test/attachments_test.dart test/voice_test.dart --reporter expanded
```

**Phase 4.8A, 4.8B and 4.8C implementation and automated verification are complete.** The earlier A/B reports describe their stage-specific programmatic previews; this settings screen now provides the user-facing persisted controls.

## Manual preview and limits

Open Profile → Appearance → Chat Appearance. Change each option, scroll the live preview to see photo/voice/reaction samples, then open personal and group chats. Change the app theme, confirm/cancel reset, restart the app and switch accounts to inspect restoration and isolation.

No physical-device tests, screenshots or Android builds were performed. SharedPreferences tests use mocked platform storage, with restart simulated by fresh store/cubit instances; actual OS-process restart, device disk failures, platform Khmer glyph shaping and real playback should be checked on target devices. The preview's media/reactions are illustrative, not playable or editable. Appearance is local to the account on this device, with no cross-device sync or per-conversation overrides.
