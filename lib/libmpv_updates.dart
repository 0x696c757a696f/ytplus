import 'dart:ffi';
import 'dart:io';

/// A libmpv build from zhongfly/mpv-winbuild: its release tag
/// (a date such as 20261018) and CPU variant.
class LibmpvBuild {
  const LibmpvBuild(this.tag, this.variant);
  final String tag;
  /// `x86_64-v3` (AVX2), `x86_64` (any x86-64 CPU) or `aarch64` (Windows
  /// on ARM).
  final String variant;

  bool get isV3 => variant == v3Variant;
  bool get isArm64 => variant == arm64Variant;
  String get folderName => '$tag-$variant';
  String get label => '$tag（${isArm64 ? 'ARM64' : isV3 ? 'x86-64-v3' : 'x86-64'}）';

  static const v3Variant = 'x86_64-v3';
  static const baseVariant = 'x86_64';
  static const arm64Variant = 'aarch64';
  static const variants = {v3Variant, baseVariant, arm64Variant};

  /// Parses a folder name written by [folderName].
  static LibmpvBuild? fromFolderName(String name) {
    final match = RegExp(r'^([0-9A-Za-z._]{1,40})-(x86_64(?:-v3)?|aarch64)$').firstMatch(name);
    return match == null ? null : LibmpvBuild(match.group(1)!, match.group(2)!);
  }

  /// Reads `libmpv-version.txt`, which the release build writes next to the
  /// bundled DLL: the tag on the first line and the variant on the second.
  static LibmpvBuild? fromVersionFile(String content) {
    final lines = content.split(RegExp(r'\r?\n')).map((line) => line.trim()).toList();
    if (lines.length < 2 || lines[0].isEmpty || !variants.contains(lines[1])) return null;
    return LibmpvBuild(lines[0], lines[1]);
  }

  /// Whether [other] should replace this build: a newer release for the same
  /// CPU architecture, or the same release built for AVX2 CPUs.
  bool isReplacedBy(LibmpvBuild other) {
    if (other.isArm64 != isArm64) return false;
    final order = other.tag.compareTo(tag);
    return order > 0 || (order == 0 && other.isV3 && !isV3);
  }

  @override
  bool operator ==(Object other) => other is LibmpvBuild && other.tag == tag && other.variant == variant;

  @override
  int get hashCode => Object.hash(tag, variant);
}

/// The development archive for [variant] among [names].
String? libmpvAssetName(Iterable<String> names, String variant) {
  final pattern = switch (variant) {
    LibmpvBuild.v3Variant => RegExp(r'^mpv-dev-x86_64-v3-.+\.7z$'),
    LibmpvBuild.arm64Variant => RegExp(r'^mpv-dev-aarch64-.+\.7z$'),
    _ => RegExp(r'^mpv-dev-x86_64-(?!v3-).+\.7z$'),
  };
  for (final name in names) {
    if (pattern.hasMatch(name)) return name;
  }
  return null;
}

/// The libmpv variant this process can load: aarch64 in the ARM64 build,
/// otherwise x86-64-v3 when the CPU supports it.
String libmpvVariantForThisProcess() {
  if (Abi.current() == Abi.windowsArm64) return LibmpvBuild.arm64Variant;
  return cpuSupportsX86_64V3() ? LibmpvBuild.v3Variant : LibmpvBuild.baseVariant;
}

typedef _FeatureNative = Int32 Function(Uint32);
typedef _FeatureDart = int Function(int);

/// Whether this CPU runs x86-64-v3 code. AVX2 stands in for the whole level:
/// every x86-64 CPU with AVX2 also has the BMI, FMA and MOVBE it requires.
bool cpuSupportsX86_64V3() {
  if (!Platform.isWindows) return false;
  try {
    const avx2 = 40; // PF_AVX2_INSTRUCTIONS_AVAILABLE
    final present = DynamicLibrary.open('kernel32.dll').lookupFunction<_FeatureNative, _FeatureDart>('IsProcessorFeaturePresent');
    return present(avx2) != 0;
  } catch (_) {
    return false;
  }
}

/// The files shared with the Windows runner (windows/runner/libmpv_loader.cpp)
/// that choose, confirm and roll back a downloaded libmpv-2.dll.
class LibmpvState {
  LibmpvState(this.directory, {String? loadedPath, this.bundled}) : loadedPath = loadedPath ?? Platform.environment['LUMTUB_LIBMPV'];

  /// `components/mpv`.
  final Directory directory;
  /// The downloaded DLL the runner loaded for this launch, if any.
  final String? loadedPath;
  /// The DLL shipped with the app, or null when its version is unknown.
  final LibmpvBuild? bundled;

  static LibmpvBuild? _buildOf(String dll) {
    final parts = dll.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();
    return parts.length < 2 ? null : LibmpvBuild.fromFolderName(parts[parts.length - 2]);
  }

  File _file(String name) => File('${directory.path}${Platform.pathSeparator}$name');

  /// The build that is running.
  LibmpvBuild? get current => loadedPath == null ? bundled : _buildOf(loadedPath!);

  bool get usesDownload => loadedPath != null;

  Set<String> failedPaths() {
    final file = _file('failed.txt');
    if (!file.existsSync()) return const {};
    return file.readAsLinesSync().map((line) => line.trim().toLowerCase()).where((line) => line.isNotEmpty).toSet();
  }

  bool hasFailed(String path) => failedPaths().contains(path.toLowerCase());

  bool get _confirmed {
    final path = loadedPath;
    final file = _file('confirmed.txt');
    return path != null && file.existsSync() && file.readAsStringSync().trim().toLowerCase() == path.toLowerCase();
  }

  /// Called before a video starts: a crash from here until [confirm] rolls
  /// the download back on the next launch.
  Future<void> markPlaying() async {
    final path = loadedPath;
    if (path == null || _confirmed) return;
    await _file('pending.txt').writeAsString('$path\nplaying\n');
  }

  /// Called once a video has played with the loaded DLL.
  Future<void> confirm() async {
    final path = loadedPath;
    if (path == null || _confirmed) return;
    await _file('confirmed.txt').writeAsString(path);
    final pending = _file('pending.txt');
    if (await pending.exists()) await pending.delete();
  }

  /// Uses [dll] from the next launch on.
  Future<void> select(String dll) async {
    await directory.create(recursive: true);
    await _file('use.txt').writeAsString(dll);
  }

  /// Goes back to the bundled DLL from the next launch on, and never loads
  /// the current download again.
  Future<void> rollBack() async {
    final path = loadedPath ?? _selectedPath();
    if (path != null) await _file('failed.txt').writeAsString('$path\n', mode: FileMode.append);
    for (final name in ['use.txt', 'pending.txt']) {
      final file = _file(name);
      if (await file.exists()) await file.delete();
    }
  }

  String? _selectedPath() {
    final file = _file('use.txt');
    if (!file.existsSync()) return null;
    final path = file.readAsStringSync().trim();
    return path.isEmpty ? null : path;
  }

  /// The build the next launch will load, if it differs from the bundled one.
  LibmpvBuild? get selected {
    final path = _selectedPath();
    if (path == null || hasFailed(path)) return null;
    return _buildOf(path);
  }

  /// Stops using a download that an app update has overtaken, without
  /// marking it failed.
  Future<void> dropIfOutdated() async {
    final chosen = selected;
    final shipped = bundled;
    // A download for the other CPU architecture never replaces the bundled
    // one, so it is dropped too: it cannot load at all.
    if (chosen == null || shipped == null || shipped.isReplacedBy(chosen)) return;
    final file = _file('use.txt');
    if (await file.exists()) await file.delete();
  }
}
