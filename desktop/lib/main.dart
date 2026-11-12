import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'advanced.dart';
import 'core_output.dart';
import 'core_service.dart';
import 'settings.dart';

void main() => runApp(const DownloadApp());

class DownloadApp extends StatefulWidget {
  const DownloadApp({super.key});

  @override
  State<DownloadApp> createState() => _DownloadAppState();
}

class _DownloadAppState extends State<DownloadApp> {
  Preferences preferences = Preferences.defaults();

  ThemeData theme(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: preferences.seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      fontFamilyFallback: const [
        'Microsoft YaHei UI',
        'PingFang SC',
        'Noto Sans CJK SC',
      ],
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'SegmentDesk',
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    themeMode: preferences.themeMode,
    home: Workspace(
      onPreferencesChanged: (value) => setState(() => preferences = value),
    ),
  );
}

class Task {
  Task(this.name, this.folder);
  final String name;
  final String folder;
  String state = '下载中';
  final List<String> log = [];
}

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.onPreferencesChanged});
  final ValueChanged<Preferences> onPreferencesChanged;

  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  final core = CoreService();
  final tasks = <Task>[];
  CoreInstall? installed;
  Task? selected;
  Process? process;
  bool updating = false;
  bool launching = false;
  int filter = 0;
  String status = '就绪';
  Preferences preferences = Preferences.defaults();
  bool preferencesReady = false;

  bool get busy => updating || launching || process != null;

  @override
  void initState() {
    super.initState();
    loadPreferences();
    core
        .installed()
        .then((value) {
          if (mounted) setState(() => installed = value);
        })
        .catchError((Object error) {
          if (mounted) setState(() => status = '读取核心失败：$error');
        });
  }

  Future<void> loadPreferences() async {
    try {
      final value = await Preferences.load();
      if (mounted) applyPreferences(value);
    } on Exception catch (error) {
      if (mounted) setState(() => status = '读取设置失败：$error');
    } finally {
      if (mounted) setState(() => preferencesReady = true);
    }
  }

  Future<void> openSettings() async {
    final value = await showDialog<Preferences>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SettingsDialog(initial: preferences, core: installed),
    );
    if (value != null && mounted) applyPreferences(value);
  }

  void applyPreferences(Preferences value) {
    setState(() => preferences = value);
    widget.onPreferencesChanged(value);
  }

  Future<void> update() async {
    if (busy) return;
    setState(() => updating = true);
    try {
      final value = await core.update((message) {
        if (mounted) setState(() => status = message);
      });
      if (mounted) {
        setState(() {
          installed = value;
          status = '核心已就绪 · ${value.tag}';
        });
      }
    } catch (error) {
      if (mounted) setState(() => status = '更新失败：$error');
    } finally {
      if (mounted) setState(() => updating = false);
    }
  }

  Future<void> createTask() async {
    final active = installed;
    if (active == null || busy || !preferencesReady) return;
    final request = await showDialog<DownloadRequest>(
      context: context,
      builder: (_) => NewDownload(initialFolder: preferences.folder),
    );
    if (request == null || !mounted || busy) return;
    await launch(
      active,
      AdvancedRequest(
        request.name.isEmpty ? Uri.parse(request.url).host : request.name,
        request.folder,
        [
          request.url,
          '--save-dir',
          request.folder,
          '--auto-select',
          '--no-ansi-color',
          '--no-log',
          '--ui-language',
          'zh-CN',
          '--disable-update-check',
          if (preferences.container != 'none') ...[
            '-M',
            'format=${preferences.container}',
          ],
          if (request.name.isNotEmpty) ...['--save-name', request.name],
        ],
      ),
    );
  }

  Future<void> openAdvanced() async {
    final active = installed;
    if (active == null || busy || !preferencesReady) return;
    final request = await showDialog<AdvancedRequest>(
      context: context,
      builder: (_) =>
          AdvancedDialog(core: active, directory: preferences.folder),
    );
    if (request != null && mounted && !busy) await launch(active, request);
  }

  Future<void> launch(CoreInstall active, AdvancedRequest request) async {
    final task = Task(request.title, request.directory);
    setState(() {
      tasks.insert(0, task);
      selected = task;
      launching = true;
      filter = 0;
      status = '正在启动任务…';
    });
    try {
      await Directory(request.directory).create(recursive: true);
      final child = await Process.start(
        active.executable,
        request.arguments,
        workingDirectory: request.directory,
      );
      process = child;
      unawaited(child.stdin.close());
      if (mounted) {
        setState(() {
          launching = false;
          status = '正在下载';
        });
      }
      void record(String line) {
        if (!mounted) return;
        setState(() {
          task.log.add(line);
          if (task.log.length > 1000) task.log.removeAt(0);
        });
      }

      Future<void> read(Stream<List<int>> stream) =>
          coreOutputLines(stream).forEach(record);
      await Future.wait([read(child.stdout), read(child.stderr)]);
      final code = await child.exitCode;
      if (mounted) {
        setState(() {
          if (task.state != '停止中') {
            task.state = code == 0 ? '已完成' : '失败 ($code)';
          } else {
            task.state = '已停止';
          }
          status = task.state;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          task.state = '失败';
          task.log.add('$error');
          status = '下载失败';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          process = null;
          launching = false;
        });
      }
    }
  }

  void stop() {
    final active = tasks.firstOrNull;
    if (process?.kill() == true && active != null) {
      setState(() => active.state = '停止中');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final visible = tasks.where((task) {
      final running = task.state == '下载中' || task.state == '停止中';
      return filter == 0 || (filter == 1 ? running : !running);
    }).toList();
    return Scaffold(
      body: Row(
        children: [
          Material(
            color: colors.surfaceContainer,
            child: SizedBox(
              width: 210,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 0, 24),
                      child: Row(
                        children: [
                          Icon(
                            Icons.downloading_rounded,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FittedBox(
                              alignment: Alignment.centerLeft,
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'SegmentDesk',
                                style: text.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final (index, label, icon) in [
                      (0, '全部任务', Icons.list_alt_rounded),
                      (1, '运行中', Icons.timelapse_rounded),
                      (2, '已结束', Icons.check_circle_outline_rounded),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          leading: Icon(icon, size: 20),
                          title: Text(label),
                          selected: filter == index,
                          selectedTileColor: colors.secondaryContainer,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          onTap: () => setState(() => filter = index),
                        ),
                      ),
                    const Spacer(),
                    ListTile(
                      leading: const Icon(Icons.tune_rounded, size: 20),
                      title: const Text('选项与工具'),
                      onTap: installed == null || busy || !preferencesReady
                          ? null
                          : openAdvanced,
                    ),
                    ListTile(
                      leading: const Icon(Icons.settings_outlined, size: 20),
                      title: const Text('设置'),
                      onTap: preferencesReady ? openSettings : null,
                    ),
                    const Divider(),
                    Text('下载核心', style: text.labelLarge),
                    const SizedBox(height: 6),
                    Text(installed?.tag ?? '未安装', style: text.bodySmall),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: busy ? null : update,
                      icon: const Icon(
                        Icons.system_update_alt_rounded,
                        size: 18,
                      ),
                      label: Text(installed == null ? '安装核心' : '检查更新'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          ['全部任务', '运行中', '已结束'][filter],
                          style: text.headlineSmall,
                        ),
                      ),
                      if (process != null)
                        OutlinedButton(
                          onPressed: stop,
                          child: const Text('停止任务'),
                        ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: installed == null || busy
                            ? null
                            : createTask,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('新建下载'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: Card(
                      color: colors.surfaceContainerLow,
                      elevation: 0,
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: visible.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.download_rounded,
                                    color: colors.primary,
                                    size: 40,
                                  ),
                                  const SizedBox(height: 12),
                                  Text('暂无任务', style: text.titleLarge),
                                  const SizedBox(height: 6),
                                  Text(
                                    installed == null
                                        ? '安装下载核心后即可添加链接'
                                        : '点击「新建下载」添加链接',
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              itemCount: visible.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, index) {
                                final task = visible[index];
                                return ListTile(
                                  selected: identical(selected, task),
                                  selectedTileColor: colors.secondaryContainer
                                      .withValues(alpha: .4),
                                  leading: const Icon(Icons.movie_outlined),
                                  title: Text(task.name),
                                  subtitle: Text(
                                    task.folder,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: Text(task.state),
                                  onTap: () => setState(() => selected = task),
                                );
                              },
                            ),
                    ),
                  ),
                  if (selected != null && visible.contains(selected)) ...[
                    const SizedBox(height: 16),
                    Text('任务日志', style: text.titleSmall),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 128,
                      child: Card(
                        margin: EdgeInsets.zero,
                        elevation: 0,
                        color: colors.surfaceContainerLow,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: SingleChildScrollView(
                            reverse: true,
                            child: SelectableText(selected!.log.join('\n')),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (updating) const LinearProgressIndicator(),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: SelectableText(status, style: text.bodySmall),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DownloadRequest {
  const DownloadRequest(this.url, this.folder, this.name);
  final String url, folder, name;
}

class NewDownload extends StatefulWidget {
  const NewDownload({super.key, required this.initialFolder});
  final String initialFolder;

  @override
  State<NewDownload> createState() => _NewDownloadState();
}

class _NewDownloadState extends State<NewDownload> {
  final form = GlobalKey<FormState>();
  final url = TextEditingController();
  final name = TextEditingController();
  late final folder = TextEditingController(text: widget.initialFolder);

  @override
  void dispose() {
    url.dispose();
    name.dispose();
    folder.dispose();
    super.dispose();
  }

  void submit() {
    if (form.currentState!.validate()) {
      Navigator.pop(
        context,
        DownloadRequest(url.text.trim(), folder.text.trim(), name.text.trim()),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建下载'),
    scrollable: true,
    content: SizedBox(
      width: 520,
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              autofocus: true,
              controller: url,
              decoration: const InputDecoration(
                labelText: '下载链接',
                hintText: 'https://…',
              ),
              validator: (value) {
                final uri = Uri.tryParse(value?.trim() ?? '');
                return uri != null &&
                        (uri.scheme == 'https' || uri.scheme == 'http') &&
                        uri.host.isNotEmpty
                    ? null
                    : '请输入完整的 HTTP 或 HTTPS 链接';
              },
              onFieldSubmitted: (_) => submit(),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: folder,
              decoration: InputDecoration(
                labelText: '保存目录',
                suffixIcon: IconButton(
                  tooltip: '选择保存目录',
                  icon: const Icon(Icons.folder_open_rounded),
                  onPressed: () async {
                    final selected = await getDirectoryPath();
                    if (selected != null && mounted) folder.text = selected;
                  },
                ),
              ),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请输入保存目录' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: name,
              decoration: const InputDecoration(labelText: '文件名（可选）'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('开始下载')),
    ],
  );
}
