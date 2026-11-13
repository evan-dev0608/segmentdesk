import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_download/settings.dart';
import 'package:stream_download/core_output.dart';
import 'package:stream_download/core_service.dart';
import 'package:stream_download/advanced.dart';
import 'package:stream_download/browser_import.dart';
import 'package:stream_download/client_updates.dart';
import 'package:stream_download/main.dart';
import 'package:stream_download/selection.dart';
import 'package:stream_download/selection_dialog.dart';

void main() {
  test('compares stable client releases numerically', () {
    expect(ClientUpdates.isNewer('v0.1.10', '0.1.9'), isTrue);
    expect(ClientUpdates.isNewer('v0.1.9', '0.1.9'), isFalse);
    expect(ClientUpdates.isNewer('v0.1.9', '0.1.10'), isFalse);
    expect(
      () => ClientUpdates.isNewer('v0.2.0-beta', '0.1.9'),
      throwsFormatException,
    );
  });
  testWidgets('settings display mode uses visible single-choice options', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          initial: Preferences.defaults(),
          core: null,
          onClose: () {},
          onSaved: (_) {},
          checkingEnvironment: false,
          environmentIssue: null,
          ffmpegAvailable: true,
          coreUpdateStatus: null,
          updatingCore: false,
          onCoreUpdate: null,
          inspectFFmpegVersion: (_) async => '8.1.1',
          onClientUpdate: () {},
        ),
      ),
    );
    final system = find.widgetWithText(ChoiceChip, '跟随系统');
    final dark = find.widgetWithText(ChoiceChip, '深色');
    expect(tester.widget<ChoiceChip>(system).selected, isTrue);
    await tester.tap(dark);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(system).selected, isFalse);
    expect(tester.widget<ChoiceChip>(dark).selected, isTrue);
  });

  testWidgets('settings scrollbar is not permanently visible', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          initial: Preferences.defaults(),
          core: null,
          onClose: () {},
          onSaved: (_) {},
          checkingEnvironment: false,
          environmentIssue: null,
          ffmpegAvailable: true,
          coreUpdateStatus: null,
          updatingCore: false,
          onCoreUpdate: null,
          inspectFFmpegVersion: (_) async => '8.1.1',
          onClientUpdate: () {},
        ),
      ),
    );
    final theme = ScrollbarTheme.of(
      tester.element(find.byType(SingleChildScrollView)),
    );
    expect(theme.thumbVisibility?.resolve(const <WidgetState>{}), isFalse);
    expect(theme.trackVisibility?.resolve(const <WidgetState>{}), isFalse);
    expect(theme.thickness?.resolve(const <WidgetState>{}), 6.0);
    expect(theme.crossAxisMargin, 6);
    expect(theme.mainAxisMargin, 12);
    expect(theme.minThumbLength, 48);
  });

  testWidgets(
    'settings scroll view spans the card so the scrollbar is on the right edge',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            initial: Preferences.defaults(),
            core: null,
            onClose: () {},
            onSaved: (_) {},
            checkingEnvironment: false,
            environmentIssue: null,
            ffmpegAvailable: true,
            coreUpdateStatus: null,
            updatingCore: false,
            onCoreUpdate: null,
            inspectFFmpegVersion: (_) async => '8.1.1',
            onClientUpdate: () {},
          ),
        ),
      );
      final card = tester.getRect(find.byType(Card));
      final scrollView = tester.getRect(find.byType(SingleChildScrollView));
      final form = tester.getRect(find.byType(Form));
      // 滚动条由桌面端 ScrollBehavior 挂在滚动视图边缘，视图必须铺满卡片。
      expect(scrollView.left, closeTo(card.left, 1.0));
      expect(scrollView.right, closeTo(card.right, 1.0));
      // 表单仍按 760（28 + 704 + 28）左对齐，不跟着拉宽。
      expect(form.left, closeTo(card.left + 28, 1.0));
      expect(form.width, 704.0);
      expect(form.right, lessThan(card.right - 100));
    },
  );

  testWidgets('settings prefill the detected core in an editable path field', (
    tester,
  ) async {
    const executable =
        r'C:\Users\Farewell\AppData\Local\StreamDownloadGUI\core-20261112\N_m3u8DL-RE.exe';
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          initial: Preferences.defaults(),
          core: const CoreInstall(executable, 'v0.6.0-beta'),
          onClose: () {},
          onSaved: (_) {},
          checkingEnvironment: false,
          environmentIssue: null,
          ffmpegAvailable: true,
          coreUpdateStatus: null,
          updatingCore: false,
          onCoreUpdate: null,
          inspectFFmpegVersion: (_) async => '8.1.1',
          onClientUpdate: () {},
        ),
      ),
    );
    final field = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == '核心可执行文件',
    );
    await tester.ensureVisible(field);
    expect(tester.widget<TextField>(field).controller?.text, executable);
    expect(find.text('核心版本 v0.6.0-beta'), findsOneWidget);
    await tester.enterText(field, 'local-core.exe');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller?.text, 'local-core.exe');
  });

  test(
    'separates audio and subtitle progress frames without newlines',
    () async {
      final lines = await coreOutputLines(
        Stream.fromIterable([
          utf8.encode(
            '15:19:59.000 INFO : Aud English\nAud 128 Kbps 1/2 50.0%Su',
          ),
          utf8.encode('b English 1/4 25.0%'),
        ]),
      ).toList();
      expect(lines, [
        '15:19:59.000 INFO : Aud English',
        'Aud 128 Kbps 1/2 50.0%',
        'Sub English 1/4 25.0%',
      ]);
      expect(lines.map(coreDownloadProgress), [null, .5, .25]);
    },
  );
  test('reads actual download percentage from a core progress frame', () {
    expect(
      coreDownloadProgress('Vid 320x184 | 246 Kbps ━━━ 2/3 66.67%'),
      closeTo(.6667, .00001),
    );
    expect(coreDownloadProgress('15:19:59.000 INFO : 2/3 66.67%'), isNull);
    expect(coreDownloadProgress('Vid 320x184 | 246 Kbps 2/3 120%'), isNull);
  });
  test('separates adjacent upstream log messages', () async {
    final lines = await coreOutputLines(
      Stream.value(
        utf8.encode(
          '15:19:58.520 INFO : Vid 1920x1080'
          '15:19:58.772 WARN : 写出meta json\n'
          '15:19:59.000 INFO : 开始下载...Vid 320x184 | 246 Kbps 0/3 0.00%'
          'Vid 320x184 | 246 Kbps 1/3 33.33%',
        ),
      ),
    ).toList();
    expect(lines, [
      '15:19:58.520 INFO : Vid 1920x1080',
      '15:19:58.772 WARN : 写出meta json',
      '15:19:59.000 INFO : 开始下载...',
      'Vid 320x184 | 246 Kbps 0/3 0.00%',
      'Vid 320x184 | 246 Kbps 1/3 33.33%',
    ]);
  });

  testWidgets('browser import prefills the original signed URL', (
    tester,
  ) async {
    const url = 'https://cdn.example.test/play?token=A%2Bb';
    final imported = BrowserImport.parse(
      jsonEncode({'version': 1, 'type': 'HLS', 'url': url, 'title': '示例视频'}),
    );
    expect(imported?.url, url);
    expect(imported?.canImport, isTrue);
    for (final type in ['DASH', 'MSS', 'M3U', 'MP4']) {
      final candidate = BrowserImport.parse(
        jsonEncode({'version': 1, 'type': type, 'url': url}),
      );
      expect(candidate?.url, url);
      expect(candidate?.canImport, isTrue);
      expect(candidate?.isDirect, type == 'MP4');
    }
    expect(
      BrowserImport.parse(
        '{"version":1,"type":"HLS","url":"file:///media.m3u8"}',
      ),
      isNull,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NewDownload(
          initialFolder: '.',
          browserImport: imported,
          buildRequest: (_, _, _, _) => throw UnimplementedError(),
          openOptions: (_, _, _, _) async => null,
        ),
      ),
    );
    expect(find.text(url), findsOneWidget);
    expect(find.text('来自 Chrome · 示例视频'), findsOneWidget);
    expect(find.text('示例视频'), findsOneWidget);
    expect(
      const BrowserImport('', '  CON: /视频? ', 'HLS').suggestedName,
      'CON 视频',
    );
    expect(const BrowserImport('', 'CON.txt', 'HLS').suggestedName, '_CON.txt');
  });

  test('maps recognized upstream log phases', () {
    expect(coreTaskPhase('INFO 开始下载...'), '下载中');
    expect(coreTaskPhase('INFO Binary merging...'), '合并中');
    expect(coreTaskPhase('unrecognized'), isNull);
  });

  test('strips options rejected by BinaryDownloadRunner', () {
    final stripped = binaryDirectArguments([
      'https://cdn.example.test/video.mp4',
      '--save-dir',
      'E:/Downloads',
      '--auto-select',
      '-M',
      'format=mp4',
      '--mux-after-done',
      'format=mkv',
      '--key',
      'kid:key',
      'kid2:key2',
      '--mux-import',
      'sub.srt',
      '--custom-range',
      '00:00:00-00:01:00',
      '--key-text-file',
      'keys.txt',
      '--save-pattern',
      '<SaveName>',
      '--save-name',
      'clip',
      '--no-ansi-color',
      '--no-config',
    ]);
    expect(stripped, [
      'https://cdn.example.test/video.mp4',
      '--save-dir',
      'E:/Downloads',
      '--auto-select',
      '--save-name',
      'clip',
      '--no-ansi-color',
      '--no-config',
    ]);
    // 不含被拒选项时参数原样保留。
    expect(binaryDirectArguments(['u', '--no-config']), ['u', '--no-config']);
  });

  test('guesses binary direct links from the path or MIME hint', () {
    expect(looksLikeBinaryDirect('https://cdn.test/a.mp4'), isTrue);
    expect(
      looksLikeBinaryDirect(
        'https://v11-weba.douyinvod.com/video/tos/?mime_type=video_mp4&token=x',
      ),
      isTrue,
    );
    expect(looksLikeBinaryDirect('https://cdn.test/master.m3u8'), isFalse);
    expect(looksLikeBinaryDirect('https://cdn.test/manifest.mpd'), isFalse);
    expect(looksLikeBinaryDirect('C:/local/file.m3u8'), isFalse);
  });

  test('reads binary download progress and folds its speed frames', () {
    const first = '00:27:39.153 INFO : 12.34MB/262.00MB 5.21MBps';
    const second = '00:27:40.153 INFO : 25.00MB/262.00MB 5.40MBps';
    expect(binaryDownloadProgress(first), closeTo(0.0471, 0.0001));
    expect(
      binaryDownloadProgress('00:27:39.153 INFO : 1.00GB/2.00GB 5.21MBps'),
      closeTo(0.5, 0.00001),
    );
    // 总长度未知时只有速度，没有可换算的百分比。
    expect(
      binaryDownloadProgress('00:27:39.153 INFO : 12.34MB 5.21MBps'),
      isNull,
    );
    expect(
      binaryDownloadProgress('00:27:39.153 INFO : 12.34MB/0.00MB 5.21MBps'),
      isNull,
    );
    expect(isBinaryProgressLine(first), isTrue);
    expect(shouldFoldLogLine(first, second), isTrue);
    expect(
      shouldFoldLogLine('12:00:00.001 INFO : 12%', '12:00:01.002 INFO : 45%'),
      isFalse,
    );
  });

  test('maps binary phases and unsupported-input failures', () {
    expect(coreTaskPhase('00:27:39.153 INFO : 内容匹配: Binary Data'), '下载中');
    expect(
      coreTaskPhase('00:27:39.153 INFO : 保存文件名: E:/Downloads/clip.mp4'),
      '下载中',
    );
    expect(
      coreTaskPhase('00:27:39.153 INFO : Content Matched: Binary Data'),
      '下载中',
    );
    expect(
      coreTaskPhase('00:27:39.153 INFO : Save Name: /tmp/clip.mp4'),
      '下载中',
    );
    expect(coreFailureSignal('System.NotSupportedException: 当前输入不受支持'), isTrue);
    expect(
      coreFailureSignal('System.NotSupportedException: Input not supported'),
      isTrue,
    );
    expect(
      coreFailureSignal(
        'Range, mux, decryption, and save-pattern options '
        'do not apply to binary direct downloads.',
      ),
      isTrue,
    );
    expect(coreReportsUnsupportedBinary('当前输入不受支持'), isTrue);
    expect(coreReportsUnsupportedBinary('内容匹配: Binary Data'), isFalse);
  });

  testWidgets('browser-imported MP4 enables binary direct mode', (
    tester,
  ) async {
    bool? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: NewDownload(
          initialFolder: '.',
          browserImport: const BrowserImport(
            'https://cdn.test/video.mp4?token=x',
            '示例',
            'MP4',
          ),
          buildRequest: (_, _, _, direct) {
            captured = direct;
            return AdvancedRequest('clip', '.', ['u'], direct: direct);
          },
          openOptions: (_, _, _, _) async => null,
        ),
      ),
    );
    final toggle = find.byType(SwitchListTile);
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(find.text('开始下载'));
    await tester.pump();
    expect(captured, isTrue);
  });

  testWidgets('a manual MP4 URL auto-enables binary direct mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NewDownload(
          initialFolder: '.',
          buildRequest: (_, _, _, _) => AdvancedRequest('clip', '.', ['u']),
          openOptions: (_, _, _, _) async => null,
        ),
      ),
    );
    final toggle = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.enterText(
      find.byType(TextFormField).first,
      'https://cdn.test/clip.mp4',
    );
    await tester.pump();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });

  testWidgets('advanced options inherit the new download fields', (
    tester,
  ) async {
    String? forwarded;
    await tester.pumpWidget(
      MaterialApp(
        home: NewDownload(
          initialFolder: '.',
          buildRequest: (input, folder, name, _) =>
              AdvancedRequest(name, folder, [input]),
          openOptions: (input, folder, name, direct) async {
            forwarded = '$input|${Directory(folder).isAbsolute}|$name|$direct';
            return null;
          },
        ),
      ),
    );
    await tester.enterText(
      find.byType(TextFormField).first,
      'https://example.com/stream.m3u8',
    );
    await tester.enterText(find.byType(TextFormField).last, 'demo');
    await tester.tap(find.text('高级选项'));
    await tester.pump();
    expect(forwarded, 'https://example.com/stream.m3u8|true|demo|false');
    expect(find.text('开始下载'), findsOneWidget);
  });
  test('appearance settings load with backwards-compatible defaults', () {
    final old = Preferences.fromJson({
      'folder': 'downloads',
      'container': 'ts',
    });
    expect(old.themeMode, ThemeMode.system);
    expect(old.accent, 'indigo');
    expect(old.container, 'ts');

    final updated = Preferences.fromJson({
      'themeMode': 'dark',
      'accent': 'green',
    });
    expect(updated.themeMode, ThemeMode.dark);
    expect(updated.seed, Preferences.accents['green']!.$2);
  });
  test('preserves UTF-8 and falls back to the system code page', () async {
    expect(decodeCoreOutput(utf8.encode('保存目录'), fallback: latin1), '保存目录');
    expect(decodeCoreOutput([0xe9], fallback: latin1), 'é');
    final bytes = utf8.encode('保存目录\r\n第二行');
    expect(
      await coreOutputLines(
        Stream.fromIterable([bytes.sublist(0, 2), bytes.sublist(2)]),
      ).toList(),
      ['保存目录', '第二行'],
    );
  });
  test('parses aliased, boolean and typed options', () {
    final options = parseCoreHelp(
      '  -H, --header <header>  Request header\n'
      '  --sub-only           Subtitles only\n'
      '  --sub-format <SRT|VTT>  Format\n'
      '  --vod-select-parts     Interactive selection\n',
    );
    expect(options.map((option) => option.flag), [
      '--header',
      '--sub-only',
      '--sub-format',
    ]);
    expect(options[1].placeholder, isNull);
    expect(options[2].placeholder, '<SRT|VTT>');
  });
  testWidgets('workspace shows task navigation and core management', (
    tester,
  ) async {
    await tester.pumpWidget(const DownloadApp());
    expect(find.text('新建下载'), findsOneWidget);
    expect(find.text('下载核心'), findsNothing);
    expect(find.text('查看客户端更新'), findsNothing);
    await tester.tap(find.text('运行中'));
    await tester.pump();
    expect(find.text('运行中'), findsNWidgets(2));
  });

  test('isolates global config except for doctor and explicit --config', () {
    expect(
      isolateCoreArguments(['https://example.com/a.m3u8', '--save-dir', '.']),
      ['https://example.com/a.m3u8', '--save-dir', '.', '--no-config'],
    );
    // --config 与 --no-config 并存会让上游 ConfigFile.cs 抛 configFileConflict。
    expect(isolateCoreArguments(['u', '--config', 'C:/core.conf']), [
      'u',
      '--config',
      'C:/core.conf',
    ]);
    expect(isolateCoreArguments(['u', '--no-config', 'false']), [
      'u',
      '--no-config',
      'false',
    ]);
    expect(isolateCoreArguments(['doctor'], isolate: false), ['doctor']);
    expect(
      AdvancedRequest('检测环境', '.', ['doctor'], tool: true).isDoctor,
      isTrue,
    );
    expect(
      AdvancedRequest('下载', '.', ['https://example.com/a.m3u8']).isDoctor,
      isFalse,
    );
  });

  test('older release builds without --no-config are handled safely', () {
    // 官方 v0.6.0-beta（20260628）的真实帮助布局：描述从第 58 列起。
    // 该版本没有 --no-config，无条件追加会让所有任务报未知参数。
    const oldHelp = '''
Description:
  N_m3u8DL-RE (Beta version) 20260628

Usage:
  N_m3u8DL-RE <input> [options]

Options:
  --tmp-dir <tmp-dir>                                     Set temporary directory
  --select-video <select-video>                           Select video streams
  --no-log                                                Disable log file
  --no-ansi-color                                         Disable ANSI colors
''';
    expect(coreHelpSupports(oldHelp, '--no-config'), isFalse);
    expect(coreHelpSupports(oldHelp, '--select-video'), isTrue);
    expect(coreHelpSupports(oldHelp, '--no-log'), isTrue);
    expect(coreHelpSupports('  --no-config   isolate', '--no-config'), isTrue);
    expect(
      coreHelpSupports('  --no-configuration   x', '--no-config'),
      isFalse,
    );

    final flags = parseCoreHelp(oldHelp).map((option) => option.flag);
    expect(flags, contains('--select-video'));
    expect(flags, isNot(contains('--no-config')));

    expect(
      previewArguments(
        input: 'u',
        tempDir: 't',
        isolateConfig: false,
      ).contains('--no-config'),
      isFalse,
    );
    expect(isolateCoreArguments(['u'], isolate: false), ['u']);
  });

  test('passes an explicit ffmpeg path only when one was located', () {
    expect(withFFmpegPath(['u'], null), ['u']);
    expect(withFFmpegPath(['u'], 'C:/tools/ffmpeg.exe'), [
      'u',
      '--ffmpeg-binary-path',
      'C:/tools/ffmpeg.exe',
    ]);
    expect(withFFmpegPath(['u', '--ffmpeg-binary-path', 'x'], 'y'), [
      'u',
      '--ffmpeg-binary-path',
      'x',
    ]);
  });

  test('recognizes the three-language chunked merge phase', () {
    expect(coreTaskPhase('INFO 分片数量达到1800个，开始分块合并...'), '合并中');
    expect(coreTaskPhase('INFO 分片數量達到1800個，開始分塊合併...'), '合并中');
    expect(
      coreTaskPhase('INFO At least 1800 segments; starting partial merge...'),
      '合并中',
    );
    expect(coreTaskPhase('INFO 二进制合并中...'), '合并中');
  });

  test('cleans control frames without dropping unstructured output', () {
    expect(
      cleanCoreLogLine('\x1B[32m12:00:00.001 INFO : done\x1B[0m'),
      '12:00:00.001 INFO : done',
    );
    expect(cleanCoreLogLine('old frame\rnew frame'), 'new frame');
    expect(cleanCoreLogLine('   '), isNull);
    // doctor / ffmpeg 的输出没有时间戳前缀，必须原样保留。
    expect(cleanCoreLogLine('ffmpeg version 9.0'), 'ffmpeg version 9.0');
  });

  test('folds progress frames but never structured log lines', () {
    expect(
      shouldFoldLogLine(
        'Downloading 12% ━━━  1.2 MB/s',
        'Downloading 45% ━━━━━  3.4 MB/s',
      ),
      isTrue,
    );
    expect(
      shouldFoldLogLine('12:00:00.001 INFO : 12%', '12:00:01.002 INFO : 45%'),
      isFalse,
    );
    expect(shouldFoldLogLine('========', '========'), isFalse);
    expect(isStructuredLogLine('12:00:00.001 WARN : retry'), isTrue);
    expect(isStructuredLogLine('ffmpeg version 9.0'), isFalse);
  });

  test('core install exposes whether integrity checks actually ran', () {
    expect(const CoreInstall('core.exe', 'v0.6.0').verified, isTrue);
    expect(
      const CoreInstall('core.exe', 'v0.6.0', verified: false).verified,
      isFalse,
    );
  });

  test('parses the Commands section without depending on the binary name', () {
    final help =
        'Description:\n  demo\n\n'
        'Usage:\n  Renamed-Tool <input> [options]\n\n'
        'Options:\n  --help  Show help\n\n'
        'Commands:\n'
        '  concat  Concat files\n'
        '  merge   Merge media\n'
        '  mux     Mux tracks\n'
        '  doctor  Inspect environment\n\n'
        'Options:\n  --other  Other\n';
    expect(parseCoreCommands(help), {'concat', 'merge', 'mux', 'doctor'});
    expect(parseCoreCommands('Usage:\n  core <input> [options]\n'), isEmpty);
    expect(
      coreUsageMatchesCommand(
        'Usage:\n  Renamed-Tool concat [options]\n',
        'concat',
      ),
      isTrue,
    );
    expect(
      coreUsageMatchesCommand('Usage:\n  core <input> [options]\n', 'concat'),
      isFalse,
    );
  });

  test('detects disabled segment count and upstream error signals', () {
    expect(
      hasDisabledSegmentCheck(['u', '--check-segments-count', 'false']),
      isTrue,
    );
    expect(
      hasDisabledSegmentCheck(['u', '--check-segments-count', 'true']),
      isFalse,
    );
    expect(hasDisabledSegmentCheck(['u']), isFalse);
    expect(coreFailureSignal('12:00:00.001 ERROR: broken'), isTrue);
    expect(coreFailureSignal('12:00:00.001 INFO : 分片数量校验不通过, 共10个'), isTrue);
    expect(coreFailureSignal('The retry attempts have been exhausted'), isTrue);
    expect(coreFailureSignal('12:00:00.001 WARN : retrying'), isFalse);
    expect(coreFailureSignal('12:00:00.001 INFO : Done'), isFalse);
  });

  group('core installation without network access', () {
    late Directory sandbox;
    late List<int> archive;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('segmentdesk-test-');
      archive = utf8.encode('fake core archive payload');
    });

    tearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    test('verifies size and digest on the GitHub API path', () async {
      final runner = FakeCoreRunner(
        archiveBytes: archive,
        size: archive.length,
        digest: 'sha256:${sha256.convert(archive)}',
      );
      final service = CoreService(runner: runner, dataDirectory: sandbox);
      final messages = <String>[];
      final result = await service.update(messages.add);
      expect(result.verified, isTrue);
      expect(result.tag, 'v0.6.0');
      expect(messages, contains('正在验证并安装核心…'));
      expect(await File('${sandbox.path}/active.json').exists(), isTrue);
      expect(await service.installed(), isNotNull);
    });

    test('marks the release-page fallback as unverified', () async {
      final runner = FakeCoreRunner(archiveBytes: archive, apiFails: true);
      final service = CoreService(runner: runner, dataDirectory: sandbox);
      final messages = <String>[];
      final result = await service.update(messages.add);
      expect(result.verified, isFalse);
      expect(messages.any((m) => m.contains('无校验信息')), isTrue);
    });

    test(
      'rejects a mismatched size without switching the active core',
      () async {
        final runner = FakeCoreRunner(
          archiveBytes: archive,
          size: archive.length + 1,
        );
        final service = CoreService(runner: runner, dataDirectory: sandbox);
        await expectLater(service.update((_) {}), throwsA(isA<StateError>()));
        expect(await File('${sandbox.path}/active.json').exists(), isFalse);
      },
    );

    test('rejects a mismatched digest', () async {
      final runner = FakeCoreRunner(
        archiveBytes: archive,
        digest: 'sha256:deadbeef',
      );
      final service = CoreService(runner: runner, dataDirectory: sandbox);
      await expectLater(service.update((_) {}), throwsA(isA<StateError>()));
      expect(await File('${sandbox.path}/active.json').exists(), isFalse);
    });

    test('rolls back when the version probe fails', () async {
      final runner = FakeCoreRunner(
        archiveBytes: archive,
        size: archive.length,
        probeFails: true,
      );
      final service = CoreService(runner: runner, dataDirectory: sandbox);
      await expectLater(service.update((_) {}), throwsA(isA<StateError>()));
      expect(await File('${sandbox.path}/active.json').exists(), isFalse);
      final leftovers = sandbox.listSync().where(
        (entity) => entity.uri.pathSegments
            .lastWhere((segment) => segment.isNotEmpty)
            .startsWith('core-'),
      );
      expect(leftovers, isEmpty);
    });

    test('skips the download when the installed tag already matches', () async {
      final runner = FakeCoreRunner(
        archiveBytes: archive,
        size: archive.length,
      );
      final service = CoreService(runner: runner, dataDirectory: sandbox);
      final existing = Directory('${sandbox.path}/core-existing');
      await existing.create();
      await File('${existing.path}/${CoreService.executable}')
          .writeAsBytes(archive);
      await File('${sandbox.path}/active.json').writeAsString(
        jsonEncode({'tag': 'v0.6.0', 'directory': 'core-existing'}),
      );
      final result = await service.update((_) {});
      expect(result.tag, 'v0.6.0');
      expect(runner.downloads, hasLength(1));
      final release = await service.checkUpdate((_) {});
      expect(release.tag, 'v0.6.0');
      expect(runner.downloads, hasLength(2));
      final repaired = await service.update(
        (_) {},
        release: release,
        force: true,
      );
      expect(repaired.executable, isNot(result.executable));
      expect(runner.downloads, hasLength(3));
    });
  });

  group('track / part / IPTV selection', () {
    const playlist =
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="c1" tvg-name="CCTV One",CCTV-1 综合\n'
        'https://iptv.example.com/c1.m3u8\n'
        '#EXTINF:-1 tvg-id="c2",\n'
        'https://iptv.example.com/c2.m3u8\n'
        '#EXTINF:-1 tvg-logo="a,b",HBO, Movies\n'
        'https://iptv.example.com/hbo.m3u8\n'
        '#EXTINF:-1,CCTV-1 综合\n'
        'https://iptv.example.com/dup.m3u8\n'
        '#EXTINF:-1,Local File\n'
        'file:///tmp/a.m3u8\n';

    final meta = [
      {
        'MediaType': 'VIDEO',
        'Url': 'https://cdn.example.com/v.m3u8',
        'Name': '1080p',
        'Language': 'zh',
        'Resolution': '1920x1080',
        'Bandwidth': 5000,
        'Codecs': 'avc1',
        'GroupId': 'g1',
        'Playlist': {
          'IsLive': false,
          'MediaParts': [
            {
              'PeriodIndex': 0,
              'MediaSegments': [
                {'Duration': 10},
                {'Duration': 5},
              ],
            },
            {
              'PeriodIndex': 1,
              'MediaSegments': [
                {'Duration': 30},
              ],
            },
          ],
        },
      },
      {
        'MediaType': 'AUDIO',
        'Url': 'https://cdn.example.com/a.m3u8',
        'Playlist': {
          'IsLive': false,
          'MediaParts': [
            {
              'PeriodIndex': 0,
              'MediaSegments': [
                {'Duration': 8},
              ],
            },
            {
              'PeriodIndex': 1,
              'MediaSegments': [
                {'Duration': 40},
              ],
            },
          ],
        },
      },
      {'MediaType': 'SUBTITLES', 'Url': ''},
    ];

    test('escapes expressions and builds channel filters', () {
      expect(
        exactExpression('https://a.b/c:8080/x.m3u8'),
        r'^https\://a\.b/c\:8080/x\.m3u8$',
      );
      expect(
        channelFilter(['CCTV-1', 'HBO HD']),
        r'name=^CCTV-1$|^HBO HD$:for=all',
      );
    });

    test('recognizes IPTV playlists the way the core does', () {
      expect(isIptvPlaylist(playlist), isTrue);
      expect(isIptvPlaylist('#EXTM3U\n#EXTGRP:News\n'), isTrue);
      expect(
        isIptvPlaylist('#EXTM3U\n#EXTINF:10,Clip\nhttps://x/a.ts\n'),
        isFalse,
      );
      expect(
        isIptvPlaylist(
          '#EXTM3U\n#EXTINF:-1,Channel\nhttps://x/a.m3u8\n'
          '#EXT-X-VERSION:3\n',
        ),
        isFalse,
      );
    });

    test(
      'parses M3U channels, quoted commas, relative URLs and duplicates',
      () {
        expect(parseChannels('\uFEFF$playlist'), ['CCTV-1 综合', 'HBO, Movies']);
        const relative = '#EXTM3U\n#EXTINF:-1,Rel\nlive/1.m3u8\n';
        expect(parseChannels(relative), isEmpty);
        expect(
          parseChannels(relative, base: 'https://iptv.example.com/list/a.m3u'),
          ['Rel'],
        );
        const simple = '#EXTM3U\n#EXTINF:10,Clip\nhttps://x/a.ts\n';
        expect(() => parseChannels(simple), throwsA(isA<FormatException>()));
        expect(parseChannels(simple, coreCompatible: false), ['Clip']);
        expect(
          () => parseChannels('#EXT-X-VERSION:3\n'),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('extracts tracks from PascalCase meta.json', () {
      final tracks = coreTracks(meta);
      expect(tracks, hasLength(2));
      expect(tracks.first.kind, 'video');
      expect(tracks.first.label, '1080p · zh · 1920x1080 · 5000 · avc1 · g1');
      expect(
        tracks.first.filter,
        r'url=^https\://cdn\.example\.com/v\.m3u8$:id=^g1$:for=best',
      );
      expect(tracks.last.kind, 'audio');
      expect(tracks.last.label, 'audio');
      expect(
        tracks.last.filter,
        r'url=^https\://cdn\.example\.com/a\.m3u8$:for=best',
      );
      expect(() => coreTracks('not a list'), throwsA(isA<FormatException>()));
    });

    test('classifies tracks when older releases omit MediaType', () {
      // 官方 v0.6.0-beta（20260628）的真实 meta.json 字段：
      // MediaType 被 null 省略，只能靠 Codecs / Resolution / Role 推断。
      const url =
          'https://media.axprod.net/TestVectors/v7-Clear/Manifest_1080p.mpd';
      final tracks = coreTracks([
        {
          'Url': url,
          'GroupId': '5',
          'Codecs': 'avc1.640033',
          'Resolution': '1920x1080',
          'Language': 'und',
          'Role': 'Main',
        },
        {
          'Url': url,
          'GroupId': '15',
          'Codecs': 'mp4a.40.29',
          'Language': 'en',
          'Role': 'Main',
        },
        {
          'Url': url,
          'GroupId': '25',
          'Codecs': 'stpp',
          'Language': 'ru',
          'Role': 'Subtitle',
        },
        {'Url': url, 'GroupId': '24', 'Codecs': 'wvtt', 'Language': 'ru'},
      ]);
      expect(tracks.map((track) => track.kind), [
        'video',
        'audio',
        'subtitle',
        'subtitle',
      ]);
      expect(coreTrackKind(const {'MediaType': 'SUBTITLES'}), 'subtitle');
      expect(coreTrackKind(const {'MediaType': 'AUDIO'}), 'audio');
      expect(coreTrackKind(const {'Extension': '.vtt'}), 'subtitle');
      expect(coreTrackKind(const {'Codecs': 'ec-3'}), 'audio');
    });

    test('sums vod parts using PeriodIndex then DiscontinuitySequence', () {
      expect(vodParts([meta, const []]), {0: 15.0, 1: 40.0});
      final hls = [
        {
          'MediaType': 'VIDEO',
          'Url': 'https://x/seg.m3u8',
          'Playlist': {
            'IsLive': false,
            'MediaParts': [
              {
                'DiscontinuitySequence': 2,
                'MediaSegments': [
                  {'Duration': 6.5},
                ],
              },
              {
                'DiscontinuitySequence': 2,
                'MediaSegments': [
                  {'Duration': 3.5},
                ],
              },
              {
                'DiscontinuitySequence': 4,
                'MediaSegments': [
                  {'Duration': 20},
                ],
              },
            ],
          },
        },
      ];
      expect(vodParts([hls]), {2: 10.0, 4: 20.0});
      expect(
        vodParts([
          {
            'Playlist': {
              'IsLive': true,
              'MediaParts': [
                {'PeriodIndex': 0},
              ],
            },
          },
        ]),
        isEmpty,
      );
      expect(dropPartsValue({0: 10, 1: 20, 2: 30}, {0, 2}), '1');
      expect(dropPartsValue({0: 10, 1: 20, 2: 30}, {0, 1, 2}), isNull);
      expect(parseDropParts('0,2-4'), {0, 2, 3, 4});
    });

    test('preview arguments isolate config and only pass network options', () {
      final args = previewArguments(
        input: 'https://x/m.m3u8',
        tempDir: '/tmp/p',
        values: {
          '--header': ['User-Agent: SegmentDesk', 'Referer: https://a/'],
          '--use-system-proxy': ['false'],
          '--select-video': ['manual'],
          '--save-dir': ['/should/not/pass'],
        },
      );
      expect(args.first, 'https://x/m.m3u8');
      expect(args.contains('--no-config'), isTrue);
      expect(args.contains('--skip-download'), isTrue);
      expect(args.contains('--auto-select'), isTrue);
      expect(args.contains('--select-video'), isFalse);
      expect(args[args.indexOf('--write-meta-json') + 1], 'true');
      expect(args[args.indexOf('--save-name') + 1], previewSaveName);
      expect(args[args.indexOf('--tmp-dir') + 1], '/tmp/p');
      expect(args[args.indexOf('--save-dir') + 1], '/tmp/p');
      expect(args.where((arg) => arg == '--header'), hasLength(2));
      expect(args[args.indexOf('--use-system-proxy') + 1], 'false');

      final withConfig = previewArguments(
        input: 'x',
        tempDir: '/t',
        values: {
          '--config': ['cfg.conf'],
        },
      );
      expect(withConfig.contains('--config'), isTrue);
      expect(withConfig.contains('--no-config'), isFalse);
    });

    test('netscape cookie header filters by domain, path and scheme', () {
      const cookies =
          '# Netscape HTTP Cookie File\n'
          '#HttpOnly_.example.com\tTRUE\t/\tTRUE\t1893456000\ttoken\tabc\n'
          '.example.com\tTRUE\t/\tFALSE\t1893456000\tplain\txyz\n'
          'other.com\tTRUE\t/\tFALSE\t1893456000\tskip\t1\n'
          '.example.com\tTRUE\t/secure\tTRUE\t1893456000\tsec\tv\n';
      expect(
        netscapeCookieHeader(
          cookies,
          Uri.parse('https://tv.example.com/live/a.m3u8'),
        ),
        'token=abc; plain=xyz',
      );
      expect(
        netscapeCookieHeader(
          cookies,
          Uri.parse('http://tv.example.com/live/a.m3u8'),
        ),
        'plain=xyz',
      );
    });

    test('selection results map back onto the advanced options form', () {
      final updated = applySelectionToValues(
        {
          '--save-dir': ['/tmp'],
          '--vod-drop-parts': ['9'],
        },
        const TrackSelection(
          video: r'url=^v$:for=best',
          dropParts: '1',
          partsShown: true,
        ),
      );
      expect(updated['--select-video'], [r'url=^v$:for=best']);
      expect(updated['--select-audio'], ['']);
      expect(updated['--vod-drop-parts'], ['1']);
      expect(updated['--auto-select'], ['false']);
      expect(updated['--save-dir'], ['/tmp']);

      final channels = applyChannelsToValues({}, ['CCTV-1', 'HBO']);
      expect(channels['--select-video'], [r'name=^CCTV-1$|^HBO$:for=all']);
      expect(channels['--auto-select'], ['false']);
    });

    testWidgets('track dialog validates and reports dropped parts', (
      tester,
    ) async {
      final captured = <TrackSelection?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                captured.add(
                  await showDialog<TrackSelection>(
                    context: context,
                    builder: (_) => TrackSelectionDialog(
                      tracks: const [
                        CoreTrack('video', '1080p', r'url=^v$:for=best'),
                      ],
                      parts: <int, double>{0: 10, 1: 20, 2: 30},
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用轨道与分段选择'));
      await tester.pumpAndSettle();
      expect(find.text('请至少保留一个点播分段。'), findsOneWidget);
      expect(captured, isEmpty);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 1 段 · 20.0 秒'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用轨道与分段选择'));
      await tester.pumpAndSettle();
      expect(captured.single?.dropParts, '1');
      expect(captured.single?.partsShown, isTrue);
    });

    testWidgets('channel dialog returns selected channels', (tester) async {
      final captured = <List<String>?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                captured.add(
                  await showDialog<List<String>>(
                    context: context,
                    builder: (_) => const ChannelSelectionDialog(
                      channels: ['CCTV-1', 'HBO', 'CNN'],
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('HBO'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用选中的频道'));
      await tester.pumpAndSettle();
      expect(captured.single, ['CCTV-1', 'CNN']);
    });
  });
}

/// 完全不联网、不调用系统 curl / tar 的核心安装执行器。
class FakeCoreRunner implements CoreRunner {
  FakeCoreRunner({
    required this.archiveBytes,
    this.size,
    this.digest,
    this.apiFails = false,
    this.probeFails = false,
  });

  final List<int> archiveBytes;
  final int? size;
  final String? digest;
  final bool apiFails;
  final bool probeFails;
  final downloads = <Uri>[];

  String get assetName {
    final os = Platform.isWindows
        ? 'win'
        : Platform.isMacOS
        ? 'osx'
        : 'linux';
    final arch = Abi.current().toString().split('_').last;
    final ext = Platform.isWindows ? 'zip' : 'tar.gz';
    return 'N_m3u8DL-RE_v0.6.0_$os-$arch.$ext';
  }

  String get assetUrl =>
      'https://github.com/nilaoda/N_m3u8DL-RE/releases/download/v0.6.0/'
      '$assetName';

  @override
  Future<Uri> download(Uri url, File target, Uri? proxy) async {
    downloads.add(url);
    final value = url.toString();
    if (value.contains('api.github.com')) {
      if (apiFails) throw const CoreNetworkException(6, 'offline');
      await target.writeAsString(
        jsonEncode({
          'tag_name': 'v0.6.0',
          'assets': [
            {'browser_download_url': assetUrl, 'size': size, 'digest': digest},
          ],
        }),
      );
      return url;
    }
    if (value.endsWith('/releases/latest')) {
      return Uri.parse('/nilaoda/N_m3u8DL-RE/releases/tag/v0.6.0');
    }
    if (value.contains('expanded_assets')) {
      await target.writeAsString(
        '<a href="/nilaoda/N_m3u8DL-RE/releases/download/v0.6.0/'
        '$assetName">asset</a>',
      );
      return url;
    }
    await target.writeAsBytes(archiveBytes);
    return url;
  }

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) async {
    if (arguments.firstOrNull == '-tf') {
      return ProcessResult(0, 0, 'bundle/${CoreService.executable}\n', '');
    }
    if (arguments.contains('--version')) {
      return ProcessResult(
        0,
        probeFails ? 1 : 0,
        probeFails ? '' : '0.6.0',
        '',
      );
    }
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<void> extract(String archive, String entry, File target) async {
    await target.writeAsBytes(archiveBytes);
  }
}
