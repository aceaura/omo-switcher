import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omo_switcher_client/main.dart';
import 'package:omo_switcher_client/workspace.dart';

// 工作目录已本机化：测试用临时目录 + 真实 zip 模拟 ~/.config/opencode。
// 云端走 FakeApi，本地仓库走 MemoryStore（避免在 flutter test 里加载原生 sqlite）。

const _balancedFiles = {
  'oh-my-openagent.json': '{"omo":"balanced"}',
  'oh-my-opencode-slim.json': '{"slim":"balanced"}',
  'opencode.jsonc': '{}',
  'tui.json': '{}',
  'package.json': '{}',
  'package-lock.json': '{}',
};

void _writeZip(Directory dir, String slug, Map<String, String> files) {
  final archive = Archive();
  files.forEach(
    (name, content) => archive.add(ArchiveFile.bytes(name, utf8.encode(content))),
  );
  File('${dir.path}${Platform.pathSeparator}$slug.zip')
      .writeAsBytesSync(ZipEncoder().encodeBytes(archive));
}

Directory _makeWorkspace(WidgetTester tester, {bool empty = false}) {
  final dir = Directory.systemTemp.createTempSync('omo_ws_');
  addTearDown(() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 偶发文件占用，测试结束清理失败可忽略。
    }
  });
  if (empty) return dir;
  _writeZip(dir, 'balanced', _balancedFiles);
  // 写入与 balanced 一致的 base 文件 -> 当前生效档位 = balanced。
  File('${dir.path}${Platform.pathSeparator}oh-my-openagent.json')
      .writeAsStringSync(_balancedFiles['oh-my-openagent.json']!);
  File('${dir.path}${Platform.pathSeparator}oh-my-opencode-slim.json')
      .writeAsStringSync(_balancedFiles['oh-my-opencode-slim.json']!);
  return dir;
}

void main() {
  testWidgets('loads tiers from local workspace and applies a tier locally', (
    tester,
  ) async {
    final dir = _makeWorkspace(tester);
    final api = FakeApi();
    final store = MemoryStore({'server_url': 'http://127.0.0.1:7600'});

    await tester.pumpWidget(MyApp(
      api: api,
      workspace: LocalWorkspace(directory: dir),
      store: store,
    ));
    await tester.pumpAndSettle();

    expect(find.text('omo-switcher'), findsOneWidget);
    expect(find.textContaining('工作目录:'), findsWidgets);
    expect(find.text('balanced'), findsWidgets);
    expect(find.text('当前配置文件'), findsOneWidget);

    // 应用档位：本地解包写入工作目录，不再调用服务器 switch。
    await tester.tap(find.text('应用到工作目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认执行'));
    await tester.pumpAndSettle();

    expect(api.switchCalls, isEmpty);
    expect(find.textContaining('已应用'), findsOneWidget);
  });

  testWidgets('renders empty workspace safely', (tester) async {
    final dir = _makeWorkspace(tester, empty: true);
    final api = FakeApi(empty: true);
    final store = MemoryStore({'server_url': 'http://127.0.0.1:7600'});

    await tester.pumpWidget(MyApp(
      api: api,
      workspace: LocalWorkspace(directory: dir),
      store: store,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('常用配置').first);
    await tester.pumpAndSettle();
    expect(find.text('0 项'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('syncs workspace->local, local->cloud, cloud->local', (
    tester,
  ) async {
    final dir = _makeWorkspace(tester);
    final api = FakeApi();
    final store = MemoryStore({'server_url': 'http://127.0.0.1:7600'});

    await tester.pumpWidget(MyApp(
      api: api,
      workspace: LocalWorkspace(directory: dir),
      store: store,
    ));
    await tester.pumpAndSettle();

    // 常用配置 -> 本地仓库（读本机 zip 字节存入 store）。
    await tester.tap(find.text('常用配置').first);
    await tester.pumpAndSettle();
    // 标签：balanced 在「常用」(工作目录)和「云端」(FakeApi) 中，尚未进「本地」。
    expect(find.text('常用'), findsOneWidget);
    expect(find.text('云端'), findsOneWidget);
    expect(find.text('本地'), findsNothing);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步到本地仓库'));
    await tester.pumpAndSettle();
    expect(store.items.containsKey('balanced'), isTrue);
    // 同步后多出「本地」标签。
    expect(find.text('本地'), findsOneWidget);
    expect(store.items['balanced']!.contentB64, isNotNull);

    // 本地仓库 -> 云端仓库（pushConfig）。
    await tester.tap(find.text('本地仓库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步到云端仓库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认执行'));
    await tester.pumpAndSettle();
    expect(api.pushNotes, contains('client all push'));

    // 云端历史 tab 已重命名（不再有「远端历史」）。
    expect(find.text('云端历史'), findsWidgets);
    expect(find.text('远端历史'), findsNothing);
  });
}

class FakeApi implements OmoApi {
  FakeApi({this.empty = false});

  final bool empty;
  final switchCalls = <(String, String)>[];
  final itemFetches = <String>[];
  final pushNotes = <String>[];
  final rollbackCalls = <String>[];

  @override
  Future<Map<String, dynamic>> health(String serverUrl) async => {
    'ok': true,
    'storeMode': 'redis',
  };

  @override
  Future<Map<String, dynamic>> state(String serverUrl) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> switchTier(String serverUrl, String tier) async {
    switchCalls.add(('/api/switch', tier));
    return {'ok': true, 'log': ['switched $tier']};
  }

  @override
  Future<Map<String, dynamic>> restart(
    String serverUrl, {
    String? launchCmd,
  }) async => {'ok': true, 'log': ['restarted']};

  @override
  Future<List<ConfigItem>> configItems(
    String serverUrl, {
    bool fs = false,
  }) async => empty
      ? []
      : [
          const ConfigItem(
            key: 'balanced',
            label: '3. 均衡 · Balanced',
            sha256: 'abcdef1234567890',
            files: ['omo.json', 'slim.json'],
          ),
        ];

  @override
  Future<Map<String, dynamic>> configItem(
    String serverUrl,
    String key, {
    String? snapshot,
    bool fs = false,
  }) async {
    itemFetches.add('/api/config/item/$key');
    return {
      'ok': true,
      'key': key,
      'contentB64': 'zip-b64',
      'sha256': 'abcdef1234567890',
    };
  }

  @override
  Future<Map<String, dynamic>> configDiff(
    String serverUrl,
    List<ConfigItem> localItems,
  ) async => {
    'ok': true,
    'diff': {
      'onlyLocal': [],
      'onlyRemote': [],
      'changed': [],
      'same': [],
    },
  };

  @override
  Future<Map<String, dynamic>> writeWorkspaceItem(
    String serverUrl,
    String key,
    String contentB64,
  ) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> pushConfig(
    String serverUrl,
    List<ConfigItem> items,
    String note,
  ) async {
    pushNotes.add(note);
    return {'ok': true, 'snapshotId': 'snap-2'};
  }

  @override
  Future<Map<String, dynamic>> snapshots(
    String serverUrl, {
    int limit = 50,
  }) async => {'ok': true, 'head': null, 'items': []};

  @override
  Future<Map<String, dynamic>> snapshot(String serverUrl, String id) async => {
    'ok': true,
    'items': [],
  };

  @override
  Future<Map<String, dynamic>> rollbackSnapshot(
    String serverUrl,
    String id,
  ) async {
    rollbackCalls.add('/api/snapshots/$id/rollback');
    return {'ok': true, 'snapshotId': 'snap-rollback'};
  }

  @override
  Future<Map<String, dynamic>> rollbackFile(
    String serverUrl,
    String id,
    String key,
  ) async => {'ok': true, 'snapshotId': 'snap-file'};
}

class MemoryStore implements LocalStore {
  MemoryStore([Map<String, String>? seed]) : settings = {...?seed};

  final Map<String, String> settings;
  final Map<String, ConfigItem> items = {};
  final List<MapEntry<HistoryEntry, List<ConfigItem>>> history = [];

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async =>
      settings[key] = value;

  @override
  Future<List<ConfigItem>> listItems() async => items.values.toList();

  @override
  Future<ConfigItem?> getItem(String key) async => items[key];

  @override
  Future<void> upsertItem(ConfigItem item, String source) async =>
      replaceItems([
        for (final existing in items.values)
          if (existing.key != item.key) existing,
        item,
      ], source);

  @override
  Future<void> replaceItems(List<ConfigItem> nextItems, String source) async {
    items
      ..clear()
      ..addEntries(
        nextItems.map(
          (item) => MapEntry(item.key, item.copyWith(source: source)),
        ),
      );
    history.insert(
      0,
      MapEntry(
        HistoryEntry(
          id: '${history.length + 1}',
          ts: DateTime.utc(2026, 6, 2, 10, history.length),
          keys: nextItems.map((item) => item.key).toList(),
          note: source,
        ),
        nextItems,
      ),
    );
  }

  @override
  Future<List<HistoryEntry>> listSnapshots() async =>
      history.map((entry) => entry.key).toList();

  @override
  Future<List<ConfigItem>> snapshotItems(String id) async {
    for (final entry in history) {
      if (entry.key.id == id) return entry.value;
    }
    return const [];
  }
}
