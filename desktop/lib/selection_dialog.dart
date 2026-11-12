import 'package:flutter/material.dart';

import 'selection.dart';

/// 「读取轨道」对话框的回填结果。
class TrackSelection {
  const TrackSelection({
    this.video,
    this.audio,
    this.subtitle,
    this.dropParts,
    this.partsShown = false,
  });

  final String? video;
  final String? audio;
  final String? subtitle;
  final String? dropParts;

  /// 是否展示了分段控件；为 false 时不应覆盖用户手填的 --vod-drop-parts。
  final bool partsShown;

  bool get hasTrack => video != null || audio != null || subtitle != null;
}

const trackKinds = <String, String>{
  'video': '视频',
  'audio': '音频',
  'subtitle': '字幕',
};

class TrackSelectionDialog extends StatefulWidget {
  const TrackSelectionDialog({
    super.key,
    required this.tracks,
    required this.parts,
    this.supportsParts = true,
    this.initialDrop = '',
  });

  final List<CoreTrack> tracks;
  final Map<int, double> parts;
  final bool supportsParts;
  final String initialDrop;

  @override
  State<TrackSelectionDialog> createState() => _TrackSelectionDialogState();
}

class _TrackSelectionDialogState extends State<TrackSelectionDialog> {
  final chosen = <String, int?>{'video': null, 'audio': null, 'subtitle': null};
  late final Set<int> kept = widget.parts.keys
      .where((id) => !parseDropParts(widget.initialDrop).contains(id))
      .toSet();
  String? error;

  bool get partsShown => widget.supportsParts && widget.parts.length > 1;

  List<CoreTrack> options(String kind) =>
      widget.tracks.where((track) => track.kind == kind).toList();

  void apply() {
    if (partsShown && kept.isEmpty) {
      setState(() => error = '请至少保留一个点播分段。');
      return;
    }
    if (!partsShown && chosen.values.every((index) => index == null)) {
      setState(() => error = '请至少选择一个轨道。');
      return;
    }
    String? filter(String kind) {
      final index = chosen[kind];
      return index == null ? null : options(kind)[index].filter;
    }

    Navigator.pop(
      context,
      TrackSelection(
        video: filter('video'),
        audio: filter('audio'),
        subtitle: filter('subtitle'),
        dropParts: partsShown ? dropPartsValue(widget.parts, kept) : null,
        partsShown: partsShown,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择下载轨道'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in trackKinds.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DropdownButtonFormField<int?>(
                    initialValue: chosen[entry.key],
                    decoration: InputDecoration(labelText: entry.value),
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('不选择（保持自动）'),
                      ),
                      for (
                        var index = 0;
                        index < options(entry.key).length;
                        index++
                      )
                        DropdownMenuItem<int?>(
                          value: index,
                          child: Text(
                            '${index + 1}. ${options(entry.key)[index].label}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => chosen[entry.key] = value),
                  ),
                ),
              ],
              if (partsShown) ...[
                const Divider(),
                Row(
                  children: [
                    const Text('保留点播分段'),
                    const Spacer(),
                    TextButton(
                      onPressed: () =>
                          setState(() => kept.addAll(widget.parts.keys)),
                      child: const Text('全选'),
                    ),
                    TextButton(
                      onPressed: () => setState(() => kept.clear()),
                      child: const Text('清空'),
                    ),
                  ],
                ),
                SizedBox(
                  height: 180,
                  child: ListView(
                    children: [
                      for (final entry in widget.parts.entries)
                        CheckboxListTile(
                          value: kept.contains(entry.key),
                          title: Text(
                            '第 ${entry.key} 段 · ${entry.value.toStringAsFixed(1)} 秒',
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (value) => setState(() {
                            if (value == true) {
                              kept.add(entry.key);
                            } else {
                              kept.remove(entry.key);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
              ],
              if (error case final message?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(onPressed: apply, child: const Text('应用轨道与分段选择')),
      ],
    );
  }
}

class ChannelSelectionDialog extends StatefulWidget {
  const ChannelSelectionDialog({super.key, required this.channels});
  final List<String> channels;

  @override
  State<ChannelSelectionDialog> createState() => _ChannelSelectionDialogState();
}

class _ChannelSelectionDialogState extends State<ChannelSelectionDialog> {
  late final Set<String> selected = widget.channels.toSet();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择 IPTV 频道'),
      content: SizedBox(
        width: 480,
        height: 400,
        child: Column(
          children: [
            Row(
              children: [
                Text('已选 ${selected.length} / ${widget.channels.length}'),
                const Spacer(),
                TextButton(
                  onPressed: () =>
                      setState(() => selected.addAll(widget.channels)),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: () => setState(() => selected.clear()),
                  child: const Text('清空'),
                ),
              ],
            ),
            Expanded(
              child: ListView.builder(
                itemCount: widget.channels.length,
                itemBuilder: (context, index) {
                  final channel = widget.channels[index];
                  return CheckboxListTile(
                    value: selected.contains(channel),
                    title: Text(channel, overflow: TextOverflow.ellipsis),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        selected.add(channel);
                      } else {
                        selected.remove(channel);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  widget.channels
                      .where((channel) => selected.contains(channel))
                      .toList(),
                ),
          child: const Text('使用选中的频道'),
        ),
      ],
    );
  }
}
