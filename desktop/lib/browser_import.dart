import 'dart:convert';
import 'dart:io';

class BrowserImport {
  const BrowserImport(this.url, this.title, this.type);

  final String url;
  final String title;
  final String type;

  bool get canImport => const {'HLS', 'DASH', 'MSS', 'M3U'}.contains(type);

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
