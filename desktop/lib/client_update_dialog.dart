import 'dart:io';

import 'package:flutter/material.dart';

import 'client_updates.dart';

class ClientUpdateDialog extends StatefulWidget {
  const ClientUpdateDialog({
    super.key,
    required this.release,
    required this.installers,
    required this.currentRenderer,
    required this.onReleasePage,
    required this.canInstall,
  });

  final ClientRelease release;
  final List<ClientInstaller> installers;
  final String currentRenderer;
  final VoidCallback onReleasePage;
  final bool Function() canInstall;

  @override
  State<ClientUpdateDialog> createState() => _ClientUpdateDialogState();
}

class _ClientUpdateDialogState extends State<ClientUpdateDialog> {
  late ClientInstaller? selected =
      widget.installers
          .where((installer) => installer.renderer == widget.currentRenderer)
          .firstOrNull ??
      widget.installers.firstOrNull;
  File? downloaded;
  double? progress;
  bool busy = false;
  String? error;

  Future<void> download() async {
    final installer = selected!;
    setState(() {
      busy = true;
      progress = 0;
      error = null;
    });
    try {
      final file = await installer.download((value) {
        if (mounted) setState(() => progress = value);
      });
      if (!mounted) {
        await file.parent.delete(recursive: true);
        return;
      }
      setState(() => downloaded = file);
    } catch (exception) {
      if (mounted) setState(() => error = '下载失败：$exception');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> install() async {
    if (!widget.canInstall()) {
      setState(() => error = '请等待当前任务结束后再安装。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Process.start(
        downloaded!.path,
        [],
        mode: ProcessStartMode.detached,
      );
      exit(0);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '无法启动安装程序，请重试或打开发布页下载。';
        });
      }
    }
  }

  @override
  void dispose() {
    downloaded?.parent.delete(recursive: true).ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text('发现新版 ${widget.release.tag}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.release.notes.trim().isNotEmpty)
                SelectableText(widget.release.notes.trim()),
              if (widget.installers.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('选择 Windows 安装版本'),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final installer in widget.installers)
                      ChoiceChip(
                        label: Text(installer.label),
                        selected: selected == installer,
                        onSelected: busy || downloaded != null
                            ? null
                            : (value) {
                                if (value) setState(() => selected = installer);
                              },
                      ),
                  ],
                ),
              ] else
                const Text('请前往发布页获取适合当前系统的安装包。'),
              if (busy && progress != null) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
                Text(
                  progress == 1
                      ? '正在校验安装包…'
                      : '正在下载 ${(progress! * 100).round()}%',
                ),
              ],
              if (downloaded != null) const Text('安装包已下载并通过校验。'),
              if (error case final message?)
                Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('稍后'),
        ),
        TextButton(
          onPressed: busy ? null : widget.onReleasePage,
          child: const Text('打开发布页'),
        ),
        if (selected != null)
          FilledButton(
            onPressed: busy
                ? null
                : downloaded == null
                ? download
                : install,
            child: Text(downloaded == null ? '下载更新' : '退出并安装'),
          ),
      ],
    ),
  );
}
