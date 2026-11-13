import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'core_service.dart';
import 'ffmpeg.dart';

class Preferences {
  const Preferences(
    this.folder,
    this.container, {
    this.themeMode = ThemeMode.system,
    this.accent = 'indigo',
    this.imageSeed,
    this.corePath = '',
    this.ffmpegPath = '',
  });

  static const accents = {
    'blue': ('钴蓝', Color(0xff315be8)),
    'indigo': ('靛蓝', Color(0xff414ac2)),
    'ocean': ('海蓝', Color(0xff006d9c)),
    'green': ('翠绿', Color(0xff21764e)),
    'violet': ('紫罗兰', Color(0xff7945a5)),
    'amber': ('琥珀', Color(0xffa35009)),
  };
  static const modes = {
    ThemeMode.system: '跟随系统',
    ThemeMode.light: '浅色',
    ThemeMode.dark: '深色',
  };
  final ThemeMode themeMode;
  final String accent;
  final int? imageSeed;
  final String corePath;
  final String ffmpegPath;
  Color get seed => imageSeed == null ? accents[accent]!.$2 : Color(imageSeed!);

  factory Preferences.defaults() => Preferences(
    '${CoreService.home}${CoreService.sep}Downloads',
    'mkv',
    accent: 'blue',
  );

  static const containers = {
    'mkv': 'MKV',
    'mp4': 'MP4',
    'ts': 'TS',
    'none': '分别保存轨道',
  };
  final String folder;
  final String container;

  static File get file => File('${CoreService.data.path}/preferences.json');

  static Future<Preferences> load() async {
    if (!await file.exists()) return Preferences.defaults();
    return Preferences.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
  }

  factory Preferences.fromJson(Map<String, dynamic> data) {
    final folder = data['folder'];
    final container = data['container'];
    final defaults = Preferences.defaults();
    return Preferences(
      folder is String && folder.trim().isNotEmpty ? folder : defaults.folder,
      container is String && containers.containsKey(container)
          ? container
          : defaults.container,
      themeMode: ThemeMode.values.firstWhere(
        (mode) => mode.name == data['themeMode'],
        orElse: () => defaults.themeMode,
      ),
      accent: accents.containsKey(data['accent'])
          ? data['accent'] as String
          : 'indigo',
      imageSeed: switch (data['imageSeed']) {
        final int value when value >= 0xff000000 && value <= 0xffffffff =>
          value,
        _ => null,
      },
      corePath: data['corePath'] is String
          ? (data['corePath'] as String).trim()
          : '',
      ffmpegPath: data['ffmpegPath'] is String
          ? (data['ffmpegPath'] as String).trim()
          : '',
    );
  }

  Future<void> save() async {
    await file.parent.create(recursive: true);
    final stage = await file.parent.createTemp('preferences-');
    try {
      final candidate = File('${stage.path}/settings.json');
      await candidate.writeAsString(
        jsonEncode({
          'folder': folder,
          'container': container,
          'themeMode': themeMode.name,
          'accent': accent,
          if (imageSeed != null) 'imageSeed': imageSeed,
          if (corePath.isNotEmpty) 'corePath': corePath,
          if (ffmpegPath.isNotEmpty) 'ffmpegPath': ffmpegPath,
        }),
        flush: true,
      );
      await candidate.rename(file.path);
    } finally {
      await stage.delete(recursive: true);
    }
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.initial,
    required this.core,
    required this.onClose,
    required this.onSaved,
    required this.checkingEnvironment,
    required this.environmentIssue,
    required this.ffmpegAvailable,
    required this.coreUpdateStatus,
    required this.updatingCore,
    required this.onCoreUpdate,
    required this.onClientUpdate,
    this.inspectFFmpegVersion = inspectFFmpeg,
    this.onCheckClientUpdate,
    this.clientVersion,
    this.clientUpdateStatus,
    this.clientUpdateAvailable = false,
  });

  final Preferences initial;
  final CoreInstall? core;
  final VoidCallback onClose;
  final ValueChanged<Preferences> onSaved;
  final bool checkingEnvironment;
  final String? environmentIssue;
  final bool? ffmpegAvailable;
  final String? coreUpdateStatus;
  final bool updatingCore;
  final Future<CoreInstall?> Function()? onCoreUpdate;
  final VoidCallback onClientUpdate;
  final Future<String> Function(String) inspectFFmpegVersion;
  final VoidCallback? onCheckClientUpdate;
  final String? clientVersion;
  final String? clientUpdateStatus;
  final bool clientUpdateAvailable;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final form = GlobalKey<FormState>();
  late final folder = TextEditingController(text: widget.initial.folder);
  late String container = widget.initial.container;
  late ThemeMode themeMode = widget.initial.themeMode;
  late String accent = widget.initial.accent;
  late int? imageSeed = widget.initial.imageSeed;
  CoreInstall? downloadedCore;
  bool corePathEdited = false;

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!corePathEdited &&
        widget.initial.corePath.isEmpty &&
        widget.core != oldWidget.core) {
      corePath.text = widget.core?.executable ?? '';
    }
  }

  late final corePath = TextEditingController(
    text: widget.initial.corePath.isEmpty
        ? widget.core?.executable ?? ''
        : widget.initial.corePath,
  );

  String get configuredCorePath {
    final value = corePath.text.trim();
    final managedPath =
        downloadedCore?.executable ??
        (widget.initial.corePath.isEmpty ? widget.core?.executable : null);
    return value == managedPath ? '' : value;
  }

  Future<void> downloadCore() async {
    final value = await widget.onCoreUpdate!();
    if (!mounted || value == null) return;
    setState(() {
      downloadedCore = value;
      corePath.text = value.executable;
    });
  }

  late final String detectedFFmpegPath = resolveFFmpeg('') ?? '';
  late final ffmpegPath = TextEditingController(
    text: widget.initial.ffmpegPath.isEmpty
        ? detectedFFmpegPath
        : widget.initial.ffmpegPath,
  );

  String get configuredFFmpegPath {
    final value = ffmpegPath.text.trim();
    return value == detectedFFmpegPath ? '' : value;
  }

  String? ffmpegVersion;
  String? versionedFFmpegPath;

  @override
  void initState() {
    super.initState();
    final path = resolveFFmpeg(widget.initial.ffmpegPath);
    if (path != null) readFFmpegVersion(path);
  }

  Future<void> readFFmpegVersion(String path) async {
    try {
      final version = await widget.inspectFFmpegVersion(path);
      if (mounted && ffmpegPath.text.trim() == path) {
        setState(() {
          ffmpegVersion = version;
          versionedFFmpegPath = path;
        });
      }
    } on Exception {
      // A path may become unavailable while the settings page is open.
    }
  }

  bool downloadingFFmpeg = false;
  String? ffmpegDownloadStatus;

  Future<void> installFFmpeg() async {
    setState(() {
      downloadingFFmpeg = true;
      ffmpegDownloadStatus = '正在准备下载 FFmpeg…';
    });
    try {
      final path = await downloadFFmpeg((message) {
        if (mounted) setState(() => ffmpegDownloadStatus = message);
      });
      if (mounted) {
        setState(() {
          ffmpegPath.text = path;
          ffmpegDownloadStatus = configuredFFmpegPath == widget.initial.ffmpegPath
              ? 'FFmpeg 已下载，当前路径已启用'
              : 'FFmpeg 已下载，保存设置后启用';
        });
        await readFFmpegVersion(path);
      }
    } catch (exception) {
      if (mounted) setState(() => ffmpegDownloadStatus = '下载失败：$exception');
    } finally {
      if (mounted) setState(() => downloadingFFmpeg = false);
    }
  }

  bool saving = false;
  bool readingImage = false;
  String? error;

  Future<void> chooseThemeImage() async {
    setState(() {
      readingImage = true;
      error = null;
    });
    try {
      final image = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: '图片', extensions: ['png', 'jpg', 'jpeg', 'webp']),
        ],
      );
      if (image == null || !mounted) return;
      final colors = await ColorScheme.fromImageProvider(
        provider: ResizeImage(FileImage(File(image.path)), width: 128),
      );
      if (mounted) setState(() => imageSeed = colors.primary.toARGB32());
    } catch (_) {
      if (mounted) setState(() => error = '无法读取图片配色，请试试其他图片。');
    } finally {
      if (mounted) setState(() => readingImage = false);
    }
  }

  @override
  void dispose() {
    folder.dispose();
    corePath.dispose();
    ffmpegPath.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving ||
        readingImage ||
        widget.updatingCore ||
        downloadingFFmpeg ||
        !form.currentState!.validate()) {
      return;
    }
    final preferences = Preferences(
      folder.text.trim(),
      container,
      themeMode: themeMode,
      accent: accent,
      imageSeed: imageSeed,
      corePath: configuredCorePath,
      ffmpegPath: configuredFFmpegPath,
    );
    setState(() {
      saving = true;
      error = null;
    });
    try {
      if (preferences.ffmpegPath.isNotEmpty &&
          preferences.ffmpegPath != widget.initial.ffmpegPath) {
        final path = resolveFFmpeg(preferences.ffmpegPath);
        if (path == null) throw const FormatException('请选择存在的 FFmpeg 可执行文件。');
        await inspectFFmpeg(path);
      }
      if (preferences.corePath.isNotEmpty &&
          preferences.corePath != widget.initial.corePath) {
        await CoreService.inspectExecutable(preferences.corePath);
      }
      await preferences.save();
      if (mounted) widget.onSaved(preferences);
    } on Exception catch (exception) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '无法保存设置：$exception';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('设置', style: theme.textTheme.headlineSmall),
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              clipBehavior: Clip.antiAlias,
              color: theme.colorScheme.surfaceContainerLow,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                // 滚动视图要占满整张卡片，滚动条才会落在卡片右边缘；
                // 内容的宽度限制放进滚动视图内部，保持左对齐。
                body: Theme(
                  data: theme.copyWith(
                    scrollbarTheme: ScrollbarThemeData(
                      // 桌面端默认常驻的滚动条在内容只略微溢出时像一条空槽。
                      // 改为仅在滚动或悬停时淡入，并收细、加圆角、留出边距。
                      thumbVisibility: const WidgetStatePropertyAll<bool?>(
                        false,
                      ),
                      trackVisibility: const WidgetStatePropertyAll<bool?>(
                        false,
                      ),
                      thickness: const WidgetStatePropertyAll<double?>(6.0),
                      radius: const Radius.circular(6),
                      thumbColor: WidgetStateProperty.resolveWith<Color?>((
                        states,
                      ) {
                        final active =
                            states.contains(WidgetState.hovered) ||
                            states.contains(WidgetState.dragged);
                        return theme.colorScheme.onSurface.withValues(
                          alpha: active ? 0.38 : 0.18,
                        );
                      }),
                      crossAxisMargin: 6,
                      mainAxisMargin: 12,
                      minThumbLength: 48,
                    ),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(28, 16, 28, 24),
                    child: Align(
                      alignment: Alignment.topLeft,
                      // 704 + 左右各 28 内边距 = 760，与底部按钮栏保持同宽。
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 704),
                        child: Form(
                          key: form,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('外观', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 12),
                              _SettingsChoices<ThemeMode>(
                                label: '显示模式',
                                value: themeMode,
                                options: Preferences.modes,
                                onChanged: saving
                                    ? null
                                    : (value) =>
                                          setState(() => themeMode = value),
                              ),
                              const SizedBox(height: 14),
                              Text('主题色', style: theme.textTheme.labelLarge),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  for (final entry
                                      in Preferences.accents.entries)
                                    ChoiceChip(
                                      avatar: CircleAvatar(
                                        backgroundColor: entry.value.$2,
                                        radius: 7,
                                      ),
                                      label: Text(entry.value.$1),
                                      selected:
                                          imageSeed == null &&
                                          accent == entry.key,
                                      onSelected: saving || readingImage
                                          ? null
                                          : (_) => setState(() {
                                              accent = entry.key;
                                              imageSeed = null;
                                            }),
                                    ),
                                  OutlinedButton.icon(
                                    onPressed: saving || readingImage
                                        ? null
                                        : chooseThemeImage,
                                    icon: Icon(
                                      Icons.palette_outlined,
                                      color: imageSeed == null
                                          ? null
                                          : Color(imageSeed!),
                                    ),
                                    label: Text(
                                      readingImage ? '正在提取…' : '从图片提取',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              const Divider(),
                              const SizedBox(height: 10),
                              Text('下载偏好', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 14),
                              TextFormField(
                                controller: folder,
                                enabled: !saving,
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                    ? '请输入默认保存目录'
                                    : null,
                                decoration: InputDecoration(
                                  labelText: '默认保存目录',
                                  suffixIcon: IconButton(
                                    tooltip: '选择默认保存目录',
                                    icon: const Icon(Icons.folder_open_rounded),
                                    onPressed: saving
                                        ? null
                                        : () async {
                                            final path =
                                                await getDirectoryPath();
                                            if (path != null && mounted) {
                                              folder.text = path;
                                            }
                                          },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              _SettingsChoices<String>(
                                label: '下载完成后混流',
                                value: container,
                                options: Preferences.containers,
                                optionWidth: 144,
                                onChanged: saving
                                    ? null
                                    : (value) =>
                                          setState(() => container = value),
                              ),
                              const SizedBox(height: 24),
                              const Divider(),
                              _ExecutableSetting(
                                title: '下载核心',
                                controller: corePath,
                                busy: widget.updatingCore,
                                disabled: saving,
                                onPathChanged: () =>
                                    setState(() => corePathEdited = true),
                                onDownload: widget.onCoreUpdate == null
                                    ? null
                                    : downloadCore,
                                status:
                                    widget.coreUpdateStatus ??
                                    widget.environmentIssue ??
                                    (widget.checkingEnvironment
                                        ? '正在检查下载环境…'
                                        : (downloadedCore ?? widget.core)
                                                  ?.executable ==
                                              corePath.text.trim()
                                        ? '核心版本 ${(downloadedCore ?? widget.core)!.tag}'
                                        : null),
                              ),
                              const SizedBox(height: 24),
                              const Divider(),
                              _ExecutableSetting(
                                title: 'FFmpeg',
                                controller: ffmpegPath,
                                busy: downloadingFFmpeg,
                                disabled: saving,
                                onDownload: canDownloadFFmpeg
                                    ? installFFmpeg
                                    : null,
                                onPathChanged: () => setState(() {
                                  ffmpegDownloadStatus = null;
                                }),
                                status:
                                    ffmpegDownloadStatus ??
                                    (ffmpegVersion != null &&
                                            versionedFFmpegPath ==
                                                ffmpegPath.text.trim()
                                        ? 'FFmpeg 版本 $ffmpegVersion'
                                        : null),
                              ),
                              const SizedBox(height: 24),
                              const Divider(),
                              Text('客户端更新', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 16,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    '当前版本 ${widget.clientVersion ?? '—'}',
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: widget.onCheckClientUpdate,
                                        icon: const Icon(Icons.refresh),
                                        label: const Text('检查更新'),
                                      ),
                                      TextButton.icon(
                                        onPressed: widget.onClientUpdate,
                                        icon: const Icon(Icons.open_in_new),
                                        label: Text(
                                          widget.clientUpdateAvailable
                                              ? '前往下载'
                                              : '打开发布页',
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              if (widget.clientUpdateStatus case final message?)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    message,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              if (error case final message?)
                                Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: Text(
                                    message,
                                    style: TextStyle(
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                bottomNavigationBar: SafeArea(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    heightFactor: 1,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 12,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed:
                                  saving ||
                                      downloadingFFmpeg ||
                                      widget.updatingCore
                                  ? null
                                  : widget.onClose,
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed:
                                  saving ||
                                      readingImage ||
                                      widget.updatingCore ||
                                      downloadingFFmpeg
                                  ? null
                                  : save,
                              child: Text(saving ? '正在保存…' : '保存设置'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExecutableSetting extends StatelessWidget {
  const _ExecutableSetting({
    required this.title,
    required this.controller,
    required this.busy,
    required this.disabled,
    required this.onDownload,
    this.onPathChanged,
    this.status,
  });

  final String title;
  final TextEditingController controller;
  final bool busy;
  final bool disabled;
  final VoidCallback? onDownload;
  final VoidCallback? onPathChanged;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = !busy && !disabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 12),
        TextFormField(
          controller: controller,
          enabled: enabled,
          onChanged: (_) => onPathChanged?.call(),
          decoration: InputDecoration(
            labelText: title == '下载核心' ? '核心可执行文件' : 'FFmpeg 可执行文件',
            suffixIcon: IconButton(
              tooltip: '选择本地文件',
              icon: const Icon(Icons.folder_open_outlined),
              onPressed: enabled
                  ? () async {
                      final selected = await openFile();
                      if (!context.mounted || selected == null) return;
                      controller.text = selected.path;
                      onPathChanged?.call();
                    }
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: enabled ? onDownload : null,
          icon: const Icon(Icons.system_update_alt),
          label: const Text('在线下载'),
        ),
        if (status case final message?) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(message, style: theme.textTheme.bodySmall),
          ),
        ],
        if (busy) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }
}

class _SettingsChoices<T> extends StatelessWidget {
  const _SettingsChoices({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.optionWidth,
  });

  final String label;
  final double? optionWidth;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final entry in options.entries)
            if (optionWidth case final width?)
              Semantics(
                selected: entry.key == value,
                child: SizedBox(
                  width: MediaQuery.textScalerOf(context).scale(width),
                  child: OutlinedButton(
                    style: entry.key == value
                        ? OutlinedButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onSecondaryContainer,
                          )
                        : null,
                    onPressed: onChanged == null
                        ? null
                        : () => onChanged!(entry.key),
                    child: Text(entry.value, textAlign: TextAlign.center),
                  ),
                ),
              )
            else
              ChoiceChip(
                label: Text(entry.value),
                selected: entry.key == value,
                onSelected: onChanged == null
                    ? null
                    : (_) => onChanged!(entry.key),
              ),
        ],
      ),
    ],
  );
}
