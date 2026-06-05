import 'package:flutter_test/flutter_test.dart';
import 'package:omo_switcher_client/main.dart';

void main() {
  test('uses LOCALAPPDATA for Windows local store by default', () {
    final directory = defaultLocalStoreDirectory(
      environment: const {
        'LOCALAPPDATA': r'C:\Users\tester\AppData\Local',
        'APPDATA': r'C:\Users\tester\AppData\Roaming',
      },
      operatingSystem: 'windows',
      currentPath: r'C:\workspace\omo-switcher\client',
      pathSeparator: r'\',
    );

    expect(
      directory.path,
      r'C:\Users\tester\AppData\Local\omo-switcher-client',
    );
  });

  test('falls back to APPDATA when LOCALAPPDATA is unavailable', () {
    final directory = defaultLocalStoreDirectory(
      environment: const {'APPDATA': r'C:\Users\tester\AppData\Roaming'},
      operatingSystem: 'windows',
      currentPath: r'C:\workspace\omo-switcher\client',
      pathSeparator: r'\',
    );

    expect(
      directory.path,
      r'C:\Users\tester\AppData\Roaming\omo-switcher-client',
    );
  });

  test('keeps the macOS Application Support path', () {
    final directory = defaultLocalStoreDirectory(
      environment: const {'HOME': '/Users/tester'},
      operatingSystem: 'macos',
      currentPath: '/workspace/omo-switcher/client',
      pathSeparator: '/',
    );

    expect(
      directory.path,
      '/Users/tester/Library/Application Support/omo-switcher-client',
    );
  });
}
