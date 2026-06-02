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
      home: OmoSwitcherHome(api: api, store: store),
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
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    final decoded = text.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(text) as Map<String, dynamic>;
    if (response.statusCode >= 400 && decoded['ok'] == null)
      decoded['ok'] = false;
    return decoded;
  }
}

class FileLocalStore implements LocalStore {
  FileLocalStore({Directory? directory})
    : _directory = directory ?? _defaultDirectory();

  final Directory _directory;
  String get directoryPath => _directory.path;

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
  Future<void> upsertItem(ConfigItem item, String source) async {
    final items = await listItems();
    final next = [
      for (final existing in items)
        if (existing.key != item.key) existing,
      item.copyWith(source: source),
    ];
    await _writeJson(_itemsFile, {
      'items': next.map((item) => item.toStoreJson()).toList(),
    });
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
  String workspacePath = '工作目录: ?';
  String localPath = '';
  String connectionStatus = '未连接';
  String selectedTier = '';
  String selectedSnapshot = '';
  String switchLog = '';
  String restartDesktopLog = '';
  String restartTuiLog = '';
  String localLog = '';
  int tabIndex = 0;
  List<Tier> tiers = [];
  List<ConfigItem> workspaceItems = [];
  List<ConfigItem> localItems = [];
  List<ConfigItem> remoteItems = [];
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
    if (widget.store is FileLocalStore)
      localPath = (widget.store as FileLocalStore).directoryPath;
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
    await Future.wait([_refreshState(), _reloadSync()]);
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
      final result = await widget.api.state(serverUrl);
      if (result['ok'] == false) return;
      final nextTiers = (result['tiers'] as List<dynamic>? ?? [])
          .map((item) => Tier.fromJson(item as Map<String, dynamic>))
          .where((tier) => tier.shared)
          .toList();
      setState(() {
        tiers = nextTiers;
        selectedTier = result['active'] is Map<String, dynamic>
            ? ((result['active'] as Map<String, dynamic>)['shared']
                      as String? ??
                  selectedTier)
            : selectedTier;
        if (selectedTier.isEmpty && tiers.isNotEmpty)
          selectedTier = tiers.first.slug;
        workspacePath = '工作目录: ${result['opencodeDir'] ?? '?'}';
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
        diff = DiffResult.fromJson(
          diffResponse['diff'] as Map<String, dynamic>? ?? const {},
        );
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

  Future<void> _applyTier() async {
    if (selectedTier.isEmpty) return;
    final confirmed = await _confirm(
      '应用档位',
      '将把 omo 与 omo-slim 同时切换到「$selectedTier」。',
    );
    if (!confirmed) return;
    final result = await widget.api.switchTier(serverUrl, selectedTier);
    setState(
      () => switchLog = result['ok'] == false
          ? '切换失败: ${_messageFor(result)}'
          : _logText(result),
    );
    await _refreshState();
  }

  Future<void> _restartDesktop() async {
    final result = await widget.api.restart(serverUrl);
    setState(
      () => restartDesktopLog = result['ok'] == false
          ? '重启失败: ${_messageFor(result)}'
          : _logText(result),
    );
  }

  Future<void> _restartTui() async {
    final result = await widget.api.restart(serverUrl, launchCmd: 'opencode');
    setState(
      () => restartTuiLog = result['ok'] == false
          ? '重启失败: ${_messageFor(result)}'
          : _logText(result),
    );
  }

  Future<void> _syncCloudToWorkspace() async {
    final keys = _defaultKeys(selectedRemote, remoteItems);
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
        await widget.api.writeWorkspaceItem(
          serverUrl,
          key,
          result['contentB64'] as String,
        );
      }
    }
    _notice('已同步 ${keys.length} 项到工作目录');
    await _refreshAll();
  }

  Future<void> _pushWorkspaceToRemote() async {
    final keys = _defaultKeys(selectedWorkspace, workspaceItems);
    if (keys.isEmpty) return _notice('工作目录没有可上传的配置项');
    final confirmed = await _confirm(
      '同步到云端仓库',
      '将把工作目录中 ${keys.length} 个档位包上传到云端仓库。\n${keys.join('\n')}',
    );
    if (!confirmed) return;
    final items = <ConfigItem>[];
    for (final key in keys) {
      final result = await widget.api.configItem(serverUrl, key, fs: true);
      items.add(ConfigItem.fromJson(result));
    }
    final result = await widget.api.pushConfig(
      serverUrl,
      items,
      'workspace push',
    );
    setState(
      () => restartDesktopLog = result['ok'] == false
          ? '同步到云端仓库失败: ${_messageFor(result)}'
          : '已同步到云端仓库: ${result['snapshotId']}',
    );
    await _refreshAll();
  }

  Future<void> _downloadWorkspaceToLocal() async {
    final keys = _defaultKeys(selectedWorkspace, workspaceItems);
    if (keys.isEmpty) return _notice('工作目录没有可下载的配置项');
    for (final key in keys) {
      final result = await widget.api.configItem(serverUrl, key, fs: true);
      await widget.store.upsertItem(ConfigItem.fromJson(result), 'local-scan');
    }
    setState(() => localLog = '已同步 ${keys.length} 项到本地仓库');
    await _reloadSync();
  }

  Future<void> _uploadLocalToWorkspace() async {
    final keys = _defaultKeys(selectedLocal, localItems);
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
      final result = await widget.api.writeWorkspaceItem(
        serverUrl,
        key,
        item.contentB64!,
      );
      if (result['ok'] == false) failed.add('$key: ${_messageFor(result)}');
      if (result['ok'] != false) exported++;
    }
    setState(
      () => localLog =
          '已上传 $exported 项到工作目录${failed.isEmpty ? '' : '\n失败: ${failed.join('\n')}'}',
    );
    await _refreshAll();
  }

  Future<void> _pullRemoteToLocal() async {
    final keys = _defaultKeys(selectedRemote, remoteItems);
    if (keys.isEmpty) return _notice('云端仓库没有可同步的配置项');
    for (final key in keys) {
      final result = await widget.api.configItem(
        serverUrl,
        key,
        snapshot: selectedSnapshot.isEmpty ? null : selectedSnapshot,
      );
      await widget.store.upsertItem(ConfigItem.fromJson(result), 'pulled');
    }
    setState(() => localLog = '已从云端仓库同步 ${keys.length} 项到本地仓库');
    await _reloadSync();
  }

  Future<void> _pushLocalToRemote() async {
    final keys = _defaultKeys(selectedLocal, localItems);
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

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _ConfigPage(
        path: workspacePath,
        tiers: tiers,
        selectedTier: selectedTier,
        switchLog: switchLog,
        restartDesktopLog: restartDesktopLog,
        restartTuiLog: restartTuiLog,
        onTierChanged: (value) => setState(() => selectedTier = value),
        onApplyTier: _applyTier,
        onRestartDesktop: _restartDesktop,
        onRestartTui: _restartTui,
      ),
      _WorkspaceSyncPage(
        path: workspacePath,
        items: workspaceItems,
        diff: workspaceDiff,
        selected: selectedWorkspace,
        onSelectedChanged: (key, checked) => setState(
          () => checked
              ? selectedWorkspace.add(key)
              : selectedWorkspace.remove(key),
        ),
        onSyncToLocal: _downloadWorkspaceToLocal,
        onSyncToRemote: _pushWorkspaceToRemote,
      ),
      _LocalPage(
        path: localPath,
        items: localItems,
        diff: diff,
        selected: selectedLocal,
        log: localLog,
        onSelectedChanged: (key, checked) => setState(
          () => checked ? selectedLocal.add(key) : selectedLocal.remove(key),
        ),
        onUploadWorkspace: _uploadLocalToWorkspace,
        onPushRemote: _pushLocalToRemote,
      ),
      _RemotePage(
        serverUrl: serverUrl,
        connectionStatus: connectionStatus,
        serverUrlController: serverUrlController,
        onTestConnection: _connectServer,
        items: remoteItems,
        diff: diff,
        selected: selectedRemote,
        onSelectedChanged: (key, checked) => setState(
          () => checked ? selectedRemote.add(key) : selectedRemote.remove(key),
        ),
        onSyncToWorkspace: _syncCloudToWorkspace,
        onSyncToLocal: _pullRemoteToLocal,
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
                icon: Icon(Icons.cloud_outlined),
                label: Text('云端仓库'),
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
    required this.switchLog,
    required this.restartDesktopLog,
    required this.restartTuiLog,
    required this.onTierChanged,
    required this.onApplyTier,
    required this.onRestartDesktop,
    required this.onRestartTui,
  });

  final String path;
  final List<Tier> tiers;
  final String selectedTier;
  final String switchLog;
  final String restartDesktopLog;
  final String restartTuiLog;
  final ValueChanged<String> onTierChanged;
  final VoidCallback onApplyTier;
  final VoidCallback onRestartDesktop;
  final VoidCallback onRestartTui;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '当前配置',
      count: '${tiers.length} 档',
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
          ],
        ),
        _LogBox(text: switchLog),
        _LogBox(text: restartDesktopLog),
        _LogBox(text: restartTuiLog),
      ],
    );
  }
}

class _WorkspaceSyncPage extends StatelessWidget {
  const _WorkspaceSyncPage({
    required this.path,
    required this.items,
    required this.diff,
    required this.selected,
    required this.onSelectedChanged,
    required this.onSyncToLocal,
    required this.onSyncToRemote,
  });

  final String path;
  final List<ConfigItem> items;
  final DiffResult diff;
  final Set<String> selected;
  final void Function(String key, bool checked) onSelectedChanged;
  final VoidCallback onSyncToLocal;
  final VoidCallback onSyncToRemote;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '常用配置',
      count: '${items.length} 项',
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
          ],
        ),
        _ConfigList(
          items: items,
          diff: diff,
          selected: selected,
          onSelectedChanged: onSelectedChanged,
        ),
      ],
    );
  }
}

class _LocalPage extends StatelessWidget {
  const _LocalPage({
    required this.path,
    required this.items,
    required this.diff,
    required this.selected,
    required this.log,
    required this.onSelectedChanged,
    required this.onUploadWorkspace,
    required this.onPushRemote,
  });

  final String path;
  final List<ConfigItem> items;
  final DiffResult diff;
  final Set<String> selected;
  final String log;
  final void Function(String key, bool checked) onSelectedChanged;
  final VoidCallback onUploadWorkspace;
  final VoidCallback onPushRemote;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '本地仓库',
      count: '${items.length} 项',
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
          ],
        ),
        _ConfigList(
          items: items,
          diff: diff,
          selected: selected,
          onSelectedChanged: onSelectedChanged,
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
    required this.diff,
    required this.selected,
    required this.onSelectedChanged,
    required this.onSyncToWorkspace,
    required this.onSyncToLocal,
  });

  final String serverUrl;
  final String connectionStatus;
  final TextEditingController serverUrlController;
  final VoidCallback onTestConnection;
  final List<ConfigItem> items;
  final DiffResult diff;
  final Set<String> selected;
  final void Function(String key, bool checked) onSelectedChanged;
  final VoidCallback onSyncToWorkspace;
  final VoidCallback onSyncToLocal;

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      title: '云端仓库',
      count: '${items.length} 项',
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
          ],
        ),
        _ConfigList(
          items: items,
          diff: diff,
          selected: selected,
          onSelectedChanged: onSelectedChanged,
        ),
      ],
    );
  }
}

class _PageShell extends StatelessWidget {
  const _PageShell({
    required this.title,
    required this.count,
    required this.children,
  });

  final String title;
  final String count;
  final List<Widget> children;

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
          ],
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
    required this.diff,
    required this.selected,
    required this.onSelectedChanged,
  });

  final List<ConfigItem> items;
  final DiffResult diff;
  final Set<String> selected;
  final void Function(String key, bool checked) onSelectedChanged;

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
            CheckboxListTile(
              value: selected.contains(item.key),
              onChanged: (checked) =>
                  onSelectedChanged(item.key, checked ?? false),
              title: Wrap(
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
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(text),
    );
  }
}

class Tier {
  const Tier({
    required this.slug,
    required this.label,
    required this.index,
    required this.shared,
  });

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

class DiffResult {
  const DiffResult({
    this.onlyLocal = const [],
    this.onlyRemote = const [],
    this.changed = const [],
    this.same = const [],
  });

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

  factory DiffResult.compare(
    List<ConfigItem> leftItems,
    List<ConfigItem> rightItems,
  ) {
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
    return DiffResult(
      onlyLocal: onlyLocal,
      onlyRemote: onlyRemote,
      changed: changed,
      same: same,
    );
  }

  String labelFor(String key) {
    if (onlyLocal.contains(key)) return '仅本地';
    if (onlyRemote.contains(key)) return '仅云端';
    if (changed.contains(key)) return '有差异';
    return '';
  }
}

List<ConfigItem> _itemsFrom(Object? items) =>
    (items as List<dynamic>? ?? const [])
        .map((item) => ConfigItem.fromJson(item as Map<String, dynamic>))
        .toList();
List<String> _strings(Object? value) => (value as List<dynamic>? ?? const [])
    .map((item) => item.toString())
    .toList();
List<String> _defaultKeys(Set<String> selected, List<ConfigItem> items) =>
    selected.isNotEmpty
    ? selected.toList()
    : items.map((item) => item.key).toList();
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
String _logText(Map<String, dynamic> result) => result['log'] is List<dynamic>
    ? (result['log'] as List<dynamic>).join('\n')
    : jsonEncode(result);
