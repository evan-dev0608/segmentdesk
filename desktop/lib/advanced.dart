import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'core_output.dart';
import 'core_service.dart';
import 'selection.dart';
import 'selection_dialog.dart';

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

/// 从根 --help 的 "Commands:" 段提取已注册的子命令名。
///
/// 上游的 UtilityHelpAction 直接委托 System.CommandLine 的标准 HelpAction，
/// 该段只列子命令名、不含可执行文件名，因此核心被重命名也不会失效，
/// 也不依赖 Usage 行的列宽。找不到该段时返回空集，由调用方兜底。
Set<String> parseCoreCommands(String help) {
  final lines = const LineSplitter().convert(help);
  final heading = lines.indexWhere(
    (line) => RegExp(r'^\s*Commands:\s*$', caseSensitive: false).hasMatch(line),
  );
  if (heading < 0) return const <String>{};
  final commands = <String>{};
  for (final line in lines.skip(heading + 1)) {
    if (line.trim().isEmpty) continue;
    // 段内条目至少缩进两格；顶格的下一节标题表示本段结束。
    if (!RegExp(r'^\s{2,}').hasMatch(line)) break;
    final match = RegExp(r'^\s{2,}([a-z][a-z0-9-]*)(?:\s{2,}|$)')
        .firstMatch(line);
    if (match != null) commands.add(match[1]!);
  }
  return commands;
}

/// 子命令 --help 的 Usage 行是否指向该子命令。
/// 仅作 Commands: 段缺失时的兜底，且不硬编码可执行文件名。
bool coreUsageMatchesCommand(String help, String command) {
  final lines = const LineSplitter().convert(help);
  final heading = lines.indexWhere(
    (line) => line.trim().toLowerCase() == 'usage:',
  );
  if (heading < 0) return false;
  final usage = lines
      .skip(heading + 1)
      .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
  return RegExp(
    '^\\s*\\S+\\s+${RegExp.escape(command)}(?:\\s|\$)',
    caseSensitive: false,
  ).hasMatch(usage);
}

/// 把「读取轨道」的结果回填到高级选项表单。
/// 手动选轨与 --auto-select true 互斥，因此有轨道选择时必须关闭自动选轨。
Map<String, List<String>> applySelectionToValues(
  Map<String, List<String>> values,
  TrackSelection choice,
) => {
  ...values,
  '--select-video': [choice.video ?? ''],
  '--select-audio': [choice.audio ?? ''],
  '--select-subtitle': [choice.subtitle ?? ''],
  if (choice.partsShown) '--vod-drop-parts': [choice.dropParts ?? ''],
  if (choice.hasTrack) '--auto-select': ['false'],
};

/// 把 IPTV 频道选择回填成一条 --select-video 表达式。
Map<String, List<String>> applyChannelsToValues(
  Map<String, List<String>> values,
  List<String> channels,
) => {
  ...values,
  '--select-video': [channelFilter(channels)],
  '--auto-select': ['false'],
};

class AdvancedRequest {
  const AdvancedRequest(
    this.title,
    this.directory,
    this.arguments, {
    this.tool = false,
    this.executable,
  });
  final String title, directory;
  final List<String> arguments;
  final String? executable;

  /// 是否为上游工具子命令（concat / merge / mux / doctor）。
  /// 这些子命令未注册根命令的 --ffmpeg-binary-path 等选项。
  final bool tool;

  /// doctor 的职责是检查本机环境（含全局配置文件），不能被配置隔离改变。
  bool get isDoctor => tool && arguments.firstOrNull == 'doctor';
}

class AdvancedDialog extends StatefulWidget {
  const AdvancedDialog({
    super.key,
    required this.core,
    required this.directory,
    this.initialInput = '',
    this.initialName = '',
    this.initialContainer = 'none',
    this.toolsOnly = false,
    this.ffmpeg,
  });
  final CoreInstall core;
  final String directory;
  final String initialInput;
  final String initialName;
  final String initialContainer;
  final bool toolsOnly;
  final String? ffmpeg;

  @override
  State<AdvancedDialog> createState() => _AdvancedDialogState();
}

class _AdvancedDialogState extends State<AdvancedDialog> {
  Future<void> remuxLocalFile() async {
    final ffmpeg = widget.ffmpeg;
    if (ffmpeg == null || probing) return;
    setState(() => probing = true);
    try {
      final input = await openFile(
        initialDirectory: Directory(widget.directory).existsSync()
            ? widget.directory
            : null,
      );
      if (input == null || !mounted) return;
      final output = await getSaveLocation(
        initialDirectory: widget.directory,
        suggestedName: '${input.name}.mkv',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Matroska', extensions: ['mkv']),
        ],
      );
      if (output == null || !mounted) return;
      final path = output.path.toLowerCase().endsWith('.mkv')
          ? output.path
          : '${output.path}.mkv';
      Navigator.pop(
        context,
        AdvancedRequest(
          '混流 · ${input.name}',
          File(path).parent.path,
          ['-nostdin', '-n', '-i', input.path, '-map', '0', '-c', 'copy', path],
          tool: true,
          executable: ffmpeg,
        ),
      );
    } on Exception catch (exception) {
      if (mounted) setState(() => error = '无法选择文件：$exception');
    } finally {
      if (mounted) setState(() => probing = false);
    }
  }

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
  late final address = TextEditingController(text: widget.initialInput);
  final tools = <String, List<CoreOption>>{};
  Map<String, List<String>> values = {};
  String mode = '';
  String query = '';
  String? error;
  bool loading = true;
  bool probing = false;

  /// 表单里是否存在核心提供的手动选轨选项。
  bool get supportsTrackSelection =>
      tools['']?.any((option) => option.flag == '--select-video') ?? false;

  /// 旧发行版没有 --no-config；预览命令同样不能无条件塞入未知参数。
  bool get supportsConfigIsolation =>
      tools['']?.any((option) => option.flag == '--no-config') ?? false;

  /// 从可重复/单值表单里取第一个有效值。
  String? firstValue(String flag) {
    for (final value in values[flag] ?? const <String>[]) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty && trimmed != '默认') return trimmed;
    }
    return null;
  }

  List<String> allValues(String flag) => (values[flag] ?? const <String>[])
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty && value != '默认')
      .toList();

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

  /// 读取核心帮助，中文乱码时回退英文。command 为空表示根帮助。
  Future<String?> readHelp(String command) async {
    Future<ProcessResult> helpFor(String language) => Process.run(
      widget.core.executable,
      [if (command.isNotEmpty) command, '--ui-language', language, '--help'],
      stdoutEncoding: null,
    ).timeout(const Duration(seconds: 12));
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
      help = utf8.decode(english.stdout as List<int>, allowMalformed: true);
    }
    return help;
  }

  Future<void> load() async {
    try {
      // 先取根帮助，从 Commands: 段确定核心实际注册了哪些工具子命令。
      // 旧版核心会把 "concat --help" 解析成 input + --help 并照样返回 0，
      // 所以退出码本身不是能力信号；Commands: 段才是。
      final rootHelp = await readHelp('');
      final registered = rootHelp == null
          ? const <String>{}
          : parseCoreCommands(rootHelp);
      final candidates = toolLabels.keys
          .where((command) => widget.toolsOnly == command.isNotEmpty)
          .where(
            (command) =>
                command.isEmpty ||
                registered.isEmpty ||
                registered.contains(command),
          )
          .toList();
      final results = await Future.wait(
        candidates.map((command) async {
          final help = command.isEmpty ? rootHelp : await readHelp(command);
          if (help == null || help.isEmpty) return null;
          // Commands: 段缺失时退回用法行判定，但不再硬编码可执行文件名。
          if (registered.isEmpty &&
              command.isNotEmpty &&
              !coreUsageMatchesCommand(help, command)) {
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
        if (widget.toolsOnly) {
          tools.remove('');
          mode = tools.keys.firstOrNull ?? '';
          if (tools.isEmpty) error = '当前核心未提供文件工具。';
        } else {
          tools.removeWhere((command, _) => command.isNotEmpty);
          if (tools['']?.isNotEmpty != true) error = '无法读取当前核心的参数帮助。';
          final flags = tools['']?.map((option) => option.flag).toSet() ?? {};
          if (flags.contains('--save-dir')) {
            values['--save-dir'] = [widget.directory];
          }
          if (flags.contains('--mux-after-done') &&
              widget.initialContainer != 'none') {
            values['--mux-after-done'] = ['format=${widget.initialContainer}'];
          }
          if (widget.initialName.isNotEmpty &&
              tools['']?.any((option) => option.flag == '--save-name') ==
                  true) {
            values['--save-name'] = [widget.initialName];
          }
        }
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

  String processHint(Object? output) {
    if (output is! List<int> || output.isEmpty) return '';
    final lines = const LineSplitter()
        .convert(utf8.decode(output, allowMalformed: true))
        .map(cleanCoreLogLine)
        .whereType<String>()
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    final tail = lines.length > 3 ? lines.sublist(lines.length - 3) : lines;
    return ' · ${tail.join(' | ')}';
  }

  Object? readMetaJson(File file) {
    var text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return jsonDecode(text);
  }

  /// 让核心只解析清单并写出 meta.json / meta_selected.json，再据此选轨。
  Future<void> previewTracks() async {
    final input = address.text.trim();
    if (input.isEmpty || input.startsWith('-') || input.startsWith('@')) {
      setState(() => error = '请先输入链接或选择本地清单。');
      return;
    }
    setState(() {
      probing = true;
      error = null;
    });
    Directory? temporary;
    try {
      temporary = await Directory.systemTemp.createTemp('segmentdesk-preview-');
      final child = await Process.start(
        widget.core.executable,
        previewArguments(
          input: input,
          tempDir: temporary.path,
          values: values,
          isolateConfig: supportsConfigIsolation,
        ),
        workingDirectory: widget.directory,
      );
      await child.stdin.close();
      final stdout = <int>[];
      final stderr = <int>[];
      final draining = Future.wait([
        child.stdout.forEach(stdout.addAll),
        child.stderr.forEach(stderr.addAll),
      ]);
      // Future.timeout 不会终止子进程，必须在超时分支里显式 kill，
      // 否则反复预览会留下继续解析清单的核心进程。
      final code = await child.exitCode.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          child.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await draining;
      if (code == -1) {
        throw StateError('读取轨道超时（45 秒），已终止核心进程。');
      }
      final folder = Directory('${temporary.path}/$previewSaveName');
      final metaFile = File('${folder.path}/meta.json');
      if (!metaFile.existsSync()) {
        throw StateError(
          '核心未输出轨道信息（退出码 $code）'
          '${processHint(stdout)}${processHint(stderr)}',
        );
      }
      final all = readMetaJson(metaFile);
      final selectedFile = File('${folder.path}/meta_selected.json');
      final selected = selectedFile.existsSync()
          ? readMetaJson(selectedFile)
          : const <Object?>[];
      final tracks = coreTracks(all);
      // meta.json 先于 FetchPlayListAsync 写出，HLS 的 Playlist 可能为 null；
      // 因此还要合并选中轨道元数据里的 DiscontinuitySequence。
      final parts = vodParts([all, selected]);
      if (tracks.isEmpty) {
        throw StateError('核心输出的元数据中没有可用轨道。');
      }
      if (!mounted || address.text.trim() != input) return;
      final choice = await showDialog<TrackSelection>(
        context: context,
        builder: (_) => TrackSelectionDialog(
          tracks: tracks,
          parts: parts,
          supportsParts: supportsVodSelection,
          initialDrop: firstValue('--vod-drop-parts') ?? '',
        ),
      );
      if (choice != null && mounted && address.text.trim() == input) {
        applyTrackSelection(choice);
      }
    } catch (exception) {
      if (mounted) setState(() => error = '无法读取轨道：$exception');
    } finally {
      try {
        temporary?.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录清理失败不影响选择结果。
      }
      if (mounted) setState(() => probing = false);
    }
  }

  void applyTrackSelection(TrackSelection choice) {
    setState(() {
      values = applySelectionToValues(values, choice);
      query = '';
      error = null;
    });
  }

  Future<void> loadLocalChannels() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'M3U 播放列表', extensions: ['m3u', 'm3u8']),
      ],
    );
    if (file == null || !mounted) return;
    setState(() {
      probing = true;
      error = null;
    });
    try {
      final content = utf8.decode(
        await file.readAsBytes(),
        allowMalformed: true,
      );
      await chooseChannels(file.path, parseChannels(content));
    } catch (exception) {
      if (mounted) setState(() => error = '无法读取 IPTV：$exception');
    } finally {
      if (mounted) setState(() => probing = false);
    }
  }

  Future<void> loadRemoteChannels() async {
    final input = address.text.trim();
    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      setState(() => error = '请先在下载地址框粘贴 M3U 链接。');
      return;
    }
    setState(() {
      probing = true;
      error = null;
    });
    try {
      final cookiePath = firstValue('--cookies');
      String? cookies;
      if (cookiePath != null) {
        final cookie = File(cookiePath);
        cookies =
            await (cookie.isAbsolute
                    ? cookie
                    : File('${widget.directory}/$cookiePath'))
                .readAsString();
      }
      final systemProxy = firstValue('--use-system-proxy');
      final content = await fetchRemotePlaylist(
        input,
        headers: allValues('--header'),
        cookies: cookies,
        proxy: firstValue('--custom-proxy'),
        useSystemProxy: systemProxy != 'false' && systemProxy != '关闭',
      );
      await chooseChannels(input, parseChannels(content, base: input));
    } catch (exception) {
      if (mounted) setState(() => error = '无法读取 IPTV：$exception');
    } finally {
      if (mounted) setState(() => probing = false);
    }
  }

  Future<void> chooseChannels(String source, List<String> channels) async {
    if (channels.isEmpty) {
      throw StateError('播放列表没有带名称的 HTTP(S) 频道');
    }
    if (!mounted) return;
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => ChannelSelectionDialog(channels: channels),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() {
      address.text = source;
      values = applyChannelsToValues(values, picked);
      query = '';
      error = null;
    });
  }

  void submit() {
    if (probing) return;
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
        tool: mode.isNotEmpty,
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
                      key: ValueKey(
                        '$mode:$flag:$index:${entries[index].hashCode}',
                      ),
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
    if (widget.toolsOnly && (loading || tools.isEmpty)) {
      return AlertDialog(
        title: const Text('文件工具'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: loading
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('正在检查核心支持的工具…'),
                  SizedBox(height: 12),
                  LinearProgressIndicator(),
                ],
              )
            : Text(
                widget.ffmpeg == null
                    ? '当前核心没有独立文件工具。安装 FFmpeg 并将它加入 PATH，即可使用本地混流。'
                    : '选择一个本地媒体文件，将其中的轨道原样封装为 MKV。${probing
                          ? ''
                          : error != null && !error!.contains('未提供')
                          ? '\n$error'
                          : ''}',
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          if (!loading && widget.ffmpeg != null)
            FilledButton(
              onPressed: probing ? null : remuxLocalFile,
              child: const Text('选择媒体文件'),
            ),
        ],
      );
    }
    final available = tools[mode] ?? [];
    const common = [
      '--save-dir',
      '--save-name',
      '--mux-after-done',
      '--thread-count',
    ];
    final filtered = available
        .where(
          (option) => '${option.flag} ${option.description}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    if (!widget.toolsOnly) {
      int rank(CoreOption option) {
        final index = common.indexOf(option.flag);
        return index < 0 ? common.length + available.indexOf(option) : index;
      }

      filtered.sort((a, b) => rank(a).compareTo(rank(b)));
    }
    return AlertDialog(
      title: Text(widget.toolsOnly ? '文件工具' : '高级下载选项'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: AbsorbPointer(
        absorbing: probing,
        child: ExcludeFocus(
          excluding: probing,
          child: SizedBox(
            width: 620,
            height: 500,
            child: Column(
              children: [
                if (loading || probing) const LinearProgressIndicator(),
                if (!loading && available.isNotEmpty) ...[
                  if (widget.toolsOnly)
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
                            if (mounted && !probing && file != null) {
                              address.text = file.path;
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: [
                        TextButton.icon(
                          onPressed: probing || !supportsTrackSelection
                              ? null
                              : previewTracks,
                          icon: const Icon(Icons.playlist_add_check_outlined),
                          label: const Text('读取轨道'),
                        ),
                        TextButton.icon(
                          onPressed: probing || !supportsTrackSelection
                              ? null
                              : loadLocalChannels,
                          icon: const Icon(Icons.file_open_outlined),
                          label: const Text('本地 IPTV'),
                        ),
                        TextButton.icon(
                          onPressed: probing || !supportsTrackSelection
                              ? null
                              : loadRemoteChannels,
                          icon: const Icon(Icons.cloud_download_outlined),
                          label: const Text('远程 IPTV'),
                        ),
                      ],
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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: available.isEmpty || probing ? null : submit,
          child: Text(widget.toolsOnly ? '运行' : '开始下载'),
        ),
      ],
    );
  }
}

extension on String {
  String? get nonEmpty => isEmpty ? null : this;
}
