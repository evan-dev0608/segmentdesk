import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_download/settings.dart';
import 'package:stream_download/core_output.dart';
import 'package:stream_download/advanced.dart';
import 'package:stream_download/main.dart';

void main() {
  test('appearance settings load with backwards-compatible defaults', () {
    final old = Preferences.fromJson({
      'folder': 'downloads',
      'container': 'ts',
    });
    expect(old.themeMode, ThemeMode.system);
    expect(old.accent, 'indigo');
    expect(old.container, 'ts');

    final updated = Preferences.fromJson({
      'themeMode': 'dark',
      'accent': 'green',
    });
    expect(updated.themeMode, ThemeMode.dark);
    expect(updated.seed, Preferences.accents['green']!.$2);
  });
  test('preserves UTF-8 and falls back to the system code page', () async {
    expect(decodeCoreOutput(utf8.encode('保存目录'), fallback: latin1), '保存目录');
    expect(decodeCoreOutput([0xe9], fallback: latin1), 'é');
    final bytes = utf8.encode('保存目录\r\n第二行');
    expect(
      await coreOutputLines(
        Stream.fromIterable([bytes.sublist(0, 2), bytes.sublist(2)]),
      ).toList(),
      ['保存目录', '第二行'],
    );
  });
  test('parses aliased, boolean and typed options', () {
    final options = parseCoreHelp(
      '  -H, --header <header>  Request header\n'
      '  --sub-only           Subtitles only\n'
      '  --sub-format <SRT|VTT>  Format\n'
      '  --vod-select-parts     Interactive selection\n',
    );
    expect(options.map((option) => option.flag), [
      '--header',
      '--sub-only',
      '--sub-format',
    ]);
    expect(options[1].placeholder, isNull);
    expect(options[2].placeholder, '<SRT|VTT>');
  });
  testWidgets('workspace shows task navigation and core management', (
    tester,
  ) async {
    await tester.pumpWidget(const DownloadApp());
    expect(find.text('新建下载'), findsOneWidget);
    expect(find.text('下载核心'), findsOneWidget);
    await tester.tap(find.text('运行中'));
    await tester.pump();
    expect(find.text('运行中'), findsNWidgets(2));
  });
}
