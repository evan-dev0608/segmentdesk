import 'dart:convert';
import 'dart:io';

String decodeCoreOutput(List<int> bytes, {Encoding? fallback}) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    final encoding = fallback ?? (Platform.isWindows ? systemEncoding : null);
    return encoding?.decode(bytes) ?? utf8.decode(bytes, allowMalformed: true);
  }
}

// 上游在 stdout 被重定向时仍会渲染下载进度条，并直接继承 mp4decrypt /
// shaka-packager 等子进程的 stdout。这里不做「只保留带时间戳的日志行」，
// 因为 doctor 报告、ffmpeg 输出等都不经过 Logger，没有时间戳前缀。
final _ansiEscape = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');
const _logPrefix = r'\d{2}:\d{2}:\d{2}\.\d{3}\s+(?:INFO|DEBUG|WARN|ERROR)\b';
final _structuredLog = RegExp('^$_logPrefix');
// Spectre can render multiple log records and progress frames without newlines.
// Match on a byte-preserving string so UTF-8 sequences may span pipe chunks.
final _recordBoundary = RegExp(
  '(?=$_logPrefix|(?<! : )(?:Vid [0-9]+x[0-9]+ \\| [0-9]+ Kbps|(?:Aud|Sub) \\S))|\\r\\n|[\\r\\n]',
);
final _progressGlyph = RegExp(r'[━─╸╺█░▒▓╴╵]+');

/// 去掉 ANSI 控制序列和回车覆盖留下的旧帧，空行直接丢弃。
String? cleanCoreLogLine(String raw) {
  var text = raw;
  final carriage = text.lastIndexOf('\r');
  if (carriage >= 0) text = text.substring(carriage + 1);
  text = text.replaceAll(_ansiEscape, '').trimRight();
  return text.trim().isEmpty ? null : text;
}

/// 上游 Logger 的正式日志行，永远不应被进度帧折叠逻辑吞掉。
bool isStructuredLogLine(String line) => _structuredLog.hasMatch(line);

final _downloadProgress = RegExp(r'\b\d+/\d+\s+(\d{1,3}(?:\.\d+)?)%');

double? coreDownloadProgress(String line) {
  if (isStructuredLogLine(line)) return null;
  final match = _downloadProgress.firstMatch(line);
  if (match == null) return null;
  final percent = double.parse(match[1]!);
  return percent <= 100 ? percent / 100 : null;
}

/// 把时间戳、百分比、字节数和进度条字形归一化，用于识别同一进度条的连续帧。
String logLineFingerprint(String line) => line
    .replaceAll(RegExp(r'\d+(?:[.,:]\d+)*%?'), '#')
    .replaceAll(_progressGlyph, '#')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// 只有「含可变数字的连续非日志行」才折叠，避免误合并 doctor 的静态分隔线。
bool shouldFoldLogLine(String previous, String current) {
  if (isStructuredLogLine(previous) || isStructuredLogLine(current)) {
    return false;
  }
  final fingerprint = logLineFingerprint(current);
  return fingerprint.contains('#') &&
      logLineFingerprint(previous) == fingerprint;
}

String? _decodeRecord(String line) {
  final raw = latin1.encode(line);
  try {
    return cleanCoreLogLine(decodeCoreOutput(raw));
  } on FormatException {
    return cleanCoreLogLine(utf8.decode(raw, allowMalformed: true));
  }
}

Stream<String> coreOutputLines(Stream<List<int>> bytes) async* {
  var pending = '';
  await for (final chunk in bytes.transform(latin1.decoder)) {
    pending += chunk;
    var start = 0;
    for (final boundary in _recordBoundary.allMatches(pending)) {
      if (boundary.start > start) {
        if (_decodeRecord(pending.substring(start, boundary.start))
            case final line?) {
          yield line;
        }
      }
      start = boundary.end;
    }
    pending = pending.substring(start);
  }
  if (_decodeRecord(pending) case final line?) yield line;
}
