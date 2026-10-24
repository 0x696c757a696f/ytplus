import 'dart:async';
import 'dart:ffi';
import 'dart:io';

/// lumtub_core.dll, the Rust library built from native/lumtub_core and
/// shipped next to lumtub.exe. Everything that uses it has a fallback, so
/// a missing or older DLL only loses what it adds.
class NativeCore {
  NativeCore._(DynamicLibrary library)
      : _adopt = library.lookupFunction<IntPtr Function(Uint32), int Function(int)>('lumtub_tree_adopt'),
        _kill = library.lookupFunction<Bool Function(IntPtr, Uint32), bool Function(int, int)>('lumtub_tree_kill'),
        _close = library.lookupFunction<Void Function(IntPtr), void Function(int)>('lumtub_tree_close');

  final int Function(int pid) _adopt;
  final bool Function(int job, int code) _kill;
  final void Function(int job) _close;

  /// The library, or null when it is not there (tests, `flutter run`, or
  /// another platform). LUMTUB_CORE_DLL points at another copy.
  static final NativeCore? instance = _load();

  static NativeCore? _load() {
    if (!Platform.isWindows) return null;
    final paths = [
      if (Platform.environment['LUMTUB_CORE_DLL'] case final path? when path.isNotEmpty) path,
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}lumtub_core.dll',
    ];
    for (final path in paths) {
      if (!File(path).existsSync()) continue;
      try {
        return NativeCore._(DynamicLibrary.open(path));
      } catch (_) {
        // An older DLL without these exports: carry on without it.
      }
    }
    return null;
  }
}

/// [process] and everything it starts (yt-dlp's ffmpeg and Deno), kept in
/// a job object: [kill] ends all of them, and whatever is still running
/// when [process] exits, or when Lumtub itself exits or crashes, ends too.
/// Without lumtub_core.dll it is [process] alone, as before.
class ProcessTree implements Process {
  ProcessTree._(this._process, this._job) {
    _process.exitCode.then((_) => _release(), onError: (_) => _release());
  }

  /// Starts [executable] like [Process.start] and puts it in its own tree.
  static Future<Process> start(String executable, List<String> arguments, {Map<String, String>? environment, String? workingDirectory}) async {
    final process = await Process.start(executable, arguments, environment: environment, workingDirectory: workingDirectory);
    return adopt(process);
  }

  /// [process] in a tree of its own, or [process] itself without the DLL.
  static Process adopt(Process process) {
    final core = NativeCore.instance;
    if (core == null) return process;
    final job = core._adopt(process.pid);
    return job == 0 ? process : ProcessTree._(process, job);
  }

  final Process _process;
  int _job;

  void _release() {
    final job = _job;
    if (job == 0) return;
    _job = 0;
    NativeCore.instance?._close(job);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    final job = _job;
    if (job != 0 && NativeCore.instance!._kill(job, 1)) return true;
    return _process.kill(signal);
  }

  @override
  int get pid => _process.pid;
  @override
  Future<int> get exitCode => _process.exitCode;
  @override
  Stream<List<int>> get stdout => _process.stdout;
  @override
  Stream<List<int>> get stderr => _process.stderr;
  @override
  IOSink get stdin => _process.stdin;
}
