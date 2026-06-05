import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omo_switcher_client/main.dart';

void main() {
  test('restartLocalDesktop kills and launches OpenCode on Windows', () async {
    final runCalls = <String>[];
    final startCalls = <String>[];

    final result = await restartLocalDesktop(
      operatingSystem: 'windows',
      environment: const {'LOCALAPPDATA': r'C:\Users\tester\AppData\Local'},
      exists: (path) =>
          path ==
          r'C:\Users\tester\AppData\Local\Programs\@opencode-aidesktop\OpenCode.exe',
      runProcess: (executable, args) async {
        runCalls.add('$executable ${args.join(' ')}');
        return ProcessResult(1, 0, '', '');
      },
      startProcess: (executable, args, {required runInShell}) async {
        startCalls.add('$executable|shell=$runInShell');
      },
    );

    expect(result.ok, isTrue);
    expect(runCalls, [r'taskkill /IM OpenCode.exe /T /F']);
    expect(startCalls, [
      r'C:\Users\tester\AppData\Local\Programs\@opencode-aidesktop\OpenCode.exe|shell=false',
    ]);
  });
}
