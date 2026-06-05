// 本地仓库：本机 SQLite 数据库，放在 <home>/.omo-switcher/omo-switcher.db。
// 实现 main.dart 的 LocalStore 抽象接口（方法签名不变，UI 调用处无需改动）。
// 镜像原 FileLocalStore（JSON）的语义：upsert/replace 后追加一条快照，最多保留 50 条。
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'package:omo_switcher_client/main.dart'
    show LocalStore, ConfigItem, HistoryEntry;

class SqliteLocalStore implements LocalStore {
  SqliteLocalStore({String? dbPath}) : _dbPath = dbPath ?? _defaultDbPath();

  final String _dbPath;
  Database? _db;

  String get path => _dbPath;
  String get directoryPath => File(_dbPath).parent.path;

  static String _defaultDbPath() {
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? Directory.current.path;
    final sep = Platform.pathSeparator;
    return '$home$sep.omo-switcher${sep}omo-switcher.db';
  }

  Database get _database {
    final existing = _db;
    if (existing != null) return existing;
    final dir = File(_dbPath).parent;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final db = sqlite3.open(_dbPath);
    db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS items ('
      'key TEXT PRIMARY KEY, label TEXT, sha256 TEXT, content_b64 TEXT, '
      'provider TEXT, tier_slug TEXT, tier_index INTEGER, size INTEGER, '
      'source TEXT, files_json TEXT, updated_at INTEGER)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS snapshots ('
      'id TEXT PRIMARY KEY, ts TEXT, note TEXT, keys_json TEXT, items_json TEXT)',
    );
    _db = db;
    return db;
  }

  @override
  Future<String?> getSetting(String key) async {
    final rs = _database.select('SELECT value FROM settings WHERE key = ?', [
      key,
    ]);
    if (rs.isEmpty) return null;
    return rs.first['value'] as String?;
  }

  @override
  Future<void> setSetting(String key, String value) async {
    _database.execute(
      'INSERT INTO settings(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  @override
  Future<List<ConfigItem>> listItems() async {
    final rs = _database.select('SELECT * FROM items ORDER BY tier_index, key');
    return rs.map(_itemFromRow).toList();
  }

  @override
  Future<ConfigItem?> getItem(String key) async {
    final rs = _database.select('SELECT * FROM items WHERE key = ?', [key]);
    if (rs.isEmpty) return null;
    return _itemFromRow(rs.first);
  }

  @override
  Future<void> upsertItem(ConfigItem item, String source) =>
      upsertItems([item], source);

  @override
  Future<void> upsertItems(List<ConfigItem> items, String source) async {
    if (items.isEmpty) return;
    for (final item in items) {
      _writeItemRow(item.copyWith(source: source));
    }
    // 整批写完只追加一条快照：一次同步=一条历史。
    await _appendSnapshot(await listItems(), source);
  }

  @override
  Future<void> deleteItems(List<String> keys, String source) async {
    final keySet = keys.toSet();
    if (keySet.isEmpty) return;
    final placeholders = List.filled(keySet.length, '?').join(', ');
    _database.execute(
      'DELETE FROM items WHERE key IN ($placeholders)',
      keySet.toList(),
    );
    await _appendSnapshot(await listItems(), source);
  }

  @override
  Future<void> renameItem(String oldKey, String newKey, String source) async {
    final existing = await getItem(oldKey);
    if (existing == null) throw StateError('本地仓库中不存在: $oldKey');
    final target = await getItem(newKey);
    if (target != null) throw StateError('目标档位已存在: $newKey');
    _database.execute('DELETE FROM items WHERE key = ?', [oldKey]);
    _writeItemRow(existing.renamed(newKey).copyWith(source: source));
    await _appendSnapshot(await listItems(), source);
  }

  @override
  Future<void> replaceItems(List<ConfigItem> items, String source) async {
    _database.execute('DELETE FROM items');
    for (final item in items) {
      _writeItemRow(item.copyWith(source: source));
    }
    await _appendSnapshot(
      items.map((i) => i.copyWith(source: source)).toList(),
      source,
    );
  }

  @override
  Future<List<HistoryEntry>> listSnapshots() async {
    final rs = _database.select(
      'SELECT id, ts, note, keys_json FROM snapshots ORDER BY ts DESC',
    );
    return rs
        .map(
          (row) => HistoryEntry.fromJson({
            'id': row['id'],
            'ts': row['ts'],
            'note': row['note'],
            'keys': jsonDecode((row['keys_json'] as String?) ?? '[]'),
          }),
        )
        .toList();
  }

  @override
  Future<List<ConfigItem>> snapshotItems(String id) async {
    final rs = _database.select(
      'SELECT items_json FROM snapshots WHERE id = ?',
      [id],
    );
    if (rs.isEmpty) return const [];
    final list = jsonDecode(rs.first['items_json'] as String) as List<dynamic>;
    return list
        .map((e) => ConfigItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ---- 内部 ----

  ConfigItem _itemFromRow(Row row) => ConfigItem(
    key: row['key'] as String,
    label: row['label'] as String?,
    sha256: row['sha256'] as String?,
    contentB64: row['content_b64'] as String?,
    provider: (row['provider'] as String?) ?? 'bundle',
    tierSlug: row['tier_slug'] as String?,
    tierIndex: (row['tier_index'] as num?)?.toInt(),
    size: (row['size'] as num?)?.toInt(),
    source: row['source'] as String?,
    files: (jsonDecode((row['files_json'] as String?) ?? '[]') as List)
        .map((e) => e.toString())
        .toList(),
  );

  void _writeItemRow(ConfigItem item) {
    _database.execute(
      'INSERT INTO items'
      '(key, label, sha256, content_b64, provider, tier_slug, tier_index, size, source, files_json, updated_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET '
      'label = excluded.label, sha256 = excluded.sha256, content_b64 = excluded.content_b64, '
      'provider = excluded.provider, tier_slug = excluded.tier_slug, tier_index = excluded.tier_index, '
      'size = excluded.size, source = excluded.source, files_json = excluded.files_json, '
      'updated_at = excluded.updated_at',
      [
        item.key,
        item.label,
        item.sha256,
        item.contentB64,
        item.provider,
        item.tierSlug,
        item.tierIndex,
        item.size,
        item.source,
        jsonEncode(item.files),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> _appendSnapshot(List<ConfigItem> items, String source) async {
    final now = DateTime.now().toUtc();
    final id = '${now.microsecondsSinceEpoch}';
    _database.execute(
      'INSERT INTO snapshots(id, ts, note, keys_json, items_json) VALUES(?, ?, ?, ?, ?)',
      [
        id,
        now.toIso8601String(),
        source,
        jsonEncode(items.map((i) => i.key).toList()),
        jsonEncode(items.map((i) => i.toStoreJson()).toList()),
      ],
    );
    // 仅保留最近 50 条快照。
    _database.execute(
      'DELETE FROM snapshots WHERE id NOT IN '
      '(SELECT id FROM snapshots ORDER BY ts DESC LIMIT 50)',
    );
  }
}
