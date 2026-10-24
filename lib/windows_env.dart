import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

import 'app_log.dart';

typedef _SetEnvNative = Int32 Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _SetEnvDart = int Function(Pointer<Utf16>, Pointer<Utf16>);

/// Prepend tool paths to the CURRENT process environment.
/// This allows mpv's built-in ytdl_hook.lua to discover yt-dlp.exe.
void addToWindowsPath(Iterable<String> directories) {
  if (!Platform.isWindows) return;
  final prefixes = directories.where((p) => p.trim().isNotEmpty).join(';');
  if (prefixes.isEmpty) return;
  final kernel = DynamicLibrary.open('kernel32.dll');
  final setEnv = kernel.lookupFunction<_SetEnvNative, _SetEnvDart>('SetEnvironmentVariableW');
  final key = 'PATH'.toNativeUtf16();
  final value = '$prefixes;${Platform.environment['PATH'] ?? ''}'.toNativeUtf16();
  try {
    if (setEnv(key, value) == 0) throw const FileSystemException('Could not update PATH for player');
  } finally {
    calloc.free(key);
    calloc.free(value);
  }
}

/// Starts Lumtub again and ends this process, such as after the language
/// changed.
Future<void> restartApp() async {
  await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
  await AppLog.current?.flush();
  exit(0);
}
