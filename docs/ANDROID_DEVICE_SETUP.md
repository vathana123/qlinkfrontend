# Android development on Windows

Use the `phase_4/phase_4.3` branches in both repositories. Run Flutter commands
from `qlinkfrontend` and backend commands from `qlinkbackend`. Commands below
use PowerShell. Put Flutter and Android SDK `platform-tools` on PATH, or use:

```powershell
$adb = "$env:LOCALAPPDATA/Android/sdk/platform-tools/adb.exe"
& $adb devices -l
```

## Backend

Keep the existing `.env`, MySQL database, JWT keys and Flyway history. For USB
only, bind to loopback; no inbound firewall rule is needed:

```powershell
.\gradlew.bat bootRun --args="--server.address=127.0.0.1 --server.port=8080"
```

For Wi-Fi, bind to the active LAN interface (or use `0.0.0.0` if appropriate):

```powershell
$backendHost = Read-Host 'Computer Wi-Fi IPv4 address from ipconfig'
.\gradlew.bat bootRun --args="--server.address=$backendHost --server.port=8080"
```

Spring Boot also accepts `SERVER_ADDRESS` / `SERVER_PORT` environment variables.
No production configuration change is required. The `test` profile requires
`TEST_STORAGE_ROOT`; it is not a physical-device development profile. The
`prod` profile retains its separate storage default and requires HTTPS at the
public endpoint.

Verify the API locally (the OpenAPI endpoint is public):

```powershell
Invoke-WebRequest http://127.0.0.1:8080/v3/api-docs -UseBasicParsing
```

When bound only to the Wi-Fi interface, substitute that address for loopback.

## Physical phone over USB (preferred)

Enable Developer options and USB debugging, connect a data-capable USB cable,
unlock the phone and accept the RSA authorization prompt. Install the phone
manufacturer's Windows USB driver if it never appears in `adb devices -l`.
Use its serial explicitly when emulators or other devices are connected:

```powershell
$phone = Read-Host 'Physical phone serial from adb devices -l'
& $adb -s $phone reverse tcp:8080 tcp:8080
& $adb -s $phone reverse --list
flutter run -d $phone --debug --dart-define-from-file=env/development.json --dart-define=API_BASE_URL=http://127.0.0.1:8080
```

In VS Code select that phone and `qLink Physical Android (USB)` after running
the reverse command. Reapply forwarding after reconnect/reboot if absent.
The phone's `127.0.0.1:8080` now reaches the computer's `127.0.0.1:8080`.
Remove forwarding when finished with `adb -s $phone reverse --remove tcp:8080`.
USB push testing still requires an Internet connection for Google/FCM.

## Emulator

The existing development configuration remains unchanged:

```powershell
flutter run -d emulator-5554 --debug --dart-define-from-file=env/development.json
```

Use the actual emulator ID from `flutter devices`. `10.0.2.2:8080` is the
Android emulator's alias for the computer; it is not a physical-phone address.

## Physical phone over Wi-Fi

Connect phone and computer to the same trusted LAN. Run `ipconfig` and use the
active Wi-Fi adapter's IPv4 address with a gateway, not a WSL/Hyper-V adapter.
At inspection, `172.19.160.1` was WSL and `10.97.227.6` was Wi-Fi; these are
observations, not stable configuration. Guest networks may isolate clients.

Start the backend with the Wi-Fi binding above, then:

```powershell
$backendHost = Read-Host 'Computer Wi-Fi IPv4 address from ipconfig'
flutter run -d $phone --debug --dart-define-from-file=env/development.json --dart-define=API_BASE_URL=http://${backendHost}:8080
```

The USB cable can remain attached for Flutter debugging; API traffic uses Wi-Fi.
VS Code's `qLink Physical Android (Wi-Fi)` prompts for the host. The phone's
browser should open `http://<computer-ip>:8080/v3/api-docs` before app testing.

If Windows Firewall blocks access, an administrator can add this narrowly
scoped rule **only on a trusted network whose Windows profile is Private**:

```powershell
New-NetFirewallRule -DisplayName 'QLink development 8080' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8080 -Profile Private -RemoteAddress LocalSubnet
# Remove it when no longer needed:
Remove-NetFirewallRule -DisplayName 'QLink development 8080'
```

Do not disable the firewall or add a Public-profile allow rule.

## One backend address for REST, WebSocket and files

`API_BASE_URL` feeds Dio and the push background receipt client. `AppConfig`
derives `/ws` with `ws` for HTTP or `wss` for HTTPS. Uploads, image/file/voice
downloads and stored avatars use relative `/api/v1/storage/...` paths through
the same authenticated Dio instance. No separate storage host is needed.
Native clients do not require browser CORS exceptions; keep existing allowlists.
If testing a browser client or sending an explicit WebSocket Origin, add only
its exact origin to `CORS_ALLOWED_ORIGINS` / `WS_ALLOWED_ORIGINS`, never `*`.

Android's debug resource overrides the network security configuration to allow
development HTTP, including changing LAN addresses. Main/release resources
remain unchanged and deny general cleartext traffic (the existing loopback
exception remains). Use HTTPS/WSS for production; do not copy the debug policy
into main or release. Local HTTP examples are for `--debug` only.

## Google Sign-In

The package/application ID is `com.example.qlinkfrontend`. Physical-device
Google login uses the same debug signing key as emulator login. Register the
existing signing certificate in the Google Cloud project that owns the current
Android OAuth client, with that exact package name:

```text
SHA-1:   98:E8:9D:F6:19:B4:9B:70:11:A0:01:65:C1:46:C5:01:DF:4F:D2:7E
SHA-256: FE:01:FF:96:E8:67:BA:1C:C5:14:C6:4B:01:3E:96:2D:C0:A1:67:41:C7:AE:F4:85:6D:D2:F8:CC:B3:A2:5E:E8
```

Recheck on other computers with `cd android; .\gradlew.bat signingReport`.
`env/development.json` supplies the existing **web/server** OAuth client ID;
it matches the backend's current accepted Google audience. Keep it intact.
`GOOGLE_ANDROID_CLIENT_IDS` must contain the Android OAuth client IDs, not
fingerprints or package names. Ensure any required OAuth test users are allowed.
No OAuth client secret belongs in Flutter. Release/Play signing fingerprints
must be registered separately before distribution.

## Firebase / push

The local `android/app/google-services.json` matches the Android package and
configures Firebase project `qlink-b1257`. Its project number differs from the
existing Google login project, and it has no OAuth client entries. This does
not by itself invalidate the separate, explicitly configured Google login flow;
do not silently replace its client IDs. Cloud-console access is needed to
verify the Android OAuth package/certificate registration. If intentionally
consolidating projects, update the server audience and Android client allowlist
together using real console-issued IDs. See [Google's Android setup guide](https://firebase.google.com/docs/auth/android/google-signin).

The native Google Services Gradle plugin is installed. Android initialization
uses those generated native resources; `firebase_options.dart` need not be
wired into the existing Android flow. To enable the optional FCM client, append:

```text
--dart-define=QLINK_FCM_ENABLED=true
```

Grant notifications permission when requested. Backend push is disabled until
the operator supplies the matching Firebase project and authorized Application
Default Credentials (ADC). Keep credential files outside the repository:

```powershell
$env:PUSH_ENABLED = 'true'
$env:FIREBASE_PROJECT_ID = 'qlink-b1257'
$env:GOOGLE_APPLICATION_CREDENTIALS = 'C:\path\outside-repository\service-account.json'
# Start backend with the chosen USB/Wi-Fi command above.
```

The credential must be authorized to send FCM messages to this Firebase project;
enable the FCM HTTP v1 API there. Do not create a service account key merely to
follow this example if your existing ADC setup already works. No backend ADC
file or push settings were found during inspection. The existing PushSession
registers authenticated devices, handles refresh and unregisters on logout.

## Device verification checklist

After backend startup validates Flyway, sign in with Google and verify REST
loads conversations and the realtime connection recovers without polling.
With a second account/device test personal and group messages, delivered/seen
receipts, replies/edits/deletion, image/file/voice upload and download, and a
profile avatar update. Test both URL modes and restart/reconnect.

For push, enable FCM on both sides, leave the recipient logged in, unmute the
conversation, background the recipient app (do not Android-force-stop it), and
send from another account. Verify one notification and tap navigation. Repeat
foreground (no duplicate notification) and terminated/background cases; confirm
logout unregisters the device. These require real accounts/device permissions
and authorized Firebase configuration; unit tests alone cannot certify them.

## Verification on 2026-10-25

- Built the debug APK with the USB URL and FCM client enabled, installed it on
  the connected Samsung SM-S938B and launched the sign-in screen successfully.
- Confirmed `adb reverse` and phone-originated HTTP 401 for a protected API
  without credentials, plus HTTP 101 for `/ws` through the USB tunnel.
- The existing backend returned OpenAPI HTTP 200. A second startup attempt
  validated all 15 Flyway migrations (already V15) but could not bind because
  the existing server occupied 8080; it was left running.
- Flutter analysis passed for the six inspected source targets. The focused
  suite initially passed 66 tests with two Windows temporary-file cleanup
  failures; all 21 tests in those two files passed when rerun sequentially.
- The phone's Wi-Fi radio was disabled, so direct LAN connectivity could not
  be verified. Enable Wi-Fi and join the computer's trusted LAN before testing.
- Google account selection, authenticated messaging/media/avatar behavior and
  FCM delivery still require interactive verification and the console/ADC
  configuration described above. No credentials or production policies changed.
- Build warning: `firebase_core` currently applies the Kotlin Gradle Plugin;
  Flutter warns about compatibility with a future toolchain. The current APK
  build succeeded; no dependency change was needed for device configuration.
