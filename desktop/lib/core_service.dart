import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';

Uri? parseUpdateProxy(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !const {'http', 'https', 'socks5', 'socks5h'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}

class CoreNetworkException implements Exception {
  const CoreNetworkException(this.code, this.details);
  final int code;
  final String details;

  @override
  String toString() => switch (code) {
    5 ||
    6 ||
    7 ||
    28 ||
    35 ||
    60 => '无法连接 GitHub。请检查网络，或在「设置 → 下载核心」填写更新代理后重试。',
    _ => '访问 GitHub 失败：$details',
  };
}

class CoreInstall {
  const CoreInstall(this.executable, this.tag, {this.verified = true});
  final String executable;
  final String tag;

  /// 本次安装是否实际执行了发行包完整性校验。
  /// GitHub 官方发行页的回退路径拿不到 size / digest，两段校验会被跳过。
  final bool verified;
}

/// 核心安装依赖的全部外部命令。测试可整体替换，
/// 从而在不联网、不调用系统 curl / tar 的前提下跑完整链路。
abstract class CoreRunner {
  Future<ProcessResult> run(String executable, List<String> arguments);
  Future<Uri> download(Uri url, File target, Uri? proxy);
  Future<void> extract(String archive, String entry, File target);
}

class SystemCoreRunner implements CoreRunner {
  const SystemCoreRunner();

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) =>
      Process.run(executable, arguments);

  @override
  Future<Uri> download(Uri url, File target, Uri? proxy) async {
    final result = await run('curl', [
      '--disable',
      if (proxy != null) ...['--proxy', proxy.toString(), '--noproxy', ''],
      '--fail',
      '--silent',
      '--show-error',
      '--location',
      '--proto',
      '=https',
      '--proto-redir',
      '=https',
      '--connect-timeout',
      '10',
      '--max-time',
      '90',
      '--user-agent',
      'StreamDownloadGUI',
      '--output',
      target.path,
      '--write-out',
      '%{url_effective}',
      url.toString(),
    ]);
    if (result.exitCode != 0) {
      throw CoreNetworkException(
        result.exitCode,
        (result.stderr as String).trim(),
      );
    }
    return Uri.parse((result.stdout as String).trim());
  }

  @override
  Future<void> extract(String archive, String entry, File target) async {
    final extraction = await Process.start('tar', [
      '-xOf',
      archive,
      '--',
      entry,
    ]);
    final drain = extraction.stderr.drain<void>();
    await extraction.stdout.pipe(target.openWrite());
    await drain;
    if (await extraction.exitCode != 0) throw StateError('解包失败');
  }
}

class CoreService {
  static Future<CoreInstall> inspectExecutable(String path) async {
    final file = File(path);
    if (!file.isAbsolute || !await file.exists()) {
      throw const FormatException('请选择存在的核心可执行文件。');
    }
    final result = await Process.run(path, [
      '--version',
    ]).timeout(const Duration(seconds: 5));
    final version = '${result.stdout}\n${result.stderr}'
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where(
          (line) =>
              line.contains('N_m3u8DL-RE') ||
              RegExp(r'^v?\d+\.\d+\.\d+(?:[-+][\w.+-]+)?$').hasMatch(line),
        )
        .firstOrNull;
    if (result.exitCode != 0 || version == null) {
      throw const FormatException('所选文件未返回 N_m3u8DL-RE 版本信息。');
    }
    final help = await Process.run(path, [
      '--help',
    ]).timeout(const Duration(seconds: 5));
    final usage = help.stdout.toString();
    if (help.exitCode != 0 ||
        !usage.contains('--select-video') ||
        !usage.contains('--write-meta-json')) {
      throw const FormatException('所选文件没有 N_m3u8DL-RE 的下载选项。');
    }
    return CoreInstall(path, version, verified: false);
  }

  CoreService({CoreRunner? runner, this.dataDirectory})
    : runner = runner ?? const SystemCoreRunner();

  final CoreRunner runner;
  final Directory? dataDirectory;

  static const repository = 'nilaoda/N_m3u8DL-RE';
  static final sep = Platform.pathSeparator;
  static final home =
      Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;
  static String get executable =>
      Platform.isWindows ? 'N_m3u8DL-RE.exe' : 'N_m3u8DL-RE';
  static Directory get data {
    final base = Platform.isWindows
        ? Platform.environment['LOCALAPPDATA'] ?? '$home/AppData/Local'
        : Platform.isMacOS
        ? '$home/Library/Application Support'
        : Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
    return Directory('$base/StreamDownloadGUI');
  }

  /// 测试注入的数据目录；生产仍使用平台默认目录。
  Directory get workingData => dataDirectory ?? data;

  Future<CoreInstall?> installed() async {
    final state = File('${workingData.path}/active.json');
    if (!await state.exists()) return null;
    final record =
        jsonDecode(await state.readAsString()) as Map<String, dynamic>;
    final directory = record['directory'] as String;
    if (!RegExp(r'^core-[A-Za-z0-9_-]+$').hasMatch(directory)) {
      throw const FormatException('核心目录无效');
    }
    final candidate = File('${workingData.path}/$directory/$executable');
    if (!await candidate.exists()) return null;
    return CoreInstall(candidate.path, record['tag'] as String);
  }

  Future<CoreInstall> update(void Function(String) status, {Uri? proxy}) async {
    await workingData.create(recursive: true);
    final stage = await workingData.createTemp('update-');
    try {
      final metadata = File('${stage.path}/release');
      final official = 'https://github.com/$repository/releases';
      String tag;
      List<String> urls;
      final checks = <String, Map<String, dynamic>>{};
      status('正在检查 GitHub 发行版…');
      try {
        await runner.download(
          Uri.parse('https://api.github.com/repos/$repository/releases/latest'),
          metadata,
          proxy,
        );
        final release =
            jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
        tag = release['tag_name'] as String;
        for (final asset
            in (release['assets'] as List).cast<Map<String, dynamic>>()) {
          checks[asset['browser_download_url'] as String] = asset;
        }
        urls = checks.keys.toList();
      } on CoreNetworkException {
        final release = await runner.download(
          Uri.parse('$official/latest'),
          metadata,
          proxy,
        );
        final match = RegExp('^/$repository/releases/tag/([\\w.-]+)\$')
            .firstMatch(release.path);
        if (match == null) throw StateError('无法识别 GitHub 官方发行版本');
        tag = match[1]!;
        await runner.download(
          Uri.parse('$official/expanded_assets/$tag'),
          metadata,
          proxy,
        );
        urls = RegExp('href="(/$repository/releases/download/[^"<>]+)"')
            .allMatches(await metadata.readAsString())
            .map((match) => 'https://github.com${match[1]}')
            .toSet()
            .toList();
      }
      final current = await installed();
      if (current?.tag == tag) return current!;
      final architecture = Abi.current().toString().split('_').last;
      if (architecture != 'x64' && architecture != 'arm64') {
        throw UnsupportedError('当前架构没有支持的官方发行包');
      }
      final os = Platform.isWindows
          ? 'win'
          : Platform.isMacOS
          ? 'osx'
          : 'linux';
      final extension = Platform.isWindows ? 'zip' : 'tar.gz';
      final suffix = RegExp(
        '[-_]$os-$architecture(?:_\\d{8})?\\.${RegExp.escape(extension)}\$',
      );
      final matching = urls
          .where(
            (url) =>
                url.startsWith('$official/download/$tag/') &&
                suffix.hasMatch(Uri.parse(url).path),
          )
          .toList();
      if (matching.length != 1) {
        throw StateError('没有找到唯一匹配的 $os-$architecture 核心');
      }
      status('正在下载核心 $tag…');
      final archive = File('${stage.path}/core.$extension');
      await runner.download(Uri.parse(matching.single), archive, proxy);
      final check = checks[matching.single];
      final size = check?['size'];
      final digest = check?['digest'];
      // 官方发行页回退路径没有 asset 元数据，两段校验都会被跳过。
      // 必须把「本次是否真的校验过」传给界面，不能默认显示成已验证。
      final verified = size is int || digest is String;
      status(verified ? '正在验证并安装核心…' : '正在安装核心（发行页回退，本次无校验信息）…');
      if (size is int && await archive.length() != size) {
        throw StateError('核心压缩包大小不一致');
      }
      if (digest is String &&
          digest != 'sha256:${await sha256.bind(archive.openRead()).first}') {
        throw StateError('核心压缩包校验失败');
      }
      final listing = await runner.run('tar', ['-tf', archive.path]);
      if (listing.exitCode != 0) throw StateError('无法读取核心压缩包');
      final entries = const LineSplitter()
          .convert(listing.stdout as String)
          .where(
            (entry) =>
                entry.split('/').last == executable && !entry.startsWith('-'),
          )
          .toList();
      if (entries.length != 1) throw StateError('压缩包中的核心文件不唯一');
      final target = await workingData.createTemp('core-');
      try {
        final candidate = File('${target.path}/$executable');
        await runner.extract(archive.path, entries.single, candidate);
        if (!Platform.isWindows) {
          final permissions = await runner.run('chmod', [
            '755',
            candidate.path,
          ]);
          if (permissions.exitCode != 0) {
            throw StateError('无法设置核心执行权限');
          }
        }
        final probe = await runner
            .run(candidate.path, ['--version'])
            .timeout(const Duration(seconds: 15));
        if (probe.exitCode != 0 ||
            !RegExp(r'\d+\.\d+').hasMatch(probe.stdout as String)) {
          throw StateError('无法运行新核心');
        }
        final pointer = File('${stage.path}/active.json');
        await pointer.writeAsString(
          jsonEncode({
            'tag': tag,
            'directory': target.uri.pathSegments.lastWhere(
              (segment) => segment.isNotEmpty,
            ),
          }),
        );
        await pointer.rename('${workingData.path}/active.json');
        return CoreInstall(candidate.path, tag, verified: verified);
      } catch (_) {
        await target.delete(recursive: true);
        rethrow;
      }
    } finally {
      await stage.delete(recursive: true);
    }
  }
}
