import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// 轨道选择、点播分段与 IPTV 频道的纯逻辑层。
///
/// 交互模型沿用 Python 原型 selection.py，但两处按上游源码校准：
/// 1. M3U 判定采用 IPTVExtractor.IsPlaylist 的规则，避免 GUI 列出频道、
///    核心却把同一份清单当 HLS 处理。
/// 2. 分段编号采用 VodPartSelector.Id：PeriodIndex ?? DiscontinuitySequence ?? 0。
///    meta.json 在 FetchPlayListAsync 之前写出，HLS 的 Playlist 可能为 null，
///    因此还要合并 meta_selected.json 里的不连续序号。

/// 预览时透传的网络相关选项，与 Python 原型 options.py 的 network_options 对齐。
const previewPassThrough = <String>{
  '--header',
  '--cookies',
  '--base-url',
  '--custom-proxy',
  '--http-version',
  '--append-url-params',
  '--config',
};

/// 预览时透传、且需要显式 true/false 值的布尔选项。
/// --no-config 不在此列：它由 [previewArguments] 统一追加，避免与 --config 冲突。
const previewBooleanPassThrough = <String>{'--use-system-proxy'};

const previewSaveName = 'preview';
const playlistSizeLimit = 8 * 1024 * 1024;

final _attributePattern = RegExp(
  r'''(?:^|\s)([\w-]+)=(?:"([^"]*)"|'([^']*)'|([^\s,]+))''',
);
final _regexMeta = RegExp(r'[.\\^$|?*+()\[\]{}]');
final _headerName = RegExp(r'''^[!#$%&'*+.^_`|~0-9A-Za-z-]+$''');

/// 把频道名或轨道 URL 转成精确的正则匹配值。
///
/// 复合选轨表达式用 `:` 分隔子键、用 `\:` 表示字面冒号
/// （ComplexParamParser.cs:27-35 会把 `\:` 还原），所以两者都要转义。
String exactExpression(String text) {
  final escaped = text
      .replaceAllMapped(_regexMeta, (match) => '\\${match[0]}')
      .replaceAll(':', r'\:');
  return '^$escaped\$';
}

/// 上游 IPTVExtractor.IsPlaylist 的等价判定。
///
/// 含任意 `#EXT-X-` 标签的一律视为 HLS；否则需要 `#EXTGRP:`、
/// `#EXTINF:-1`，或带 tvg-* / group-title 属性的 #EXTINF 才当作 IPTV 列表。
bool isIptvPlaylist(String text) {
  final lines = const LineSplitter()
      .convert(text)
      .map((l) => l.trim())
      .toList();
  if (lines.any((line) => line.startsWith('#EXT-X-'))) return false;
  for (final line in lines) {
    if (line.startsWith('#EXTGRP:')) return true;
    if (!line.startsWith('#EXTINF:')) continue;
    final head = line.substring(8);
    final first = head
        .split(RegExp(r'[ \t,]'))
        .firstWhere((part) => part.isNotEmpty, orElse: () => '');
    if (first == '-1') return true;
    if (_attributePattern.allMatches(head).any((match) {
      final name = (match.group(1) ?? '').toLowerCase();
      return name.startsWith('tvg-') || name == 'group-title';
    })) {
      return true;
    }
  }
  return false;
}

/// 对齐 IPTVExtractor.FindTitleSeparator：跳过引号内的逗号。
int? _titleSeparator(String line) {
  var quote = 0;
  for (var index = 8; index < line.length; index++) {
    final unit = line.codeUnitAt(index);
    if (quote != 0) {
      if (unit == quote) quote = 0;
    } else if (unit == 0x22 || unit == 0x27) {
      quote = unit;
    } else if (unit == 0x2c) {
      return index;
    }
  }
  return null;
}

/// 取 #EXTINF 的频道名；标题为空时回退到 tvg-name 属性（上游行为）。
String _extinfName(String line) {
  final comma = _titleSeparator(line);
  if (comma == null) return '';
  final title = line.substring(comma + 1).trim();
  if (title.isNotEmpty) return title;
  for (final match in _attributePattern.allMatches(line.substring(0, comma))) {
    if ((match.group(1) ?? '').toLowerCase() == 'tvg-name') {
      return match.group(2) ?? match.group(3) ?? match.group(4) ?? '';
    }
  }
  return '';
}

/// 解析 M3U/M3U8 播放列表中的带名称 HTTP(S) 频道，保序去重。
///
/// [coreCompatible] 为 true 时先做 [isIptvPlaylist] 校验，避免把核心
/// 会当成 HLS 的清单误列为 IPTV 频道。
List<String> parseChannels(
  String content, {
  String base = '',
  bool coreCompatible = true,
}) {
  final text = content.startsWith('\uFEFF') ? content.substring(1) : content;
  if (!text.trimLeft().startsWith('#EXTM3U')) {
    throw const FormatException('输入不是 M3U 播放列表');
  }
  if (coreCompatible && !isIptvPlaylist(text)) {
    throw const FormatException(
      '该播放列表不满足核心的 IPTV 判定条件（需 #EXTGRP:、#EXTINF:-1 '
      '或 tvg-*/group-title 属性，且不能含 #EXT-X- 标签），核心会把它当作 HLS 处理',
    );
  }
  final baseUri = base.isEmpty ? null : Uri.tryParse(base);
  final channels = <String>[];
  final seen = <String>{};
  var name = '';
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF:')) {
      name = _extinfName(line);
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      if (name.isNotEmpty && !seen.contains(name)) {
        final resolved = baseUri?.resolve(line) ?? Uri.tryParse(line);
        if (resolved != null &&
            (resolved.scheme == 'http' || resolved.scheme == 'https')) {
          seen.add(name);
          channels.add(name);
        }
      }
      name = '';
    }
  }
  return channels;
}

/// 多个频道名合成一条 --select-video 表达式：任一名称命中即保留。
String channelFilter(Iterable<String> names) =>
    'name=${names.map(exactExpression).join('|')}:for=all';

class CoreTrack {
  const CoreTrack(this.kind, this.label, this.filter);
  final String kind; // video / audio / subtitle
  final String label;
  final String filter;
}

/// 上游发行版之间的 meta.json 字段并不一致：较新的源码带 MediaType，
/// 官方 v0.6.0-beta（20260628）因 null 省略完全没有该字段，
/// 只剩 Codecs / Resolution / Role / AudioId / SubtitleId。
/// 缺了这层推断时，音频和字幕会被全部误判成视频。
String coreTrackKind(Map<String, Object?> data) {
  // 既可从 coreTracks 收到已归一化的字段，也可被直接传入原始 PascalCase 映射。
  final fields = <String, Object?>{
    for (final entry in data.entries)
      entry.key.toString().toLowerCase(): entry.value,
  };
  final mediaType = '${fields['mediatype'] ?? ''}'.toLowerCase();
  if (const {'video', 'audio', 'subtitles', 'subtitle'}.contains(mediaType)) {
    return mediaType.startsWith('sub') ? 'subtitle' : mediaType;
  }
  final codecs = '${fields['codecs'] ?? ''}'.toLowerCase();
  final extension = '${fields['extension'] ?? ''}'.toLowerCase().replaceAll(
    '.',
    '',
  );
  final role = '${fields['role'] ?? ''}'.toLowerCase();
  const subtitleHints = [
    'stpp',
    'wvtt',
    'ttml',
    'webvtt',
    'vtt',
    'srt',
    'subtitle',
    'text',
  ];
  const audioHints = [
    'mp4a',
    'aac',
    'ac-3',
    'ec-3',
    'eac3',
    'opus',
    'flac',
    'dts',
    'alac',
  ];
  if (role == 'subtitle' ||
      subtitleHints.any(codecs.contains) ||
      const {'vtt', 'srt', 'ttml'}.contains(extension)) {
    return 'subtitle';
  }
  if (audioHints.any(codecs.contains)) return 'audio';
  return 'video';
}

/// 从 meta.json 的顶层数组提取可选轨道。
/// 字段大小写不敏感（上游为 PascalCase，null 字段会省略）。
List<CoreTrack> coreTracks(Object? json) {
  final list = json is List ? json : null;
  if (list == null || list.any((item) => item is! Map)) {
    throw const FormatException('无法识别当前核心的轨道信息格式');
  }
  final tracks = <CoreTrack>[];
  for (final item in list) {
    final track = item as Map;
    final data = <String, Object?>{
      for (final entry in track.entries)
        entry.key.toString().toLowerCase(): entry.value,
    };
    final url = data['url'];
    if (url == null || '$url'.isEmpty) continue;
    final kind = coreTrackKind(data);
    final label =
        const [
              'name',
              'language',
              'resolution',
              'bandwidth',
              'codecs',
              'groupid',
            ]
            .map((key) => data[key])
            .where((value) => value != null && '$value'.isNotEmpty)
            .map((value) => '$value')
            .join(' · ');
    final filters = <String>['url=${exactExpression('$url')}'];
    final groupId = data['groupid'];
    if (groupId != null && '$groupId'.isNotEmpty) {
      filters.add('id=${exactExpression('$groupId')}');
    }
    tracks.add(
      CoreTrack(
        kind,
        label.isEmpty ? kind : label,
        '${filters.join(':')}:for=best',
      ),
    );
  }
  return tracks;
}

/// 汇总点播分段编号与时长（秒）。
///
/// 同一轨道内相同编号累加（HLS 的同一 DiscontinuitySequence 可能有多个 MAP），
/// 跨轨道取最大值。遇到直播清单直接返回空表。
Map<int, double> vodParts(Iterable<Object?> sources) {
  final durations = <int, double>{};
  for (final source in sources) {
    final list = source is List ? source : const <Object?>[];
    for (final item in list) {
      if (item is! Map) continue;
      final playlist = item['Playlist'];
      if (playlist is! Map) continue;
      if (playlist['IsLive'] == true) return <int, double>{};
      final parts = playlist['MediaParts'];
      if (parts is! List) continue;
      final perTrack = <int, double>{};
      for (final part in parts) {
        if (part is! Map) continue;
        final id = part['PeriodIndex'] ?? part['DiscontinuitySequence'] ?? 0;
        if (id is! int || id < 0) continue;
        var total = 0.0;
        final segments = part['MediaSegments'];
        if (segments is List) {
          for (final segment in segments) {
            if (segment is Map && segment['Duration'] is num) {
              total += (segment['Duration'] as num).toDouble();
            }
          }
        }
        perTrack[id] = (perTrack[id] ?? 0) + total;
      }
      for (final entry in perTrack.entries) {
        durations[entry.key] = math.max(durations[entry.key] ?? 0, entry.value);
      }
    }
  }
  final keys = durations.keys.toList()..sort();
  return <int, double>{for (final key in keys) key: durations[key]!};
}

/// 未保留的分段编号转成 --vod-drop-parts 的值；全部保留时返回 null。
String? dropPartsValue(Map<int, double> parts, Set<int> kept) {
  if (parts.length < 2) return null;
  final dropped = parts.keys.where((id) => !kept.contains(id)).toList();
  if (dropped.isEmpty || dropped.length == parts.length) return null;
  return dropped.join(',');
}

/// 解析用户手填的 --vod-drop-parts（支持 `0,2-4`，与上游 ParseIds 一致）。
Set<int> parseDropParts(String value) {
  final ids = <int>{};
  for (final item in value.split(',')) {
    final range = item.trim().split('-');
    final first = int.tryParse(range.first.trim());
    if (first == null || range.length > 2) continue;
    final last = range.length == 2
        ? int.tryParse(range[1].trim()) ?? first
        : first;
    if (last < first || last - first > 10000) continue;
    for (var id = first; id <= last; id++) {
      ids.add(id);
    }
  }
  return ids;
}

/// 组装「读取轨道」的预览命令。
///
/// 只透传网络相关选项，避免用户已填的手动筛选影响 meta_selected.json；
/// --auto-select + --skip-download 让核心写出元数据而不下载，
/// 元数据落在 `tmpDir/preview/`（Program.cs:292 的 tmpDir 规则）。
List<String> previewArguments({
  required String input,
  required String tempDir,
  Map<String, List<String>> values = const {},
  bool isolateConfig = true,
  String? ffmpeg,
}) {
  final arguments = <String>[input];
  var explicitConfig = false;
  for (final entry in values.entries) {
    final boolean = previewBooleanPassThrough.contains(entry.key);
    if (!boolean && !previewPassThrough.contains(entry.key)) continue;
    for (final raw in entry.value) {
      var value = raw.trim();
      if (value == '启用' || value == '关闭') {
        value = value == '启用' ? 'true' : 'false';
      }
      if (value.isEmpty || value == '默认') continue;
      if (entry.key == '--config') explicitConfig = true;
      arguments.addAll([entry.key, value]);
    }
  }
  // --config 与 --no-config 同时出现会让上游 ConfigFile.cs 抛 configFileConflict。
  if (isolateConfig && !explicitConfig) arguments.add('--no-config');
  arguments.addAll([
    if (ffmpeg != null) ...['--ffmpeg-binary-path', ffmpeg],
    '--tmp-dir',
    tempDir,
    '--save-dir',
    tempDir,
    '--save-name',
    previewSaveName,
    '--auto-select',
    '--skip-download',
    '--write-meta-json',
    'true',
    '--no-log',
    '--no-ansi-color',
    '--disable-update-check',
  ]);
  return arguments;
}

/// 从 Netscape Cookie 文件里挑出适用于 [uri] 的条目，合成 Cookie 请求头。
String? netscapeCookieHeader(String content, Uri uri) {
  final host = uri.host.toLowerCase();
  final path = uri.path.isEmpty ? '/' : uri.path;
  final pairs = <String>[];
  for (final raw in const LineSplitter().convert(content)) {
    var line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#HttpOnly_')) {
      line = line.substring(10);
    } else if (line.startsWith('#')) {
      continue;
    }
    final fields = line.split('\t');
    if (fields.length < 7) continue;
    final domain = fields[0].toLowerCase();
    final cookiePath = fields[2];
    final secure = fields[3].toUpperCase() == 'TRUE';
    final name = fields[5];
    if (name.isEmpty) continue;
    if (secure && uri.scheme != 'https') continue;
    final bare = domain.startsWith('.') ? domain.substring(1) : domain;
    if (host != bare && !host.endsWith('.$bare')) continue;
    if (cookiePath.isNotEmpty && !path.startsWith(cookiePath)) continue;
    pairs.add('$name=${fields.sublist(6).join('\t')}');
  }
  return pairs.isEmpty ? null : pairs.join('; ');
}

/// 拉取远程 M3U 播放列表。支持自定义请求头、代理与 Netscape Cookie 内容。
Future<String> fetchRemotePlaylist(
  String url, {
  List<String> headers = const [],
  String? cookies,
  String? proxy,
  bool useSystemProxy = true,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const FormatException('请输入完整的 HTTP 或 HTTPS 播放列表地址');
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 20)
    ..userAgent = 'SegmentDesk';
  final custom = proxy?.trim() ?? '';
  if (custom.isNotEmpty) {
    final target = custom.contains(':') ? custom : '$custom:80';
    client.findProxy = (_) => 'PROXY $target';
  } else if (!useSystemProxy) {
    client.findProxy = (_) => 'DIRECT';
  } else {
    client.findProxy = HttpClient.findProxyFromEnvironment;
  }
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.followRedirects = true;
    request.maxRedirects = 5;
    for (final header in headers) {
      final separator = header.indexOf(':');
      if (separator <= 0) {
        throw const FormatException('请求头应使用「名称: 值」格式');
      }
      final name = header.substring(0, separator).trim();
      final value = header.substring(separator + 1).trim();
      if (!_headerName.hasMatch(name) ||
          value.contains('\r') ||
          value.contains('\n')) {
        throw const FormatException('请求头格式不正确');
      }
      request.headers.set(name, value);
    }
    final cookieHeader = cookies == null
        ? null
        : netscapeCookieHeader(cookies, uri);
    if (cookieHeader != null) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('播放列表请求失败（HTTP ${response.statusCode}）');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      if (bytes.length + chunk.length > playlistSizeLimit) {
        throw const FormatException('播放列表超过 8 MiB');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    client.close(force: true);
  }
}
