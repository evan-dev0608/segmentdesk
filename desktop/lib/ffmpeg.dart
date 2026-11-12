import 'dart:io';

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
