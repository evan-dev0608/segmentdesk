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
    this.updateProxy = '',
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
  final String updateProxy;
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
      updateProxy:
          data['updateProxy'] is String &&
              parseUpdateProxy(data['updateProxy'] as String) != null
          ? data['updateProxy'] as String
          : '',
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
          'updateProxy': updateProxy,
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
    this.onCheckClientUpdate,
    this.clientVersion,
    this.clientUpdateStatus,
    this.clientUpdateAvailable = false,
    this.coreActionLabel,
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
  final ValueChanged<String>? onCoreUpdate;
  final VoidCallback onClientUpdate;
  final VoidCallback? onCheckClientUpdate;
  final String? clientVersion;
  final String? clientUpdateStatus;
  final bool clientUpdateAvailable;
  final String? coreActionLabel;

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
  late final proxy = TextEditingController(text: widget.initial.updateProxy);
  late final corePath = TextEditingController(text: widget.initial.corePath);
  late final ffmpegPath = TextEditingController(
    text: widget.initial.ffmpegPath,
  );
  late bool customCore = widget.initial.corePath.isNotEmpty;
  String? ffmpegResult;
  bool testingFFmpeg = false;

  Future<void> testFFmpeg() async {
    setState(() => testingFFmpeg = true);
    try {
      final path = resolveFFmpeg(ffmpegPath.text.trim());
      if (path == null) throw const FormatException('未找到 FFmpeg 可执行文件。');
      final version = await inspectFFmpeg(path);
      if (mounted) setState(() => ffmpegResult = 'FFmpeg $version\n$path');
    } catch (exception) {
      if (mounted) setState(() => ffmpegResult = '检测失败：$exception');
    } finally {
      if (mounted) setState(() => testingFFmpeg = false);
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
    proxy.dispose();
    corePath.dispose();
    ffmpegPath.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving ||
        readingImage ||
        widget.updatingCore ||
        !form.currentState!.validate()) {
      return;
    }
    final preferences = Preferences(
      folder.text.trim(),
      container,
      themeMode: themeMode,
      accent: accent,
      imageSeed: imageSeed,
      updateProxy: proxy.text.trim(),
      corePath: customCore ? corePath.text.trim() : '',
      ffmpegPath: ffmpegPath.text.trim(),
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
                              _SettingsSelect<ThemeMode>(
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
                              _SettingsSelect<String>(
                                label: '下载完成后混流',
                                value: container,
                                options: Preferences.containers,
                                onChanged: saving
                                    ? null
                                    : (value) =>
                                          setState(() => container = value),
                              ),
                              const SizedBox(height: 24),
                              const Divider(),
                              Text('下载核心', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 12),
                              _SettingsSelect<bool>(
                                label: '核心来源',
                                value: customCore,
                                options: const {false: '托管核心', true: '自定义核心'},
                                onChanged: saving || widget.updatingCore
                                    ? null
                                    : (value) =>
                                          setState(() => customCore = value),
                              ),
                              const SizedBox(height: 12),
                              if (!customCore)
                                TextFormField(
                                  controller: proxy,
                                  enabled: !saving,
                                  decoration: const InputDecoration(
                                    labelText: '核心更新代理（可选）',
                                    hintText: 'http://127.0.0.1:7890',
                                    helperText: '仅用于从 GitHub 安装和更新核心。',
                                  ),
                                  validator: (value) {
                                    if (value == null || value.trim().isEmpty) {
                                      return null;
                                    }
                                    return parseUpdateProxy(value) == null
                                        ? '请输入包含协议、主机和端口的代理地址'
                                        : null;
                                  },
                                ),
                              const SizedBox(height: 8),
                              if (customCore)
                                TextFormField(
                                  controller: corePath,
                                  enabled: !saving && !widget.updatingCore,
                                  decoration: InputDecoration(
                                    labelText: '自定义核心路径',
                                    suffixIcon: IconButton(
                                      tooltip: '选择核心可执行文件',
                                      icon: const Icon(
                                        Icons.folder_open_outlined,
                                      ),
                                      onPressed: saving || widget.updatingCore
                                          ? null
                                          : () async {
                                              final selected = await openFile();
                                              if (mounted &&
                                                  selected != null &&
                                                  !saving) {
                                                corePath.text = selected.path;
                                              }
                                            },
                                    ),
                                  ),
                                  validator: (value) =>
                                      value == null || value.trim().isEmpty
                                      ? '请选择核心可执行文件'
                                      : null,
                                ),
                              const SizedBox(height: 8),
                              if (widget.core case final installed?)
                                ExpansionTile(
                                  tilePadding: EdgeInsets.zero,
                                  shape: const Border(),
                                  collapsedShape: const Border(),
                                  title: Wrap(
                                    spacing: 10,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      const Text('核心版本'),
                                      Text(
                                        installed.tag,
                                        style: theme.textTheme.titleSmall,
                                      ),
                                    ],
                                  ),
                                  subtitle: Text(
                                    widget.initial.corePath.isEmpty
                                        ? '托管核心 · 查看安装路径'
                                        : '自定义核心 · 查看安装路径',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  // 展开内容默认紧贴标题（childrenPadding 为零），
                                  // 输入框的浮动标签会被挤到边框线上。这里改成
                                  // 撑满宽度 + 显式标题 + 可换行复制的路径文本。
                                  expandedCrossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  childrenPadding: const EdgeInsets.only(
                                    top: 8,
                                    bottom: 12,
                                  ),
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: Text(
                                        '当前生效路径',
                                        style: theme.textTheme.labelMedium,
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: theme
                                            .colorScheme
                                            .surfaceContainerHighest
                                            .withValues(alpha: 0.55),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color:
                                              theme.colorScheme.outlineVariant,
                                        ),
                                      ),
                                      child: SelectableText(
                                        installed.executable,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  ],
                                )
                              else
                                Text(
                                  widget.checkingEnvironment
                                      ? '正在检查下载环境…'
                                      : widget.environmentIssue ?? '未安装',
                                ),
                              const SizedBox(height: 12),
                              if (!customCore)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: OutlinedButton.icon(
                                    onPressed:
                                        widget.onCoreUpdate == null ||
                                            widget.initial.corePath.isNotEmpty
                                        ? null
                                        : () {
                                            final value = proxy.text.trim();
                                            if (value.isNotEmpty &&
                                                parseUpdateProxy(value) ==
                                                    null) {
                                              form.currentState?.validate();
                                              return;
                                            }
                                            widget.onCoreUpdate!(value);
                                          },
                                    icon: const Icon(Icons.system_update_alt),
                                    label: Text(
                                      widget.coreActionLabel ??
                                          (widget.core == null
                                              ? '安装核心'
                                              : '检查核心更新'),
                                    ),
                                  ),
                                ),
                              if (widget.updatingCore)
                                const LinearProgressIndicator(),
                              if (widget.coreUpdateStatus case final message?)
                                Text(message, style: theme.textTheme.bodySmall),
                              const SizedBox(height: 24),
                              const Divider(),
                              Text('FFmpeg', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: ffmpegPath,
                                enabled: !saving && !testingFFmpeg,
                                onChanged: (_) =>
                                    setState(() => ffmpegResult = null),
                                decoration: InputDecoration(
                                  labelText: 'FFmpeg 可执行文件',
                                  helperText: '留空时从 PATH 自动查找。',
                                  suffixIcon: IconButton(
                                    tooltip: '选择 FFmpeg',
                                    icon: const Icon(
                                      Icons.folder_open_outlined,
                                    ),
                                    onPressed: saving || testingFFmpeg
                                        ? null
                                        : () async {
                                            final selected = await openFile();
                                            if (mounted &&
                                                selected != null &&
                                                !saving) {
                                              setState(() {
                                                ffmpegPath.text = selected.path;
                                                ffmpegResult = null;
                                              });
                                            }
                                          },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              if (ffmpegResult case final result?)
                                SelectableText(
                                  result,
                                  style: theme.textTheme.bodySmall,
                                )
                              else if (widget.ffmpegAvailable == false)
                                const Text('未找到 FFmpeg，请指定路径。')
                              else if (resolveFFmpeg(widget.initial.ffmpegPath)
                                  case final path?)
                                SelectableText(
                                  '当前路径 · $path',
                                  style: theme.textTheme.bodySmall,
                                ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: saving || testingFFmpeg
                                        ? null
                                        : testFFmpeg,
                                    child: Text(
                                      testingFFmpeg ? '正在测试…' : '测试 FFmpeg',
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: saving || testingFFmpeg
                                        ? null
                                        : () {
                                            setState(() {
                                              ffmpegPath.clear();
                                              ffmpegResult = null;
                                            });
                                          },
                                    child: const Text('恢复自动查找'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                              const Divider(),
                              Text('客户端', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 8),
                              Text('当前版本 ${widget.clientVersion ?? '—'}'),
                              if (widget.clientUpdateStatus case final message?)
                                Text(message, style: theme.textTheme.bodySmall),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: widget.onCheckClientUpdate,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('检查客户端更新'),
                                  ),
                                  if (widget.clientUpdateAvailable)
                                    TextButton.icon(
                                      onPressed: widget.onClientUpdate,
                                      icon: const Icon(Icons.open_in_new),
                                      label: const Text('前往下载'),
                                    ),
                                ],
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
                              onPressed: saving ? null : widget.onClose,
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed:
                                  saving || readingImage || widget.updatingCore
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

class _SettingsSelect<T> extends StatelessWidget {
  const _SettingsSelect({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => MenuAnchor(
        alignmentOffset: const Offset(0, 6),
        style: MenuStyle(
          alignment: Alignment.bottomLeft,
          minimumSize: WidgetStatePropertyAll(Size(constraints.maxWidth, 0)),
          backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerHigh),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        menuChildren: [
          for (final entry in options.entries)
            MenuItemButton(
              leadingIcon: Icon(
                entry.key == value ? Icons.check : null,
                size: 18,
              ),
              onPressed: onChanged == null ? null : () => onChanged!(entry.key),
              child: Text(entry.value),
            ),
        ],
        builder: (context, controller, _) => Semantics(
          button: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onChanged == null
                ? null
                : () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: label,
                enabled: onChanged != null,
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
              isFocused: controller.isOpen,
              child: Row(
                children: [
                  Expanded(child: Text(options[value] ?? '')),
                  Icon(
                    controller.isOpen
                        ? Icons.arrow_drop_up
                        : Icons.arrow_drop_down,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
