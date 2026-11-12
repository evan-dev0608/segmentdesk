import 'dart:convert';
import 'dart:io';
import 'dart:ffi';

import 'package:crypto/crypto.dart';

class CoreInstall {
  const CoreInstall(this.executable, this.tag);
  final String executable;
  final String tag;
}

class CoreService {
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

  Future<CoreInstall?> installed() async {
    final state = File('${data.path}/active.json');
    if (!await state.exists()) return null;
    final record =
        jsonDecode(await state.readAsString()) as Map<String, dynamic>;
    final directory = record['directory'] as String;
    if (!RegExp(r'^core-[A-Za-z0-9_-]+$').hasMatch(directory)) {
      throw const FormatException('核心目录无效');
    }
    final candidate = File('${data.path}/$directory/$executable');
    if (!await candidate.exists()) return null;
    return CoreInstall(candidate.path, record['tag'] as String);
  }

  Future<Uri> _download(Uri url, File target) async {
    final result = await Process.run('curl', [
      '--disable',
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
      throw StateError((result.stderr as String).trim());
    }
    return Uri.parse((result.stdout as String).trim());
  }

  Future<CoreInstall> update(void Function(String) status) async {
    await data.create(recursive: true);
    final stage = await data.createTemp('update-');
    try {
      final metadata = File('${stage.path}/release');
      final official = 'https://github.com/$repository/releases';
      String tag;
      List<String> urls;
      final checks = <String, Map<String, dynamic>>{};
      status('正在检查 GitHub 发行版…');
      try {
        await _download(
          Uri.parse('https://api.github.com/repos/$repository/releases/latest'),
          metadata,
        );
        final release =
            jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
        tag = release['tag_name'] as String;
        for (final asset
            in (release['assets'] as List).cast<Map<String, dynamic>>()) {
          checks[asset['browser_download_url'] as String] = asset;
        }
        urls = checks.keys.toList();
      } on StateError {
        final release = await _download(
          Uri.parse('$official/latest'),
          metadata,
        );
        final match = RegExp('^/$repository/releases/tag/([\\w.-]+)\$')
            .firstMatch(release.path);
        if (match == null) throw StateError('无法识别 GitHub 官方发行版本');
        tag = match[1]!;
        await _download(Uri.parse('$official/expanded_assets/$tag'), metadata);
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
      await _download(Uri.parse(matching.single), archive);
      status('正在验证并安装核心…');
      final check = checks[matching.single];
      final size = check?['size'];
      if (size is int && await archive.length() != size) {
        throw StateError('核心压缩包大小不一致');
      }
      final digest = check?['digest'];
      if (digest is String &&
          digest != 'sha256:${await sha256.bind(archive.openRead()).first}') {
        throw StateError('核心压缩包校验失败');
      }
      final listing = await Process.run('tar', ['-tf', archive.path]);
      if (listing.exitCode != 0) throw StateError('无法读取核心压缩包');
      final entries = const LineSplitter()
          .convert(listing.stdout as String)
          .where(
            (entry) =>
                entry.split('/').last == executable && !entry.startsWith('-'),
          )
          .toList();
      if (entries.length != 1) throw StateError('压缩包中的核心文件不唯一');
      final target = await data.createTemp('core-');
      try {
        final candidate = File('${target.path}/$executable');
        final extraction = await Process.start('tar', [
          '-xOf',
          archive.path,
          '--',
          entries.single,
        ]);
        final drain = extraction.stderr.drain<void>();
        await extraction.stdout.pipe(candidate.openWrite());
        await drain;
        if (await extraction.exitCode != 0) throw StateError('解包失败');
        if (!Platform.isWindows) {
          final permissions = await Process.run('chmod', [
            '755',
            candidate.path,
          ]);
          if (permissions.exitCode != 0) throw StateError('无法设置核心执行权限');
        }
        final probe = await Process.run(candidate.path, [
          '--version',
        ]).timeout(const Duration(seconds: 15));
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
        await pointer.rename('${data.path}/active.json');
        return CoreInstall(candidate.path, tag);
      } catch (_) {
        await target.delete(recursive: true);
        rethrow;
      }
    } finally {
      await stage.delete(recursive: true);
    }
  }
}
