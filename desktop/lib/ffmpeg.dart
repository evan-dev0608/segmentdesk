import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'core_service.dart';

String? resolveFFmpeg(String configured) {
  if (configured.isNotEmpty) {
    final file = File(configured);
    return file.isAbsolute && file.existsSync() ? file.path : null;
  }
  final windows = Platform.isWindows;
  final name = windows ? 'ffmpeg.exe' : 'ffmpeg';
  for (final entry in (Platform.environment['PATH'] ?? '').split(
    windows ? ';' : ':',
  )) {
    final directory = entry.replaceAll('"', '').trim();
    if (directory.isEmpty) continue;
    final file = File('$directory${Platform.pathSeparator}$name');
    if (file.isAbsolute && file.existsSync()) return file.path;
  }
  return null;
}

Future<String> inspectFFmpeg(String path) async {
  final result = await Process.run(path, [
    '-version',
  ]).timeout(const Duration(seconds: 5));
  final line = result.stdout.toString().split('\n').first.trim();
  if (result.exitCode != 0 || !line.startsWith('ffmpeg version ')) {
    throw const FormatException('所选程序未返回 FFmpeg 版本信息。');
  }
  return line.split(RegExp(r'\s+'))[2];
}

bool get canDownloadFFmpeg => Abi.current() == Abi.windowsX64;

Future<String> downloadFFmpeg(void Function(String) report) async {
  const runner = SystemCoreRunner(downloadTimeoutSeconds: 600);
  const source =
      'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip';
  final root = await Directory('${CoreService.data.path}/ffmpeg')
      .create(recursive: true);
  final stage = await root.createTemp('.download-');
  try {
    final checksum = File('${stage.path}/checksum');
    report('正在检查可下载的 FFmpeg…');
    await runner.download(Uri.parse('$source.sha256'), checksum, null);
    final digest = (await checksum.readAsString()).trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('无效的 FFmpeg 校验值。');
    }
    final target = File('${root.path}/$digest/ffmpeg.exe');
    if (await target.exists()) {
      await inspectFFmpeg(target.path);
      return target.path;
    }
    report('正在下载 FFmpeg…');
    final archive = File('${stage.path}/ffmpeg.zip');
    await runner.download(Uri.parse(source), archive, null);
    report('正在校验和解包 FFmpeg…');
    if ((await sha256.bind(archive.openRead()).first).toString() != digest) {
      throw const FormatException('FFmpeg 下载文件校验失败，请重试。');
    }
    final listing = await runner.run('tar', ['-tf', archive.path]);
    final entries = listing.stdout
        .toString()
        .split(RegExp(r'[\r\n]+'))
        .where(
          (entry) => RegExp(r'^ffmpeg-[^/]+/bin/ffmpeg\.exe$').hasMatch(entry),
        );
    if (listing.exitCode != 0 || entries.length != 1) {
      throw const FormatException('压缩包中未找到 FFmpeg 可执行文件。');
    }
    final executable = File('${stage.path}/ffmpeg.exe');
    await runner.extract(archive.path, entries.single, executable);
    await inspectFFmpeg(executable.path);
    await target.parent.create(recursive: true);
    if (!await target.exists()) await executable.rename(target.path);
    return target.path;
  } finally {
    await stage.delete(recursive: true);
  }
}
