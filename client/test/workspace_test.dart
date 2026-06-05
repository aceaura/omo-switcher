import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omo_switcher_client/workspace.dart';

const _balanced = {
  'oh-my-openagent.json': '{"omo":"balanced"}',
  'oh-my-opencode-slim.json': '{"slim":"balanced"}',
  'opencode.jsonc': '{"shared":true}',
  'tui.json': '{}',
  'package.json': '{}',
  'package-lock.json': '{}',
};

const _tokenSaving = {
  'oh-my-openagent.json': '{"omo":"token-saving"}',
  'oh-my-opencode-slim.json': '{"slim":"token-saving"}',
  'opencode.jsonc': '{"shared":true}',
  'tui.json': '{}',
  'package.json': '{}',
  'package-lock.json': '{}',
};

void _writeZip(Directory dir, String slug, Map<String, String> files) {
  final archive = Archive();
  files.forEach(
    (name, content) =>
        archive.add(ArchiveFile.bytes(name, utf8.encode(content))),
  );
  File(
    '${dir.path}${Platform.pathSeparator}$slug.zip',
  ).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('omo_ws_test_');
    _writeZip(dir, 'balanced', _balanced);
    _writeZip(dir, 'token-saving', _tokenSaving);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('OPENCODE_DIR overrides default opencode directory', () {
    final resolved = defaultOpencodeDirectory(
      environment: const {'OPENCODE_DIR': r'D:\custom\opencode'},
      operatingSystem: 'windows',
      pathSeparator: r'\',
    );
    expect(resolved.path, r'D:\custom\opencode');
  });

  test('defaults to <home>/.config/opencode on Windows', () {
    final resolved = defaultOpencodeDirectory(
      environment: const {'USERPROFILE': r'C:\Users\tester'},
      operatingSystem: 'windows',
      pathSeparator: r'\',
    );
    expect(resolved.path, r'C:\Users\tester\.config\opencode');
  });

  test('listBundles returns 6-file bundles sorted by tier index', () async {
    final ws = LocalWorkspace(directory: dir);
    final items = await ws.listBundles();
    expect(items.map((i) => i.key).toList(), ['token-saving', 'balanced']);
    final balanced = items.firstWhere((i) => i.key == 'balanced');
    expect(balanced.files.length, 6);
    expect(balanced.files, containsAll(_balanced.keys));
    expect(balanced.sha256, isNotNull);
    expect(balanced.tierIndex, 103);
  });

  test('allows uppercase underscore and dot in safe bundle names', () async {
    _writeZip(dir, 'Opus_Mode.v2', _balanced);

    final ws = LocalWorkspace(directory: dir);
    final items = await ws.listBundles();

    expect(items.map((i) => i.key), contains('Opus_Mode.v2'));
    expect(await ws.readBundleB64('Opus_Mode.v2'), isNotEmpty);
  });

  test('rejects path-like bundle names when writing', () async {
    final ws = LocalWorkspace(directory: dir);

    await expectLater(
      ws.writeBundle('../escape', base64Encode(const [])),
      throwsArgumentError,
    );
  });

  test('renameBundle renames the zip file and rejects conflicts', () async {
    final ws = LocalWorkspace(directory: dir);

    await ws.renameBundle('balanced', 'balanced_custom');

    expect(
      File('${dir.path}${Platform.pathSeparator}balanced.zip').existsSync(),
      isFalse,
    );
    expect(
      File(
        '${dir.path}${Platform.pathSeparator}balanced_custom.zip',
      ).existsSync(),
      isTrue,
    );
    await expectLater(
      ws.renameBundle('balanced_custom', 'token-saving'),
      throwsA(isA<Exception>()),
    );
  });

  test('getState detects active tier from base files', () async {
    // 写入与 balanced 一致的 base 文件 -> active = balanced。
    File(
      '${dir.path}${Platform.pathSeparator}oh-my-openagent.json',
    ).writeAsStringSync(_balanced['oh-my-openagent.json']!);
    File(
      '${dir.path}${Platform.pathSeparator}oh-my-opencode-slim.json',
    ).writeAsStringSync(_balanced['oh-my-opencode-slim.json']!);

    final state = await LocalWorkspace(directory: dir).getState();
    expect(state.opencodeDir, dir.path);
    expect(state.tiers.map((t) => t.slug), ['token-saving', 'balanced']);
    expect(state.active['omo'], 'balanced');
    expect(state.active['omo-slim'], 'balanced');
    expect(state.active['shared'], 'balanced');
  });

  test(
    'applyTier extracts bundle members into the working directory',
    () async {
      await LocalWorkspace(directory: dir).applyTier('token-saving');
      final omo = File(
        '${dir.path}${Platform.pathSeparator}oh-my-openagent.json',
      );
      expect(omo.existsSync(), isTrue);
      final omoConfig = jsonDecode(omo.readAsStringSync()) as Map;
      expect(omoConfig['omo'], 'token-saving');
      expect(
        omoConfig['disabled_skills'],
        containsAll(['security-research', 'security-review']),
      );
      // 应用后 active 应为 token-saving。
      final state = await LocalWorkspace(directory: dir).getState();
      expect(state.active['shared'], 'token-saving');
    },
  );
}
