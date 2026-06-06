import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:omo_switcher_client/local_store.dart';
import 'package:omo_switcher_client/workspace.dart';

typedef DesktopProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> args);
typedef DesktopProcessStarter =
    Future<void> Function(
      String executable,
      List<String> args, {
      required bool runInShell,
    });

void main() {
  runApp(
    MyApp(
      api: HttpOmoApi(),
      workspace: LocalWorkspace(),
      store: SqliteLocalStore(),
    ),
  );
}

class DesktopRestartResult {
  const DesktopRestartResult({required this.ok, required this.log});

  final bool ok;
  final List<String> log;
}

Future<DesktopRestartResult> restartLocalDesktop({
  String? operatingSystem,
  Map<String, String>? environment,
  bool Function(String path)? exists,
  DesktopProcessRunner? runProcess,
  DesktopProcessStarter? startProcess,
}) async {
  final os = operatingSystem ?? Platform.operatingSystem;
  final env = environment ?? Platform.environment;
  final fileExists = exists ?? (path) => File(path).existsSync();
  final run =
      runProcess ??
      (executable, args) => Process.run(executable, args, runInShell: false);
  final start =
      startProcess ??
      (executable, args, {required runInShell}) async {
        await Process.start(
          executable,
          args,
          mode: ProcessStartMode.detached,
          runInShell: runInShell,
        );
      };
  final log = <String>[];

  if (os == 'windows') {
    final kill = await run('taskkill', const [
      '/IM',
      'OpenCode.exe',
      '/T',
      '/F',
    ]);
    if (kill.exitCode == 0) {
      log.add('[kill] OpenCode.exe');
    } else {
      final message = '${kill.stdout}${kill.stderr}'.trim();
      log.add(message.isEmpty ? '[kill] 未发现 OpenCode.exe' : '[kill] $message');
    }

    final launch = _windowsOpenCodeLaunchCommand(env, fileExists);
    try {
      await start(launch, const [], runInShell: _isBareCommand(launch));
      log.add('[launch] $launch');
      return DesktopRestartResult(ok: true, log: log);
    } catch (error) {
      log.add('[launch-failed] $error');
      return DesktopRestartResult(ok: false, log: log);
    }
  }

  if (os == 'macos') {
    await run('pkill', const ['-x', 'OpenCode']);
    try {
      await start('open', const ['-a', 'OpenCode'], runInShell: false);
      log.add('[launch] open -a OpenCode');
      return DesktopRestartResult(ok: true, log: log);
    } catch (error) {
      log.add('[launch-failed] $error');
      return DesktopRestartResult(ok: false, log: log);
    }
  }

  return DesktopRestartResult(ok: false, log: ['暂未支持的平台: $os']);
}

String _windowsOpenCodeLaunchCommand(
  Map<String, String> env,
  bool Function(String path) exists,
) {
  final localAppData =
      env['LOCALAPPDATA'] ??
      (env['USERPROFILE'] == null
          ? null
          : '${env['USERPROFILE']}\\AppData\\Local');
  final candidates =
      [
            env['RESTART_LAUNCH_CMD'],
            if (localAppData != null)
              '$localAppData\\Programs\\@opencode-aidesktop\\OpenCode.exe',
            if (localAppData != null)
              '$localAppData\\Programs\\OpenCode\\OpenCode.exe',
            if (env['ProgramFiles'] != null)
              '${env['ProgramFiles']}\\OpenCode\\OpenCode.exe',
            'OpenCode.exe',
          ]
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty);

  for (final candidate in candidates) {
    if (_isBareCommand(candidate) || exists(candidate)) return candidate;
  }
  return 'OpenCode.exe';
}

bool _isBareCommand(String value) =>
    !value.contains(r'\') && !value.contains('/') && !value.contains(':');

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.api,
    required this.workspace,
    required this.store,
  });

  final OmoApi api;
  final LocalWorkspace workspace;
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
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: lightScheme,
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 12),
          bodySmall: TextStyle(fontSize: 11),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: darkScheme,
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 12),
          bodySmall: TextStyle(fontSize: 11),
        ),
      ),
      home: OmoSwitcherHome(api: api, workspace: workspace, store: store),
    );
  }
}

abstract class OmoApi {
  Future<Map<String, dynamic>> health(String serverUrl);
  Future<Map<String, dynamic>> state(String serverUrl);
  Future<Map<String, dynamic>> switchTier(String serverUrl, String tier);
  Future<Map<String, dynamic>> restart(String serverUrl, {String? launchCmd});
  Future<List<ConfigItem>> configItems(String serverUrl, {bool fs = false});
  Future<Map<String, dynamic>> configItem(
    String serverUrl,
    String key, {
    String? snapshot,
    bool fs = false,
  });
  Future<Map<String, dynamic>> configDiff(
    String serverUrl,
    List<ConfigItem> localItems,
  );
  Future<Map<String, dynamic>> writeWorkspaceItem(
    String serverUrl,
    String key,
    String contentB64,
  );
  Future<Map<String, dynamic>> pushConfig(
    String serverUrl,
    List<ConfigItem> items,
    String note,
  );
  Future<Map<String, dynamic>> deleteRemoteItems(
    String serverUrl,
    List<String> keys,
    String note,
  );
  Future<Map<String, dynamic>> renameRemoteItem(
    String serverUrl,
    String key,
    String newKey,
    String note,
  );
  Future<Map<String, dynamic>> snapshots(String serverUrl, {int limit = 50});
  Future<Map<String, dynamic>> snapshot(String serverUrl, String id);
  Future<Map<String, dynamic>> rollbackSnapshot(String serverUrl, String id);
  Future<Map<String, dynamic>> rollbackFile(
    String serverUrl,
    String id,
    String key,
  );
}

abstract class LocalStore {
  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);
  Future<List<ConfigItem>> listItems();
  Future<ConfigItem?> getItem(String key);
  Future<void> upsertItem(ConfigItem item, String source);
  // 整批合并写入：保留未涉及的档位，并只追加一条快照（一次同步=一条历史）。
  Future<void> upsertItems(List<ConfigItem> items, String source);
  Future<void> deleteItems(List<String> keys, String source);
  Future<void> renameItem(String oldKey, String newKey, String source);
  Future<void> replaceItems(List<ConfigItem> items, String source);
  Future<List<HistoryEntry>> listSnapshots();
  Future<List<ConfigItem>> snapshotItems(String id);
}

class HttpOmoApi implements OmoApi {
  final HttpClient _client = HttpClient();

  @override
  Future<Map<String, dynamic>> health(String serverUrl) =>
      _request('GET', serverUrl, '/api/health');

  @override
  Future<Map<String, dynamic>> state(String serverUrl) =>
      _request('GET', serverUrl, '/api/state');

  @override
  Future<Map<String, dynamic>> switchTier(String serverUrl, String tier) =>
      _request('POST', serverUrl, '/api/switch', body: {'tier': tier});

  @override
  Future<Map<String, dynamic>> restart(String serverUrl, {String? launchCmd}) =>
      _request(
        'POST',
        serverUrl,
        '/api/restart',
        body: launchCmd != null
            ? <String, dynamic>{'launchCmd': launchCmd}
            : <String, dynamic>{},
      );

  @override
  Future<List<ConfigItem>> configItems(
    String serverUrl, {
    bool fs = false,
  }) async {
    final result = await _request(
      'GET',
      serverUrl,
      fs ? '/api/config/items?fs=1' : '/api/config/items',
    );
    return _itemsFrom(result['items']);
  }

  @override
  Future<Map<String, dynamic>> configItem(
    String serverUrl,
    String key, {
    String? snapshot,
    bool fs = false,
  }) {
    final query = fs
        ? '?fs=1'
        : snapshot == null
        ? ''
        : '?snapshot=${Uri.encodeQueryComponent(snapshot)}';
    return _request(
      'GET',
      serverUrl,
      '/api/config/item/${Uri.encodeComponent(key)}$query',
    );
  }

  @override
  Future<Map<String, dynamic>> configDiff(
    String serverUrl,
    List<ConfigItem> localItems,
  ) => _request(
    'POST',
    serverUrl,
    '/api/config/diff',
    body: {
      'localItems': localItems.map((item) => item.toServerJson()).toList(),
    },
  );

  @override
  Future<Map<String, dynamic>> writeWorkspaceItem(
    String serverUrl,
    String key,
    String contentB64,
  ) => _request(
    'POST',
    serverUrl,
    '/api/config/item/${Uri.encodeComponent(key)}/fs',
    body: {'contentB64': contentB64},
  );

  @override
  Future<Map<String, dynamic>> pushConfig(
    String serverUrl,
    List<ConfigItem> items,
    String note,
  ) => _request(
    'POST',
    serverUrl,
    '/api/config/push',
    body: {
      'items': items.map((item) => item.toPushJson()).toList(),
      'note': note,
    },
  );

  @override
  Future<Map<String, dynamic>> deleteRemoteItems(
    String serverUrl,
    List<String> keys,
    String note,
  ) => _request(
    'DELETE',
    serverUrl,
    '/api/config/items',
    body: {'keys': keys, 'note': note},
  );

  @override
  Future<Map<String, dynamic>> renameRemoteItem(
    String serverUrl,
    String key,
    String newKey,
    String note,
  ) => _request(
    'POST',
    serverUrl,
    '/api/config/item/${Uri.encodeComponent(key)}/rename',
    body: {'newKey': newKey, 'note': note},
  );

  @override
  Future<Map<String, dynamic>> snapshots(String serverUrl, {int limit = 50}) =>
      _request('GET', serverUrl, '/api/snapshots?limit=$limit');

  @override
  Future<Map<String, dynamic>> snapshot(String serverUrl, String id) =>
      _request('GET', serverUrl, '/api/snapshots/${Uri.encodeComponent(id)}');

  @override
  Future<Map<String, dynamic>> rollbackSnapshot(String serverUrl, String id) =>
      _request(
        'POST',
        serverUrl,
        '/api/snapshots/${Uri.encodeComponent(id)}/rollback',
        body: <String, dynamic>{},
      );

  @override
  Future<Map<String, dynamic>> rollbackFile(
    String serverUrl,
    String id,
    String key,
  ) => _request(
    'POST',
    serverUrl,
    '/api/snapshots/${Uri.encodeComponent(id)}/rollback-file',
    body: {'key': key},
  );

  Future<Map<String, dynamic>> _request(
    String method,
    String serverUrl,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final base = _normalizeServerUrl(serverUrl);
    final request = await _client.openUrl(method, Uri.parse('$base$path'));
    request.headers.contentType = ContentType.json;
    if (body != null) {
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    final decoded = text.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(text) as Map<String, dynamic>;
    if (response.statusCode >= 400 && decoded['ok'] == null) {
      decoded['ok'] = false;
    }
    return decoded;
  }
}

Directory defaultLocalStoreDirectory({
  Map<String, String>? environment,
  String? operatingSystem,
  String? currentPath,
  String? pathSeparator,
}) {
  final env = environment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;
  final cwd = currentPath ?? Directory.current.path;
  final separator = pathSeparator ?? (os == 'windows' ? r'\' : '/');

  String childOf(String base, String name) => '$base$separator$name';

  if (os == 'windows') {
    final localAppData = env['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return Directory(childOf(localAppData, 'omo-switcher-client'));
    }
    final appData = env['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return Directory(childOf(appData, 'omo-switcher-client'));
    }
  }

  if (os == 'macos') {
    final home = env['HOME'] ?? cwd;
    return Directory('$home/Library/Application Support/omo-switcher-client');
  }

  final home = env['HOME'];
  if (home != null && home.isNotEmpty) {
    return Directory(
      childOf(childOf(childOf(home, '.local'), 'share'), 'omo-switcher-client'),
    );
  }

  return Directory(childOf(cwd, 'omo-switcher-client'));
}

class FileLocalStore implements LocalStore {
  FileLocalStore({Directory? directory})
    : _directory = directory ?? _defaultDirectory();

  final Directory _directory;
  String get directoryPath => _directory.path;

  File get _settingsFile => File('${_directory.path}/settings.json');
  File get _itemsFile => File('${_directory.path}/config_items.json');
  File get _historyFile => File('${_directory.path}/config_history.json');

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
  Future<List<ConfigItem>> listItems() async =>
      _itemsFrom((await _readMap(_itemsFile))['items']);

  @override
  Future<ConfigItem?> getItem(String key) async {
    for (final item in await listItems()) {
      if (item.key == key) return item;
    }
    return null;
  }

  @override
  Future<void> upsertItem(ConfigItem item, String source) =>
      upsertItems([item], source);

  @override
  Future<void> upsertItems(List<ConfigItem> items, String source) async {
    if (items.isEmpty) return;
    final incoming = {for (final item in items) item.key};
    final existing = await listItems();
    final next = [
      for (final item in existing)
        if (!incoming.contains(item.key)) item,
      for (final item in items) item.copyWith(source: source),
    ];
    await _writeItems(next, source);
  }

  @override
  Future<void> deleteItems(List<String> keys, String source) async {
    final keySet = keys.toSet();
    if (keySet.isEmpty) return;
    final next = [
      for (final item in await listItems())
        if (!keySet.contains(item.key)) item,
    ];
    await _writeItems(next, source);
  }

  @override
  Future<void> renameItem(String oldKey, String newKey, String source) async {
    final items = await listItems();
    if (!items.any((item) => item.key == oldKey)) {
      throw StateError('本地仓库中不存在: $oldKey');
    }
    if (items.any((item) => item.key == newKey)) {
      throw StateError('目标档位已存在: $newKey');
    }
    await _writeItems([
      for (final item in items)
        if (item.key == oldKey)
          item.renamed(newKey).copyWith(source: source)
        else
          item,
    ], source);
  }

  @override
  Future<void> replaceItems(List<ConfigItem> items, String source) async {
    await _writeItems(
      items.map((item) => item.copyWith(source: source)).toList(),
      source,
    );
  }

  @override
  Future<List<HistoryEntry>> listSnapshots() async {
    final rows = (await _readMap(_historyFile))['items'] as List<dynamic>?;
    return (rows ?? const [])
        .map((row) => HistoryEntry.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<ConfigItem>> snapshotItems(String id) async {
    final rows = (await _readMap(_historyFile))['items'] as List<dynamic>?;
    for (final row in rows ?? const []) {
      final data = row as Map<String, dynamic>;
      if (data['id'] == id) return _itemsFrom(data['items']);
    }
    return const [];
  }

  Future<void> _writeItems(List<ConfigItem> items, String source) async {
    await _writeJson(_itemsFile, {
      'items': items.map((item) => item.toStoreJson()).toList(),
    });
    await _appendSnapshot(items, source);
  }

  Future<void> _appendSnapshot(List<ConfigItem> items, String source) async {
    final history = await _readMap(_historyFile);
    final rows = List<Map<String, dynamic>>.from(
      (history['items'] as List<dynamic>? ?? const []).map(
        (row) => Map<String, dynamic>.from(row as Map),
      ),
    );
    final now = DateTime.now().toUtc();
    rows.insert(0, {
      'id': '${now.microsecondsSinceEpoch}',
      'ts': now.toIso8601String(),
      'note': source,
      'keys': items.map((item) => item.key).toList(),
      'items': items.map((item) => item.toStoreJson()).toList(),
    });
    await _writeJson(_historyFile, {'items': rows.take(50).toList()});
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
    return defaultLocalStoreDirectory();
  }
}

class OmoSwitcherHome extends StatefulWidget {
  const OmoSwitcherHome({
    super.key,
    required this.api,
    required this.workspace,
    required this.store,
  });

  final OmoApi api;
  final LocalWorkspace workspace;
  final LocalStore store;

  @override
  State<OmoSwitcherHome> createState() => _OmoSwitcherHomeState();
}

class _OmoSwitcherHomeState extends State<OmoSwitcherHome> {
  String serverUrl = 'http://127.0.0.1:7600';
  String workspacePath = '工作目录: ?';
  String localPath = '';
  String connectionStatus = '未连接';
  String selectedTier = '';
  String selectedSnapshot = '';
  String selectedLocalHistory = '';
  String selectedRemoteHistory = '';
  String switchLog = '';
  String restartDesktopLog = '';
  String restartTuiLog = '';
  String localLog = '';
  String remoteLog = '';
  int tabIndex = 0;
  List<Tier> tiers = [];
  List<ConfigItem> workspaceItems = [];
  List<ConfigItem> localItems = [];
  List<ConfigItem> remoteItems = [];
  List<ConfigItem> localHistoryItems = [];
  List<ConfigItem> remoteHistoryItems = [];
  List<HistoryEntry> localHistory = [];
  List<HistoryEntry> remoteHistory = [];
  final selectedWorkspace = <String>{};
  final selectedLocal = <String>{};
  final selectedRemote = <String>{};
  final serverUrlController = TextEditingController();
  final searchController = TextEditingController();
  String searchQuery = '';
  bool isRefreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    serverUrlController.dispose();
    searchController.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    serverUrl = await widget.store.getSetting('server_url') ?? serverUrl;
    serverUrlController.text = serverUrl;
    if (widget.store is SqliteLocalStore) {
      localPath = '本地仓库: ${(widget.store as SqliteLocalStore).directoryPath}';
    }
    if (mounted) setState(() {});
    // 自动连接已缓存的地址
    try {
      final result = await widget.api.health(serverUrl);
      if (result['ok'] != false) connectionStatus = '已连接';
      if (mounted) setState(() {});
    } catch (_) {
      connectionStatus = '未连接';
      if (mounted) setState(() {});
    }
    await _refreshAll();
  }

  Future<void> _refreshAll() async {
    await Future.wait([_refreshState(), _reloadSync(), _reloadHistory()]);
  }

  Future<void> _refreshFromUi() async {
    if (isRefreshing) return;
    setState(() => isRefreshing = true);
    try {
      await _refreshAll();
      _notice('已刷新');
    } catch (error) {
      _notice('刷新失败: $error');
    } finally {
      if (mounted) setState(() => isRefreshing = false);
    }
  }

  Future<void> _reloadHistory() async {
    final nextLocalHistory = await widget.store.listSnapshots();
    List<HistoryEntry> nextRemoteHistory = [];
    try {
      final response = await widget.api.snapshots(serverUrl);
      nextRemoteHistory = _historyFrom(response['items']);
    } catch (_) {
      nextRemoteHistory = [];
    }
    final nextLocalId = _selectedOrFirst(
      selectedLocalHistory,
      nextLocalHistory,
    );
    final nextRemoteId = _selectedOrFirst(
      selectedRemoteHistory,
      nextRemoteHistory,
    );
    final nextLocalItems = nextLocalId.isEmpty
        ? <ConfigItem>[]
        : await widget.store.snapshotItems(nextLocalId);
    final nextRemoteItems = nextRemoteId.isEmpty
        ? <ConfigItem>[]
        : await _remoteSnapshotItems(nextRemoteId);
    setState(() {
      localHistory = nextLocalHistory;
      remoteHistory = nextRemoteHistory;
      selectedLocalHistory = nextLocalId;
      selectedRemoteHistory = nextRemoteId;
      localHistoryItems = nextLocalItems;
      remoteHistoryItems = nextRemoteItems;
    });
  }

  Future<List<ConfigItem>> _remoteSnapshotItems(String id) async {
    final response = await widget.api.snapshot(serverUrl, id);
    return _itemsFrom(response['items']);
  }

  Future<void> _selectLocalHistory(String id) async {
    final items = await widget.store.snapshotItems(id);
    setState(() {
      selectedLocalHistory = id;
      localHistoryItems = items;
    });
  }

  Future<void> _selectRemoteHistory(String id) async {
    final items = await _remoteSnapshotItems(id);
    setState(() {
      selectedRemoteHistory = id;
      remoteHistoryItems = items;
    });
  }

  Future<void> _connectServer() async {
    final nextUrl = serverUrlController.text.trim();
    try {
      final result = await widget.api.health(nextUrl);
      if (result['ok'] == false) throw StateError(_messageFor(result));
      await widget.store.setSetting('server_url', nextUrl);
      serverUrl = nextUrl;
      connectionStatus = '已连接';
      if (mounted) setState(() {});
      await _refreshAll();
    } catch (error) {
      connectionStatus = '连接失败';
      remoteItems = [];
      if (mounted) setState(() {});
    }
  }

  Future<void> _refreshState() async {
    try {
      final state = await widget.workspace.getState();
      setState(() {
        tiers = state.tiers
            .map(
              (tier) => Tier(
                slug: tier.slug,
                label: tier.label,
                index: tier.index,
                shared: true,
                files: tier.files,
              ),
            )
            .toList();
        final activeShared = state.active['shared'];
        if (activeShared != null && activeShared.isNotEmpty) {
          selectedTier = activeShared;
        }
        if (selectedTier.isEmpty && tiers.isNotEmpty) {
          selectedTier = tiers.first.slug;
        }
        workspacePath = '工作目录: ${state.opencodeDir}';
      });
    } catch (_) {}
  }

  Future<void> _reloadSync() async {
    // 工作目录 = 本机文件系统（不依赖服务器）。
    final workspace = await widget.workspace.listBundles();
    final local = await widget.store.listItems();
    // 云端依赖服务器；离线时清空但不影响工作目录/本地仓库。
    List<ConfigItem> remote = [];
    try {
      remote = await widget.api.configItems(serverUrl);
    } catch (_) {
      remote = [];
    }
    setState(() {
      workspaceItems = workspace;
      remoteItems = remote;
      localItems = local;
    });
  }

  Future<void> _applyTier() async {
    if (selectedTier.isEmpty) return;
    final confirmed = await _confirm(
      '应用档位',
      '将把「$selectedTier」档位包解包到本机工作目录，覆盖 omo 与 omo-slim 的生效配置。',
    );
    if (!confirmed) return;
    try {
      final log = await widget.workspace.applyTier(selectedTier);
      setState(() => switchLog = '已应用「$selectedTier」:\n${log.join('\n')}');
    } catch (error) {
      setState(() => switchLog = '切换失败: $error');
    }
    await _refreshState();
  }

  Future<void> _applyWorkspaceItem(String key) async {
    if (!await _confirmApplyConfig(key, '常用配置')) return;
    await _applyWorkspaceKey(key);
  }

  Future<void> _applyLocalItem(String key) async {
    if (!await _confirmApplyConfig(key, '本地仓库')) return;
    if (!_workspaceHasKey(key)) {
      final item = await widget.store.getItem(key);
      if (item?.contentB64 == null) {
        return _notice('本地仓库中没有可应用的配置内容: $key');
      }
      await widget.workspace.writeBundle(key, item!.contentB64!);
    }
    await _applyWorkspaceKey(key);
  }

  Future<void> _applyLocalHistoryItem(String key) async {
    if (!await _confirmApplyConfig(key, '本地历史')) return;
    if (!_workspaceHasKey(key)) {
      final item = _itemByKey(localHistoryItems, key);
      if (item?.contentB64 == null) {
        return _notice('本地历史中没有可应用的配置内容: $key');
      }
      await widget.workspace.writeBundle(key, item!.contentB64!);
    }
    await _applyWorkspaceKey(key);
  }

  Future<void> _applyRemoteItem(String key) async {
    if (!await _confirmApplyConfig(key, '云端仓库')) return;
    if (!_workspaceHasKey(key)) {
      final result = await widget.api.configItem(serverUrl, key);
      final contentB64 = result['contentB64'] as String?;
      if (contentB64 == null) return _notice('云端仓库中没有可应用的配置内容: $key');
      await widget.workspace.writeBundle(key, contentB64);
    }
    await _applyWorkspaceKey(key);
  }

  Future<void> _applyRemoteHistoryItem(String key) async {
    if (selectedRemoteHistory.isEmpty) return _notice('请选择一条云端历史');
    if (!await _confirmApplyConfig(key, '云端历史')) return;
    if (!_workspaceHasKey(key)) {
      final result = await widget.api.configItem(
        serverUrl,
        key,
        snapshot: selectedRemoteHistory,
      );
      final contentB64 = result['contentB64'] as String?;
      if (contentB64 == null) return _notice('云端历史中没有可应用的配置内容: $key');
      await widget.workspace.writeBundle(key, contentB64);
    }
    await _applyWorkspaceKey(key);
  }

  Future<bool> _confirmApplyConfig(String key, String source) async {
    return _confirm('是否应用此配置', '将应用「$key」到当前配置。\n来源：$source');
  }

  Future<void> _applyWorkspaceKey(String key) async {
    try {
      final log = await widget.workspace.applyTier(key);
      setState(() {
        selectedTier = key;
        switchLog = '已应用「$key」:\n${log.join('\n')}';
      });
      _notice('已应用配置: $key');
      await _refreshAll();
      await _showModelCheckDialog(showWhenEmpty: false);
    } catch (error) {
      setState(() => switchLog = '应用失败: $error');
      _notice('应用失败: $error');
    }
  }

  bool _workspaceHasKey(String key) =>
      workspaceItems.any((item) => item.key == key);

  Future<void> _showModelCheckDialog({bool showWhenEmpty = true}) async {
    List<ModelCheckTarget> targets;
    try {
      targets = collectModelCheckTargets(widget.workspace.resolveDir());
    } catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('检测连接'),
          content: Text('读取模型配置失败: $error'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    if (targets.isEmpty && !showWhenEmpty) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ModelCheckDialog(targets: targets),
    );
  }

  Future<void> _restartDesktop() async {
    setState(() => restartDesktopLog = '正在重启 opencode Desktop...');
    final result = await restartLocalDesktop();
    if (!mounted) return;
    setState(() => restartDesktopLog = result.log.join('\n'));
    _notice(result.ok ? '已重启 Desktop' : '重启 Desktop 失败');
  }

  Future<void> _restartTui() async {
    setState(() => restartTuiLog = '工作目录配置已更新。请在终端重新运行 opencode 使其生效。');
  }

  Future<void> _syncCloudToWorkspace() async {
    final keys = _defaultKeys(selectedRemote, _visibleItems(remoteItems));
    if (keys.isEmpty) return _notice('云端没有可同步的配置项');
    final confirmed = await _confirm(
      '同步到常用配置',
      '将把云端 ${keys.length} 个档位包写入工作目录。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    for (final key in keys) {
      final result = await widget.api.configItem(
        serverUrl,
        key,
        snapshot: selectedSnapshot.isEmpty ? null : selectedSnapshot,
      );
      if (result['contentB64'] != null) {
        await widget.workspace.writeBundle(key, result['contentB64'] as String);
      }
    }
    _notice('已同步 ${keys.length} 项到工作目录');
    await _refreshAll();
  }

  Future<void> _pushWorkspaceToRemote() async {
    final keys = _defaultKeys(selectedWorkspace, _visibleItems(workspaceItems));
    if (keys.isEmpty) return _notice('工作目录没有可上传的配置项');
    final confirmed = await _confirm(
      '同步到云端仓库',
      '将把工作目录中 ${keys.length} 个档位包上传到云端仓库。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    final byKey = {for (final item in workspaceItems) item.key: item};
    final items = <ConfigItem>[];
    for (final key in keys) {
      final meta = byKey[key];
      final contentB64 = await widget.workspace.readBundleB64(key);
      items.add(
        ConfigItem(
          key: key,
          contentB64: contentB64,
          sha256: meta?.sha256,
          size: meta?.size,
          files: meta?.files ?? const [],
        ),
      );
    }
    final result = await widget.api.pushConfig(
      serverUrl,
      items,
      'workspace push',
    );
    _notice(
      result['ok'] == false
          ? '同步到云端仓库失败: ${_messageFor(result)}'
          : '已同步到云端仓库: ${result['snapshotId']}',
    );
    await _refreshAll();
  }

  Future<void> _deleteWorkspaceItems() async {
    final keys = _defaultKeys(selectedWorkspace, _visibleItems(workspaceItems));
    if (keys.isEmpty) return _notice('常用配置没有可删除的配置项');
    final confirmed = await _confirm(
      '删除常用配置',
      '将从工作目录删除 ${keys.length} 个档位包。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    final deleted = await widget.workspace.deleteBundles(keys);
    setState(() {
      selectedWorkspace.removeAll(keys);
      localLog = '已从常用配置删除 ${deleted.length} 项';
    });
    _notice('已从常用配置删除 ${deleted.length} 项');
    await _refreshAll();
  }

  Future<void> _renameWorkspaceItem() async {
    final key = _singleSelectedKey(
      selectedWorkspace,
      _visibleItems(workspaceItems),
    );
    if (key == null) return _notice('请选择 1 个常用配置进行重命名');
    final newKey = await _promptRename(key);
    if (newKey == null) return;
    try {
      await widget.workspace.renameBundle(key, newKey);
      setState(() {
        selectedWorkspace
          ..remove(key)
          ..add(newKey);
      });
      _notice('已重命名常用配置: $key → $newKey');
      await _refreshAll();
    } catch (error) {
      _notice('重命名失败: $error');
    }
  }

  Future<void> _downloadWorkspaceToLocal() async {
    final keys = _defaultKeys(selectedWorkspace, _visibleItems(workspaceItems));
    if (keys.isEmpty) return _notice('工作目录没有可下载的配置项');
    final byKey = {for (final item in workspaceItems) item.key: item};
    final items = <ConfigItem>[];
    for (final key in keys) {
      final meta = byKey[key];
      final contentB64 = await widget.workspace.readBundleB64(key);
      items.add(
        ConfigItem(
          key: key,
          label: meta?.label,
          sha256: meta?.sha256,
          size: meta?.size,
          contentB64: contentB64,
          tierSlug: meta?.tierSlug,
          tierIndex: meta?.tierIndex,
          files: meta?.files ?? const [],
        ),
      );
    }
    await widget.store.upsertItems(items, 'local-scan');
    setState(() => localLog = '已同步 ${keys.length} 项到本地仓库');
    await Future.wait([_reloadSync(), _reloadHistory()]);
  }

  Future<void> _uploadLocalToWorkspace() async {
    final keys = _defaultKeys(selectedLocal, _visibleItems(localItems));
    if (keys.isEmpty) return _notice('本地仓库没有可同步的配置项');
    final confirmed = await _confirm(
      '同步到常用配置',
      '将把本地仓库中 ${keys.length} 个档位包同步到工作目录。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    var exported = 0;
    final failed = <String>[];
    for (final key in keys) {
      final item = await widget.store.getItem(key);
      if (item == null || item.contentB64 == null) {
        failed.add('$key: 本地仓库中不存在');
        continue;
      }
      try {
        await widget.workspace.writeBundle(key, item.contentB64!);
        exported++;
      } catch (error) {
        failed.add('$key: $error');
      }
    }
    setState(
      () => localLog =
          '已上传 $exported 项到工作目录${failed.isEmpty ? '' : '\n失败: ${failed.join('\n')}'}',
    );
    await _refreshAll();
  }

  Future<void> _pullRemoteToLocal() async {
    final keys = _defaultKeys(selectedRemote, _visibleItems(remoteItems));
    if (keys.isEmpty) return _notice('云端仓库没有可同步的配置项');
    final items = <ConfigItem>[];
    for (final key in keys) {
      final result = await widget.api.configItem(
        serverUrl,
        key,
        snapshot: selectedSnapshot.isEmpty ? null : selectedSnapshot,
      );
      items.add(ConfigItem.fromJson(result));
    }
    await widget.store.upsertItems(items, 'pulled');
    setState(() => localLog = '已从云端仓库同步 ${keys.length} 项到本地仓库');
    await Future.wait([_reloadSync(), _reloadHistory()]);
  }

  Future<void> _pushLocalToRemote() async {
    final keys = _defaultKeys(selectedLocal, _visibleItems(localItems));
    if (keys.isEmpty) return _notice('本地仓库没有可同步的配置项');
    final confirmed = await _confirm(
      '同步到云端仓库',
      '将在云端仓库生成新快照，包含本地仓库中 ${keys.length} 个档位包。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    final items = <ConfigItem>[];
    for (final key in keys) {
      final item = await widget.store.getItem(key);
      if (item != null) items.add(item);
    }
    final scope = keys.length == localItems.length ? 'all' : 'selected';
    final result = await widget.api.pushConfig(
      serverUrl,
      items,
      'client $scope push',
    );
    setState(
      () => localLog = result['ok'] == false
          ? '同步失败: ${_messageFor(result)}'
          : '已同步到云端仓库: ${result['snapshotId']}',
    );
    await _refreshAll();
  }

  Future<void> _deleteLocalItems() async {
    final keys = _defaultKeys(selectedLocal, _visibleItems(localItems));
    if (keys.isEmpty) return _notice('本地仓库没有可删除的配置项');
    final confirmed = await _confirm(
      '删除本地仓库配置',
      '将从本地仓库删除 ${keys.length} 个档位包，并保留一条本地历史。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    await widget.store.deleteItems(keys, 'delete local');
    setState(() {
      selectedLocal.removeAll(keys);
      localLog = '已从本地仓库删除 ${keys.length} 项';
    });
    await Future.wait([_reloadSync(), _reloadHistory()]);
  }

  Future<void> _renameLocalItem() async {
    final key = _singleSelectedKey(selectedLocal, _visibleItems(localItems));
    if (key == null) return _notice('请选择 1 个本地仓库配置进行重命名');
    final newKey = await _promptRename(key);
    if (newKey == null) return;
    try {
      await widget.store.renameItem(key, newKey, 'rename local');
      setState(() {
        selectedLocal
          ..remove(key)
          ..add(newKey);
        localLog = '已重命名本地仓库: $key → $newKey';
      });
      await Future.wait([_reloadSync(), _reloadHistory()]);
    } catch (error) {
      _notice('重命名失败: $error');
    }
  }

  Future<void> _restoreLocalHistoryToLocal() async {
    if (selectedLocalHistory.isEmpty || localHistoryItems.isEmpty) {
      return _notice('本地历史没有可同步的配置项');
    }
    final confirmed = await _confirm(
      '同步到本地仓库',
      '将用所选历史覆盖本地仓库最新配置。\n${localHistoryItems.map((item) => item.key).join('\n')}',
    );
    if (!confirmed) return;
    await widget.store.replaceItems(localHistoryItems, 'local-history restore');
    setState(() => localLog = '已从本地历史覆盖本地仓库');
    await Future.wait([_reloadSync(), _reloadHistory()]);
  }

  Future<void> _restoreRemoteHistoryToRemote() async {
    if (selectedRemoteHistory.isEmpty) {
      return _notice('云端历史没有可同步的配置项');
    }
    final confirmed = await _confirm('同步到云端仓库', '将用所选历史覆盖云端仓库最新配置。');
    if (!confirmed) return;
    final result = await widget.api.rollbackSnapshot(
      serverUrl,
      selectedRemoteHistory,
    );
    setState(
      () => remoteLog = result['ok'] == false
          ? '同步失败: ${_messageFor(result)}'
          : '已从云端历史覆盖云端仓库: ${result['snapshotId']}',
    );
    await _refreshAll();
  }

  Future<void> _deleteRemoteItems() async {
    final keys = _defaultKeys(selectedRemote, _visibleItems(remoteItems));
    if (keys.isEmpty) return _notice('云端仓库没有可删除的配置项');
    final confirmed = await _confirm(
      '删除云端仓库配置',
      '将在云端仓库生成新快照，删除 ${keys.length} 个档位包。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    final result = await widget.api.deleteRemoteItems(
      serverUrl,
      keys,
      'delete remote',
    );
    setState(() {
      selectedRemote.removeAll(keys);
      remoteLog = result['ok'] == false
          ? '删除失败: ${_messageFor(result)}'
          : '已从云端仓库删除 ${keys.length} 项: ${result['snapshotId']}';
    });
    await _refreshAll();
  }

  Future<void> _renameRemoteItem() async {
    final key = _singleSelectedKey(selectedRemote, _visibleItems(remoteItems));
    if (key == null) return _notice('请选择 1 个云端仓库配置进行重命名');
    final newKey = await _promptRename(key);
    if (newKey == null) return;
    final result = await widget.api.renameRemoteItem(
      serverUrl,
      key,
      newKey,
      'rename remote',
    );
    setState(() {
      if (result['ok'] == false) {
        remoteLog = '重命名失败: ${_messageFor(result)}';
      } else {
        selectedRemote
          ..remove(key)
          ..add(newKey);
        remoteLog = '已重命名云端仓库: $key → $newKey (${result['snapshotId']})';
      }
    });
    await _refreshAll();
  }

  Future<void> _syncLocalHistoryToWorkspace() async {
    final keys = _defaultKeys(selectedLocal, _visibleItems(localHistoryItems));
    if (keys.isEmpty) return _notice('本地历史没有可同步的配置项');
    final confirmed = await _confirm(
      '同步到常用配置',
      '将把所选本地历史中的 ${keys.length} 个档位包同步到工作目录。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    for (final key in keys) {
      ConfigItem? item;
      for (final candidate in localHistoryItems) {
        if (candidate.key == key) item = candidate;
      }
      if (item?.contentB64 != null) {
        await widget.workspace.writeBundle(key, item!.contentB64!);
      }
    }
    _notice('已从本地历史同步 ${keys.length} 项到工作目录');
    await _refreshAll();
  }

  Future<void> _pushLocalHistoryToRemote() async {
    final keys = _defaultKeys(selectedLocal, _visibleItems(localHistoryItems));
    if (keys.isEmpty) return _notice('本地历史没有可同步的配置项');
    final items = [
      for (final item in localHistoryItems)
        if (keys.contains(item.key)) item,
    ];
    final confirmed = await _confirm(
      '同步到云端仓库',
      '将在云端仓库生成新快照，包含所选本地历史中的 ${items.length} 个档位包。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    final result = await widget.api.pushConfig(
      serverUrl,
      items,
      'local history push',
    );
    setState(
      () => localLog = result['ok'] == false
          ? '同步失败: ${_messageFor(result)}'
          : '已从本地历史同步到云端仓库: ${result['snapshotId']}',
    );
    await _refreshAll();
  }

  Future<void> _syncRemoteHistoryToWorkspace() async {
    final keys = _defaultKeys(
      selectedRemote,
      _visibleItems(remoteHistoryItems),
    );
    if (selectedRemoteHistory.isEmpty || keys.isEmpty) {
      return _notice('云端历史没有可同步的配置项');
    }
    final confirmed = await _confirm(
      '同步到常用配置',
      '将把所选云端历史中的 ${keys.length} 个档位包同步到工作目录。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    for (final key in keys) {
      final result = await widget.api.configItem(
        serverUrl,
        key,
        snapshot: selectedRemoteHistory,
      );
      if (result['contentB64'] != null) {
        await widget.workspace.writeBundle(key, result['contentB64'] as String);
      }
    }
    _notice('已从云端历史同步 ${keys.length} 项到工作目录');
    await _refreshAll();
  }

  Future<void> _syncRemoteHistoryToLocal() async {
    final keys = _defaultKeys(
      selectedRemote,
      _visibleItems(remoteHistoryItems),
    );
    if (selectedRemoteHistory.isEmpty || keys.isEmpty) {
      return _notice('云端历史没有可同步的配置项');
    }
    final items = <ConfigItem>[];
    for (final key in keys) {
      final result = await widget.api.configItem(
        serverUrl,
        key,
        snapshot: selectedRemoteHistory,
      );
      items.add(ConfigItem.fromJson(result));
    }
    await widget.store.replaceItems(items, 'cloud-history pull');
    setState(() => localLog = '已从云端历史同步 ${items.length} 项到本地仓库');
    await Future.wait([_reloadSync(), _reloadHistory()]);
  }

  Future<bool> _confirm(String title, String body) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认执行'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<String?> _promptRename(String oldKey) async {
    final controller = TextEditingController(text: oldKey);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新名称',
            helperText: '允许字母、数字、下划线、点、连字符，且需以字母或数字开头',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确认重命名'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result == oldKey) return null;
    if (!_isSafeConfigKey(result)) {
      _notice('名称不合法: $result');
      return null;
    }
    return result;
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _setSearchQuery(String value) {
    setState(() => searchQuery = value);
  }

  void _clearSearchQuery() {
    if (searchQuery.isEmpty) return;
    searchController.clear();
    setState(() => searchQuery = '');
  }

  List<ConfigItem> _visibleItems(List<ConfigItem> items) =>
      _filterConfigItems(items, searchQuery);

  @override
  Widget build(BuildContext context) {
    final currentFiles = _currentFilesFor(selectedTier, tiers);
    final filteredCurrentFiles = _filterStrings(currentFiles, searchQuery);
    final filteredWorkspaceItems = _filterConfigItems(
      workspaceItems,
      searchQuery,
    );
    final filteredLocalItems = _filterConfigItems(localItems, searchQuery);
    final filteredRemoteItems = _filterConfigItems(remoteItems, searchQuery);
    final filteredLocalHistoryItems = _filterConfigItems(
      localHistoryItems,
      searchQuery,
    );
    final filteredRemoteHistoryItems = _filterConfigItems(
      remoteHistoryItems,
      searchQuery,
    );
    // 标签：每个档位包分别在「常用/本地/云端」中是否存在（按 key 判定）。
    final presence = Presence(
      workspace: {for (final item in workspaceItems) item.key},
      local: {for (final item in localItems) item.key},
      cloud: {for (final item in remoteItems) item.key},
    );
    final pages = [
      _ConfigPage(
        path: workspacePath,
        tiers: tiers,
        selectedTier: selectedTier,
        currentFiles: filteredCurrentFiles,
        totalFiles: currentFiles.length,
        switchLog: switchLog,
        restartDesktopLog: restartDesktopLog,
        restartTuiLog: restartTuiLog,
        onTierChanged: (value) => setState(() => selectedTier = value),
        onApplyTier: _applyTier,
        onRestartDesktop: _restartDesktop,
        onRestartTui: _restartTui,
        onCheckModels: () => unawaited(_showModelCheckDialog()),
        onRefresh: () => unawaited(_refreshFromUi()),
        isRefreshing: isRefreshing,
        searchController: searchController,
        searchQuery: searchQuery,
        onSearchChanged: _setSearchQuery,
        onClearSearch: _clearSearchQuery,
      ),
      _WorkspaceSyncPage(
        path: workspacePath,
        items: filteredWorkspaceItems,
        totalItems: workspaceItems.length,
        presence: presence,
        selected: selectedWorkspace,
        onSelectedChanged: (key, checked) => setState(
          () => checked
              ? selectedWorkspace.add(key)
              : selectedWorkspace.remove(key),
        ),
        onSyncToLocal: _downloadWorkspaceToLocal,
        onSyncToRemote: _pushWorkspaceToRemote,
        onRename: _renameWorkspaceItem,
        onDelete: _deleteWorkspaceItems,
        onApplyItem: (key) => unawaited(_applyWorkspaceItem(key)),
        onRefresh: () => unawaited(_refreshFromUi()),
        isRefreshing: isRefreshing,
        searchController: searchController,
        searchQuery: searchQuery,
        onSearchChanged: _setSearchQuery,
        onClearSearch: _clearSearchQuery,
      ),
      _LocalPage(
        path: localPath,
        items: filteredLocalItems,
        totalItems: localItems.length,
        presence: presence,
        selected: selectedLocal,
        log: localLog,
        onSelectedChanged: (key, checked) => setState(
          () => checked ? selectedLocal.add(key) : selectedLocal.remove(key),
        ),
        onUploadWorkspace: _uploadLocalToWorkspace,
        onPushRemote: _pushLocalToRemote,
        onRename: _renameLocalItem,
        onDelete: _deleteLocalItems,
        onApplyItem: (key) => unawaited(_applyLocalItem(key)),
        onRefresh: () => unawaited(_refreshFromUi()),
        isRefreshing: isRefreshing,
        searchController: searchController,
        searchQuery: searchQuery,
        onSearchChanged: _setSearchQuery,
        onClearSearch: _clearSearchQuery,
      ),
      _LocalHistoryPage(
        snapshots: localHistory,
        selectedSnapshot: selectedLocalHistory,
        items: filteredLocalHistoryItems,
        totalItems: localHistoryItems.length,
        presence: presence,
        selected: selectedLocal,
        log: localLog,
        onSnapshotChanged: (id) => unawaited(_selectLocalHistory(id)),
        onSelectedChanged: (key, checked) => setState(
          () => checked ? selectedLocal.add(key) : selectedLocal.remove(key),
        ),
        onSyncToLocal: _restoreLocalHistoryToLocal,
        onUploadWorkspace: _syncLocalHistoryToWorkspace,
        onPushRemote: _pushLocalHistoryToRemote,
        onApplyItem: (key) => unawaited(_applyLocalHistoryItem(key)),
        onRefresh: () => unawaited(_refreshFromUi()),
        isRefreshing: isRefreshing,
        searchController: searchController,
        searchQuery: searchQuery,
        onSearchChanged: _setSearchQuery,
        onClearSearch: _clearSearchQuery,
      ),
      _RemotePage(
        serverUrl: serverUrl,
        connectionStatus: connectionStatus,
        serverUrlController: serverUrlController,
        onTestConnection: _connectServer,
        items: filteredRemoteItems,
        totalItems: remoteItems.length,
        presence: presence,
        selected: selectedRemote,
        log: remoteLog,
        onSelectedChanged: (key, checked) => setState(
          () => checked ? selectedRemote.add(key) : selectedRemote.remove(key),
        ),
        onSyncToWorkspace: _syncCloudToWorkspace,
        onSyncToLocal: _pullRemoteToLocal,
        onRename: _renameRemoteItem,
        onDelete: _deleteRemoteItems,
        onApplyItem: (key) => unawaited(_applyRemoteItem(key)),
        onRefresh: () => unawaited(_refreshFromUi()),
        isRefreshing: isRefreshing,
        searchController: searchController,
        searchQuery: searchQuery,
        onSearchChanged: _setSearchQuery,
        onClearSearch: _clearSearchQuery,
      ),
      _RemoteHistoryPage(
        snapshots: remoteHistory,
        selectedSnapshot: selectedRemoteHistory,
        items: filteredRemoteHistoryItems,
        totalItems: remoteHistoryItems.length,
        presence: presence,
        selected: selectedRemote,
        log: remoteLog,
        onSnapshotChanged: (id) => unawaited(_selectRemoteHistory(id)),
        onSelectedChanged: (key, checked) => setState(
          () => checked ? selectedRemote.add(key) : selectedRemote.remove(key),
        ),
        onSyncToRemote: _restoreRemoteHistoryToRemote,
        onSyncToWorkspace: _syncRemoteHistoryToWorkspace,
        onSyncToLocal: _syncRemoteHistoryToLocal,
        onApplyItem: (key) => unawaited(_applyRemoteHistoryItem(key)),
        onRefresh: () => unawaited(_refreshFromUi()),
        isRefreshing: isRefreshing,
        searchController: searchController,
        searchQuery: searchQuery,
        onSearchChanged: _setSearchQuery,
        onClearSearch: _clearSearchQuery,
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('omo-switcher')),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: tabIndex,
            onDestinationSelected: (index) => setState(() => tabIndex = index),
            labelType: NavigationRailLabelType.all,
            groupAlignment: -0.9,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.tune_outlined),
                label: Text('当前配置'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.folder_copy_outlined),
                label: Text('常用配置'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.storage_outlined),
                label: Text('本地仓库'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.history_outlined),
                label: Text('本地历史'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.cloud_outlined),
                label: Text('云端仓库'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.manage_history_outlined),
                label: Text('云端历史'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pages[tabIndex]),
        ],
      ),
    );
  }
}

class _ConfigPage extends StatelessWidget {
  const _ConfigPage({
    required this.path,
    required this.tiers,
    required this.selectedTier,
    required this.currentFiles,
    required this.totalFiles,
    required this.switchLog,
    required this.restartDesktopLog,
    required this.restartTuiLog,
    required this.onTierChanged,
    required this.onApplyTier,
    required this.onRestartDesktop,
    required this.onRestartTui,
    required this.onCheckModels,
    required this.onRefresh,
    required this.isRefreshing,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  final String path;
  final List<Tier> tiers;
  final String selectedTier;
  final List<String> currentFiles;
  final int totalFiles;
  final String switchLog;
  final String restartDesktopLog;
  final String restartTuiLog;
  final ValueChanged<String> onTierChanged;
  final VoidCallback onApplyTier;
  final VoidCallback onRestartDesktop;
  final VoidCallback onRestartTui;
  final VoidCallback onCheckModels;
  final VoidCallback onRefresh;
  final bool isRefreshing;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '当前配置',
      count: '${tiers.length} 档',
      onRefresh: onRefresh,
      isRefreshing: isRefreshing,
      searchController: searchController,
      searchQuery: searchQuery,
      onSearchChanged: onSearchChanged,
      onClearSearch: onClearSearch,
      children: [
        Text(path),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: selectedTier.isEmpty && tiers.isNotEmpty
                      ? tiers.first.slug
                      : selectedTier.isEmpty
                      ? null
                      : selectedTier,
                  isDense: true,
                  items: tiers
                      .map(
                        (tier) => DropdownMenuItem(
                          value: tier.slug,
                          child: Text(tier.slug),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) onTierChanged(value);
                  },
                ),
              ),
            ),
            FilledButton(onPressed: onApplyTier, child: const Text('应用到工作目录')),
            FilledButton.tonalIcon(
              onPressed: onRestartDesktop,
              icon: const Icon(Icons.desktop_windows_outlined),
              label: const Text('重启 Desktop'),
            ),
            FilledButton.tonalIcon(
              onPressed: onRestartTui,
              icon: const Icon(Icons.terminal_outlined),
              label: const Text('重启 TUI'),
            ),
            FilledButton.tonalIcon(
              onPressed: onCheckModels,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('检测连接'),
            ),
          ],
        ),
        _LogBox(text: switchLog),
        _LogBox(text: restartDesktopLog),
        _LogBox(text: restartTuiLog),
        _FileList(
          title: '当前配置文件',
          files: currentFiles,
          totalFiles: totalFiles,
          isFiltered: searchQuery.trim().isNotEmpty,
        ),
      ],
    );
  }
}

class _WorkspaceSyncPage extends StatelessWidget {
  const _WorkspaceSyncPage({
    required this.path,
    required this.items,
    required this.totalItems,
    required this.presence,
    required this.selected,
    required this.onSelectedChanged,
    required this.onSyncToLocal,
    required this.onSyncToRemote,
    required this.onRename,
    required this.onDelete,
    required this.onApplyItem,
    required this.onRefresh,
    required this.isRefreshing,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  final String path;
  final List<ConfigItem> items;
  final int totalItems;
  final Presence presence;
  final Set<String> selected;
  final void Function(String key, bool checked) onSelectedChanged;
  final VoidCallback onSyncToLocal;
  final VoidCallback onSyncToRemote;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<String> onApplyItem;
  final VoidCallback onRefresh;
  final bool isRefreshing;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '常用配置',
      count: _countLabel(items.length, totalItems, '项', searchQuery),
      onRefresh: onRefresh,
      isRefreshing: isRefreshing,
      searchController: searchController,
      searchQuery: searchQuery,
      onSearchChanged: onSearchChanged,
      onClearSearch: onClearSearch,
      children: [
        Text(path),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(
              onPressed: onSyncToLocal,
              child: const Text('同步到本地仓库'),
            ),
            OutlinedButton(
              onPressed: onSyncToRemote,
              child: const Text('同步到云端仓库'),
            ),
            OutlinedButton.icon(
              onPressed: onRename,
              icon: const Icon(Icons.drive_file_rename_outline, size: 16),
              label: const Text('重命名'),
            ),
            OutlinedButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('删除'),
            ),
          ],
        ),
        _ConfigList(
          items: items,
          presence: presence,
          selected: selected,
          onSelectedChanged: onSelectedChanged,
          onItemPressed: onApplyItem,
        ),
      ],
    );
  }
}

class _LocalPage extends StatelessWidget {
  const _LocalPage({
    required this.path,
    required this.items,
    required this.totalItems,
    required this.presence,
    required this.selected,
    required this.log,
    required this.onSelectedChanged,
    required this.onUploadWorkspace,
    required this.onPushRemote,
    required this.onRename,
    required this.onDelete,
    required this.onApplyItem,
    required this.onRefresh,
    required this.isRefreshing,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  final String path;
  final List<ConfigItem> items;
  final int totalItems;
  final Presence presence;
  final Set<String> selected;
  final String log;
  final void Function(String key, bool checked) onSelectedChanged;
  final VoidCallback onUploadWorkspace;
  final VoidCallback onPushRemote;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<String> onApplyItem;
  final VoidCallback onRefresh;
  final bool isRefreshing;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '本地仓库',
      count: _countLabel(items.length, totalItems, '项', searchQuery),
      onRefresh: onRefresh,
      isRefreshing: isRefreshing,
      searchController: searchController,
      searchQuery: searchQuery,
      onSearchChanged: onSearchChanged,
      onClearSearch: onClearSearch,
      children: [
        if (path.isNotEmpty) Text(path),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(
              onPressed: onUploadWorkspace,
              child: const Text('同步到常用配置'),
            ),
            OutlinedButton(
              onPressed: onPushRemote,
              child: const Text('同步到云端仓库'),
            ),
            OutlinedButton.icon(
              onPressed: onRename,
              icon: const Icon(Icons.drive_file_rename_outline, size: 16),
              label: const Text('重命名'),
            ),
            OutlinedButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('删除'),
            ),
          ],
        ),
        _ConfigList(
          items: items,
          presence: presence,
          selected: selected,
          onSelectedChanged: onSelectedChanged,
          onItemPressed: onApplyItem,
        ),
        _LogBox(text: log),
      ],
    );
  }
}

class _LocalHistoryPage extends StatelessWidget {
  const _LocalHistoryPage({
    required this.snapshots,
    required this.selectedSnapshot,
    required this.items,
    required this.totalItems,
    required this.presence,
    required this.selected,
    required this.log,
    required this.onSnapshotChanged,
    required this.onSelectedChanged,
    required this.onSyncToLocal,
    required this.onUploadWorkspace,
    required this.onPushRemote,
    required this.onApplyItem,
    required this.onRefresh,
    required this.isRefreshing,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  final List<HistoryEntry> snapshots;
  final String selectedSnapshot;
  final List<ConfigItem> items;
  final int totalItems;
  final Presence presence;
  final Set<String> selected;
  final String log;
  final ValueChanged<String> onSnapshotChanged;
  final void Function(String key, bool checked) onSelectedChanged;
  final VoidCallback onSyncToLocal;
  final VoidCallback onUploadWorkspace;
  final VoidCallback onPushRemote;
  final ValueChanged<String> onApplyItem;
  final VoidCallback onRefresh;
  final bool isRefreshing;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '本地历史',
      count:
          '${snapshots.length} 版 / ${_countLabel(items.length, totalItems, '项', searchQuery)}',
      onRefresh: onRefresh,
      isRefreshing: isRefreshing,
      searchController: searchController,
      searchQuery: searchQuery,
      onSearchChanged: onSearchChanged,
      onClearSearch: onClearSearch,
      children: [
        _HistoryToolbar(
          snapshots: snapshots,
          selectedSnapshot: selectedSnapshot,
          onSnapshotChanged: onSnapshotChanged,
          actionLabel: '同步到本地仓库',
          onAction: onSyncToLocal,
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(
              onPressed: onUploadWorkspace,
              child: const Text('同步到常用配置'),
            ),
            OutlinedButton(
              onPressed: onPushRemote,
              child: const Text('同步到云端仓库'),
            ),
          ],
        ),
        _ConfigList(
          items: items,
          presence: presence,
          selected: selected,
          onSelectedChanged: onSelectedChanged,
          onItemPressed: onApplyItem,
        ),
        _LogBox(text: log),
      ],
    );
  }
}

class _RemotePage extends StatelessWidget {
  const _RemotePage({
    required this.serverUrl,
    required this.connectionStatus,
    required this.serverUrlController,
    required this.onTestConnection,
    required this.items,
    required this.totalItems,
    required this.presence,
    required this.selected,
    required this.log,
    required this.onSelectedChanged,
    required this.onSyncToWorkspace,
    required this.onSyncToLocal,
    required this.onRename,
    required this.onDelete,
    required this.onApplyItem,
    required this.onRefresh,
    required this.isRefreshing,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  final String serverUrl;
  final String connectionStatus;
  final TextEditingController serverUrlController;
  final VoidCallback onTestConnection;
  final List<ConfigItem> items;
  final int totalItems;
  final Presence presence;
  final Set<String> selected;
  final String log;
  final void Function(String key, bool checked) onSelectedChanged;
  final VoidCallback onSyncToWorkspace;
  final VoidCallback onSyncToLocal;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<String> onApplyItem;
  final VoidCallback onRefresh;
  final bool isRefreshing;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '云端仓库',
      count: _countLabel(items.length, totalItems, '项', searchQuery),
      onRefresh: onRefresh,
      isRefreshing: isRefreshing,
      searchController: searchController,
      searchQuery: searchQuery,
      onSearchChanged: onSearchChanged,
      onClearSearch: onClearSearch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: serverUrlController,
                decoration: const InputDecoration(
                  labelText: '仓库地址',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: onTestConnection, child: const Text('连接')),
            const SizedBox(width: 8),
            Text(
              connectionStatus,
              style: TextStyle(
                color: connectionStatus == '已连接'
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(
              onPressed: onSyncToWorkspace,
              child: const Text('同步到常用配置'),
            ),
            OutlinedButton(
              onPressed: onSyncToLocal,
              child: const Text('同步到本地仓库'),
            ),
            OutlinedButton.icon(
              onPressed: onRename,
              icon: const Icon(Icons.drive_file_rename_outline, size: 16),
              label: const Text('重命名'),
            ),
            OutlinedButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('删除'),
            ),
          ],
        ),
        _ConfigList(
          items: items,
          presence: presence,
          selected: selected,
          onSelectedChanged: onSelectedChanged,
          onItemPressed: onApplyItem,
        ),
        _LogBox(text: log),
      ],
    );
  }
}

class _RemoteHistoryPage extends StatelessWidget {
  const _RemoteHistoryPage({
    required this.snapshots,
    required this.selectedSnapshot,
    required this.items,
    required this.totalItems,
    required this.presence,
    required this.selected,
    required this.log,
    required this.onSnapshotChanged,
    required this.onSelectedChanged,
    required this.onSyncToRemote,
    required this.onSyncToWorkspace,
    required this.onSyncToLocal,
    required this.onApplyItem,
    required this.onRefresh,
    required this.isRefreshing,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  final List<HistoryEntry> snapshots;
  final String selectedSnapshot;
  final List<ConfigItem> items;
  final int totalItems;
  final Presence presence;
  final Set<String> selected;
  final String log;
  final ValueChanged<String> onSnapshotChanged;
  final void Function(String key, bool checked) onSelectedChanged;
  final VoidCallback onSyncToRemote;
  final VoidCallback onSyncToWorkspace;
  final VoidCallback onSyncToLocal;
  final ValueChanged<String> onApplyItem;
  final VoidCallback onRefresh;
  final bool isRefreshing;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '云端历史',
      count:
          '${snapshots.length} 版 / ${_countLabel(items.length, totalItems, '项', searchQuery)}',
      onRefresh: onRefresh,
      isRefreshing: isRefreshing,
      searchController: searchController,
      searchQuery: searchQuery,
      onSearchChanged: onSearchChanged,
      onClearSearch: onClearSearch,
      children: [
        _HistoryToolbar(
          snapshots: snapshots,
          selectedSnapshot: selectedSnapshot,
          onSnapshotChanged: onSnapshotChanged,
          actionLabel: '同步到云端仓库',
          onAction: onSyncToRemote,
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(
              onPressed: onSyncToWorkspace,
              child: const Text('同步到常用配置'),
            ),
            OutlinedButton(
              onPressed: onSyncToLocal,
              child: const Text('同步到本地仓库'),
            ),
          ],
        ),
        _ConfigList(
          items: items,
          presence: presence,
          selected: selected,
          onSelectedChanged: onSelectedChanged,
          onItemPressed: onApplyItem,
        ),
        _LogBox(text: log),
      ],
    );
  }
}

class _HistoryToolbar extends StatelessWidget {
  const _HistoryToolbar({
    required this.snapshots,
    required this.selectedSnapshot,
    required this.onSnapshotChanged,
    required this.actionLabel,
    required this.onAction,
  });

  final List<HistoryEntry> snapshots;
  final String selectedSnapshot;
  final ValueChanged<String> onSnapshotChanged;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outline),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: snapshots.any((item) => item.id == selectedSnapshot)
                    ? selectedSnapshot
                    : null,
                hint: const Text('选择创建时间'),
                isExpanded: true,
                isDense: true,
                items: snapshots
                    .map(
                      (snapshot) => DropdownMenuItem(
                        value: snapshot.id,
                        child: Text(snapshot.createdLabel),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) onSnapshotChanged(value);
                },
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(onPressed: onAction, child: Text(actionLabel)),
      ],
    );
  }
}

class _PageShell extends StatelessWidget {
  const _PageShell({
    required this.title,
    required this.count,
    required this.children,
    required this.onRefresh,
    required this.isRefreshing,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  final String title;
  final String count;
  final List<Widget> children;
  final VoidCallback onRefresh;
  final bool isRefreshing;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (count.isNotEmpty)
              Chip(label: Text(count), visualDensity: VisualDensity.compact),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: isRefreshing ? null : onRefresh,
              icon: isRefreshing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_outlined),
              label: const Text('刷新'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: searchController,
          onChanged: onSearchChanged,
          decoration: InputDecoration(
            labelText: '关键字搜索',
            hintText: '输入名称、标签、sha 或文件名自动过滤',
            prefixIcon: const Icon(Icons.search_outlined),
            suffixIcon: searchQuery.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空搜索',
                    onPressed: onClearSearch,
                    icon: const Icon(Icons.close_outlined),
                  ),
            border: const OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 10,
            ),
          ),
          textInputAction: TextInputAction.search,
        ),
        const SizedBox(height: 8),
        ...children.expand((child) => [child, const SizedBox(height: 8)]),
      ],
    );
  }
}

class _ConfigList extends StatelessWidget {
  const _ConfigList({
    required this.items,
    required this.presence,
    required this.selected,
    required this.onSelectedChanged,
    required this.onItemPressed,
  });

  final List<ConfigItem> items;
  final Presence presence;
  final Set<String> selected;
  final void Function(String key, bool checked) onSelectedChanged;
  final ValueChanged<String> onItemPressed;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const Text('0 项');
    final allSelected =
        items.isNotEmpty && items.every((item) => selected.contains(item.key));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          CheckboxListTile(
            value: allSelected,
            onChanged: (checked) {
              for (final item in items) {
                onSelectedChanged(item.key, checked ?? false);
              }
            },
            title: Text(
              '全选',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const Divider(height: 1),
          for (final item in items)
            ListTile(
              onTap: () => onItemPressed(item.key),
              leading: Checkbox(
                value: selected.contains(item.key),
                onChanged: (checked) =>
                    onSelectedChanged(item.key, checked ?? false),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Tooltip(
                          message:
                              '${item.label ?? item.key}\n包含 ${item.files.length} 个文件:\n${item.files.join('\n')}',
                          child: Text(
                            item.key,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (item.files.isNotEmpty)
                          Text('(${item.files.length}个文件)'),
                        for (final tag in presence.tagsFor(item.key))
                          _PresenceTag(label: tag),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.play_circle_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
              subtitle: Text(shortSha(item.sha256)),
            ),
        ],
      ),
    );
  }
}

class _PresenceTag extends StatelessWidget {
  const _PresenceTag({required this.label});

  final String label;

  static const _colors = {
    '常用': Color(0xff3fb950), // workspace
    '本地': Color(0xff58a6ff), // local repo
    '云端': Color(0xffd29922), // cloud
  };

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final color = _colors[label] ?? Theme.of(context).colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11)),
    );
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
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(text),
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({
    required this.title,
    required this.files,
    required this.totalFiles,
    required this.isFiltered,
  });

  final String title;
  final List<String> files;
  final int totalFiles;
  final bool isFiltered;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        if (isFiltered)
          Text(
            '显示 ${files.length}/$totalFiles 个文件',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 6),
        if (files.isEmpty)
          const Text('0 个文件')
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final file in files)
                  ListTile(
                    dense: true,
                    title: Text(file),
                    leading: const Icon(Icons.description_outlined, size: 18),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class Tier {
  const Tier({
    required this.slug,
    required this.label,
    required this.index,
    required this.shared,
    this.files = const [],
  });

  final String slug;
  final String label;
  final int index;
  final bool shared;
  final List<String> files;

  factory Tier.fromJson(Map<String, dynamic> json) => Tier(
    slug: json['slug'] as String? ?? '',
    label: json['label'] as String? ?? json['slug'] as String? ?? '',
    index: (json['index'] as num?)?.toInt() ?? 0,
    shared: json['shared'] == true,
    files: _strings(json['files']),
  );
}

class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.ts,
    required this.keys,
    this.note = '',
  });

  final String id;
  final DateTime ts;
  final List<String> keys;
  final String note;

  String get createdLabel {
    final local = ts.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} ${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
  }

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    final rawTs = json['ts'];
    final ts = rawTs is num
        ? DateTime.fromMillisecondsSinceEpoch(rawTs.toInt(), isUtc: true)
        : DateTime.tryParse(rawTs?.toString() ?? '') ?? DateTime.now().toUtc();
    return HistoryEntry(
      id: json['id']?.toString() ?? '',
      ts: ts,
      keys: _strings(json['keys']),
      note: json['note']?.toString() ?? '',
    );
  }
}

class ConfigItem {
  const ConfigItem({
    required this.key,
    this.label,
    this.sha256,
    this.contentB64,
    this.provider = 'bundle',
    this.tierSlug,
    this.tierIndex,
    this.size,
    this.source,
    this.files = const [],
  });

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

  ConfigItem renamed(String newKey) => ConfigItem(
    key: newKey,
    label: label == key ? newKey : label,
    sha256: sha256,
    contentB64: contentB64,
    provider: provider,
    tierSlug: tierSlug == null || tierSlug == key ? newKey : tierSlug,
    tierIndex: tierIndex,
    size: size,
    source: source,
    files: files,
  );

  factory ConfigItem.fromJson(Map<String, dynamic> json) => ConfigItem(
    key: json['key'] as String? ?? '',
    label: json['label'] as String?,
    sha256: json['sha256'] as String?,
    contentB64: json['contentB64'] as String? ?? json['content_b64'] as String?,
    provider: json['provider'] as String? ?? 'bundle',
    tierSlug: json['tierSlug'] as String? ?? json['tier_slug'] as String?,
    tierIndex: (json['tierIndex'] as num? ?? json['tier_index'] as num?)
        ?.toInt(),
    size: (json['size'] as num?)?.toInt(),
    source: json['source'] as String?,
    files: (json['files'] as List<dynamic>? ?? const [])
        .map((file) => file.toString())
        .toList(),
  );

  Map<String, dynamic> toServerJson() => {
    'key': key,
    'sha256': sha256,
    'size': size,
  };
  Map<String, dynamic> toPushJson() => {
    'key': key,
    'contentB64': contentB64,
    'sha256': sha256,
    'size': size,
  };
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

// 档位包在三处的存在情况（按 key 判定）。每命中一处加一个标签：常用/本地/云端。
class Presence {
  const Presence({
    this.workspace = const {},
    this.local = const {},
    this.cloud = const {},
  });

  final Set<String> workspace; // 常用（本机 opencode 工作目录）
  final Set<String> local; // 本地仓库（SQLite）
  final Set<String> cloud; // 云端仓库（服务器）

  List<String> tagsFor(String key) => [
    if (workspace.contains(key)) '常用',
    if (local.contains(key)) '本地',
    if (cloud.contains(key)) '云端',
  ];
}

List<ConfigItem> _itemsFrom(Object? items) =>
    (items as List<dynamic>? ?? const [])
        .map((item) => ConfigItem.fromJson(item as Map<String, dynamic>))
        .toList();
List<HistoryEntry> _historyFrom(Object? items) =>
    (items as List<dynamic>? ?? const [])
        .map((item) => HistoryEntry.fromJson(item as Map<String, dynamic>))
        .where((item) => item.id.isNotEmpty)
        .toList();
List<String> _strings(Object? value) => (value as List<dynamic>? ?? const [])
    .map((item) => item.toString())
    .toList();
List<String> _defaultKeys(Set<String> selected, List<ConfigItem> items) =>
    selected.isNotEmpty
    ? selected.toList()
    : items.map((item) => item.key).toList();
String? _singleSelectedKey(Set<String> selected, List<ConfigItem> items) {
  final keys = selected.isNotEmpty
      ? selected.toList()
      : items.length == 1
      ? [items.first.key]
      : <String>[];
  return keys.length == 1 ? keys.first : null;
}

bool _isSafeConfigKey(String key) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(key);
String shortSha(String? value) => value == null || value.isEmpty
    ? '—'
    : value.substring(0, value.length < 8 ? value.length : 8);
String _normalizeServerUrl(String value) =>
    (value.trim().isEmpty ? 'http://127.0.0.1:7600' : value.trim())
        .replaceFirst(RegExp(r'/+$'), '');
String _messageFor(Map<String, dynamic> result) =>
    result['error'] is Map<String, dynamic>
    ? ((result['error'] as Map<String, dynamic>)['message']?.toString() ??
          jsonEncode(result))
    : jsonEncode(result);
String _selectedOrFirst(String selected, List<HistoryEntry> items) =>
    items.any((item) => item.id == selected)
    ? selected
    : items.isEmpty
    ? ''
    : items.first.id;
String _countLabel(int filtered, int total, String unit, String query) =>
    query.trim().isEmpty ? '$total $unit' : '$filtered/$total $unit';
List<String> _filterStrings(List<String> items, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return items;
  return [
    for (final item in items)
      if (item.toLowerCase().contains(needle)) item,
  ];
}

List<ConfigItem> _filterConfigItems(List<ConfigItem> items, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return items;
  return [
    for (final item in items)
      if (_matchesConfigItem(item, needle)) item,
  ];
}

bool _matchesConfigItem(ConfigItem item, String needle) {
  final values = [
    item.key,
    item.label,
    item.sha256,
    item.provider,
    item.tierSlug,
    item.tierIndex?.toString(),
    item.size?.toString(),
    item.source,
    ...item.files,
  ];
  return values.whereType<String>().any(
    (value) => value.toLowerCase().contains(needle),
  );
}

ConfigItem? _itemByKey(List<ConfigItem> items, String key) {
  for (final item in items) {
    if (item.key == key) return item;
  }
  return null;
}

List<String> _currentFilesFor(String selectedTier, List<Tier> tiers) {
  for (final tier in tiers) {
    if (tier.slug == selectedTier) return tier.files;
  }
  return tiers.isEmpty ? const [] : tiers.first.files;
}

class ModelCheckTarget {
  const ModelCheckTarget({
    required this.model,
    required this.variant,
    required this.locations,
    required this.providerId,
    required this.modelId,
    required this.baseUrl,
    required this.apiKey,
    required this.error,
  });

  final String model;
  final String? variant;
  final List<String> locations;
  final String providerId;
  final String modelId;
  final String? baseUrl;
  final String? apiKey;
  final String? error;

  String get label => variant == null ? model : '$model / $variant';
}

class ModelCheckStatus {
  const ModelCheckStatus.pending() : ok = null, message = '检测中';
  const ModelCheckStatus.success(this.message) : ok = true;
  const ModelCheckStatus.failure(this.message) : ok = false;

  final bool? ok;
  final String message;
}

class _ModelCheckDialog extends StatefulWidget {
  const _ModelCheckDialog({required this.targets});

  final List<ModelCheckTarget> targets;

  @override
  State<_ModelCheckDialog> createState() => _ModelCheckDialogState();
}

class _ModelCheckDialogState extends State<_ModelCheckDialog> {
  late final Map<String, ModelCheckStatus> statuses;

  @override
  void initState() {
    super.initState();
    statuses = {
      for (final target in widget.targets)
        target.label: const ModelCheckStatus.pending(),
    };
    unawaited(_runChecks());
  }

  Future<void> _runChecks() async {
    await Future.wait(widget.targets.map(_runOne));
  }

  Future<void> _runOne(ModelCheckTarget target) async {
    ModelCheckStatus status;
    try {
      final message = await checkModelConnectivity(target);
      status = ModelCheckStatus.success(message);
    } catch (error) {
      status = ModelCheckStatus.failure(error.toString());
    }
    if (!mounted) return;
    setState(() => statuses[target.label] = status);
  }

  @override
  Widget build(BuildContext context) {
    final pending = statuses.values.where((status) => status.ok == null).length;
    final okCount = statuses.values.where((status) => status.ok == true).length;
    final failCount = statuses.values
        .where((status) => status.ok == false)
        .length;
    return AlertDialog(
      title: const Text('检测连接'),
      content: SizedBox(
        width: 720,
        child: widget.targets.isEmpty
            ? const Text('当前配置没有引用模型。')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('成功 $okCount / 失败 $failCount / 检测中 $pending'),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: widget.targets.length,
                      separatorBuilder: (_, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final target = widget.targets[index];
                        final status =
                            statuses[target.label] ??
                            const ModelCheckStatus.pending();
                        final color = status.ok == null
                            ? Theme.of(context).colorScheme.primary
                            : status.ok == true
                            ? Colors.green
                            : Theme.of(context).colorScheme.error;
                        final icon = status.ok == null
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                status.ok == true
                                    ? Icons.check_circle_outline
                                    : Icons.cancel_outlined,
                                color: color,
                              );
                        return ListTile(
                          dense: true,
                          leading: icon,
                          title: Text(target.label),
                          subtitle: Text(
                            '${target.locations.join(', ')}\n${status.message}',
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

List<ModelCheckTarget> collectModelCheckTargets(Directory opencodeDir) {
  final providerFile = File(
    '${opencodeDir.path}${Platform.pathSeparator}opencode.jsonc',
  );
  final providerConfig = providerFile.existsSync()
      ? jsonDecode(_stripJsonc(providerFile.readAsStringSync()))
            as Map<String, dynamic>
      : <String, dynamic>{};
  final providers = providerConfig['provider'] is Map<String, dynamic>
      ? providerConfig['provider'] as Map<String, dynamic>
      : <String, dynamic>{};

  final refs =
      <String, ({String model, String? variant, List<String> locations})>{};
  for (final fileName in const [
    'oh-my-openagent.json',
    'oh-my-opencode-slim.json',
  ]) {
    final file = File('${opencodeDir.path}${Platform.pathSeparator}$fileName');
    if (!file.existsSync()) continue;
    final cfg =
        jsonDecode(_stripBom(file.readAsStringSync())) as Map<String, dynamic>;
    for (final ref in _collectModelRefs(cfg, fileName)) {
      final key = '${ref.model}|${ref.variant ?? ''}';
      final prev = refs[key];
      refs[key] = (
        model: ref.model,
        variant: ref.variant,
        locations: [...(prev?.locations ?? const <String>[]), ref.where],
      );
    }
  }

  return refs.values.map((ref) {
    final slash = ref.model.indexOf('/');
    final providerId = slash <= 0 ? '' : ref.model.substring(0, slash);
    final modelId = slash <= 0 ? ref.model : ref.model.substring(slash + 1);
    final provider = providers[providerId] is Map<String, dynamic>
        ? providers[providerId] as Map<String, dynamic>
        : null;
    final baseUrl = provider == null
        ? null
        : _firstString(provider, const [
            'baseURL',
            'baseUrl',
            'base_url',
            'apiBase',
            'api_base',
            'endpoint',
            'url',
          ]);
    final apiKey = provider == null
        ? null
        : _firstString(provider, const [
            'apiKey',
            'api_key',
            'apikey',
            'token',
            'accessToken',
            'access_token',
          ]);
    final error = slash <= 0
        ? '模型 ID 应为 provider/model'
        : provider == null
        ? 'provider 未在 opencode.jsonc 定义: $providerId'
        : baseUrl == null
        ? 'provider 缺少 baseURL/baseUrl/base_url'
        : null;
    return ModelCheckTarget(
      model: ref.model,
      variant: ref.variant,
      locations: ref.locations,
      providerId: providerId,
      modelId: modelId,
      baseUrl: baseUrl,
      apiKey: apiKey,
      error: error,
    );
  }).toList()..sort((a, b) => a.label.compareTo(b.label));
}

Future<String> checkModelConnectivity(ModelCheckTarget target) async {
  if (target.error != null) throw Exception(target.error);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final failures = <String>[];
    for (final uri in _chatCompletionsUris(target.baseUrl!)) {
      for (final probe in _modelCheckProbes(target.modelId)) {
        final request = await client
            .postUrl(uri)
            .timeout(const Duration(seconds: 10));
        request.headers.contentType = ContentType.json;
        if (target.apiKey != null && target.apiKey!.isNotEmpty) {
          request.headers.set('Authorization', 'Bearer ${target.apiKey}');
        }
        request.write(jsonEncode(probe.body));
        try {
          final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
          if (response.statusCode >= 200 && response.statusCode < 300) {
            return '请求成功 (${response.statusCode}, ${uri.path}, ${probe.label})';
          }
          final text = await response.transform(utf8.decoder).join();
          failures.add(
            '${uri.path} ${probe.label}: HTTP ${response.statusCode}: ${_shortText(text)}',
          );
        } on SocketException catch (error) {
          failures.add('${uri.path} ${probe.label}: ${error.message}');
        } on HttpException catch (error) {
          failures.add('${uri.path} ${probe.label}: ${error.message}');
        } on TimeoutException {
          failures.add('${uri.path} ${probe.label}: 请求超时');
        }
      }
    }
    throw Exception(failures.join(' ; '));
  } finally {
    client.close(force: true);
  }
}

List<({String label, Map<String, Object> body})> _modelCheckProbes(
  String modelId,
) => [
  (
    label: 'non-stream',
    body: {
      'model': modelId,
      'messages': const [
        {'role': 'user', 'content': 'ping'},
      ],
      'max_tokens': 1,
    },
  ),
  (
    label: 'stream',
    body: {
      'model': modelId,
      'messages': const [
        {'role': 'user', 'content': 'ping'},
      ],
      'stream': true,
    },
  ),
];

List<Uri> _chatCompletionsUris(String baseUrl) {
  final trimmed = baseUrl.replaceFirst(RegExp(r'/+$'), '');
  final base = Uri.parse(trimmed);
  final segments = base.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (_hasPathSuffix(segments, const ['chat', 'completions'])) {
    return [base];
  }

  final suffixes = _isVersionSegment(segments.lastOrNull)
      ? const [
          ['chat', 'completions'],
        ]
      : const [
          ['v1', 'chat', 'completions'],
          ['chat', 'completions'],
        ];
  return suffixes
      .map((suffix) => _appendPathSegments(base, suffix))
      .toSet()
      .toList(growable: false);
}

Uri _appendPathSegments(Uri base, List<String> suffix) => base.replace(
  pathSegments: [
    ...base.pathSegments.where((segment) => segment.isNotEmpty),
    ...suffix,
  ],
  query: '',
  fragment: '',
);

bool _hasPathSuffix(List<String> segments, List<String> suffix) {
  if (segments.length < suffix.length) return false;
  final start = segments.length - suffix.length;
  for (var i = 0; i < suffix.length; i++) {
    if (segments[start + i].toLowerCase() != suffix[i]) return false;
  }
  return true;
}

bool _isVersionSegment(String? segment) =>
    segment != null &&
    RegExp(r'^v\d+(?:\.\d+)?$').hasMatch(segment.toLowerCase());

String _shortText(String text) {
  final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length <= 180 ? oneLine : '${oneLine.substring(0, 180)}...';
}

List<({String model, String? variant, String where})> _collectModelRefs(
  Map<String, dynamic> cfg,
  String fileName,
) {
  final refs = <({String model, String? variant, String where})>[];

  void visit(Object? node, String where) {
    if (node is Map<String, dynamic>) {
      final model = node['model'];
      if (model is String) {
        refs.add((
          model: model,
          variant: node['variant']?.toString(),
          where: '$fileName:$where',
        ));
      }
      final fallbacks = node['fallback_models'];
      if (fallbacks is List) {
        for (var i = 0; i < fallbacks.length; i++) {
          final fb = fallbacks[i];
          if (fb is String) {
            refs.add((
              model: fb,
              variant: null,
              where: '$fileName:$where.fallback[$i]',
            ));
          } else if (fb is Map<String, dynamic> && fb['model'] is String) {
            refs.add((
              model: fb['model'] as String,
              variant: fb['variant']?.toString(),
              where: '$fileName:$where.fallback[$i]',
            ));
          }
        }
      }
      for (final entry in node.entries) {
        if (entry.key == 'fallback_models') continue;
        visit(entry.value, where.isEmpty ? entry.key : '$where.${entry.key}');
      }
      return;
    }
    if (node is List) {
      for (var i = 0; i < node.length; i++) {
        visit(node[i], '$where[$i]');
      }
    }
  }

  visit(cfg, '');
  return refs;
}

String? _firstString(Map<String, dynamic> obj, List<String> keys) {
  for (final key in keys) {
    final value = _configString(obj[key]);
    if (value != null) return value;
  }
  final options = obj['options'];
  if (options is Map<String, dynamic>) return _firstString(options, keys);
  return null;
}

String? _configString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    String? envName;
    final envMatch = RegExp(
      r'^(?:\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?|\{env:([A-Za-z_][A-Za-z0-9_]*)\}|env:([A-Za-z_][A-Za-z0-9_]*))$',
    ).firstMatch(trimmed);
    if (envMatch != null) {
      for (final group in envMatch.groups([1, 2, 3])) {
        if (group != null) {
          envName = group;
          break;
        }
      }
    }
    if (envName != null) {
      final envValue = Platform.environment[envName]?.trim();
      return envValue == null || envValue.isEmpty ? null : envValue;
    }
    return trimmed;
  }
  if (value is Map<String, dynamic>) {
    for (final key in const ['env', 'environment', 'name', 'value']) {
      final nested = _configString(value[key]);
      if (nested != null) return nested;
    }
  }
  return null;
}

String _stripBom(String text) =>
    text.startsWith('\ufeff') ? text.substring(1) : text;

String _stripJsonc(String text) {
  var out = _stripBom(text);
  out = out.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  out = out.replaceAllMapped(
    RegExp(r'(^|[^:])//[^\n]*', multiLine: true),
    (m) => m.group(1) ?? '',
  );
  out = out.replaceAllMapped(RegExp(r',(\s*[}\]])'), (m) => m.group(1) ?? '');
  return out;
}

String _two(int value) => value.toString().padLeft(2, '0');
