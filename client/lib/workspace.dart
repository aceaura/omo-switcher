// 本地工作目录（opencode 配置目录）。客户端直接读写本机文件系统，与服务器无关。
// 这是「常用配置」页的数据来源，镜像服务端 server/src 的 config.js / bundle.js /
// presets.js / sync.js 逻辑，但只做 zip 解码（不重新压缩），保证 sha256 与云端一致。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'package:omo_switcher_client/main.dart' show ConfigItem;

// 两个 provider 的文件前缀（镜像 config.js providers）。
const Map<String, String> kProviderPrefixes = {
  'omo': 'oh-my-openagent',
  'omo-slim': 'oh-my-opencode-slim',
};

// 除两个 provider 档位文件外，额外打包进每个 zip 的共享文件（镜像 config.js bundle.sharedFiles）。
const List<String> kSharedFiles = [
  'opencode.jsonc',
  'tui.json',
  'package.json',
  'package-lock.json',
];

class TierMeta {
  const TierMeta(this.index, this.label, this.color);
  final int index;
  final String label;
  final String color;
}

// 档位展示元数据（镜像 config.js tierMeta）。
const Map<String, TierMeta> kTierMeta = {
  'opus-ultra': TierMeta(1, 'OpusMode · Ultra', '#f85149'),
  'opus-high': TierMeta(2, 'OpusMode · High', '#d29922'),
  'opus-medium': TierMeta(3, 'OpusMode · Medium', '#58a6ff'),
  'opus-low': TierMeta(4, 'OpusMode · Low', '#3fb950'),
  'gpt-ultra': TierMeta(5, 'GptMode · Ultra', '#f85149'),
  'gpt-high': TierMeta(6, 'GptMode · High', '#d29922'),
  'gpt-medium': TierMeta(7, 'GptMode · Medium', '#58a6ff'),
  'gpt-low': TierMeta(8, 'GptMode · Low', '#3fb950'),
  'token-saving': TierMeta(101, '省钱 · Token Saving', '#3fb950'),
  'predictable-cost': TierMeta(102, '可预测成本 · Predictable Cost', '#58a6ff'),
  'balanced': TierMeta(103, '均衡 · Balanced', '#d29922'),
  'quality-first': TierMeta(104, '质量优先 · Quality First', '#f85149'),
};

final RegExp _slugRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
const List<String> _requiredDisabledSkills = [
  'security-research',
  'security-review',
];
const Map<String, String> _requiredPackageDeps = {
  'oh-my-opencode-slim': '^1.1.1',
};

bool _isSafeSlug(String slug) => _slugRe.hasMatch(slug);

void _assertSafeSlug(String slug) {
  if (!_isSafeSlug(slug)) throw ArgumentError('非法档位名: $slug');
}

class WorkspaceTier {
  const WorkspaceTier({
    required this.slug,
    required this.index,
    required this.label,
    required this.color,
    required this.files,
  });
  final String slug;
  final int index;
  final String label;
  final String color;
  final List<String> files;
}

class WorkspaceState {
  const WorkspaceState({
    required this.opencodeDir,
    required this.tiers,
    required this.active,
  });
  final String opencodeDir;
  final List<WorkspaceTier> tiers;
  // key: 'omo' / 'omo-slim' / 'shared' -> 当前生效档位 slug（或 null）
  final Map<String, String?> active;
}

// 解析本机 opencode 目录：OPENCODE_DIR 优先，否则 <home>/.config/opencode。
Directory defaultOpencodeDirectory({
  Map<String, String>? environment,
  String? operatingSystem,
  String? pathSeparator,
}) {
  final env = environment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;
  final sep = pathSeparator ?? (os == 'windows' ? r'\' : '/');
  final override = env['OPENCODE_DIR'];
  if (override != null && override.isNotEmpty) return Directory(override);
  final home =
      (os == 'windows' ? env['USERPROFILE'] : env['HOME']) ??
      env['USERPROFILE'] ??
      env['HOME'] ??
      Directory.current.path;
  return Directory('$home$sep.config${sep}opencode');
}

class LocalWorkspace {
  LocalWorkspace({Directory? directory}) : _override = directory;

  final Directory? _override;

  Directory resolveDir() => _override ?? defaultOpencodeDirectory();
  String get path => resolveDir().path;

  String _join(String name) =>
      '${resolveDir().path}${Platform.pathSeparator}$name';

  // 列出工作目录中的全部档位包（不含 zip 内容，sha256 取原始 zip 字节）。
  Future<List<ConfigItem>> listBundles() async {
    final dir = resolveDir();
    if (!dir.existsSync()) return const [];
    final items = <ConfigItem>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.zip')) continue;
      final slug = name.substring(0, name.length - 4);
      if (!_isSafeSlug(slug)) continue;
      final bytes = entity.readAsBytesSync();
      final meta = kTierMeta[slug];
      items.add(
        ConfigItem(
          key: slug,
          label: meta?.label ?? slug,
          sha256: sha256.convert(bytes).toString(),
          size: bytes.length,
          provider: 'bundle',
          tierSlug: slug,
          tierIndex: meta?.index ?? 999,
          files: _memberNames(slug, bytes),
        ),
      );
    }
    items.sort((a, b) {
      final byIndex = (a.tierIndex ?? 999).compareTo(b.tierIndex ?? 999);
      if (byIndex != 0) return byIndex;
      return a.key.compareTo(b.key);
    });
    return items;
  }

  // 读取某档位 zip 的原始字节 -> base64（用于上传云端 / 存入本地仓库）。
  // 用同步 IO：文件很小，且在 widget test 的 fake-async 区里异步 IO 不会推进。
  Future<String> readBundleB64(String slug) async {
    _assertSafeSlug(slug);
    return base64Encode(File(_join('$slug.zip')).readAsBytesSync());
  }

  // 把 zip 字节写入 <slug>.zip（云端/本地仓库 -> 工作目录）。
  Future<void> writeBundle(String slug, String contentB64) async {
    _assertSafeSlug(slug);
    final dir = resolveDir();
    dir.createSync(recursive: true);
    File(_join('$slug.zip')).writeAsBytesSync(base64Decode(contentB64));
  }

  Future<List<String>> deleteBundles(List<String> slugs) async {
    final deleted = <String>[];
    for (final slug in slugs.toSet()) {
      _assertSafeSlug(slug);
      final file = File(_join('$slug.zip'));
      if (!file.existsSync()) continue;
      file.deleteSync();
      deleted.add(slug);
    }
    return deleted;
  }

  Future<void> renameBundle(String oldSlug, String newSlug) async {
    _assertSafeSlug(oldSlug);
    _assertSafeSlug(newSlug);
    final oldFile = File(_join('$oldSlug.zip'));
    final newFile = File(_join('$newSlug.zip'));
    if (!oldFile.existsSync()) throw Exception('档位 zip 不存在: $oldSlug.zip');
    if (newFile.existsSync()) throw Exception('目标档位已存在: $newSlug.zip');
    oldFile.renameSync(newFile.path);
  }

  // 汇总状态：tiers（按 index 排序）+ 当前生效档位（按 base 文件字节比对）。
  Future<WorkspaceState> getState() async {
    final dir = resolveDir();
    final tiers = <WorkspaceTier>[];
    // slug -> {归一化成员名: 内容}，供 active 检测。
    final bundleEntries = <String, Map<String, List<int>>>{};
    if (dir.existsSync()) {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.zip')) continue;
        final slug = name.substring(0, name.length - 4);
        if (!_isSafeSlug(slug)) continue;
        final entries = _extractEntries(slug, entity.readAsBytesSync());
        bundleEntries[slug] = entries;
        final meta = kTierMeta[slug];
        tiers.add(
          WorkspaceTier(
            slug: slug,
            index: meta?.index ?? 999,
            label: meta?.label ?? slug,
            color: meta?.color ?? '#8b949e',
            files: entries.keys.toList()..sort(),
          ),
        );
      }
    }
    tiers.sort((a, b) {
      final byIndex = a.index.compareTo(b.index);
      if (byIndex != 0) return byIndex;
      return a.slug.compareTo(b.slug);
    });

    final active = <String, String?>{};
    for (final entry in kProviderPrefixes.entries) {
      active[entry.key] = _detectActive(dir, entry.value, bundleEntries);
    }
    final distinct = active.values.toSet();
    active['shared'] = distinct.length == 1 ? distinct.first : null;

    return WorkspaceState(opencodeDir: dir.path, tiers: tiers, active: active);
  }

  // 应用档位（本地 switch）：解出 <slug>.zip 的成员，写入工作目录。返回写入日志。
  Future<List<String>> applyTier(String slug) async {
    _assertSafeSlug(slug);
    final file = File(_join('$slug.zip'));
    if (!file.existsSync()) throw Exception('档位 zip 不存在: $slug.zip');
    final entries = _extractEntries(slug, file.readAsBytesSync());
    if (entries.isEmpty) throw Exception('档位 "$slug" 没有可应用的文件');
    final dir = resolveDir();
    dir.createSync(recursive: true);
    final log = <String>[];
    final names = entries.keys.toList()..sort();
    for (final name in names) {
      File(_join(name)).writeAsBytesSync(entries[name]!);
      log.add('写入 $name');
    }
    return log;
  }

  // ---- 内部 ----

  // zip 成员名清单（归一化 + 去重 + 排序），镜像 bundle.js readZipMetadata。
  List<String> _memberNames(String slug, List<int> bytes) {
    final names = <String>{};
    for (final file in ZipDecoder().decodeBytes(bytes)) {
      if (!file.isFile) continue;
      names.add(_normalizeBundleName(slug, file.name) ?? file.name);
    }
    return names.toList()..sort();
  }

  // 解出 zip 成员（归一化名 -> 内容），跳过不在白名单的条目。
  Map<String, List<int>> _extractEntries(String slug, List<int> bytes) {
    final out = <String, List<int>>{};
    for (final file in ZipDecoder().decodeBytes(bytes)) {
      if (!file.isFile) continue;
      final normalized = _normalizeBundleName(slug, file.name);
      if (normalized == null) continue;
      out[normalized] = _normalizeMemberContent(normalized, file.content);
    }
    return out;
  }

  // 镜像 bundle.js normalizeBundleName：把 <prefix>.<n>-<slug>.json 视作 <prefix>.json。
  String? _normalizeBundleName(String slug, String name) {
    if (kSharedFiles.contains(name)) return name;
    for (final prefix in kProviderPrefixes.values) {
      if (name == '$prefix.json') return name;
      final safePrefix = RegExp.escape(prefix);
      final safeSlug = RegExp.escape(slug);
      if (RegExp('^$safePrefix\\.\\d+-$safeSlug\\.json\$').hasMatch(name)) {
        return '$prefix.json';
      }
    }
    return null;
  }

  List<int> _normalizeMemberContent(String name, List<int> content) {
    try {
      if (name == '${kProviderPrefixes['omo']}.json') {
        return _normalizeOmoConfig(content);
      }
      if (name == 'package.json') return _normalizePackageJson(content);
    } catch (_) {
      return content;
    }
    return content;
  }

  List<int> _normalizeOmoConfig(List<int> content) {
    final parsed = _decodeJson(content);
    final obj = parsed.obj;
    final current = obj['disabled_skills'] is List
        ? List<Object?>.from(obj['disabled_skills'] as List)
        : <Object?>[];
    final merged = [...current];
    for (final skill in _requiredDisabledSkills) {
      if (!merged.contains(skill)) merged.add(skill);
    }
    if (obj['disabled_skills'] is List && merged.length == current.length) {
      return content;
    }
    obj['disabled_skills'] = merged;
    final ordered = <String, Object?>{};
    if (obj.containsKey(r'$schema')) {
      for (final entry in obj.entries) {
        if (entry.key == 'disabled_skills') continue;
        ordered[entry.key] = entry.value;
        if (entry.key == r'$schema') ordered['disabled_skills'] = merged;
      }
    } else {
      ordered['disabled_skills'] = merged;
      for (final entry in obj.entries) {
        if (entry.key != 'disabled_skills') ordered[entry.key] = entry.value;
      }
    }
    return _encodeJson(ordered, parsed.hadBom);
  }

  List<int> _normalizePackageJson(List<int> content) {
    final parsed = _decodeJson(content);
    final obj = parsed.obj;
    final deps = obj['dependencies'] is Map
        ? Map<String, Object?>.from(obj['dependencies'] as Map)
        : <String, Object?>{};
    var changed = false;
    for (final entry in _requiredPackageDeps.entries) {
      if (!deps.containsKey(entry.key) || deps[entry.key] == null) {
        deps[entry.key] = entry.value;
        changed = true;
      }
    }
    if (!changed) return content;
    obj['dependencies'] = deps;
    return _encodeJson(obj, parsed.hadBom);
  }

  ({Map<String, dynamic> obj, bool hadBom}) _decodeJson(List<int> content) {
    var text = utf8.decode(content);
    final hadBom = text.startsWith('\ufeff');
    if (hadBom) text = text.substring(1);
    return (obj: jsonDecode(text) as Map<String, dynamic>, hadBom: hadBom);
  }

  List<int> _encodeJson(Map<String, Object?> obj, bool hadBom) {
    final prefix = hadBom ? '\ufeff' : '';
    return utf8.encode(
      '$prefix${const JsonEncoder.withIndent('  ').convert(obj)}\n',
    );
  }

  // 镜像 presets.js detectActive：读 base 文件 <prefix>.json，与各 zip 同名成员字节比对。
  String? _detectActive(
    Directory dir,
    String prefix,
    Map<String, Map<String, List<int>>> bundleEntries,
  ) {
    final baseFile = File('${dir.path}${Platform.pathSeparator}$prefix.json');
    if (!baseFile.existsSync()) return null;
    final baseBytes = _normalizeMemberContent(
      '$prefix.json',
      baseFile.readAsBytesSync(),
    );
    for (final entry in bundleEntries.entries) {
      final member = entry.value['$prefix.json'];
      if (member != null && _bytesEqual(member, baseBytes)) return entry.key;
    }
    return null;
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
