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
  });

  static const accents = {
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
  Color get seed => accents[accent]!.$2;

  factory Preferences.defaults() =>
      Preferences('${CoreService.home}${CoreService.sep}Downloads', 'mkv');

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
          : defaults.accent,
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
        }),
        flush: true,
      );
      await candidate.rename(file.path);
    } finally {
      await stage.delete(recursive: true);
    }
  }
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.initial, required this.core});

  final Preferences initial;
  final CoreInstall? core;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final form = GlobalKey<FormState>();
  late final folder = TextEditingController(text: widget.initial.folder);
  late String container = widget.initial.container;
  late ThemeMode themeMode = widget.initial.themeMode;
  late String accent = widget.initial.accent;
  bool saving = false;
  String? error;

  @override
  void dispose() {
    folder.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    final preferences = Preferences(
      folder.text.trim(),
      container,
      themeMode: themeMode,
      accent: accent,
    );
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await preferences.save();
      if (mounted) Navigator.pop(context, preferences);
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
    return AlertDialog(
      title: const Text('设置'),
      scrollable: true,
      content: SizedBox(
        width: 500,
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
                      selected: accent == entry.key,
                      onSelected: saving
                          ? null
                          : (_) => setState(() => accent = entry.key),
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
                    value == null || value.trim().isEmpty ? '请输入默认保存目录' : null,
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
              const SizedBox(height: 8),
              Text(widget.core?.tag ?? '未安装'),
              if (widget.core case final installed?)
                SelectableText(
                  installed.executable,
                  style: theme.textTheme.bodySmall,
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
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? '正在保存…' : '保存设置'),
        ),
      ],
    );
  }
}
