import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

  static Future<ClientRelease> latestRelease() async {
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
        final tag = data['tag_name'] as String;
        return ClientRelease(
          tag,
          data['body'] is String ? data['body'] as String : '',
          [
            for (final asset in (data['assets'] as List? ?? const []))
              if (asset is Map)
                for (final renderer in ['skia', 'impeller'])
                  if (asset['name'] ==
                          'SegmentDesk-windows-x64-$renderer-setup.exe' &&
                      asset['digest'] is String &&
                      RegExp(r'^sha256:[a-fA-F0-9]{64}$')
                          .hasMatch(asset['digest'] as String) &&
                      asset['size'] is int &&
                      (asset['size'] as int) > 0)
                    ClientInstaller(
                      tag,
                      renderer,
                      asset['digest'] as String,
                      asset['size'] as int,
                    ),
          ],
        );
      })().timeout(const Duration(seconds: 10));
    } finally {
      client.close(force: true);
    }
  }
}

class ClientRelease {
  const ClientRelease(this.tag, this.notes, this.installers);
  final String tag, notes;
  final List<ClientInstaller> installers;
}

class ClientInstaller {
  const ClientInstaller(this.tag, this.renderer, this.digest, this.size);
  final String tag, renderer, digest;
  final int size;

  String get label => renderer == 'skia' ? 'Skia 兼容版' : 'Impeller 版';
  String get filename => 'SegmentDesk-windows-x64-$renderer-setup.exe';

  Future<File> download(void Function(double) onProgress) async {
    final directory = await Directory.systemTemp.createTemp(
      'segmentdesk-update-',
    );
    final installer = File(
      '${directory.path}${Platform.pathSeparator}$filename',
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final url = Uri.parse(
        '${ClientUpdates.releases}/download/${Uri.encodeComponent(tag)}/$filename',
      );
      final response = await (await client.getUrl(url))
          .close()
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw HttpException('下载安装包失败（HTTP ${response.statusCode}）');
      }
      var received = 0;
      final sink = installer.openWrite();
      try {
        await sink.addStream(
          response.timeout(const Duration(seconds: 20)).map((chunk) {
            received += chunk.length;
            if (received > size) throw const FormatException('安装包大小不符。');
            onProgress(received / size);
            return chunk;
          }),
        );
      } finally {
        await sink.close();
      }
      final actual = await sha256.bind(installer.openRead()).first;
      if (received != size || 'sha256:$actual' != digest.toLowerCase()) {
        throw const FormatException('安装包校验失败。');
      }
      return installer;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
