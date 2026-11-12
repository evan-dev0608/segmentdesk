import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class ClientUpdates {
  static const repository = 'evan-dev0608/segmentdesk';
  static const releases = 'https://github.com/$repository/releases';

  static Future<String> installedVersion() async {
    final manifest = await rootBundle.loadString('pubspec.yaml');
    final match = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$',
      multiLine: true,
    ).firstMatch(manifest);
    if (match == null) throw const FormatException('无法读取客户端版本。');
    return match[1]!;
  }

  static bool isNewer(String tag, String installed) {
    final stable = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$');
    final remote = stable.firstMatch(tag);
    final local = stable.firstMatch(installed);
    if (remote == null || local == null) {
      throw const FormatException('无法识别正式版版本号。');
    }
    for (var part = 1; part <= 3; part++) {
      final difference = int.parse(remote[part]!)
          .compareTo(int.parse(local[part]!));
      if (difference != 0) return difference > 0;
    }
    return false;
  }

  static Future<String> latestTag() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      return await (() async {
        final request = await client.getUrl(
          Uri.https('api.github.com', '/repos/$repository/releases/latest'),
        );
        request.headers.set('Accept', 'application/vnd.github+json');
        request.headers.set('User-Agent', 'SegmentDesk');
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException('GitHub 返回 HTTP ${response.statusCode}');
        }
        final data = jsonDecode(await response.transform(utf8.decoder).join());
        if (data is! Map ||
            data['tag_name'] is! String ||
            data['draft'] != false ||
            data['prerelease'] != false) {
          throw const FormatException('未取得正式版信息。');
        }
        return data['tag_name'] as String;
      })().timeout(const Duration(seconds: 10));
    } finally {
      client.close(force: true);
    }
  }
}
