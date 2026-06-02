import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omo_switcher_client/main.dart';

void main() {
  testWidgets('connects, loads state, and applies selected tier', (tester) async {
    final api = FakeApi();
    final store = MemoryStore({'server_url': 'http://old.example'});

    await tester.pumpWidget(MyApp(api: api, store: store));
    await tester.pumpAndSettle();

    expect(find.text('omo-switcher'), findsOneWidget);
    expect(find.text('opencodeDir: /tmp/opencode'), findsOneWidget);
    expect(find.text('3. 均衡 · Balanced'), findsOneWidget);

    await tester.tap(find.text('应用到工作目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认执行'));
    await tester.pumpAndSettle();

    expect(api.switchCalls, [('/api/switch', 'balanced')]);
    expect(find.textContaining('switched balanced'), findsOneWidget);
  });

  testWidgets('renders empty storage zones safely', (tester) async {
    final api = FakeApi(empty: true);
    final store = MemoryStore({'server_url': 'http://127.0.0.1:7600'});

    await tester.pumpWidget(MyApp(api: api, store: store));
    await tester.pumpAndSettle();

    expect(find.text('本地工作区'), findsOneWidget);
    expect(find.text('0 项'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('performs selected sync and rollback actions', (tester) async {
    final api = FakeApi();
    final store = MemoryStore({'server_url': 'http://127.0.0.1:7600'});
    await store.upsertItem(const ConfigItem(key: 'balanced', contentB64: 'zip-b64', sha256: 'abcdef1234567890'), 'seed');

    await tester.pumpWidget(MyApp(api: api, store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载选中到 SQLite'));
    await tester.pumpAndSettle();
    expect(api.itemFetches, contains('/api/config/item/balanced?fs=1'));

    await tester.tap(find.text('SQLite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上传选中到 Redis'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认执行'));
    await tester.pumpAndSettle();
    expect(api.pushNotes, ['client all push']);

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('整体回滚'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认执行'));
    await tester.pumpAndSettle();
    expect(api.rollbackCalls, ['/api/snapshots/snap-1/rollback']);
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
  Future<Map<String, dynamic>> health(String serverUrl) async => {'ok': true, 'storeMode': 'redis'};

  @override
  Future<Map<String, dynamic>> state(String serverUrl) async => {
        'ok': true,
        'opencodeDir': '/tmp/opencode',
        'tiers': empty
            ? []
            : [
                {'slug': 'balanced', 'label': '均衡 · Balanced', 'index': 3, 'shared': true},
              ],
        'active': {'shared': empty ? '' : 'balanced'},
      };

  @override
  Future<Map<String, dynamic>> switchTier(String serverUrl, String tier) async {
    switchCalls.add(('/api/switch', tier));
    return {'ok': true, 'log': ['switched $tier']};
  }

  @override
  Future<Map<String, dynamic>> restart(String serverUrl) async => {'ok': true, 'log': ['restarted']};

  @override
  Future<List<ConfigItem>> configItems(String serverUrl, {bool fs = false}) async => empty
      ? []
      : [
          const ConfigItem(key: 'balanced', label: '3. 均衡 · Balanced', sha256: 'abcdef1234567890', files: ['omo.json', 'slim.json']),
        ];

  @override
  Future<Map<String, dynamic>> configItem(String serverUrl, String key, {String? snapshot, bool fs = false}) async {
    itemFetches.add('/api/config/item/$key${fs ? '?fs=1' : snapshot == null ? '' : '?snapshot=$snapshot'}');
    return {'ok': true, 'key': key, 'contentB64': 'zip-b64', 'sha256': 'abcdef1234567890'};
  }

  @override
  Future<Map<String, dynamic>> configDiff(String serverUrl, List<ConfigItem> localItems) async => {
        'ok': true,
        'diff': {'onlyLocal': [], 'onlyRemote': empty ? [] : ['balanced'], 'changed': [], 'same': []},
      };

  @override
  Future<Map<String, dynamic>> writeWorkspaceItem(String serverUrl, String key, String contentB64) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> pushConfig(String serverUrl, List<ConfigItem> items, String note) async {
    pushNotes.add(note);
    return {'ok': true, 'snapshotId': 'snap-2'};
  }

  @override
  Future<Map<String, dynamic>> snapshots(String serverUrl, {int limit = 50}) async => empty
      ? {'ok': true, 'items': []}
      : {
          'ok': true,
          'head': 'snap-1',
          'items': [
            {'id': 'snap-1', 'ts': '2026-06-02T10:00:00.000Z', 'note': 'seed', 'keys': ['balanced']},
          ],
        };

  @override
  Future<Map<String, dynamic>> snapshot(String serverUrl, String id) async => {
        'ok': true,
        'items': [
          {'key': 'balanced', 'sha256': 'abcdef1234567890'},
        ],
      };

  @override
  Future<Map<String, dynamic>> rollbackSnapshot(String serverUrl, String id) async {
    rollbackCalls.add('/api/snapshots/$id/rollback');
    return {'ok': true, 'snapshotId': 'snap-rollback'};
  }

  @override
  Future<Map<String, dynamic>> rollbackFile(String serverUrl, String id, String key) async => {'ok': true, 'snapshotId': 'snap-file'};
}

class MemoryStore implements LocalStore {
  MemoryStore([Map<String, String>? seed]) : settings = {...?seed};

  final Map<String, String> settings;
  final Map<String, ConfigItem> items = {};

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async => settings[key] = value;

  @override
  Future<List<ConfigItem>> listItems() async => items.values.toList();

  @override
  Future<ConfigItem?> getItem(String key) async => items[key];

  @override
  Future<void> upsertItem(ConfigItem item, String source) async => items[item.key] = item.copyWith(source: source);
}
