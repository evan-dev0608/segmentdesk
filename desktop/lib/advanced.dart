import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'core_output.dart';
import 'core_service.dart';

const toolLabels = {
  '': '下载',
  'concat': '拼接文件',
  'merge': '合并媒体',
  'mux': '混流轨道',
  'doctor': '检测环境',
};

class CoreOption {
  const CoreOption(this.flag, this.placeholder, this.description);
  final String flag;
  final String? placeholder;
  final String description;
}

List<CoreOption> parseCoreHelp(String help) {
  final pattern = RegExp(
    r'^\s+((?:-\S+?,\s+)*--[\w-]+)(?:\s+(<[^>]+>))?(?:\s{2,}(.*))?$',
  );
  const hidden = {
    '--help',
    '--version',
    '--morehelp',
    '--generate-completion',
    '--force-ansi-console',
    '--vod-select-parts',
  };
  return [
    for (final line in const LineSplitter().convert(help))
      if (pattern.firstMatch(line) case final match?)
        if (!hidden.contains(match[1]!.split(RegExp(r'\s+')).last))
          CoreOption(
            match[1]!.split(RegExp(r'\s+')).last,
            match[2],
            match[3] ?? '',
          ),
  ];
}

class AdvancedRequest {
  const AdvancedRequest(this.title, this.directory, this.arguments);
  final String title, directory;
  final List<String> arguments;
}

class AdvancedDialog extends StatefulWidget {
  const AdvancedDialog({
    super.key,
    required this.core,
    required this.directory,
  });
  final CoreInstall core;
  final String directory;

  @override
  State<AdvancedDialog> createState() => _AdvancedDialogState();
}

class _AdvancedDialogState extends State<AdvancedDialog> {
  static const repeatable = {
    '--input',
    '--header',
    '--key',
    '--ad-keyword',
    '--mux-import',
  };
  static const selectors = {
    '--select-video',
    '--select-audio',
    '--select-subtitle',
  };
  final address = TextEditingController();
  final tools = <String, List<CoreOption>>{};
  final values = <String, List<String>>{};
  String mode = '';
  String query = '';
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final results = await Future.wait(
        toolLabels.keys.map((command) async {
          Future<ProcessResult> helpFor(String language) =>
              Process.run(widget.core.executable, [
                if (command.isNotEmpty) command,
                '--ui-language',
                language,
                '--help',
              ], stdoutEncoding: null).timeout(const Duration(seconds: 12));
          final result = await helpFor('zh-CN');
          if (result.exitCode != 0) return null;
          String help;
          try {
            help = decodeCoreOutput(result.stdout as List<int>);
          } on FormatException {
            help = '';
          }
          if (help.isEmpty || help.contains('\uFFFD')) {
            final english = await helpFor('en-US');
            if (english.exitCode != 0) return null;
            help = utf8.decode(
              english.stdout as List<int>,
              allowMalformed: true,
            );
          }
          if (command.isNotEmpty &&
              !RegExp(
                '^\\s*N_m3u8DL-RE(?:\\.exe)?\\s+$command(?:\\s|\$)',
                caseSensitive: false,
                multiLine: true,
              ).hasMatch(help)) {
            return null;
          }
          return MapEntry(command, parseCoreHelp(help));
        }),
      );
      if (!mounted) return;
      setState(() {
        tools.addEntries(
          results.whereType<MapEntry<String, List<CoreOption>>>(),
        );
        loading = false;
        if (tools['']?.isNotEmpty != true) error = '无法读取当前核心的参数帮助。';
      });
    } catch (exception) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '无法读取核心帮助：$exception';
        });
      }
    }
  }

  void submit() {
    final input = address.text.trim();
    if (mode.isEmpty &&
        (input.isEmpty || input.startsWith('-') || input.startsWith('@'))) {
      setState(() => error = '请输入链接或选择本地清单。');
      return;
    }
    final chosen = <String, List<String>>{
      for (final entry in values.entries)
        if (entry.value.any((value) => value.trim().isNotEmpty))
          entry.key: entry.value
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(),
    };
    final arguments = <String>[mode.isEmpty ? input : mode];
    if (mode.isEmpty) {
      final subtitleOnly = chosen['--sub-only']?.first == 'true';
      final manual = chosen.keys.any(selectors.contains);
      final auto = chosen['--auto-select']?.first;
      if ((auto == 'true' && (subtitleOnly || manual)) ||
          (subtitleOnly && manual) ||
          (auto == 'false' && !subtitleOnly && !manual)) {
        setState(() => error = '请选择自动选轨、仅字幕或手动选轨中的一种。');
        return;
      }
      chosen.putIfAbsent('--save-dir', () => [widget.directory]);
      chosen.putIfAbsent(
        '--auto-select',
        () => [(!subtitleOnly && !manual).toString()],
      );
      if (supportsVodSelection) {
        arguments.addAll(['--vod-select-parts', 'false']);
      }
    }
    for (final entry in chosen.entries) {
      for (final value in entry.value) {
        arguments.addAll([entry.key, value]);
      }
    }
    Navigator.pop(
      context,
      AdvancedRequest(
        mode.isEmpty
            ? Uri.tryParse(input)?.host.nonEmpty ??
                  File(input).uri.pathSegments.last
            : toolLabels[mode]!,
        widget.directory,
        arguments,
      ),
    );
  }

  bool get supportsVodSelection =>
      tools['']?.any((option) => option.flag == '--vod-drop-parts') ?? false;

  Widget optionRow(CoreOption option) {
    final flag = option.flag;
    final entries = values.putIfAbsent(flag, () => ['']);
    final label = option.description.isEmpty ? flag : option.description;
    final choices = option.placeholder
        ?.substring(1, option.placeholder!.length - 1)
        .split('|');
    final path = RegExp(r'file|path|dir|input|output|cookies|config')
        .hasMatch(flag);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 6),
          for (var index = 0; index < entries.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: option.placeholder == null || (choices?.length ?? 0) > 1
                  ? DropdownButtonFormField<String>(
                      key: ValueKey('$mode:$flag:$index'),
                      initialValue: entries[index],
                      decoration: InputDecoration(labelText: flag),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('默认')),
                        if (option.placeholder == null) ...[
                          const DropdownMenuItem(
                            value: 'true',
                            child: Text('启用'),
                          ),
                          const DropdownMenuItem(
                            value: 'false',
                            child: Text('关闭'),
                          ),
                        ] else
                          for (final choice in choices!)
                            DropdownMenuItem(
                              value: choice,
                              child: Text(choice),
                            ),
                      ],
                      onChanged: (value) => entries[index] = value ?? '',
                    )
                  : TextFormField(
                      key: ValueKey(
                        '$mode:$flag:$index:${entries[index].hashCode}',
                      ),
                      initialValue: entries[index],
                      onChanged: (value) => entries[index] = value,
                      decoration: InputDecoration(
                        labelText: flag,
                        suffixIcon: path
                            ? IconButton(
                                tooltip: '浏览',
                                icon: const Icon(Icons.folder_open_outlined),
                                onPressed: () async {
                                  final selected = flag.endsWith('-dir')
                                      ? await getDirectoryPath()
                                      : flag == '--output'
                                      ? (await getSaveLocation())?.path
                                      : (await openFile())?.path;
                                  if (mounted && selected != null) {
                                    setState(() => entries[index] = selected);
                                  }
                                },
                              )
                            : null,
                      ),
                    ),
            ),
          if (repeatable.contains(flag))
            TextButton.icon(
              onPressed: () => setState(() => entries.add('')),
              icon: const Icon(Icons.add),
              label: const Text('添加一项'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final available = tools[mode] ?? [];
    final filtered = available.where(
      (option) =>
          '${option.flag} ${option.description}'.toLowerCase().contains(query),
    );
    return AlertDialog(
      title: const Text('下载选项与工具'),
      content: SizedBox(
        width: 620,
        height: 500,
        child: Column(
          children: [
            if (loading) const LinearProgressIndicator(),
            if (!loading && available.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                initialValue: mode,
                decoration: const InputDecoration(labelText: '操作'),
                items: [
                  for (final entry in toolLabels.entries)
                    if (tools.containsKey(entry.key))
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                ],
                onChanged: (value) => setState(() {
                  mode = value!;
                  values.clear();
                  error = null;
                }),
              ),
              if (mode.isEmpty) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: address,
                  decoration: InputDecoration(
                    labelText: '链接或本地清单',
                    suffixIcon: IconButton(
                      tooltip: '选择本地清单',
                      icon: const Icon(Icons.folder_open_outlined),
                      onPressed: () async {
                        final file = await openFile();
                        if (mounted && file != null) address.text = file.path;
                      },
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                onChanged: (value) =>
                    setState(() => query = value.trim().toLowerCase()),
                decoration: const InputDecoration(
                  labelText: '搜索选项',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(children: filtered.map(optionRow).toList()),
              ),
            ],
            if (error case final message?)
              Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: available.isEmpty ? null : submit,
          child: const Text('运行'),
        ),
      ],
    );
  }
}

extension on String {
  String? get nonEmpty => isEmpty ? null : this;
}
