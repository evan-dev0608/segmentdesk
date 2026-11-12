import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'advanced.dart';
import 'browser_import.dart';
import 'client_updates.dart';
import 'core_output.dart';
import 'core_service.dart';
import 'ffmpeg.dart';
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
  Task(this.request);
  final AdvancedRequest request;
  String get name => request.title;
  String get folder {
    final arguments = request.arguments;
    for (final flag in ['--save-dir', '--output']) {
      final index = arguments.lastIndexOf(flag);
      if (index > 0 && index + 1 < arguments.length) {
        final value = arguments[index + 1];
        final path = File(value).isAbsolute
            ? value
            : '${request.directory}${CoreService.sep}$value';
        return flag == '--output' ? File(path).parent.path : path;
      }
    }
    return request.directory;
  }

  String state = '准备中';
  bool running = true;
  bool failed = false;
  int errorSignals = 0;
  bool uncheckedSegments = false;
  double? progress;
  final List<String> log = [];
}

String? coreTaskPhase(String line) {
  final text = line.toLowerCase();
  if (text.contains('开始下载...') ||
      text.contains('開始下載...') ||
      text.contains('start downloading...')) {
    return '下载中';
  }
  if (text.contains('二进制合并中') ||
      text.contains('二進位制合併中') ||
      text.contains('ffmpeg合并中') ||
      text.contains('ffmpeg合併中') ||
      text.contains('binary merging...') ||
      text.contains('ffmpeg merging...') ||
      // StaticText.cs 的 partMerge：分片过多时先分块合并，同样属于合并阶段。
      text.contains('分片数量达到') ||
      text.contains('分片數量達到') ||
      text.contains('at least 1800 segments')) {
    return '合并中';
  }
  return null;
}

/// 上游默认读取全局 config.conf（命令行 > 配置 > 默认，可重复选项会合并），
/// 这些注入值在界面上完全不可见。用户显式指定 --config 时不能追加
/// --no-config：上游 ConfigFile.cs 会对两者并存直接抛 configFileConflict。
List<String> isolateCoreArguments(
  List<String> arguments, {
  bool isolate = true,
}) {
  if (!isolate ||
      arguments.any((value) => value == '--config' || value == '--no-config')) {
    return arguments;
  }
  return [...arguments, '--no-config'];
}

/// 官方发行版与上游源码存在版本差：例如 v0.6.0-beta（20260628）并没有
/// --no-config，无条件追加会让所有任务因「未知参数」直接失败。
/// 这里按帮助文本判断能力，探测失败时宁可不隔离，也不能让任务起不来。
bool coreHelpSupports(String help, String flag) {
  for (final line in const LineSplitter().convert(help)) {
    final trimmed = line.trimLeft();
    // 只看选项行，避免描述文字里提到同名参数时误判。
    if (!trimmed.startsWith('-')) continue;
    if (trimmed.split(RegExp(r'\s+')).contains(flag)) return true;
  }
  return false;
}

Future<bool> probeCoreFlag(String executable, String flag) async {
  try {
    final result = await Process.run(executable, [
      '--ui-language',
      'en-US',
      '--help',
    ], stdoutEncoding: null).timeout(const Duration(seconds: 12));
    if (result.exitCode != 0) return false;
    return coreHelpSupports(
      utf8.decode(result.stdout as List<int>, allowMalformed: true),
      flag,
    );
  } catch (_) {
    return false;
  }
}

/// 找到 ffmpeg 时把绝对路径显式交给核心，避免两端解析到不同副本。
/// 找不到时不阻断：核心仍有 CheckMediaTools 与自带的工具查找逻辑。
List<String> withFFmpegPath(List<String> arguments, String? ffmpeg) {
  if (ffmpeg == null || arguments.contains('--ffmpeg-binary-path')) {
    return arguments;
  }
  return [...arguments, '--ffmpeg-binary-path', ffmpeg];
}

/// 上游 SimpleDownloadManager.cs 在 --check-segments-count false 时会
/// 静默移除缺失分片并继续合并，可能返回退出码 0 且没有 ERROR 日志。
bool hasDisabledSegmentCheck(List<String> arguments) {
  for (var index = 0; index + 1 < arguments.length; index++) {
    if (arguments[index] == '--check-segments-count' &&
        arguments[index + 1].toLowerCase() == 'false') {
      return true;
    }
  }
  return false;
}

/// 上游部分失败不体现在退出码里：分片重试耗尽只写 Extra / WARN，
/// 某些失败路径还会被吞掉后继续推进。只认 ERROR 级正式日志和
/// 上游明确的失败字面量，避免把普通 WARN 误判成失败。
bool coreFailureSignal(String line) {
  final text = line.toLowerCase();
  if (RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3}\s+error\b').hasMatch(text)) {
    return true;
  }
  const literals = [
    'segment count check not pass',
    '分片数量校验不通过',
    '分片數量校驗不通過',
    'the retry attempts have been exhausted',
    'mux failed',
    'decryption failed',
    '解密失败',
    'processing failed',
    '处理失败',
    '處理失敗',
    'failed to load url',
    '加载url失败',
  ];
  return literals.any((literal) => text.contains(literal));
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
  bool checkingEnvironment = true;
  String? coreUpdateStatus;
  String? clientVersion;
  String? clientUpdateStatus;
  String? availableClientTag;
  bool checkingClientUpdate = false;
  String? environmentIssue;
  bool? ffmpegAvailable;
  Future<bool>? noConfigProbe;
  Timer? browserImportTimer;
  bool checkingBrowserImport = false;
  bool showingSettings = false;
  String? browserImportNotice;

  bool get busy => updating || launching || process != null;

  /// 同一核心只探测一次；换核心后由 update() 清空缓存。
  Future<bool> supportsNoConfig(String executable) =>
      noConfigProbe ??= probeCoreFlag(executable, '--no-config');

  @override
  void initState() {
    super.initState();
    unawaited(loadClientVersion());
    final inbox = BrowserImport.inbox;
    if (inbox != null) {
      browserImportTimer = Timer.periodic(
        const Duration(milliseconds: 750),
        (_) => unawaited(checkBrowserImport(inbox)),
      );
    }
    unawaited(
      loadPreferences().then((_) {
        if (mounted) return checkEnvironment();
      }),
    );
  }

  Future<void> checkEnvironment() async {
    final foundFFmpeg = resolveFFmpeg(preferences.ffmpegPath) != null;
    CoreInstall? active;
    String? issue;
    try {
      final customPath = preferences.corePath;
      active = customPath.isEmpty
          ? await core.installed()
          : await CoreService.inspectExecutable(customPath);
      if (active != null && customPath.isEmpty) {
        final probe = await Process.run(active.executable, [
          '--version',
        ]).timeout(const Duration(seconds: 5));
        if (probe.exitCode != 0) throw StateError('核心版本检查失败');
      }
    } catch (_) {
      active = null;
      issue = preferences.corePath.isEmpty
          ? '核心无法运行，请重新安装。'
          : '自定义核心无法运行，请在设置中更换路径。';
    }
    if (!mounted) return;
    setState(() {
      installed = active;
      environmentIssue = issue;
      ffmpegAvailable = foundFFmpeg;
      checkingEnvironment = false;
      if (active != null && !foundFFmpeg && status == '就绪') {
        status = '未找到 FFmpeg，请在设置中查看环境提示。';
      }
    });
  }

  Future<void> loadClientVersion() async {
    try {
      final version = await ClientUpdates.installedVersion();
      if (!mounted) return;
      setState(() => clientVersion = version);
      if (kReleaseMode) await checkClientUpdate();
    } catch (_) {
      if (mounted) setState(() => clientUpdateStatus = '无法读取当前版本。');
    }
  }

  Future<void> checkClientUpdate() async {
    if (checkingClientUpdate) return;
    setState(() {
      checkingClientUpdate = true;
      clientUpdateStatus = '正在检查 GitHub 正式版…';
    });
    try {
      final version = clientVersion ?? await ClientUpdates.installedVersion();
      final tag = await ClientUpdates.latestTag();
      final newer = ClientUpdates.isNewer(tag, version);
      if (!mounted) return;
      setState(() {
        clientVersion = version;
        availableClientTag = newer ? tag : null;
        clientUpdateStatus = newer ? '发现新版 $tag' : '已是最新正式版';
      });
    } catch (_) {
      if (mounted) {
        setState(() => clientUpdateStatus = '检查失败，请检查网络后重试。');
      }
    } finally {
      if (mounted) setState(() => checkingClientUpdate = false);
    }
  }

  Future<void> openClientUpdates() async {
    final tag = availableClientTag;
    final releases = tag == null
        ? ClientUpdates.releases
        : '${ClientUpdates.releases}/tag/${Uri.encodeComponent(tag)}';
    try {
      final result = await Process.run(
        Platform.isWindows
            ? 'rundll32.exe'
            : Platform.isMacOS
            ? 'open'
            : 'xdg-open',
        [if (Platform.isWindows) 'url.dll,FileProtocolHandler', releases],
      );
      if (result.exitCode != 0) throw StateError('浏览器启动失败');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法打开发布页：$releases')));
    }
  }

  @override
  void dispose() {
    browserImportTimer?.cancel();
    super.dispose();
  }

  Future<void> checkBrowserImport(Directory inbox) async {
    if (showingSettings) return;
    if (checkingBrowserImport ||
        !preferencesReady ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    checkingBrowserImport = true;
    try {
      if (!await inbox.exists()) return;
      await for (final file in inbox.list(followLinks: false)) {
        if (file is! File || !file.path.endsWith('.json')) continue;
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        if (installed == null || busy) {
          final message = installed == null
              ? '有浏览器导入等待处理，请先安装下载核心。'
              : '有浏览器导入等待处理，将在当前操作结束后打开。';
          if (browserImportNotice != message) {
            setState(() => browserImportNotice = message);
          }
          return;
        }
        final request = await file.length() <= 32768
            ? BrowserImport.parse(
                utf8.decode(await file.readAsBytes(), allowMalformed: true),
              )
            : null;
        if (!mounted ||
            showingSettings ||
            busy ||
            ModalRoute.of(context)?.isCurrent != true) {
          return;
        }
        file.deleteSync();
        if (browserImportNotice != null) {
          setState(() => browserImportNotice = null);
        }
        if (request != null) {
          if (!request.canImport) {
            setState(() => status = '当前版本尚未开放 ${request.type} 浏览器导入。');
            return;
          }
          await createTask(browserImport: request);
          return;
        }
      }
    } on FileSystemException {
      // The inbox can disappear during uninstall or be consumed by another window.
    } finally {
      checkingBrowserImport = false;
    }
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

  void applyPreferences(Preferences value) {
    setState(() => preferences = value);
    widget.onPreferencesChanged(value);
  }

  Future<CoreInstall?> update() async {
    if (busy || checkingEnvironment) return null;
    setState(() {
      updating = true;
      coreUpdateStatus = '正在检查可下载的核心…';
    });
    try {
      final value = await core.update((message) {
        if (mounted) setState(() => coreUpdateStatus = message);
      }, force: preferences.corePath.isEmpty && environmentIssue != null);
      if (!mounted) return null;
      setState(() {
        if (preferences.corePath.isEmpty) {
          installed = value;
          environmentIssue = null;
          noConfigProbe = null;
        }
        coreUpdateStatus = value.verified ? '下载核心已就绪' : '下载核心已就绪（本次未做完整性校验）';
      });
      return value;
    } catch (error) {
      if (mounted) setState(() => coreUpdateStatus = '下载失败：$error');
      return null;
    } finally {
      if (mounted) setState(() => updating = false);
    }
  }

  Future<void> createTask({BrowserImport? browserImport}) async {
    final active = installed;
    if (active == null || busy || !preferencesReady) return;
    final request = await showDialog<AdvancedRequest>(
      context: context,
      builder: (_) => NewDownload(
        initialFolder: preferences.folder,
        browserImport: browserImport,
        buildRequest: (input, folder, name) =>
            AdvancedRequest(name.isEmpty ? inputTitle(input) : name, folder, [
              input,
              '--save-dir',
              folder,
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
              if (name.isNotEmpty) ...['--save-name', name],
            ]),
        openOptions: (input, folder, name) => showDialog<AdvancedRequest>(
          context: context,
          builder: (_) => AdvancedDialog(
            core: active,
            directory: folder,
            initialInput: input,
            initialName: name,
            initialContainer: preferences.container,
            configuredFFmpeg: preferences.ffmpegPath,
          ),
        ),
      ),
    );
    if (request != null && mounted && !busy) await launch(active, request);
  }

  String inputTitle(String input) {
    final uri = Uri.tryParse(input);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return uri.pathSegments.where((part) => part.isNotEmpty).lastOrNull ??
          uri.host;
    }
    return File(input).uri.pathSegments.last;
  }

  Future<void> launch(CoreInstall active, AdvancedRequest request) async {
    final task = Task(request);
    setState(() {
      tasks.insert(0, task);
      selected = task;
      launching = true;
      filter = 0;
      status = '正在启动任务…';
    });
    try {
      await Directory(request.directory).create(recursive: true);
      // doctor 的职责是检查本机环境（含全局配置文件），豁免配置隔离。
      // 旧发行版没有 --no-config，此时只跳过隔离并提示全局配置可能生效。
      final canIsolate =
          request.executable == null &&
          !request.isDoctor &&
          await supportsNoConfig(active.executable);
      var arguments = isolateCoreArguments(
        request.arguments,
        isolate: canIsolate,
      );
      if (request.executable == null &&
          !canIsolate &&
          !request.isDoctor &&
          mounted) {
        task.log.add(
          '提示：当前核心未提供 --no-config，已跳过配置隔离；'
          '全局 config.conf 可能影响本次任务。',
        );
      }
      if (!request.tool) {
        final ffmpeg = resolveFFmpeg(preferences.ffmpegPath);
        if (ffmpeg == null &&
            preferences.ffmpegPath.isNotEmpty &&
            !arguments.contains('--ffmpeg-binary-path')) {
          throw StateError('自定义 FFmpeg 路径失效，请在设置中修正。');
        }
        if (ffmpeg == null && mounted) {
          setState(() {
            task.log.add(
              '提示：未在 PATH 中找到 ffmpeg，核心将按自身配置查找。'
              '若混流失败，请安装 FFmpeg 并重启客户端。',
            );
          });
        }
        arguments = withFFmpegPath(arguments, ffmpeg);
      }
      // 关闭分片数量校验时，上游会静默移除缺失分片并继续合并，
      // 可能以退出码 0 结束。GUI 无法从日志反推，只能显式提示风险。
      if (hasDisabledSegmentCheck(arguments) && mounted) {
        setState(() {
          task.uncheckedSegments = true;
          task.log.add(
            '提示：本次关闭了分片数量校验，核心可能跳过缺失分片并以退出码 0 结束，'
            '请核对输出文件是否完整。',
          );
        });
      }
      final child = await Process.start(
        request.executable ?? active.executable,
        arguments,
        workingDirectory: request.directory,
      );
      process = child;
      unawaited(child.stdin.close());
      if (mounted) {
        setState(() {
          launching = false;
          task.state = '核心运行中';
          status = task.state;
        });
      }
      void record(String line) {
        if (!mounted) return;
        setState(() {
          // 进度条每一帧都是独立行，折叠成一行，避免刷掉正式日志。
          if (task.log.isNotEmpty && shouldFoldLogLine(task.log.last, line)) {
            task.log.last = line;
          } else {
            task.log.add(line);
          }
          if (task.log.length > 1000) task.log.removeAt(0);
          if (coreFailureSignal(line)) task.errorSignals++;
          final progress = coreDownloadProgress(line);
          if (progress != null && task.state != '停止中' && task.state != '合并中') {
            task.progress = progress;
            task.state = '下载中';
            status = task.state;
          }
          if (coreTaskPhase(line) case final phase? when task.state != '停止中') {
            task.state = phase;
            status = phase;
          }
        });
      }

      Future<void> read(Stream<List<int>> stream) =>
          coreOutputLines(stream).forEach(record);
      await Future.wait([read(child.stdout), read(child.stderr)]);
      final code = await child.exitCode;
      if (mounted) {
        setState(() {
          task.running = false;
          if (task.state != '停止中') {
            if (code != 0) {
              task.failed = true;
              task.state = '失败 ($code)';
            } else if (task.errorSignals > 0) {
              // 日志里有明确错误信号，退出码 0 也不能当成完整成功。
              task.failed = true;
              task.state = '完成（有错误）';
            } else if (task.uncheckedSegments) {
              task.state = '已完成（未校验分片数）';
            } else {
              task.state = '已完成';
            }
          } else {
            task.state = '已停止';
          }
          status = task.state;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          task.running = false;
          task.failed = true;
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

  Future<void> openTaskFolder(Task task) async {
    try {
      final folder = Directory(task.folder).absolute.path;
      if (!await Directory(folder).exists()) {
        throw FileSystemException('输出目录不存在', folder);
      }
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [
          folder,
        ], mode: ProcessStartMode.detached);
      } else {
        final result = await Process.run(
          Platform.isMacOS ? 'open' : 'xdg-open',
          [folder],
        );
        if (result.exitCode != 0) throw FileSystemException('系统无法打开目录', folder);
      }
    } on Exception catch (error) {
      if (mounted) setState(() => status = '打开目录失败：$error');
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
      final running = task.running;
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
                          selected: !showingSettings && filter == index,
                          selectedTileColor: colors.secondaryContainer,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          onTap: () => setState(() {
                            showingSettings = false;
                            filter = index;
                          }),
                        ),
                      ),
                    const Spacer(),
                    ListTile(
                      leading: const Icon(Icons.settings_outlined, size: 20),
                      title: const Text('设置'),
                      selected: showingSettings,
                      selectedTileColor: colors.secondaryContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      onTap: preferencesReady
                          ? () => setState(() => showingSettings = true)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (showingSettings)
            Expanded(
              child: SettingsPage(
                initial: preferences,
                core: installed,
                checkingEnvironment: checkingEnvironment,
                environmentIssue: environmentIssue,
                ffmpegAvailable: ffmpegAvailable,
                coreUpdateStatus: coreUpdateStatus,
                updatingCore: updating,
                onCoreUpdate: busy || checkingEnvironment ? null : update,
                onClientUpdate: openClientUpdates,
                onCheckClientUpdate: checkingClientUpdate
                    ? null
                    : checkClientUpdate,
                clientVersion: clientVersion,
                clientUpdateStatus: clientUpdateStatus,
                clientUpdateAvailable: availableClientTag != null,
                onClose: () => setState(() => showingSettings = false),
                onSaved: (value) {
                  final changedCore = preferences.corePath != value.corePath;
                  final changedFFmpeg =
                      preferences.ffmpegPath != value.ffmpegPath;
                  applyPreferences(value);
                  setState(() {
                    showingSettings = false;
                    if (changedCore) {
                      installed = null;
                      checkingEnvironment = true;
                      noConfigProbe = null;
                      coreUpdateStatus = null;
                    }
                    if (changedFFmpeg) {
                      ffmpegAvailable = resolveFFmpeg(value.ffmpegPath) != null;
                    }
                  });
                  if (changedCore) unawaited(checkEnvironment());
                },
              ),
            )
          else
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
                                          ? (checkingEnvironment
                                                ? '正在检查下载环境…'
                                                : environmentIssue ??
                                                      '请在设置中安装下载核心。')
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
                                    title: Text(
                                      task.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          task.folder,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (task.progress case final progress?
                                            when task.running &&
                                                task.state == '下载中')
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 8,
                                              bottom: 4,
                                            ),
                                            child: LinearProgressIndicator(
                                              value: progress,
                                              semanticsLabel: '当前轨道下载进度',
                                            ),
                                          ),
                                      ],
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Chip(
                                          label: Text(
                                            task.running &&
                                                    task.state == '下载中' &&
                                                    task.progress != null
                                                ? '当前轨道 · ${(task.progress! * 100).toStringAsFixed(1)}%'
                                                : task.state,
                                          ),
                                          avatar: Icon(
                                            task.failed
                                                ? Icons.error_outline
                                                : task.running
                                                ? Icons.timelapse
                                                : task.state == '已完成'
                                                ? Icons.check_circle_outline
                                                : Icons.stop_circle_outlined,
                                            size: 16,
                                          ),
                                          side: BorderSide.none,
                                          backgroundColor: task.failed
                                              ? colors.errorContainer
                                              : colors.secondaryContainer,
                                        ),
                                        const SizedBox(width: 8),
                                        SizedBox(
                                          width: 40,
                                          child: task.state.startsWith('已完成')
                                              ? IconButton(
                                                  tooltip: '打开文件夹',
                                                  icon: const Icon(
                                                    Icons.folder_open_outlined,
                                                  ),
                                                  onPressed: () =>
                                                      openTaskFolder(task),
                                                )
                                              : null,
                                        ),
                                        SizedBox(
                                          width: 40,
                                          child: task.running
                                              ? null
                                              : IconButton(
                                                  tooltip: '从列表移除任务',
                                                  icon: const Icon(
                                                    Icons.delete_outline,
                                                  ),
                                                  onPressed: () => setState(() {
                                                    tasks.remove(task);
                                                    if (identical(
                                                      selected,
                                                      task,
                                                    )) {
                                                      selected = visible
                                                          .where(
                                                            (item) =>
                                                                !identical(
                                                                  item,
                                                                  task,
                                                                ),
                                                          )
                                                          .firstOrNull;
                                                    }
                                                  }),
                                                ),
                                        ),
                                      ],
                                    ),
                                    onTap: () =>
                                        setState(() => selected = task),
                                  );
                                },
                              ),
                      ),
                    ),
                    if (selected != null) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(child: Text('任务日志', style: text.titleSmall)),
                          if (!selected!.running)
                            IconButton(
                              tooltip: '打开输出目录',
                              icon: const Icon(Icons.folder_open_outlined),
                              onPressed: () => openTaskFolder(selected!),
                            ),
                          if (selected!.failed)
                            TextButton.icon(
                              icon: const Icon(Icons.replay),
                              label: const Text('用原设置重试'),
                              onPressed: busy || installed == null
                                  ? null
                                  : () => launch(installed!, selected!.request),
                            ),
                        ],
                      ),
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
                    if (((selected?.running ?? false) &&
                        (selected?.progress == null ||
                            selected?.state != '下载中')))
                      const LinearProgressIndicator(),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: SelectableText(status, style: text.bodySmall),
                    ),
                    if (browserImportNotice case final message?)
                      Text(message, style: text.bodySmall),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class NewDownload extends StatefulWidget {
  const NewDownload({
    super.key,
    required this.initialFolder,
    required this.buildRequest,
    required this.openOptions,
    this.browserImport,
  });
  final String initialFolder;
  final BrowserImport? browserImport;
  final AdvancedRequest Function(String input, String folder, String name)
  buildRequest;
  final Future<AdvancedRequest?> Function(
    String input,
    String folder,
    String name,
  )
  openOptions;

  @override
  State<NewDownload> createState() => _NewDownloadState();
}

class _NewDownloadState extends State<NewDownload> {
  final form = GlobalKey<FormState>();
  late final url = TextEditingController(text: widget.browserImport?.url);
  late final name = TextEditingController(
    text: widget.browserImport?.suggestedName,
  );
  late final folder = TextEditingController(text: widget.initialFolder);
  String? localInput;

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
        widget.buildRequest(
          url.text.trim(),
          Directory(folder.text.trim()).absolute.path,
          name.text.trim(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.browserImport == null ? '新建下载' : '确认下载'),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    scrollable: true,
    content: SizedBox(
      width: 520,
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              autofocus: widget.browserImport == null,
              controller: url,
              decoration: InputDecoration(
                labelText: '链接或本地清单',
                hintText: 'https://…',
                helperText: switch (widget.browserImport?.title) {
                  final title? when title.isNotEmpty => '来自 Chrome · $title',
                  _ => '网页视频可用 Chrome 的 SegmentDesk 媒体检测扩展获取清单链接。',
                },
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  tooltip: '选择本地清单',
                  icon: const Icon(Icons.file_open_outlined),
                  onPressed: () async {
                    final file = await openFile();
                    if (file != null && mounted) {
                      localInput = file.path;
                      url.text = file.path;
                    }
                  },
                ),
              ),
              validator: (value) {
                if (localInput != null && value?.trim() == localInput) {
                  return null;
                }
                final uri = Uri.tryParse(value?.trim() ?? '');
                return uri != null &&
                        (uri.scheme == 'https' || uri.scheme == 'http') &&
                        uri.host.isNotEmpty
                    ? null
                    : '请输入完整链接或选择本地清单';
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
      OutlinedButton(
        onPressed: () async {
          final output = folder.text.trim();
          if (output.isEmpty) {
            form.currentState!.validate();
            return;
          }
          final request = await widget.openOptions(
            url.text.trim(),
            Directory(output).absolute.path,
            name.text.trim(),
          );
          if (request != null && context.mounted) {
            Navigator.pop(context, request);
          }
        },
        child: const Text('高级选项'),
      ),
      FilledButton(onPressed: submit, child: const Text('开始下载')),
    ],
  );
}
