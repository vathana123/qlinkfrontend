# Windows Android build locks

## Findings (2026-10-25)

Gradle daemon logs confirmed overlapping QLink frontend builds against the same
`build/` directory. For example, daemon 34044 built from 01:39:00 to 01:41:46;
daemon 15164 started at 01:39:16 and failed to access Firebase's generated
`BuildConfig.java`. Earlier overlapping builds failed to delete
`build/app/outputs/apk/debug`. A Flutter run for emulator-5556 was still active
when recovery began.

`android/build.gradle.kts` assigns one output directory per Gradle project,
not per device. This is the existing Flutter layout; no incorrect project
directory configuration was found. Separate emulator IDs do not isolate
simultaneous builds. Failed/interrupted builds can leave Kotlin incremental
state behind; no compiler flags or dependency changes were justified.

Windows deletion-access probes and Restart Manager checks found no remaining
file owner at inspection time. The earlier transient handle owner was not
captured, so antivirus or another external process is not established as the
cause. Security protections were not changed.

## Prevent recurrence

Run only one Android build/clean operation at a time in this checkout, including
terminal commands and IDE launches. Stop or detach the existing Flutter session
before starting another build. An emulator can keep running with its installed
app while a different emulator is built sequentially.

For a single build, install and launch without leaving a Flutter build session:

```powershell
flutter run -d emulator-5554 --debug --no-resident --dart-define-from-file=env/development.json --dart-define=QLINK_FCM_ENABLED=true
```

For hot reload, omit `--no-resident`. Press `d` to detach before building for
another device. Do not start a concurrent `flutter clean` or IDE Gradle sync
while the Android build is writing outputs.

For two devices with the same configuration, build once and install the same
APK sequentially instead of launching two builds:

```powershell
flutter build apk --debug --dart-define-from-file=env/development.json --dart-define=QLINK_FCM_ENABLED=true
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5556 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 shell am start -n com.example.qlinkfrontend/.MainActivity
adb -s emulator-5556 shell am start -n com.example.qlinkfrontend/.MainActivity
```

## Recover safely

1. Stop QLink frontend run/build sessions through their terminal or IDE. Inspect
   process command lines and Gradle daemon logs before stopping any residual
   PID. Never kill every `java`, `dart`, or `adb` process; Spring Boot, IDEs and
   other projects may use them. `gradlew --stop` can affect other builds using
   the same Gradle version, so use it only when that scope is acceptable.
2. If a file is still locked, identify its owner with Windows Resource Monitor,
   Restart Manager, or an existing trusted process-inspection tool. Close the
   owning build/file viewer normally. Do not disable antivirus or add broad
   exclusions. If the owner cannot safely be stopped, report it rather than
   repeatedly deleting caches or killing unrelated processes.
3. With builds stopped, remove only project-local generated outputs after
   verifying each absolute path is inside this checkout. Recovery here removed
   `build/`, `android/.gradle/`, `android/.kotlin/` and
   `.dart_tool/flutter_build/`. Keep `.dart_tool/package_config.json`, the pub
   cache, global Gradle caches, source files and configuration intact.
4. Run the single-device command above and inspect the complete result before
   launching a second build.

Firebase/Google configuration, signing keys, package identity and all Flutter,
Gradle, Kotlin and Firebase dependency versions remain unchanged by recovery.

## Verification

The single-device debug build using `env/development.json` and
`QLINK_FCM_ENABLED=true` succeeded after cleanup (717 seconds), without file-lock
or Kotlin cache-registration errors. The first installation failed because the
emulator's Android system had crashed and its package service was missing.
Rebooting only emulator-5554 without wiping data restored that service; installing
the already-built APK then succeeded, and `am start -W` reported `Status: ok`
with a running QLink process.

After the build, 15 generated files were checked for incompatible deletion
handles; none were found. Hash checks confirmed Firebase/Google configuration,
environment values, build settings and dependency manifests/lockfiles were
unchanged. Only this guide was added as a source-controlled change for recovery.
