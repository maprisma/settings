import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf, uiLabel;
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'app_facts.dart';
import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'theme.dart';

/// Picks another bar icon for an app (`icons.get`, `icons.set`, `icons.reset`): the icon theme's
/// symbolic icons to search, a preview, an SVG file of your own, and Reset. Pops true when it
/// changed something.
class IconPicker extends StatefulWidget {
  const IconPicker({super.key, required this.core, required this.app, this.pickFile});
  final CoreCall core;
  final App app;

  /// Tests replace the file chooser.
  final Future<String?> Function()? pickFile;
  @override
  State<IconPicker> createState() => _IconPickerState();
}

class _IconPickerState extends State<IconPicker> {
  Map<String, dynamic>? info;
  List<Map> choices = [];
  String source = 'theme';
  String query = '';

  String galleryPack = 'lucide';
  List<Map> galleryPacks = const [
    {'id': 'lucide', 'name': 'Lucide', 'license': 'ISC'},
    {'id': 'tabler', 'name': 'Tabler', 'license': 'MIT'},
    {'id': 'mdi', 'name': 'Material Design', 'license': 'Apache-2.0'},
    {'id': 'bi', 'name': 'Bootstrap', 'license': 'MIT'},
  ];
  List<Map> galleryChoices = [];
  int galleryTotal = 0;
  bool galleryTruncated = false;
  bool galleryLoading = false;
  bool galleryLoaded = false;
  bool galleryOffline = false;
  String? galleryError;
  int _gallerySeq = 0;

  String? selected, selectedLabel, selectedSvg, selectedThemeFile, selectedFile, error;
  bool working = false, changed = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _search() async {
    try {
      final r = await widget.core('icons.get', {'app': widget.app['id'], 'query': query, 'limit': 240});
      if (!mounted) return;
      setState(() {
        info = r;
        choices = ((r['choices'] as List?) ?? const []).cast<Map>();
        error = null;
      });
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = e.reason ?? e.code);
    }
  }

  Future<void> _searchGallery({bool refresh = false}) async {
    final seq = ++_gallerySeq;
    if (mounted) {
      setState(() {
        galleryLoading = true;
        galleryError = null;
      });
    }
    try {
      final r = await widget.core('icons.gallery', {
        'pack': galleryPack,
        'query': query,
        'limit': 240,
        if (refresh) 'refresh': true,
      });
      if (!mounted || seq != _gallerySeq) return;
      final packs = (r['packs'] as List?)?.cast<Map>();
      final list = ((r['choices'] as List?) ?? const []).cast<Map>();
      setState(() {
        if (packs != null && packs.isNotEmpty) galleryPacks = packs;
        galleryChoices = list;
        galleryTotal = (r['total'] as num?)?.toInt() ?? list.length;
        galleryTruncated = r['truncated'] == true;
        galleryOffline = r['offline'] == true;
        galleryError = r['error'] as String?;
        galleryLoading = false;
        galleryLoaded = true;
      });
    } on ServiceError catch (e) {
      if (!mounted || seq != _gallerySeq) return;
      setState(() {
        galleryError = e.reason ?? e.code;
        galleryLoading = false;
        galleryLoaded = true;
      });
    }
  }

  void _setSource(String next) {
    if (next == source) return;
    _debounce?.cancel();
    setState(() => source = next);
    if (next == 'gallery') {
      unawaited(_searchGallery());
    } else {
      unawaited(_search());
    }
  }

  void _setGalleryPack(String pack) {
    if (pack == galleryPack && galleryError == null) return;
    _debounce?.cancel();
    setState(() {
      galleryPack = pack;
      galleryError = null;
    });
    unawaited(_searchGallery());
  }

  Future<void> _apply(String icon) async {
    setState(() => working = true);
    try {
      await widget.core('icons.set', {'app': widget.app['id'], 'icon': icon});
      changed = true;
      if (mounted) Navigator.pop(context, true);
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = '${e.code == 'bad_icon' ? tr('Not an icon Maprisma Settings writes') : e.code}: ${e.reason ?? ''}');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _reset() async {
    setState(() => working = true);
    try {
      await widget.core('icons.reset', {'app': widget.app['id']});
      changed = true;
      if (mounted) Navigator.pop(context, true);
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = e.reason ?? e.code);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _pickFile() async {
    final String? path;
    if (widget.pickFile != null) {
      path = await widget.pickFile!();
    } else {
      final f = await openFile(acceptedTypeGroups: [XTypeGroup(label: tr('SVG icons'), extensions: ['svg'], mimeTypes: ['image/svg+xml'])]);
      path = f?.path;
    }
    if (path == null || !mounted) return;
    setState(() {
      selected = null;
      selectedLabel = null;
      selectedSvg = null;
      selectedThemeFile = null;
      selectedFile = path;
    });
  }

  Widget _svg(String? file, double size, {bool fresh = false}) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Icon(Icons.image_not_supported_outlined, size: size, color: scheme.onSurfaceVariant);
    if (file == null || !File(file).existsSync()) return fallback;
    final filter = file.endsWith('-symbolic.svg') ? ColorFilter.mode(scheme.onSurface, BlendMode.srcIn) : null;
    if (fresh) {
      try {
        final bytes = File(file).readAsBytesSync();
        if (bytes.isEmpty) return fallback;
        return SvgPicture.memory(
          bytes,
          width: size,
          height: size,
          colorFilter: filter,
          placeholderBuilder: (_) => SizedBox(width: size, height: size),
        );
      } on FileSystemException {
        return fallback;
      }
    }
    return SvgPicture.file(
      File(file),
      width: size,
      height: size,
      colorFilter: filter,
      placeholderBuilder: (_) => SizedBox(width: size, height: size),
    );
  }

  Widget _svgString(String? svg, double size) {
    final scheme = Theme.of(context).colorScheme;
    if (svg == null || svg.isEmpty) return Icon(Icons.image_not_supported_outlined, size: size, color: scheme.onSurfaceVariant);
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(scheme.onSurface, BlendMode.srcIn),
      placeholderBuilder: (_) => SizedBox(width: size, height: size),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final i = info;
    final changeable = i?['changeable'] == true;
    final pickedThemeFile = selectedThemeFile ??
        (selected == null ? null : choices.where((c) => c['name'] == selected).firstOrNull?['file'] as String?);
    final activePack = galleryPacks.where((p) => p['id'] == galleryPack).firstOrNull;
    final activePackLicense = activePack?['license'] as String?;
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 640;
    final previewSize = narrow ? 32.0 : 40.0;
    final Widget previewNew;
    if (selectedFile != null) {
      previewNew = _svg(selectedFile, previewSize, fresh: true);
    } else if (selectedSvg != null) {
      previewNew = _svgString(selectedSvg, previewSize);
    } else if (pickedThemeFile != null) {
      previewNew = _svg(pickedThemeFile, previewSize);
    } else {
      previewNew = SizedBox(width: previewSize, height: previewSize, child: Icon(Icons.help_outline, color: scheme.outlineVariant));
    }
    return AlertDialog(
      insetPadding: narrow ? const EdgeInsets.symmetric(horizontal: 16, vertical: 16) : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      titlePadding: narrow ? const EdgeInsets.fromLTRB(20, 16, 20, 8) : null,
      contentPadding: narrow ? const EdgeInsets.fromLTRB(20, 8, 20, 8) : null,
      actionsPadding: narrow ? const EdgeInsets.fromLTRB(16, 4, 16, 12) : null,
      title: Text(trf('Bar icon of {0}', [widget.app['name']])),
      content: SizedBox(
        width: narrow ? width - 72 : 560,
        // the grid keeps room on small windows too
        height: (MediaQuery.sizeOf(context).height - (narrow ? 230 : 220)).clamp(320.0, 560.0),
        child: i == null
            ? (error != null ? Text(error!, style: TextStyle(color: scheme.error)) : const Center(child: CircularProgressIndicator()))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Column(children: [
                        _svg(i['file'] as String?, previewSize, fresh: true),
                        const SizedBox(height: 4),
                        Text(i['current'] == 'original' ? tr('now (original)') : tr('now (changed)'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                      SizedBox(width: narrow ? 8 : 12),
                      Icon(Icons.arrow_forward, size: narrow ? 18 : 24, color: scheme.onSurfaceVariant),
                      SizedBox(width: narrow ? 8 : 12),
                      Column(children: [
                        previewNew,
                        const SizedBox(height: 4),
                        Text(tr('new'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                      SizedBox(width: narrow ? 10 : 16),
                      Expanded(
                        child: Text(
                          selectedFile != null ? selectedFile! : (selectedLabel ?? selected ?? tr('Pick an icon below, or a file')),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  if (!changeable)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(trf('It can\'t be changed: {0}', [i['why'] ?? tr('no icon of its own')]), style: TextStyle(color: scheme.error)),
                    ),
                  if (i['note'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          // a long note stays short on narrow windows; the whole text in its tooltip
                          Expanded(
                            child: Tooltip(
                              message: uiLabel(i['note']),
                              child: Text(trf('Note: {0}', [uiLabel(i['note'])]),
                                  maxLines: narrow ? 3 : 5,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: scheme.error))),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: [
                      ButtonSegment<String>(
                        value: 'theme',
                        label: Text(
                          tr('Installed theme'),
                          key: const ValueKey('icon-tab-theme'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      ButtonSegment<String>(
                        value: 'gallery',
                        label: Text(
                          tr('Online gallery'),
                          key: const ValueKey('icon-tab-gallery'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    selected: {source},
                    onSelectionChanged: changeable ? (s) => _setSource(s.first) : null,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('icon-search'),
                    autofocus: true,
                    enabled: changeable,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: source == 'gallery'
                          ? trf('Search {0}\'s icons', [activePack?['name'] ?? galleryPack])
                          : trf('Search {0}\'s icons', [(i['theme'] as Map?)?['name'] ?? tr('the icon theme')]),
                      prefixIcon: const Icon(Icons.search, size: 20),
                    ),
                    onChanged: (v) {
                      query = v;
                      _debounce?.cancel();
                      _debounce = Timer(const Duration(milliseconds: 250), source == 'gallery' ? _searchGallery : _search);
                    },
                  ),
                  if (source == 'gallery') ...[
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final p in galleryPacks)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                key: ValueKey('gallery-pack-${p['id']}'),
                                label: Text('${p['name']}'),
                                selected: galleryPack == p['id'],
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                onSelected: !changeable ? null : (_) => _setGalleryPack('${p['id']}'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  if (source == 'theme')
                    Text(
                      trf('{0} icons{1}', [i['total'], i['truncated'] == true ? trf(', the first {0} shown', [choices.length]) : '']),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    )
                  else if (galleryLoaded && (galleryError == null || galleryChoices.isNotEmpty))
                    Text(
                      '${trf('{0} icons{1}', [galleryTotal, galleryTruncated ? trf(', the first {0} shown', [galleryChoices.length]) : ''])}'
                      '${activePackLicense != null ? ' · $activePackLicense' : ''}'
                      '${galleryOffline && galleryChoices.isNotEmpty ? ' · ${tr('Offline: showing cached icons')}' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: source == 'theme'
                        ? GridView.builder(
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 52, mainAxisSpacing: 4, crossAxisSpacing: 4),
                            itemCount: changeable ? choices.length : 0,
                            itemBuilder: (context, n) {
                              final c = choices[n];
                              final on = c['name'] == selected;
                              return Tooltip(
                                message: '${c['name']} (${c['theme']})',
                                waitDuration: const Duration(milliseconds: 400),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(cornerSizes(context).control),
                                  onTap: () => setState(() {
                                    selected = '${c['name']}';
                                    selectedLabel = '${c['name']}';
                                    selectedSvg = null;
                                    selectedThemeFile = c['file'] as String?;
                                    selectedFile = null;
                                  }),
                                  onDoubleTap: () => _apply('${c['name']}'),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: on ? scheme.primary.withValues(alpha: .18) : null,
                                      borderRadius: BorderRadius.circular(cornerSizes(context).control),
                                      border: Border.all(color: on ? scheme.primary : Colors.transparent),
                                    ),
                                    child: Center(child: _svg(c['file'] as String?, 24)),
                                  ),
                                ),
                              );
                            },
                          )
                        : (galleryLoading && galleryChoices.isEmpty)
                            ? const Center(child: CircularProgressIndicator())
                            : (galleryError != null && galleryChoices.isEmpty)
                                ? Center(
                                    child: SingleChildScrollView(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            galleryError!,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(color: scheme.error),
                                          ),
                                          const SizedBox(height: 10),
                                          OutlinedButton.icon(
                                            key: const ValueKey('gallery-retry'),
                                            onPressed: galleryLoading ? null : () => _searchGallery(refresh: true),
                                            icon: const Icon(Icons.refresh, size: 16),
                                            label: Text(tr('Retry')),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                : GridView.builder(
                                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 52, mainAxisSpacing: 4, crossAxisSpacing: 4),
                                    itemCount: changeable ? galleryChoices.length : 0,
                                    itemBuilder: (context, n) {
                                      final c = galleryChoices[n];
                                      final id = '${c['id']}';
                                      final on = id == selected;
                                      return Tooltip(
                                        message: '${c['name']} (${c['pack']})',
                                        waitDuration: const Duration(milliseconds: 400),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(cornerSizes(context).control),
                                          onTap: () => setState(() {
                                            selected = id;
                                            selectedLabel = '${c['name']} (${c['pack']})';
                                            selectedSvg = c['svg'] as String?;
                                            selectedThemeFile = null;
                                            selectedFile = null;
                                          }),
                                          onDoubleTap: () => _apply(id),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: on ? scheme.primary.withValues(alpha: .18) : null,
                                              borderRadius: BorderRadius.circular(cornerSizes(context).control),
                                              border: Border.all(color: on ? scheme.primary : Colors.transparent),
                                            ),
                                            child: Center(child: _svgString(c['svg'] as String?, 24)),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                  ),
                ],
              ),
      ),
      actions: [
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(onPressed: !changeable || working ? null : _pickFile, child: Text(tr('Choose an SVG file…'))),
            TextButton(onPressed: i?['current'] == 'original' || i?['current'] == null || working ? null : _reset, child: Text(tr('Reset'))),
            TextButton(onPressed: () => Navigator.pop(context, changed), child: Text(tr('Cancel'))),
            FilledButton(
              onPressed: !changeable || working || (selected == null && selectedFile == null) ? null : () => _apply(selectedFile ?? selected!),
              child: working ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(tr('Use this icon')),
            ),
          ],
        ),
      ],
    );
  }
}
