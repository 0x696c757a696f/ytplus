import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../downloads/download_models.dart';
import '../ffmpeg_component.dart';
import '../l10n/l10n.dart';
import 'common.dart';

/// Before a download in [quality]: when merging needs ffmpeg and it is not
/// installed, asks to install it. Returns false when the user dismissed the
/// question and the download should not start. If the install fails the
/// download goes on as single-file.
Future<bool> ensureFfmpegForDownload(BuildContext context, AppController controller, DownloadQuality quality) async {
  if (controller.ffmpegChoice(quality) != FfmpegChoice.ask) return true;
  final answer = await showDialog<_Answer>(
    context: context,
    builder: (context) => _FfmpegQuestion(size: controller.ffmpegDownloadSize()),
  );
  if (answer == null || !context.mounted) return false;
  if (answer.install) {
    final progress = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _FfmpegProgress(controller),
    );
    await controller.installFfmpeg();
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await progress;
  } else if (answer.remember) {
    await controller.declineFfmpegPrompt();
  }
  return true;
}

class _Answer {
  const _Answer.install() : install = true, remember = false;
  const _Answer.single({required this.remember}) : install = false;
  final bool install;
  final bool remember;
}

class _FfmpegQuestion extends StatefulWidget {
  const _FfmpegQuestion({required this.size});
  final Future<int?> size;

  @override
  State<_FfmpegQuestion> createState() => _FfmpegQuestionState();
}

class _FfmpegQuestionState extends State<_FfmpegQuestion> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('需要安装 ffmpeg')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        FutureBuilder<int?>(
          future: widget.size,
          builder: (context, snapshot) {
            final size = snapshot.data;
            return Text(size == null
                ? tr('合并高画质视频和音频需要 ffmpeg，现在下载并安装（Lumtub 自建的 LGPL 精简版，经 SHA-256 校验）。')
                : tr('合并高画质视频和音频需要 ffmpeg，现在下载并安装（下载约 {0}，Lumtub 自建的 LGPL 精简版，经 SHA-256 校验）。', [formatBytes(size)]));
          },
        ),
        const SizedBox(height: 8),
        Text(tr('也可以只下载单文件格式（通常为 360p），不需要 ffmpeg。')),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _remember,
          onChanged: (v) => setState(() => _remember = v ?? false),
          title: Text(tr('选择单文件格式时不再询问')),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消'))),
        TextButton(onPressed: () => Navigator.pop(context, _Answer.single(remember: _remember)), child: Text(tr('只下单文件格式'))),
        FilledButton(onPressed: () => Navigator.pop(context, const _Answer.install()), child: Text(tr('下载并继续'))),
      ],
    );
  }
}

class _FfmpegProgress extends StatelessWidget {
  const _FfmpegProgress(this.controller);
  final AppController controller;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(tr('正在安装 ffmpeg…')),
          content: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => LinearProgressIndicator(value: controller.ffmpegProgress),
          ),
        ),
      );
}
