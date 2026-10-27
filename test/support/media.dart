import 'package:flutter_test/flutter_test.dart';

import 'dart:async';

/// Disk I/O completes outside Flutter's fake animation clock.
Future<void> pumpMedia(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
  }
  throw TestFailure('Media did not finish loading.');
}

Future<void> runMediaTask(
  WidgetTester tester,
  Future<void> Function() task,
) async {
  var done = false;
  Object? error;
  StackTrace? stack;
  unawaited(
    task().then(
      (_) => done = true,
      onError: (Object failure, StackTrace trace) {
        error = failure;
        stack = trace;
        done = true;
      },
    ),
  );
  await pumpMedia(tester, () => done);
  if (error != null) Error.throwWithStackTrace(error!, stack!);
}
