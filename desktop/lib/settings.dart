import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'core_service.dart';

class Preferences {
  const Preferences(
    this.folder,
    this.container, {
    this.themeMode = ThemeMode.system,
    this.accent = 'indigo',
    this.imageSeed,
    this.updateProxy = '',
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
    super.dispose();
  }

  Future<void> save() async {
    if (saving || readingImage || !form.currentState!.validate()) return;
    final preferences = Preferences(
      folder.text.trim(),
      container,
      themeMode: themeMode,
      accent: accent,
      imageSeed: imageSeed,
      updateProxy: proxy.text.trim(),
    );
    setState(() {
      saving = true;
      error = null;
    });
    try {
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
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 28,
        title: Text('设置', style: theme.textTheme.headlineSmall),
      ),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 24),
            child: Form(
              key: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('外观', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ThemeMode>(
                    initialValue: themeMode,
                    decoration: const InputDecoration(labelText: '显示模式'),
                    items: [
                      for (final entry in Preferences.modes.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: saving
                        ? null
                        : (value) => setState(() => themeMode = value!),
                  ),
                  const SizedBox(height: 14),
                  Text('主题色', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final entry in Preferences.accents.entries)
                        ChoiceChip(
                          avatar: CircleAvatar(
                            backgroundColor: entry.value.$2,
                            radius: 7,
                          ),
                          label: Text(entry.value.$1),
                          selected: imageSeed == null && accent == entry.key,
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
                          color: imageSeed == null ? null : Color(imageSeed!),
                        ),
                        label: Text(readingImage ? '正在提取…' : '从图片提取'),
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
                    validator: (value) => value == null || value.trim().isEmpty
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
                                final path = await getDirectoryPath();
                                if (path != null && mounted) folder.text = path;
                              },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: container,
                    decoration: const InputDecoration(labelText: '下载完成后混流'),
                    items: Preferences.containers.entries
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: saving
                        ? null
                        : (value) => setState(() => container = value!),
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  Text('下载核心', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: proxy,
                    enabled: !saving,
                    decoration: const InputDecoration(
                      labelText: '核心更新代理（可选）',
                      hintText: 'http://127.0.0.1:7890',
                      helperText: '仅用于从 GitHub 安装和更新核心。',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) return null;
                      return parseUpdateProxy(value) == null
                          ? '请输入包含协议、主机和端口的代理地址'
                          : null;
                    },
                  ),
                  const SizedBox(height: 8),
                  if (widget.core case final installed?)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(installed.tag),
                      subtitle: const Text('安装详情'),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      expandedAlignment: Alignment.centerLeft,
                      children: [
                        SelectableText(
                          installed.executable,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    )
                  else
                    Text(
                      widget.checkingEnvironment
                          ? '正在检查下载环境…'
                          : widget.environmentIssue ?? '未安装',
                    ),
                  if (widget.ffmpegAvailable == false)
                    const Text('PATH 中未找到 FFmpeg。安装后请重启客户端。'),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: widget.onCoreUpdate == null
                          ? null
                          : () {
                              final value = proxy.text.trim();
                              if (value.isNotEmpty &&
                                  parseUpdateProxy(value) == null) {
                                form.currentState?.validate();
                                return;
                              }
                              widget.onCoreUpdate!(value);
                            },
                      icon: const Icon(Icons.system_update_alt),
                      label: Text(widget.core == null ? '安装核心' : '检查核心更新'),
                    ),
                  ),
                  if (widget.updatingCore) const LinearProgressIndicator(),
                  if (widget.coreUpdateStatus case final message?)
                    Text(message, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 24),
                  const Divider(),
                  Text('客户端', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: widget.onClientUpdate,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('查看客户端更新'),
                    ),
                  ),
                  if (error case final message?)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        message,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                ],
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
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: saving ? null : widget.onClose,
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: saving || readingImage ? null : save,
                    child: Text(saving ? '正在保存…' : '保存设置'),
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
