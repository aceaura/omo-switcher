import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

void main() {
  runApp(MyApp(api: HttpOmoApi(), store: FileLocalStore()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.api, required this.store});

  final OmoApi api;
  final LocalStore store;

  @override
  Widget build(BuildContext context) {
    const darkScheme = ColorScheme.dark(
      primary: Color(0xff58a6ff),
      surface: Color(0xff161b22),
      error: Color(0xfff85149),
      onSurface: Color(0xffc9d1d9),
    );
    const lightScheme = ColorScheme.light(
      primary: Color(0xff0969da),
      surface: Color(0xfff6f8fa),
      error: Color(0xffcf222e),
      onSurface: Color(0xff1f2328),
    );

    return MaterialApp(
      title: 'omo-switcher',
      themeMode: ThemeMode.system,
      theme: ThemeData(colorScheme: lightScheme, useMaterial3: true),
      darkTheme: ThemeData(colorScheme: darkScheme, useMaterial3: true),
      home: OmoSwitcherHome(api: api, store: store),
    );
  }
}

abstract class OmoApi {
  Future<Map<String, dynamic>> health(String serverUrl);
  Future<Map<String, dynamic>> state(String serverUrl);
  Future<Map<String, dynamic>> switchTier(String serverUrl, String tier);
  Future<Map<String, dynamic>> restart(String serverUrl);
  Future<List<ConfigItem>> configItems(String serverUrl, {bool fs = false});
  Future<Map<String, dynamic>> configItem(String serverUrl, String key, {String? snapshot, bool fs = false});
  Future<Map<String, dynamic>> configDiff(String serverUrl, List<ConfigItem> localItems);
  Future<Map<String, dynamic>> writeWorkspaceItem(String serverUrl, String key, String contentB64);
  Future<Map<String, dynamic>> pushConfig(String serverUrl, List<ConfigItem> items, String note);
  Future<Map<String, dynamic>> snapshots(String serverUrl, {int limit = 50});
  Future<Map<String, dynamic>> snapshot(String serverUrl, String id);
  Future<Map<String, dynamic>> rollbackSnapshot(String serverUrl, String id);
  Future<Map<String, dynamic>> rollbackFile(String serverUrl, String id, String key);
}

abstract class LocalStore {
  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);
  Future<List<ConfigItem>> listItems();
  Future<ConfigItem?> getItem(String key);
  Future<void> upsertItem(ConfigItem item, String source);
}

class HttpOmoApi implements OmoApi {
  final HttpClient _client = HttpClient();

  @override
  Future<Map<String, dynamic>> health(String serverUrl) => _request('GET', serverUrl, '/api/health');

  @override
  Future<Map<String, dynamic>> state(String serverUrl) => _request('GET', serverUrl, '/api/state');

  @override
  Future<Map<String, dynamic>> switchTier(String serverUrl, String tier) =>
      _request('POST', serverUrl, '/api/switch', body: {'tier': tier});

  @override
  Future<Map<String, dynamic>> restart(String serverUrl) => _request('POST', serverUrl, '/api/restart', body: <String, dynamic>{});

  @override
  Future<List<ConfigItem>> configItems(String serverUrl, {bool fs = false}) async {
    final result = await _request('GET', serverUrl, fs ? '/api/config/items?fs=1' : '/api/config/items');
    return _itemsFrom(result['items']);
  }

  @override
  Future<Map<String, dynamic>> configItem(String serverUrl, String key, {String? snapshot, bool fs = false}) {
    final query = fs ? '?fs=1' : snapshot == null ? '' : '?snapshot=${Uri.encodeQueryComponent(snapshot)}';
    return _request('GET', serverUrl, '/api/config/item/${Uri.encodeComponent(key)}$query');
  }

  @override
  Future<Map<String, dynamic>> configDiff(String serverUrl, List<ConfigItem> localItems) =>
      _request('POST', serverUrl, '/api/config/diff', body: {'localItems': localItems.map((item) => item.toServerJson()).toList()});

  @override
  Future<Map<String, dynamic>> writeWorkspaceItem(String serverUrl, String key, String contentB64) =>
      _request('POST', serverUrl, '/api/config/item/${Uri.encodeComponent(key)}/fs', body: {'contentB64': contentB64});

  @override
  Future<Map<String, dynamic>> pushConfig(String serverUrl, List<ConfigItem> items, String note) => _request(
        'POST',
        serverUrl,
        '/api/config/push',
        body: {'items': items.map((item) => item.toPushJson()).toList(), 'note': note},
      );

  @override
  Future<Map<String, dynamic>> snapshots(String serverUrl, {int limit = 50}) => _request('GET', serverUrl, '/api/snapshots?limit=$limit');

  @override
  Future<Map<String, dynamic>> snapshot(String serverUrl, String id) => _request('GET', serverUrl, '/api/snapshots/${Uri.encodeComponent(id)}');

  @override
  Future<Map<String, dynamic>> rollbackSnapshot(String serverUrl, String id) =>
      _request('POST', serverUrl, '/api/snapshots/${Uri.encodeComponent(id)}/rollback', body: <String, dynamic>{});

  @override
  Future<Map<String, dynamic>> rollbackFile(String serverUrl, String id, String key) => _request(
        'POST',
        serverUrl,
        '/api/snapshots/${Uri.encodeComponent(id)}/rollback-file',
        body: {'key': key},
      );

  Future<Map<String, dynamic>> _request(String method, String serverUrl, String path, {Map<String, dynamic>? body}) async {
    final base = _normalizeServerUrl(serverUrl);
    final request = await _client.openUrl(method, Uri.parse('$base$path'));
    request.headers.contentType = ContentType.json;
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
    if (response.statusCode >= 400 && decoded['ok'] == null) decoded['ok'] = false;
    return decoded;
  }
}

class FileLocalStore implements LocalStore {
  FileLocalStore({Directory? directory}) : _directory = directory ?? _defaultDirectory();

  final Directory _directory;

  File get _settingsFile => File('${_directory.path}/settings.json');
  File get _itemsFile => File('${_directory.path}/config_items.json');

  @override
  Future<String?> getSetting(String key) async {
    final settings = await _readMap(_settingsFile);
    return settings[key] as String?;
  }

  @override
  Future<void> setSetting(String key, String value) async {
    final settings = await _readMap(_settingsFile);
    settings[key] = value;
    await _writeJson(_settingsFile, settings);
  }

  @override
  Future<List<ConfigItem>> listItems() async => _itemsFrom((await _readMap(_itemsFile))['items']);

  @override
  Future<ConfigItem?> getItem(String key) async {
    for (final item in await listItems()) {
      if (item.key == key) return item;
    }
    return null;
  }

  @override
  Future<void> upsertItem(ConfigItem item, String source) async {
    final items = await listItems();
    final next = [for (final existing in items) if (existing.key != item.key) existing, item.copyWith(source: source)];
    await _writeJson(_itemsFile, {'items': next.map((item) => item.toStoreJson()).toList()});
  }

  Future<Map<String, dynamic>> _readMap(File file) async {
    if (!await file.exists()) return <String, dynamic>{};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<void> _writeJson(File file, Map<String, dynamic> value) async {
    await _directory.create(recursive: true);
    await file.writeAsString(jsonEncode(value));
  }

  static Directory _defaultDirectory() {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return Directory('$home/Library/Application Support/omo-switcher-client');
  }
}

class OmoSwitcherHome extends StatefulWidget {
  const OmoSwitcherHome({super.key, required this.api, required this.store});

  final OmoApi api;
  final LocalStore store;

  @override
  State<OmoSwitcherHome> createState() => _OmoSwitcherHomeState();
}

class _OmoSwitcherHomeState extends State<OmoSwitcherHome> {
  String serverUrl = 'http://127.0.0.1:7600';
  String connectionText = '未连接';
  String storeMode = 'store: ?';
  String workspacePath = 'opencodeDir: ?';
  String selectedTier = '';
  String selectedSnapshot = '';
  String switchLog = '';
  String restartLog = '';
  String localLog = '';
  int tabIndex = 0;
  List<Tier> tiers = [];
  List<ConfigItem> workspaceItems = [];
  List<ConfigItem> localItems = [];
  List<ConfigItem> remoteItems = [];
  List<SnapshotInfo> snapshotItems = [];
  List<ConfigItem> snapshotDetailItems = [];
  DiffResult diff = const DiffResult();
  DiffResult workspaceDiff = const DiffResult();
  final selectedWorkspace = <String>{};
  final selectedLocal = <String>{};
  final selectedRemote = <String>{};
  final serverUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    serverUrl = await widget.store.getSetting('server_url') ?? serverUrl;
    serverUrlController.text = serverUrl;
    if (mounted) setState(() {});
    await _refreshAll();
  }

  Future<void> _refreshAll() async {
    await Future.wait([_refreshState(), _reloadSync(), _reloadSnapshots()]);
  }

  Future<void> _testConnection() async {
    final nextUrl = serverUrlController.text.trim();
    try {
      final result = await widget.api.health(nextUrl);
      if (result['ok'] == false) throw StateError(_messageFor(result));
      await widget.store.setSetting('server_url', nextUrl);
      serverUrl = nextUrl;
      connectionText = '已连接';
      storeMode = 'store: ${result['storeMode'] ?? '?'}';
      if (mounted) setState(() {});
      await _refreshAll();
    } catch (error) {
      setState(() {
        connectionText = '未连接';
        storeMode = 'store: ${_errorMessage(error)}';
      });
    }
  }

  Future<void> _refreshState() async {
    try {
      final result = await widget.api.state(serverUrl);
      if (result['ok'] == false) return;
      final nextTiers = (result['tiers'] as List<dynamic>? ?? [])
          .map((item) => Tier.fromJson(item as Map<String, dynamic>))
          .where((tier) => tier.shared)
          .toList();
      setState(() {
        tiers = nextTiers;
        selectedTier = result['active'] is Map<String, dynamic> ? ((result['active'] as Map<String, dynamic>)['shared'] as String? ?? selectedTier) : selectedTier;
        if (selectedTier.isEmpty && tiers.isNotEmpty) selectedTier = tiers.first.slug;
        workspacePath = 'opencodeDir: ${result['opencodeDir'] ?? '?'}';
      });
    } catch (_) {}
  }

  Future<void> _reloadSync() async {
    try {
      final workspace = await widget.api.configItems(serverUrl, fs: true);
      final remote = await widget.api.configItems(serverUrl);
      final local = await widget.store.listItems();
      final diffResponse = await widget.api.configDiff(serverUrl, local);
      setState(() {
        workspaceItems = workspace;
        remoteItems = remote;
        localItems = local;
        diff = DiffResult.fromJson(diffResponse['diff'] as Map<String, dynamic>? ?? const {});
        workspaceDiff = DiffResult.compare(local, workspace);
      });
    } catch (_) {
      setState(() {
        workspaceItems = [];
        remoteItems = [];
        localItems = [];
      });
    }
  }

  Future<void> _reloadSnapshots() async {
    try {
      final result = await widget.api.snapshots(serverUrl);
      setState(() => snapshotItems = _snapshotsFrom(result['items']));
    } catch (_) {
      setState(() => snapshotItems = []);
    }
  }

  Future<void> _applyTier() async {
    if (selectedTier.isEmpty) return;
    final confirmed = await _confirm('应用档位', '将把 omo 与 omo-slim 同时切换到「$selectedTier」。');
    if (!confirmed) return;
    final result = await widget.api.switchTier(serverUrl, selectedTier);
    setState(() => switchLog = result['ok'] == false ? '切换失败: ${_messageFor(result)}' : _logText(result));
    await _refreshState();
  }

  Future<void> _restart() async {
    final result = await widget.api.restart(serverUrl);
    setState(() => restartLog = result['ok'] == false ? '重启失败: ${_messageFor(result)}' : _logText(result));
  }

  Future<void> _downloadWorkspaceToLocal() async {
    final keys = _defaultKeys(selectedWorkspace, workspaceItems);
    if (keys.isEmpty) return _notice('工作目录没有可下载的配置项');
    for (final key in keys) {
      final result = await widget.api.configItem(serverUrl, key, fs: true);
      await widget.store.upsertItem(ConfigItem.fromJson(result), 'local-scan');
    }
    setState(() => localLog = '已下载 ${keys.length} 项到 SQLite');
    await _reloadSync();
  }

  Future<void> _uploadLocalToWorkspace() async {
    final keys = _defaultKeys(selectedLocal, localItems);
    if (keys.isEmpty) return _notice('SQLite 没有可上传的配置项');
    final confirmed = await _confirm('上传到工作目录', '将把 SQLite 中 ${keys.length} 个档位包写回工作目录。\n${keys.join('\n')}');
    if (!confirmed) return;
    var exported = 0;
    final failed = <String>[];
    for (final key in keys) {
      final item = await widget.store.getItem(key);
      if (item == null || item.contentB64 == null) {
        failed.add('$key: 本地 SQLite 中不存在');
        continue;
      }
      final result = await widget.api.writeWorkspaceItem(serverUrl, key, item.contentB64!);
      if (result['ok'] == false) failed.add('$key: ${_messageFor(result)}');
      if (result['ok'] != false) exported++;
    }
    setState(() => localLog = '已上传 $exported 项到工作目录${failed.isEmpty ? '' : '\n失败: ${failed.join('\n')}'}');
    await _refreshAll();
  }

  Future<void> _pullRedisToLocal() async {
    final keys = _defaultKeys(selectedRemote, remoteItems);
    if (keys.isEmpty) return _notice('Redis 没有可下载的配置项');
    for (final key in keys) {
      final result = await widget.api.configItem(serverUrl, key, snapshot: selectedSnapshot.isEmpty ? null : selectedSnapshot);
      await widget.store.upsertItem(ConfigItem.fromJson(result), 'pulled');
    }
    setState(() => localLog = '已从 Redis 下载 ${keys.length} 项到 SQLite');
    await _reloadSync();
  }

  Future<void> _pushLocalToRedis() async {
    final keys = _defaultKeys(selectedLocal, localItems);
    if (keys.isEmpty) return _notice('SQLite 没有可上传的配置项');
    final confirmed = await _confirm('上传到 Redis', '将在 Redis 生成新快照，包含 SQLite 中 ${keys.length} 个档位包。\n${keys.join('\n')}');
    if (!confirmed) return;
    final items = <ConfigItem>[];
    for (final key in keys) {
      final item = await widget.store.getItem(key);
      if (item != null) items.add(item);
    }
    final scope = keys.length == localItems.length ? 'all' : 'selected';
    final result = await widget.api.pushConfig(serverUrl, items, 'client $scope push');
    setState(() => localLog = result['ok'] == false ? '上传失败: ${_messageFor(result)}' : '已上传到 Redis: ${result['snapshotId']}');
    await _refreshAll();
  }

  Future<void> _viewSnapshot(String id) async {
    final result = await widget.api.snapshot(serverUrl, id);
    setState(() => snapshotDetailItems = _itemsFrom(result['items']));
  }

  Future<void> _rollbackAll(String id) async {
    if (!await _confirm('整体回滚', '整体回滚到快照 $id？将生成一个新快照并设为最新。')) return;
    final result = await widget.api.rollbackSnapshot(serverUrl, id);
    _notice(result['ok'] == false ? '回滚失败' : '回滚完成: ${result['snapshotId']}');
    await _refreshAll();
  }

  Future<void> _rollbackFile(String id, String key) async {
    if (!await _confirm('单文件回滚', '从快照 $id 回滚单文件 $key？')) return;
    final result = await widget.api.rollbackFile(serverUrl, id, key);
    _notice(result['ok'] == false ? '回滚失败' : '单文件回滚完成: ${result['snapshotId']}');
    await _refreshAll();
  }

  Future<bool> _confirm(String title, String body) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认执行')),
            ],
          ),
        ) ??
        false;
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _WorkspacePage(
        path: workspacePath,
        tiers: tiers,
        selectedTier: selectedTier,
        items: workspaceItems,
        diff: workspaceDiff,
        selected: selectedWorkspace,
        switchLog: switchLog,
        restartLog: restartLog,
        onTierChanged: (value) => setState(() => selectedTier = value),
        onSelectedChanged: (key, checked) => setState(() => checked ? selectedWorkspace.add(key) : selectedWorkspace.remove(key)),
        onApplyTier: _applyTier,
        onDownload: _downloadWorkspaceToLocal,
        onRestart: _restart,
      ),
      _LocalPage(
        items: localItems,
        diff: diff,
        selected: selectedLocal,
        log: localLog,
        onSelectedChanged: (key, checked) => setState(() => checked ? selectedLocal.add(key) : selectedLocal.remove(key)),
        onUploadWorkspace: _uploadLocalToWorkspace,
        onPushRedis: _pushLocalToRedis,
      ),
      _RemotePage(
        serverUrlController: serverUrlController,
        items: remoteItems,
        diff: diff,
        selected: selectedRemote,
        snapshots: snapshotItems,
        selectedSnapshot: selectedSnapshot,
        onSelectedChanged: (key, checked) => setState(() => checked ? selectedRemote.add(key) : selectedRemote.remove(key)),
        onSnapshotChanged: (value) => setState(() => selectedSnapshot = value),
        onTestConnection: _testConnection,
        onPull: _pullRedisToLocal,
        onReload: _refreshAll,
      ),
      _HistoryPage(
        snapshots: snapshotItems,
        detailItems: snapshotDetailItems,
        onReload: _reloadSnapshots,
        onView: _viewSnapshot,
        onRollbackAll: _rollbackAll,
        onRollbackFile: _rollbackFile,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('omo-switcher'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Chip(label: Text(connectionText)),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: Text(storeMode)),
          ),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: tabIndex,
            onDestinationSelected: (index) => setState(() => tabIndex = index),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.folder_copy_outlined), label: Text('工作区')),
              NavigationRailDestination(icon: Icon(Icons.storage_outlined), label: Text('SQLite')),
              NavigationRailDestination(icon: Icon(Icons.cloud_outlined), label: Text('Redis')),
              NavigationRailDestination(icon: Icon(Icons.history_outlined), label: Text('历史')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pages[tabIndex]),
        ],
      ),
    );
  }
}

class _WorkspacePage extends StatelessWidget {
  const _WorkspacePage({
    required this.path,
    required this.tiers,
    required this.selectedTier,
    required this.items,
    required this.diff,
    required this.selected,
    required this.switchLog,
    required this.restartLog,
    required this.onTierChanged,
    required this.onSelectedChanged,
    required this.onApplyTier,
    required this.onDownload,
    required this.onRestart,
  });

  final String path;
  final List<Tier> tiers;
  final String selectedTier;
  final List<ConfigItem> items;
  final DiffResult diff;
  final Set<String> selected;
  final String switchLog;
  final String restartLog;
  final ValueChanged<String> onTierChanged;
  final void Function(String key, bool checked) onSelectedChanged;
  final VoidCallback onApplyTier;
  final VoidCallback onDownload;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '本地工作区',
      count: '${items.length} 项',
      children: [
        Text(path),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('当前档位'),
            DropdownButton<String>(
              value: selectedTier.isEmpty && tiers.isNotEmpty ? tiers.first.slug : selectedTier.isEmpty ? null : selectedTier,
              items: tiers.map((tier) => DropdownMenuItem(value: tier.slug, child: Text('${tier.index}. ${tier.label}'))).toList(),
              onChanged: (value) {
                if (value != null) onTierChanged(value);
              },
            ),
            FilledButton(onPressed: onApplyTier, child: const Text('应用到工作目录')),
            OutlinedButton(onPressed: onDownload, child: const Text('下载选中到 SQLite')),
            FilledButton.tonalIcon(onPressed: onRestart, icon: const Icon(Icons.restart_alt), label: const Text('重启 Desktop')),
          ],
        ),
        _ConfigList(items: items, diff: diff, selected: selected, onSelectedChanged: onSelectedChanged),
        _LogBox(text: switchLog),
        _LogBox(text: restartLog),
      ],
    );
  }
}

class _LocalPage extends StatelessWidget {
  const _LocalPage({required this.items, required this.diff, required this.selected, required this.log, required this.onSelectedChanged, required this.onUploadWorkspace, required this.onPushRedis});

  final List<ConfigItem> items;
  final DiffResult diff;
  final Set<String> selected;
  final String log;
  final void Function(String key, bool checked) onSelectedChanged;
  final VoidCallback onUploadWorkspace;
  final VoidCallback onPushRedis;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '本地 SQLite zip 仓库',
      count: '${items.length} 项',
      children: [
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: onUploadWorkspace, child: const Text('上传选中到工作目录')),
          OutlinedButton(onPressed: onPushRedis, child: const Text('上传选中到 Redis')),
        ]),
        _ConfigList(items: items, diff: diff, selected: selected, onSelectedChanged: onSelectedChanged),
        _LogBox(text: log),
      ],
    );
  }
}

class _RemotePage extends StatelessWidget {
  const _RemotePage({
    required this.serverUrlController,
    required this.items,
    required this.diff,
    required this.selected,
    required this.snapshots,
    required this.selectedSnapshot,
    required this.onSelectedChanged,
    required this.onSnapshotChanged,
    required this.onTestConnection,
    required this.onPull,
    required this.onReload,
  });

  final TextEditingController serverUrlController;
  final List<ConfigItem> items;
  final DiffResult diff;
  final Set<String> selected;
  final List<SnapshotInfo> snapshots;
  final String selectedSnapshot;
  final void Function(String key, bool checked) onSelectedChanged;
  final ValueChanged<String> onSnapshotChanged;
  final VoidCallback onTestConnection;
  final VoidCallback onPull;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '远端服务器 / Redis zip 仓库',
      count: '${items.length} 项',
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(width: 320, child: TextField(controller: serverUrlController, decoration: const InputDecoration(labelText: '同步地址'))),
            FilledButton(onPressed: onTestConnection, child: const Text('连接')),
            DropdownButton<String>(
              value: selectedSnapshot,
              items: [
                const DropdownMenuItem(value: '', child: Text('最新(head)')),
                ...snapshots.map((snap) => DropdownMenuItem(value: snap.id, child: Text('${snap.timeText} · ${snap.note.isEmpty ? snap.id : snap.note}'))),
              ],
              onChanged: (value) => onSnapshotChanged(value ?? ''),
            ),
            OutlinedButton(onPressed: onPull, child: const Text('下载选中到 SQLite')),
            OutlinedButton(onPressed: onReload, child: const Text('刷新三层')),
          ],
        ),
        const Text('该地址属于本机私有设置，不参与同步、不会被覆盖。'),
        Text('SQLite↔Redis：仅 SQLite ${diff.onlyLocal.length} · 仅 Redis ${diff.onlyRemote.length} · 有差异 ${diff.changed.length} · 相同 ${diff.same.length}'),
        _ConfigList(items: items, diff: diff, selected: selected, onSelectedChanged: onSelectedChanged),
      ],
    );
  }
}

class _HistoryPage extends StatelessWidget {
  const _HistoryPage({required this.snapshots, required this.detailItems, required this.onReload, required this.onView, required this.onRollbackAll, required this.onRollbackFile});

  final List<SnapshotInfo> snapshots;
  final List<ConfigItem> detailItems;
  final VoidCallback onReload;
  final ValueChanged<String> onView;
  final ValueChanged<String> onRollbackAll;
  final void Function(String id, String key) onRollbackFile;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '远端历史版本',
      count: '${snapshots.length} 项',
      children: [
        Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: onReload, child: const Text('刷新历史'))),
        for (final snap in snapshots)
          Card(
            child: ListTile(
              title: Text(snap.id),
              subtitle: Text('${snap.timeText} · ${snap.note} · ${snap.keys.length} 文件'),
              trailing: Wrap(spacing: 8, children: [
                OutlinedButton(onPressed: () => onView(snap.id), child: const Text('查看')),
                FilledButton.tonal(onPressed: () => onRollbackAll(snap.id), child: const Text('整体回滚')),
              ]),
            ),
          ),
        if (detailItems.isNotEmpty) const Divider(),
        for (final item in detailItems)
          ListTile(
            title: Text(item.key),
            subtitle: Text(shortSha(item.sha256)),
            trailing: FilledButton.tonal(onPressed: snapshots.isEmpty ? null : () => onRollbackFile(snapshots.first.id, item.key), child: const Text('单文件回滚')),
          ),
      ],
    );
  }
}

class _PageShell extends StatelessWidget {
  const _PageShell({required this.title, required this.count, required this.children});

  final String title;
  final String count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const Spacer(),
            Chip(label: Text(count)),
          ],
        ),
        const SizedBox(height: 12),
        ...children.expand((child) => [child, const SizedBox(height: 12)]),
      ],
    );
  }
}

class _ConfigList extends StatelessWidget {
  const _ConfigList({required this.items, required this.diff, required this.selected, required this.onSelectedChanged});

  final List<ConfigItem> items;
  final DiffResult diff;
  final Set<String> selected;
  final void Function(String key, bool checked) onSelectedChanged;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const Text('0 项');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final item in items)
            CheckboxListTile(
              value: selected.contains(item.key),
              onChanged: (checked) => onSelectedChanged(item.key, checked ?? false),
              title: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Tooltip(message: '${item.label ?? item.key}\n包含 ${item.files.length} 个文件:\n${item.files.join('\n')}', child: Text(item.key, style: const TextStyle(fontWeight: FontWeight.w700))),
                  if (item.files.isNotEmpty) Text('(${item.files.length}个文件)'),
                  _DiffTag(label: diff.labelFor(item.key)),
                ],
              ),
              subtitle: Text(shortSha(item.sha256)),
            ),
        ],
      ),
    );
  }
}

class _DiffTag extends StatelessWidget {
  const _DiffTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Chip(label: Text(label), visualDensity: VisualDensity.compact);
  }
}

class _LogBox extends StatelessWidget {
  const _LogBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)),
      child: SelectableText(text),
    );
  }
}

class Tier {
  const Tier({required this.slug, required this.label, required this.index, required this.shared});

  final String slug;
  final String label;
  final int index;
  final bool shared;

  factory Tier.fromJson(Map<String, dynamic> json) => Tier(
        slug: json['slug'] as String? ?? '',
        label: json['label'] as String? ?? json['slug'] as String? ?? '',
        index: (json['index'] as num?)?.toInt() ?? 0,
        shared: json['shared'] == true,
      );
}

class ConfigItem {
  const ConfigItem({required this.key, this.label, this.sha256, this.contentB64, this.provider = 'bundle', this.tierSlug, this.tierIndex, this.size, this.source, this.files = const []});

  final String key;
  final String? label;
  final String? sha256;
  final String? contentB64;
  final String provider;
  final String? tierSlug;
  final int? tierIndex;
  final int? size;
  final String? source;
  final List<String> files;

  ConfigItem copyWith({String? source}) => ConfigItem(
        key: key,
        label: label,
        sha256: sha256,
        contentB64: contentB64,
        provider: provider,
        tierSlug: tierSlug,
        tierIndex: tierIndex,
        size: size,
        source: source ?? this.source,
        files: files,
      );

  factory ConfigItem.fromJson(Map<String, dynamic> json) => ConfigItem(
        key: json['key'] as String? ?? '',
        label: json['label'] as String?,
        sha256: json['sha256'] as String?,
        contentB64: json['contentB64'] as String? ?? json['content_b64'] as String?,
        provider: json['provider'] as String? ?? 'bundle',
        tierSlug: json['tierSlug'] as String? ?? json['tier_slug'] as String?,
        tierIndex: (json['tierIndex'] as num? ?? json['tier_index'] as num?)?.toInt(),
        size: (json['size'] as num?)?.toInt(),
        source: json['source'] as String?,
        files: (json['files'] as List<dynamic>? ?? const []).map((file) => file.toString()).toList(),
      );

  Map<String, dynamic> toServerJson() => {'key': key, 'sha256': sha256, 'size': size};
  Map<String, dynamic> toPushJson() => {'key': key, 'contentB64': contentB64, 'sha256': sha256, 'size': size};
  Map<String, dynamic> toStoreJson() => {
        'key': key,
        'label': label,
        'sha256': sha256,
        'contentB64': contentB64,
        'provider': provider,
        'tierSlug': tierSlug,
        'tierIndex': tierIndex,
        'size': size,
        'source': source,
        'files': files,
      };
}

class SnapshotInfo {
  const SnapshotInfo({required this.id, required this.timeText, required this.note, required this.keys});

  final String id;
  final String timeText;
  final String note;
  final List<String> keys;

  factory SnapshotInfo.fromJson(Map<String, dynamic> json) => SnapshotInfo(
        id: json['id'] as String? ?? '',
        timeText: json['ts'] == null ? '' : DateTime.tryParse(json['ts'].toString())?.toLocal().toString() ?? json['ts'].toString(),
        note: json['note'] as String? ?? '',
        keys: (json['keys'] as List<dynamic>? ?? const []).map((key) => key.toString()).toList(),
      );
}

class DiffResult {
  const DiffResult({this.onlyLocal = const [], this.onlyRemote = const [], this.changed = const [], this.same = const []});

  final List<String> onlyLocal;
  final List<String> onlyRemote;
  final List<String> changed;
  final List<String> same;

  factory DiffResult.fromJson(Map<String, dynamic> json) => DiffResult(
        onlyLocal: _strings(json['onlyLocal']),
        onlyRemote: _strings(json['onlyRemote']),
        changed: _strings(json['changed']),
        same: _strings(json['same']),
      );

  factory DiffResult.compare(List<ConfigItem> leftItems, List<ConfigItem> rightItems) {
    final left = {for (final item in leftItems) item.key: item.sha256};
    final right = {for (final item in rightItems) item.key: item.sha256};
    final onlyLocal = <String>[];
    final onlyRemote = <String>[];
    final changed = <String>[];
    final same = <String>[];
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key)) {
        onlyLocal.add(entry.key);
      } else if (right[entry.key] != entry.value) {
        changed.add(entry.key);
      } else {
        same.add(entry.key);
      }
    }
    for (final key in right.keys) {
      if (!left.containsKey(key)) onlyRemote.add(key);
    }
    return DiffResult(onlyLocal: onlyLocal, onlyRemote: onlyRemote, changed: changed, same: same);
  }

  String labelFor(String key) {
    if (onlyLocal.contains(key)) return '仅 SQLite';
    if (onlyRemote.contains(key)) return '仅目标';
    if (changed.contains(key)) return '有差异';
    return '';
  }
}

List<ConfigItem> _itemsFrom(Object? items) => (items as List<dynamic>? ?? const []).map((item) => ConfigItem.fromJson(item as Map<String, dynamic>)).toList();
List<SnapshotInfo> _snapshotsFrom(Object? items) => (items as List<dynamic>? ?? const []).map((item) => SnapshotInfo.fromJson(item as Map<String, dynamic>)).toList();
List<String> _strings(Object? value) => (value as List<dynamic>? ?? const []).map((item) => item.toString()).toList();
List<String> _defaultKeys(Set<String> selected, List<ConfigItem> items) => selected.isNotEmpty ? selected.toList() : items.map((item) => item.key).toList();
String shortSha(String? value) => value == null || value.isEmpty ? '—' : value.substring(0, value.length < 8 ? value.length : 8);
String _normalizeServerUrl(String value) => (value.trim().isEmpty ? 'http://127.0.0.1:7600' : value.trim()).replaceFirst(RegExp(r'/+$'), '');
String _messageFor(Map<String, dynamic> result) => result['error'] is Map<String, dynamic> ? ((result['error'] as Map<String, dynamic>)['message']?.toString() ?? jsonEncode(result)) : jsonEncode(result);
String _logText(Map<String, dynamic> result) => result['log'] is List<dynamic> ? (result['log'] as List<dynamic>).join('\n') : jsonEncode(result);
String _errorMessage(Object error) => error is Error ? error.toString() : error.toString();
