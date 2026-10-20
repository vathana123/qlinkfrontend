# qLink — Flutter Phase 1

Material 3 frontend with real Google/Apple identity-token authentication against Spring Boot. Chat rows are local presentation data; calls, contacts and composition are labeled placeholders. No Firebase Authentication or Phase 2 functionality is included.

Preserves the generated platform projects, application identifiers, SDK constraint and existing Cupertino dependency. Implemented using the installed **Flutter 3.47.4 / Dart 3.13.3**.

## Run

Environment settings are centralized in `lib/core/config/app_config.dart`.
`env/development.json` supplies the public Google Web OAuth client ID and the
Android emulator API URL (no client secret). Start with:

```powershell
flutter run -d <android-device-id> --dart-define-from-file=env/development.json
```

In VS Code, select **qLink Development**, select an Android device, and press
**F5**. No manual environment arguments are needed. The previous
**qLink Android (Google Sign-In)** launch profile is preserved.
For a physical device or a different backend, append
`--dart-define=API_BASE_URL=https://<api-host>` to the command.
Stop and restart the app after changing Dart defines; hot reload does not change
compile-time values. A bare `flutter run` without the define file or explicit ID
still correctly reports missing configuration.

AppConfig reads `GOOGLE_SERVER_CLIENT_ID`, `API_BASE_URL`, and the optional
native `GOOGLE_CLIENT_ID` using `String.fromEnvironment`. Dio uses
`AppConfig.apiBaseUrl`; the existing provider passes
`AppConfig.googleServerClientId` to `GoogleSignIn.instance.initialize(serverClientId: ...)` using
the installed `google_sign_in` 7.2.0 API. After `authenticate()`, it obtains
`account.authentication.idToken`. AuthRepository forwards this as `idToken`
with `provider: GOOGLE` through Dio to signup or signin, then securely stores
the returned application tokens. AuthBloc and the screens are unchanged.

Local overrides such as `env/development.local.json`, other JSON files in `env/`,
and `.env` files are ignored by Git; the public `env/development.json` is allowed.
Never put OAuth client secrets in any Flutter Dart-define file: compiled app
configuration can be extracted, even when the source file is ignored by Git.

Environment configuration verification (2026-10-17): `flutter analyze` passed,
37 authentication regression tests passed with `env/development.json`, and
`flutter run -d emulator-5554 --dart-define-from-file=env/development.json --no-resident`
successfully built, installed and launched the Android debug app. This uses the
same environment arguments as the F5 profile; the VS Code debugger UI itself
and a real Google account login were not exercised.

```powershell
flutter pub get
flutter devices
# Android emulator; replace IDs with your registered public OAuth client IDs.
flutter run -d <android-device-id> --dart-define=API_BASE_URL=http://10.0.2.2:8080 --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>.apps.googleusercontent.com
# iOS on a Mac, after completing signing and callback registration below.
flutter run -d <ios-device-id> --dart-define=API_BASE_URL=https://<api-host> --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>.apps.googleusercontent.com --dart-define=GOOGLE_CLIENT_ID=<ios-client-id>.apps.googleusercontent.com
flutter analyze
flutter test
```

`API_BASE_URL` is an origin, without `/api/v1`. The default `http://10.0.2.2:8080` is Android emulator host loopback. Physical devices need a reachable host/LAN address. Use HTTPS for release. Android cleartext is enabled **only for debug**. iOS ATS remains enabled; use HTTPS rather than weakening release transport security.

## Project structure and file inventory

All listed Dart files are new except `lib/main.dart`, which replaces the generated counter app.

```text
lib/
  main.dart
  app/
    app.dart
    router/app_router.dart
    theme/app_theme.dart
    theme/theme_cubit.dart
  core/
    error/app_exception.dart
    network/api_endpoints.dart
    network/auth_interceptor.dart
    network/dio_client.dart
    storage/token_storage.dart
    widgets/user_avatar.dart
  features/
    auth/
      data/
        datasources/oauth_provider.dart
        models/app_user.dart
        repositories/auth_repository.dart
      presentation/
        bloc/auth_bloc.dart
        screens/sign_in_screen.dart
        screens/sign_up_screen.dart
        widgets/auth_screen.dart
    home/presentation/
      screens/home_screen.dart
      screens/placeholder_screen.dart
      widgets/blur_app_bar.dart
      widgets/blur_bottom_bar.dart
      widgets/chat_list_tile.dart
    settings/presentation/screens/settings_screen.dart
  layout/main_layout.dart
test/
  auth_bloc_test.dart
  auth_repository_test.dart
  preferences_test.dart
  router_widget_test.dart
  session_test.dart
  support/fakes.dart
assets/branding/
  google_g.png
  README.md
ios/Runner/Runner.entitlements
```

Other modified files: `README.md`, `pubspec.yaml`, `pubspec.lock`, `android/app/src/main/AndroidManifest.xml`, `android/app/src/debug/AndroidManifest.xml`, `ios/Runner/Info.plist`, `ios/Runner.xcodeproj/project.pbxproj`, `macos/Runner/DebugProfile.entitlements`, `macos/Runner/Release.entitlements`. Removed the obsolete `test/widget_test.dart`. Flutter regenerates desktop plugin registrants/CMake plugin lists during package resolution; do not edit these manually.

## Added dependencies

| Package | Constraint | Purpose |
| --- | --- | --- |
| flutter_bloc | ^9.1.1 | Auth BLoC and theme Cubit |
| dio | ^5.11.1 | HTTP and refresh interceptor |
| go_router | ^18.1.0 | Auth guards and persistent tabs |
| flutter_secure_storage | ^11.2.0 | Platform secure credentials |
| shared_preferences | ^2.5.6 | Theme preference only |
| google_sign_in | ^7.2.0 | Native Google identity token |
| sign_in_with_apple | ^8.2.0 | Apple identity token and branded button |
| equatable | ^3.0.0 | Immutable state/event equality |

No extra test dependencies. HTTP uses an injected Dio adapter; OAuth uses an interface fake; storage/preferences use package test hooks. `pubspec.lock` pins resolved versions.

## Backend contract

Inspected actual sources in `../qlinkbackend/src/main/java/com/qlink`: `AuthController`, auth DTOs, `AuthService`, `NonceService`, `UserResponse`, `ApiResponse`, `ApiError`, `GlobalExceptionHandler`, and `OidcProviderTokenVerifier`.

Success envelope is `{success: true, message, data}`. Errors have **`data.code`**, not `error.code`. Auth responses contain `accessToken`, `refreshToken`, `tokenType`, `expiresIn`, and `user`. User fields are `id`, nullable `displayName`, nullable `email`, nullable `avatarUrl`, and `status`. The UI provides a neutral missing-name fallback.

| Endpoint | Request | Purpose |
| --- | --- | --- |
| POST `/api/v1/auth/signup` | `{provider, idToken, nonce?}` | Register provider identity |
| POST `/api/v1/auth/signin` | `{provider, idToken, nonce?}` | Existing identity login |
| POST `/api/v1/auth/nonce` | `{provider: "APPLE"}` | Single-use Apple challenge |
| POST `/api/v1/auth/refresh` | `{refreshToken}` | Rotate application tokens |
| GET `/api/v1/auth/me` | Bearer header | Validate session/load profile |
| POST `/api/v1/auth/signout` | Bearer header, **no body** | Revoke JWT `sid` session |

Known codes such as `NOT_REGISTERED`, `ALREADY_REGISTERED`, `INVALID_PROVIDER_TOKEN`, and `INVALID_NONCE` map to actionable messages. Raw provider/server exceptions never appear in UI.

## Dio and secure sessions

One reusable client sets JSON content/accept headers and 15-second connect/send and 20-second receive timeouts. Protected requests read their bearer token from secure storage. Signin/signup/nonce/refresh bypass bearer injection and refresh handling.

A protected 401 joins a shared refresh future, preventing concurrent rotation of the same refresh token. Late 401s compare their failed bearer token with the stored token and reuse an already refreshed token. Each original request retries at most once. Refresh is never recursively intercepted. Failed refresh clears credentials and notifies AuthBloc; a second 401 after retry also expires the session. A 5xx from a retried business request preserves valid refreshed credentials.

Tokens are stored together as one JSON secure-storage entry (`qlink.session.v1`), avoiding partial pair writes. They never enter SharedPreferences, UI state or logs. No HTTP logging interceptor is installed. Corrupt sessions are deleted. A startup `/me` connection failure does not grant Home access or automatically erase otherwise valid credentials; reopening the app retries restoration.

Sign-out calls the backend first, then deletes local credentials. If remote revocation cannot be confirmed, the UI explicitly reports local-only sign-out. If local secure deletion fails, the UI reports failure rather than claiming deletion succeeded. Per the backend contract, access JWTs remain valid until expiry even after successful refresh-session revocation.

## BLoC, navigation and theme

`AuthStarted` validates secure credentials with `/me`, refreshing on 401. Signin/signup events open the real provider, exchange its ID token at distinct backend endpoints, save application tokens, and use the profile returned by that exchange. No second `/me` request is required for a successful login. Cancellation returns quietly to unauthenticated state. Other failures emit `AuthFailure`. A busy guard drops duplicate submissions; a generation counter prevents expired startup work from subsequently authenticating the UI.

GoRouter listens to AuthBloc and centrally redirects startup to a progress screen, private unauthenticated routes to `/signin`, and authenticated login routes to `/chats`. Sign-out loading retains the current profile until completion. Repositories never navigate. `StatefulShellRoute.indexedStack` preserves tab state.

`ThemeCubit` restores Light/Dark/System from SharedPreferences (System by default), immediately emits selections, and serializes persistence writes. MaterialApp follows device appearance in System mode. Central blue-based ColorSchemes provide consistent surfaces and system icon contrast. Google/Apple button branding intentionally uses provider colors.

Auth content scrolls on small devices and disables duplicate submissions. Home supports filtering/search of local previews. Clipped backdrop filters blur content scrolling beneath the overlaid app bar and shell bottom navigation. Content padding keeps the final rows and settings controls reachable. Calls, contacts, chat taps and composition disclose their placeholder status.

## Android Google OAuth setup

Configured **Web** client ID:
`66607447341-57pg2483cp73jo2geh525sa1ucm1b7os.apps.googleusercontent.com`.

In the same Google Cloud project, also create an **Android** OAuth client with:

| Google Cloud field | Value for this checkout/machine |
| --- | --- |
| Package name | `com.example.qlinkfrontend` |
| Debug signing certificate SHA-1 | `98:E8:9D:F6:19:B4:9B:70:11:A0:01:65:C1:46:C5:01:DF:4F:D2:7E` |

The SHA-1 was read from `C:/Users/ADMIN/.android/debug.keystore`, alias
`androiddebugkey`. Another computer, release keystore, or Play App Signing key
can have a different fingerprint and needs its own matching registration.
The Web ID goes into `serverClientId`; do not replace it with the Android client ID.

Configure the Spring Boot process with `GOOGLE_CLIENT_IDS` including the Web ID
above and any applicable native client IDs needed by its `aud`/`azp` validation.
Restart the backend after changing its environment. This task does not change
backend configuration or Google Cloud Console settings. If the consent screen
is in testing mode, add the Google account used on the device as a test user.

The missing-client-ID warning is bypassed when running with the supplied define
file. Other native configuration failures still produce a safe error; cancellation
returns to the authentication screen without saving credentials. No end-to-end
Google login has been verified with a real account.

1. Configure Google Cloud OAuth consent and test users/publishing status. Register an **Android** OAuth client using the actual application ID (currently `com.example.qlinkfrontend`) and SHA-1 for each debug/release signing certificate. Register the Play signing certificate if distributing through Play.
2. Create a **Web application** OAuth client and pass its public ID as `GOOGLE_SERVER_CLIENT_ID`. The v7 SDK receives `serverClientId` explicitly; this does not require Firebase or `google-services.json`.
3. Set backend `GOOGLE_CLIENT_IDS` to your allowed audiences/authorized-party client IDs. Include the web/server ID and applicable native IDs to satisfy the backend's `aud` and `azp` checks.
4. Use a device/emulator with Google Play services. Repeated cancellation after account selection can indicate an incorrect package name, certificate SHA, or server client ID.
5. INTERNET permission and disabled automatic backup are configured. The installed Flutter default minSdk (24) is retained. Set a real application ID and production release signing before distribution; the starter's release signing configuration was preserved.

## iOS Google and Apple OAuth setup

On a Mac, open `ios/Runner.xcworkspace`, select your developer team, and use a registered bundle ID. The existing iOS deployment target is 15.0.

**Google:** Register an iOS OAuth client for that bundle ID. Pass it as `GOOGLE_CLIENT_ID`, along with the web/server `GOOGLE_SERVER_CLIENT_ID`. Add this to the top-level `ios/Runner/Info.plist` dictionary, replacing the scheme with the reversed **iOS** client ID. The native URL scheme is required even when the client IDs come from Dart defines:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>CFBundleURLSchemes</key>
    <array><string>com.googleusercontent.apps.YOUR_IOS_CLIENT_ID_PREFIX</string></array>
  </dict>
</array>
```

**Apple:** Enable Sign in with Apple for the App ID in the Apple Developer portal and Xcode Signing & Capabilities, then refresh provisioning profiles. `Runner.entitlements` supplies the Apple capability and app-scoped keychain group and is wired into Debug/Profile/Release. Entitlements alone do not configure the developer account. Set backend `APPLE_CLIENT_IDS` to your bundle ID. Native login needs no web Services ID or embedded client secret.

Each Apple attempt obtains a single-use five-minute nonce from Spring Boot. `nonceHash` goes to Apple's SDK; raw `nonce` accompanies the ID token to signup/signin. Google uses the native SDK without a nonce, explicitly permitted by the inspected backend. Its Flutter v7 API exposes nonce at initialization rather than per attempt; do not configure a static nonce that violates the backend's single-use contract.

Apple may supply name/email only on initial consent. The backend accepts verified token claims, not the SDK's separate full-name field, so the UI renders the actual server profile with a missing-name fallback.

For macOS, configure the corresponding native client ID and callback scheme in `macos/Runner/Info.plist`, signing and Apple capability. Network-client and keychain entitlements were added while preserving sandbox/JIT settings. Validate on a Mac.

Google is enabled on Android/iOS/macOS; Apple is offered on iOS/macOS and checks device availability. Windows/Linux/web retain their projects but native login is disabled with explanatory text. Apple Android/browser redirects and Google's web-rendered authentication button are not configured in this mobile phase.

## Validation and remaining configuration

- `flutter test`: **48 tests passed**. Covers preferences/storage, BLoC transitions, duplicate submissions, API and nonce mappings, stale-header removal on public endpoints, refresh eligibility, bearer injection, concurrent/late refresh, startup rotation, bounded retries, failures, signout, redirect guards, small screens with large text, and light/dark navigation/settings.
- `flutter analyze`: **No issues found**.
- HTTP/OAuth are mocked only in tests; production has no mock-login switch.
- Live authentication still requires registered client IDs, consent settings, signing certificates, Apple capabilities/profiles and a reachable configured backend. These were not supplied; no live-provider success is claimed.
- The Android debug build and emulator launch were verified during environment setup. Manual provider consent flows remain untested; iOS/macOS builds require macOS/Xcode.
- Before release, smoke-test real signup/signin, provider cancellation, unregistered/existing accounts, restart, token expiry/rotation, revoked sessions, offline signout, and blur/edge-to-edge behavior on target devices.

## Authentication investigation (2026-10-17)

No WorkManager dependency, initialization, callback dispatcher, scheduled auth task, or periodic polling was found in this project's source, package manifests/lockfile or generated plugin metadata. Authentication uses normal BLoC-triggered Dio requests. No background dependency needed removal.

The supplied log's PID **6462** was verified on `emulator-5554` as **`com.example.test_flutter_message`**, whereas qLink's package is **`com.example.qlinkfrontend`**. Android scheduler metadata confirmed BackgroundWorker jobs for the separate test app; those unrelated jobs were not removed. Its exact requested endpoint was not present in the supplied log or recovered URL-only diagnostics.

The response `data.code=UNAUTHORIZED` comes from the inspected Spring security entry point: the request did not satisfy application access-token authentication. It does not identify whether the token was absent, expired, had an invalid signature/issuer, or was sent to the wrong path/method. Direct localhost probes confirmed `GET /api/v1/auth/me` without a bearer returns 401/UNAUTHORIZED, while empty `POST /api/v1/auth/signin` and `/signup` reach DTO validation (400/VALIDATION_ERROR). Public routing therefore works. Backend source checks issuer, timestamps, access/refresh token purpose, and RSA signature; its encoder checks matching keys. A real token's claims/signature cannot be verified from the supplied log. No backend changes were made.

Fixed a separate client gap: inherited/default Authorization headers are now removed from public API calls; protected calls use the securely stored access token. This prevents stale inherited bearers from failing Spring's bearer filter before public endpoint authorization. Only signed protected requests to the configured API origin qualify for refresh. Signin/signup now return their already-validated response profile after storing credentials, avoiding a redundant post-login request. Startup still uses `/me` and the existing bounded refresh path.

Changed files for this fix: `lib/core/network/auth_interceptor.dart`, `lib/features/auth/data/repositories/auth_repository.dart`, `test/session_test.dart`, `test/auth_repository_test.dart`, and this README. BLoC, token storage, UI, theme and router needed no changes. Native provider consent flows remain unverified; automated auth tests mock provider and HTTP responses.

Filter Android logs to `com.example.qlinkfrontend` when validating qLink; logs from the separate test app do not demonstrate a qLink background-authentication failure.

## References

- [Google Flutter v7 API](https://pub.dev/packages/google_sign_in)
- [Android plugin configuration](https://pub.dev/packages/google_sign_in_android)
- [iOS plugin configuration](https://pub.dev/packages/google_sign_in_ios)
- [Apple plugin setup](https://pub.dev/packages/sign_in_with_apple)
- [Google button branding](https://developers.google.com/identity/branding-guidelines)
- [Secure storage setup](https://pub.dev/packages/flutter_secure_storage)

Installed package READMEs/source APIs were also inspected for the exact resolved versions.
