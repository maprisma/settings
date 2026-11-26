/// Online monochrome icon gallery (Iconify SVG packs on cdn.jsdelivr.net).
///
/// Packs are fetched via `curl` (or an injectable fetcher in tests), cached atomically under
/// `$XDG_CACHE_HOME/maprisma-settings/icon-gallery/<pack>.json` for [galleryCacheTtl], and
/// validated icon-by-icon through [svgProblem] before ever being returned or applied.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar_cosmic.dart' show atomicWrite;
import 'context.dart';
import 'icons.dart' show maxIconBytes, svgProblem;
import 'paths.dart' show appFolder;
import 'translations.dart';

/// How long a cached icon pack counts as fresh before refreshing from the CDN.
const galleryCacheTtl = Duration(days: 7);

/// Maximum accepted pack JSON size (6 MiB).
const galleryMaxBytes = 6 * 1024 * 1024;

/// Default number of choices returned by `icons.gallery`.
const defaultGalleryLimit = 160;

/// Valid icon / alias slug in an Iconify pack.
final iconSlugPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,120}$');

/// Injectable pack fetcher for offline tests: returns the raw JSON body, or null on failure.
typedef GalleryFetcher = Future<String?> Function(String url);

/// Metadata for a supported open-source monochrome Iconify icon pack.
final class IconPack {
  const IconPack({
    required this.id,
    required this.name,
    required this.license,
    required this.url,
  });

  final String id;
  final String name;
  final String license;
  final String url;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'license': license};
}

/// Allowlisted open-source monochrome Iconify SVG packs.
const List<IconPack> galleryPacks = [
  IconPack(
    id: 'lucide',
    name: 'Lucide',
    license: 'ISC',
    url: 'https://cdn.jsdelivr.net/npm/@iconify-json/lucide/icons.json',
  ),
  IconPack(
    id: 'tabler',
    name: 'Tabler',
    license: 'MIT',
    url: 'https://cdn.jsdelivr.net/npm/@iconify-json/tabler/icons.json',
  ),
  IconPack(
    id: 'mdi',
    name: 'Material Design',
    license: 'Apache-2.0',
    url: 'https://cdn.jsdelivr.net/npm/@iconify-json/mdi/icons.json',
  ),
  IconPack(
    id: 'bi',
    name: 'Bootstrap',
    license: 'MIT',
    url: 'https://cdn.jsdelivr.net/npm/@iconify-json/bi/icons.json',
  ),
];

/// Looks up a pack by id in [galleryPacks], or null if not allowlisted.
IconPack? findGalleryPack(String id) {
  for (final pack in galleryPacks) {
    if (pack.id == id) return pack;
  }
  return null;
}

/// Parses `'gallery:<pack>:<name>'`, strictly validating that `<pack>` is in [galleryPacks]
/// and `<name>` matches [iconSlugPattern]. Returns null otherwise.
({String pack, String name})? parseGalleryId(String value) {
  if (!value.startsWith('gallery:')) return null;
  final parts = value.substring('gallery:'.length).split(':');
  if (parts.length != 2) return null;
  final pack = parts[0];
  final name = parts[1];
  if (findGalleryPack(pack) == null) return null;
  if (!iconSlugPattern.hasMatch(name)) return null;
  return (pack: pack, name: name);
}

/// Curated bar-friendly keywords shown first when the gallery search query is empty.
const List<String> _curatedBarKeywords = [
  'wifi',
  'bluetooth',
  'volume',
  'bell',
  'sun',
  'moon',
  'lightbulb',
  'lamp',
  'power',
  'settings',
  'sliders',
  'monitor',
  'display',
  'mail',
  'mic',
  'headphones',
  'speaker',
  'cpu',
  'activity',
  'shield',
  'home',
  'terminal',
  'layout',
  'grid',
  'sparkles',
  'star',
  'flame',
  'zap',
  'globe',
  'music',
  'music-2',
  'radio',
  'clipboard',
  'video',
  'languages',
  'cloud',
  'battery',
  'lock',
  'eye',
  'search',
  'rocket',
  'compass',
  'palette',
  'brush',
  'wrench',
];

final Map<String, int> _curatedExactOrder = {
  for (var i = 0; i < _curatedBarKeywords.length; i++) _curatedBarKeywords[i]: i,
};
final Set<String> _curatedKeywordSet = _curatedBarKeywords.toSet();

String _fmtDim(num v) => v == v.truncateToDouble() ? '${v.toInt()}' : '$v';

num _numOr(Object? value, num fallback) => value is num && value.isFinite ? value : fallback;

/// Builds a symbolic SVG compatible with KDE Breeze (`ColorScheme-Text`), GTK/COSMIC symbolic,
/// `maprisma-shell`, and `flutter_svg`, returning null if it fails [svgProblem] or [maxIconBytes].
String? buildGallerySvg({
  required String body,
  num left = 0,
  num top = 0,
  num width = 24,
  num height = 24,
}) {
  if (body.trim().isEmpty) return null;
  if (!left.isFinite || !top.isFinite || !width.isFinite || !height.isFinite) return null;
  if (width <= 0 || height <= 0) return null;
  final svg =
      '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" '
      'viewBox="${_fmtDim(left)} ${_fmtDim(top)} ${_fmtDim(width)} ${_fmtDim(height)}">'
      '<defs><style type="text/css" id="current-color-scheme">.ColorScheme-Text { color:#232629; }</style></defs>'
      '<g class="ColorScheme-Text" color="#232629">$body</g></svg>';
  final bytes = utf8.encode(svg);
  if (bytes.length > maxIconBytes || svgProblem(bytes) != null) return null;
  return svg;
}

final class _RawIcon {
  const _RawIcon(this.body, this.left, this.top, this.width, this.height);
  final String body;
  final num left;
  final num top;
  final num width;
  final num height;
}

/// Decoded, searchable Iconify pack index.
///
/// SVGs are built and validated through [svgProblem] on demand (and cached) when checking or
/// returning icons so large packs (e.g. 7 000+ MDI icons) stay fast while never emitting an
/// unvalidated SVG.
final class _PackIndex {
  _PackIndex._(this._raw, this._aliases, this._defaultOrder);

  final Map<String, _RawIcon> _raw;
  final Map<String, String> _aliases;
  final List<String> _defaultOrder;
  final Map<String, String?> _validated = {};

  static _PackIndex? parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final rawIcons = decoded['icons'];
    if (rawIcons is! Map) return null;

    final defaultLeft = _numOr(decoded['left'], 0);
    final defaultTop = _numOr(decoded['top'], 0);
    final defaultWidth = _numOr(decoded['width'], 24);
    final defaultHeight = _numOr(decoded['height'], 24);

    final icons = <String, _RawIcon>{};
    for (final entry in rawIcons.entries) {
      final name = entry.key;
      final value = entry.value;
      if (name is! String || !iconSlugPattern.hasMatch(name) || value is! Map) continue;
      final body = value['body'];
      if (body is! String || body.trim().isEmpty) continue;
      final left = _numOr(value['left'], defaultLeft);
      final top = _numOr(value['top'], defaultTop);
      final width = _numOr(value['width'], defaultWidth);
      final height = _numOr(value['height'], defaultHeight);
      if (width <= 0 || height <= 0) continue;
      icons[name] = _RawIcon(body, left, top, width, height);
    }

    final aliases = <String, String>{};
    final rawAliases = decoded['aliases'];
    if (rawAliases is Map) {
      final direct = <String, String>{};
      for (final entry in rawAliases.entries) {
        final alias = entry.key;
        final value = entry.value;
        if (alias is! String || !iconSlugPattern.hasMatch(alias) || value is! Map) continue;
        final parent = value['parent'];
        if (parent is String && iconSlugPattern.hasMatch(parent)) {
          direct[alias] = parent;
        }
      }
      for (final alias in direct.keys) {
        if (icons.containsKey(alias)) continue;
        var target = direct[alias];
        var depth = 0;
        while (target != null && !icons.containsKey(target) && depth < 5) {
          target = direct[target];
          depth++;
        }
        if (target != null && icons.containsKey(target)) {
          aliases[alias] = target;
        }
      }
    }

    final exact = <String>[];
    final curatedRelated = <String>[];
    final rest = <String>[];
    for (final name in icons.keys) {
      if (_curatedExactOrder.containsKey(name)) {
        exact.add(name);
      } else if (name.split('-').any(_curatedKeywordSet.contains)) {
        curatedRelated.add(name);
      } else {
        rest.add(name);
      }
    }
    exact.sort((a, b) => _curatedExactOrder[a]!.compareTo(_curatedExactOrder[b]!));
    curatedRelated.sort();
    rest.sort();

    return _PackIndex._(icons, aliases, [...exact, ...curatedRelated, ...rest]);
  }

  /// Validates and returns the safe SVG for [name] (or canonical parent if [name] is an alias).
  String? svgFor(String name) {
    final canonical = _raw.containsKey(name) ? name : _aliases[name];
    if (canonical == null) return null;
    if (_validated.containsKey(canonical)) return _validated[canonical];
    final raw = _raw[canonical]!;
    final svg = buildGallerySvg(
      body: raw.body,
      left: raw.left,
      top: raw.top,
      width: raw.width,
      height: raw.height,
    );
    _validated[canonical] = svg;
    return svg;
  }

  /// Searches icons and aliases (deduplicated by canonical name), returning ordered candidates.
  List<String> _rankCandidates(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return _defaultOrder;

    final words = q.split(RegExp(r'[\s_-]+')).where((w) => w.isNotEmpty).toList();
    final qSlug = words.join('-');

    int? score(String name) {
      if (name == q || (qSlug.isNotEmpty && name == qSlug)) return 0;
      if (name.startsWith(q) || (qSlug.isNotEmpty && name.startsWith(qSlug))) return 1;
      if (words.isNotEmpty) {
        final segs = name.split('-');
        if (words.every(segs.contains)) return 2;
        if (words.every((w) => segs.any((s) => s.startsWith(w)))) return 3;
      }
      if (name.contains(q) ||
          (qSlug.isNotEmpty && name.contains(qSlug)) ||
          (words.isNotEmpty && words.every(name.contains))) {
        return 4;
      }
      return null;
    }

    final best = <String, ({int tier, bool viaAlias})>{};
    for (final name in _raw.keys) {
      final s = score(name);
      if (s != null) best[name] = (tier: s, viaAlias: false);
    }
    for (final entry in _aliases.entries) {
      final s = score(entry.key);
      if (s == null) continue;
      final parent = entry.value;
      final prev = best[parent];
      if (prev == null || s < prev.tier) {
        best[parent] = (tier: s, viaAlias: true);
      }
    }

    final ranked = best.entries.toList()
      ..sort((a, b) {
        final t = a.value.tier.compareTo(b.value.tier);
        if (t != 0) return t;
        final al = (a.value.viaAlias ? 1 : 0).compareTo(b.value.viaAlias ? 1 : 0);
        if (al != 0) return al;
        final l = a.key.length.compareTo(b.key.length);
        if (l != 0) return l;
        return a.key.compareTo(b.key);
      });
    return [for (final e in ranked) e.key];
  }

  /// Returns validated matches (up to [limit]) and the accurate validated total.
  ({List<({String name, String svg})> items, int total}) search(String query, int limit) {
    final candidates = _rankCandidates(query);
    final items = <({String name, String svg})>[];
    var total = 0;
    for (final name in candidates) {
      final svg = svgFor(name);
      if (svg == null) continue;
      total++;
      if (items.length < limit) {
        items.add((name: name, svg: svg));
      }
    }
    return (items: items, total: total);
  }
}

final class _CachedPack {
  _CachedPack(this.index, {required this.fetchedAt, required this.diskMtime});
  final _PackIndex index;
  final DateTime fetchedAt;
  final DateTime diskMtime;
}

/// Fetches, caches, searches, and renders monochrome Iconify packs.
final class IconGallery {
  IconGallery(this.ctx, {this.fetch});

  final Ctx ctx;

  /// Optional fetcher override (for offline tests).
  GalleryFetcher? fetch;

  final Map<String, _CachedPack> _memory = {};

  String cacheFile(String packId) => p.join(ctx.paths.cache, appFolder, 'icon-gallery', '$packId.json');

  Future<({String? text, String? error})> _download(IconPack pack) async {
    final custom = fetch;
    if (custom != null) {
      try {
        final body = await custom(pack.url);
        if (body == null || body.isEmpty) return (text: null, error: tr('could not download icon pack'));
        return (text: body, error: null);
      } on Object catch (e) {
        return (text: null, error: '$e');
      }
    }
    final curl = ctx.runner.which('curl');
    if (curl == null) return (text: null, error: tr('curl is missing'));
    if (ctx.environment['MAPRISMA_MANAGER_OFFLINE'] == '1' && curl == '/usr/bin/curl') {
      return (text: null, error: 'offline (MAPRISMA_MANAGER_OFFLINE)');
    }
    final r = await ctx.runner.run(
      [
        curl,
        '--silent',
        '--show-error',
        '--fail',
        '--proto',
        '=https',
        '--max-redirs',
        '0',
        '--max-time',
        '25',
        '--max-filesize',
        '$galleryMaxBytes',
        '--',
        pack.url,
      ],
      timeout: const Duration(seconds: 30),
    );
    if (!r.ok) {
      final msg = r.stderr
          .trim()
          .split('\n')
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => tr('could not download icon pack'));
      return (text: null, error: msg);
    }
    return (text: r.stdout, error: null);
  }

  ({_PackIndex index, DateTime mtime})? _readDiskCache(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file || stat.size > galleryMaxBytes) return null;
      final index = _PackIndex.parse(file.readAsStringSync());
      if (index == null) return null;
      return (index: index, mtime: stat.modified);
    } on Object {
      return null;
    }
  }

  Future<({_PackIndex? index, bool cached, bool offline, String? error})> _loadPack(
    IconPack pack, {
    bool refresh = false,
  }) async {
    final path = cacheFile(pack.id);
    final now = ctx.clock();
    final file = File(path);
    FileStat? diskStat;
    try {
      final st = file.statSync();
      if (st.type == FileSystemEntityType.file) diskStat = st;
    } on FileSystemException {
      diskStat = null;
    }

    final mem = _memory[pack.id];
    ({_PackIndex index, DateTime mtime})? disk;

    if (diskStat != null) {
      if (mem != null && diskStat.modified == mem.diskMtime) {
        disk = (index: mem.index, mtime: mem.diskMtime);
        if (!refresh && now.difference(mem.fetchedAt) < galleryCacheTtl) {
          return (index: mem.index, cached: true, offline: false, error: null);
        }
      } else {
        disk = _readDiskCache(path);
        if (!refresh && disk != null && now.difference(disk.mtime) < galleryCacheTtl) {
          _memory[pack.id] = _CachedPack(disk.index, fetchedAt: disk.mtime, diskMtime: disk.mtime);
          return (index: disk.index, cached: true, offline: false, error: null);
        }
      }
    } else if (mem != null) {
      _memory.remove(pack.id);
    }

    final fetched = await _download(pack);
    if (fetched.text != null) {
      final text = fetched.text!;
      if (utf8.encode(text).length <= galleryMaxBytes) {
        final parsed = _PackIndex.parse(text);
        if (parsed != null) {
          atomicWrite(path, text);
          final mtime = File(path).statSync().modified;
          _memory[pack.id] = _CachedPack(parsed, fetchedAt: now, diskMtime: mtime);
          return (index: parsed, cached: false, offline: false, error: null);
        }
      }
      final err = tr('invalid icon pack data');
      if (disk != null) return (index: disk.index, cached: true, offline: true, error: err);
      return (index: null, cached: false, offline: true, error: err);
    }

    final err = fetched.error ?? tr('could not download icon pack');
    if (disk != null) return (index: disk.index, cached: true, offline: true, error: err);
    return (index: null, cached: false, offline: true, error: err);
  }

  /// Queries [pack] for icons matching [query] (up to [limit] choices).
  Future<Map<String, dynamic>> query(
    IconPack pack, {
    String query = '',
    int limit = defaultGalleryLimit,
    bool refresh = false,
  }) async {
    final loaded = await _loadPack(pack, refresh: refresh);
    final packsJson = [for (final pk in galleryPacks) pk.toJson()];
    if (loaded.index == null) {
      return {
        'pack': pack.id,
        'packs': packsJson,
        'query': query,
        'total': 0,
        'truncated': false,
        'cached': false,
        'offline': true,
        if (loaded.error != null) 'error': loaded.error,
        'choices': <Map<String, dynamic>>[],
      };
    }
    final found = loaded.index!.search(query, limit);
    return {
      'pack': pack.id,
      'packs': packsJson,
      'query': query,
      'total': found.total,
      'truncated': found.total > limit,
      'cached': loaded.cached,
      'offline': loaded.offline,
      if (loaded.error != null) 'error': loaded.error,
      'choices': [
        for (final item in found.items)
          {
            'id': 'gallery:${pack.id}:${item.name}',
            'pack': pack.id,
            'name': item.name,
            'svg': item.svg,
          },
      ],
    };
  }

  /// Loads a single validated SVG for [packId]:[name], or null if missing/unavailable.
  Future<({String? svg, String? error, bool packLoaded})> iconSvg(String packId, String name) async {
    final pack = findGalleryPack(packId);
    if (pack == null || !iconSlugPattern.hasMatch(name)) {
      return (svg: null, error: null, packLoaded: false);
    }
    final loaded = await _loadPack(pack);
    if (loaded.index == null) {
      return (svg: null, error: loaded.error, packLoaded: false);
    }
    return (svg: loaded.index!.svgFor(name), error: null, packLoaded: true);
  }
}
