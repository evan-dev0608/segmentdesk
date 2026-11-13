import 'dart:convert';
import 'dart:io';

class BrowserImport {
  const BrowserImport(this.url, this.title, this.type);

  final String url;
  final String title;
  final String type;

  String get suggestedName {
    final cleaned = title
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    final name = StringBuffer();
    var bytes = 0;
    for (final rune in cleaned.runes) {
      final character = String.fromCharCode(rune);
      bytes += utf8.encode(character).length;
      if (bytes > 150) break;
      name.write(character);
    }
    final stem = name.toString().replaceFirst(RegExp(r'[. ]+$'), '');
    final reserved = RegExp(
      r'^(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]) *(?:\.|$)|^[-@]',
      caseSensitive: false,
    );
    return reserved.hasMatch(stem) ? '_$stem' : stem;
  }

  bool get canImport =>
      const {'HLS', 'DASH', 'MSS', 'M3U', 'MP4'}.contains(type);

  /// 扩展探测到的 MP4 是单文件直链：核心按响应内容直接下载，
  /// 不走清单解析、选轨与混流，需要在任务里显式标记。
  bool get isDirect => type == 'MP4';

  static BrowserImport? parse(String payload) {
    final Object? data;
    try {
      data = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    if (data is! Map<String, dynamic> || data['version'] != 1) return null;
    final type = data['type'];
    if (type is! String ||
        !const {'HLS', 'DASH', 'MSS', 'M3U', 'MP4'}.contains(type)) {
      return null;
    }
    final url = data['url'];
    if (url is! String || RegExp(r'[\x00-\x20\x7f]').hasMatch(url)) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final title = data['title'];
    return BrowserImport(url, title is String ? title : '', type);
  }

  static Directory? get inbox {
    if (!Platform.isWindows) return null;
    final local = Platform.environment['LOCALAPPDATA'];
    return local == null ? null : Directory('$local/SegmentDesk/browser-inbox');
  }
}
