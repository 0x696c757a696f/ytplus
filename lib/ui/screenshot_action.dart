import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app_log.dart';
import '../l10n/l10n.dart';
import '../screenshot.dart';

/// Saves the current frame of the playing video into Pictures\Lumtub, puts
/// it on the clipboard and tells where it went, with a button that shows
/// the file in Explorer. [onFeedback] is the indicator over the video, the
/// only message visible in fullscreen.
Future<void> captureScreenshot(BuildContext context, AppController controller, {void Function(IconData icon, String text)? onFeedback}) async {
  final player = controller.player;
  if (player == null || controller.playing == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final title = controller.details?.title.isNotEmpty == true ? controller.details!.title : controller.playing!.title;
    final file = await takeScreenshot(player, title: title);
    if (file == null) throw StateError('no file written');
    unawaited(copyImageToClipboard(file));
    onFeedback?.call(Icons.photo_camera_rounded, tr('截图已保存并复制'));
    messenger?.showSnackBar(SnackBar(
      content: Text(tr('截图已保存：{0}', [file.path])),
      action: SnackBarAction(label: tr('打开文件夹'), onPressed: () => unawaited(revealInFolder(file))),
    ));
  } catch (e) {
    logError('截图失败', e);
    onFeedback?.call(Icons.error_outline_rounded, tr('截图失败'));
    messenger?.showSnackBar(SnackBar(content: Text(tr('截图失败'))));
  }
}
