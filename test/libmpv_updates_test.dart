import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/libmpv_updates.dart';

void main() {
  const base = LibmpvBuild('20261018', LibmpvBuild.baseVariant);
  const v3 = LibmpvBuild('20261018', LibmpvBuild.v3Variant);

  test('picks the archive for the CPU', () {
    const names = [
      'mpv-x86_64-v3-20261018-git-abc1234.7z',
      'mpv-dev-aarch64-20261018-git-abc1234.7z',
      'mpv-dev-x86_64-v3-20261018-git-abc1234.7z',
      'mpv-dev-x86_64-20261018-git-abc1234.7z',
      'mpv-dev-i686-20261018-git-abc1234.7z',
    ];
    expect(libmpvAssetName(names, LibmpvBuild.v3Variant), 'mpv-dev-x86_64-v3-20261018-git-abc1234.7z');
    expect(libmpvAssetName(names, LibmpvBuild.baseVariant), 'mpv-dev-x86_64-20261018-git-abc1234.7z');
    expect(libmpvAssetName(names, LibmpvBuild.arm64Variant), 'mpv-dev-aarch64-20261018-git-abc1234.7z');
    expect(libmpvAssetName(const ['mpv-dev-x86_64-v3-20261018-git-abc1234.7z'], LibmpvBuild.baseVariant), isNull);
  });

  test('an ARM64 build only replaces or is replaced by an ARM64 build', () {
    const arm = LibmpvBuild('20261018', LibmpvBuild.arm64Variant);
    expect(arm.isReplacedBy(const LibmpvBuild('20261019', LibmpvBuild.arm64Variant)), isTrue);
    expect(arm.isReplacedBy(const LibmpvBuild('20261019', LibmpvBuild.v3Variant)), isFalse);
    expect(base.isReplacedBy(const LibmpvBuild('20261019', LibmpvBuild.arm64Variant)), isFalse);
    expect(LibmpvBuild.fromFolderName('20261018-aarch64'), arm);
    expect(LibmpvBuild.fromVersionFile('20261018\naarch64\n'), arm);
    expect(arm.label, '20261018（ARM64）');
  });

  test('a newer release or the AVX2 build of the same release replaces a build', () {
    expect(base.isReplacedBy(v3), isTrue);
    expect(v3.isReplacedBy(base), isFalse);
    expect(v3.isReplacedBy(const LibmpvBuild('20261019', LibmpvBuild.baseVariant)), isTrue);
    expect(base.isReplacedBy(const LibmpvBuild('20261017', LibmpvBuild.v3Variant)), isFalse);
    expect(base.isReplacedBy(base), isFalse);
  });

  test('reads the bundled version file and folder names', () {
    expect(LibmpvBuild.fromVersionFile('20261018\r\nx86_64\r\n'), base);
    expect(LibmpvBuild.fromVersionFile('20261018'), isNull);
    expect(LibmpvBuild.fromVersionFile('20261018\narm64\n'), isNull);
    expect(LibmpvBuild.fromFolderName('20261018-x86_64-v3'), v3);
    expect(LibmpvBuild.fromFolderName('20261018-x86_64'), base);
    expect(LibmpvBuild.fromFolderName('downloads'), isNull);
  });

  group('state shared with the Windows runner', () {
    late Directory dir;
    late String dll;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('lumtub_mpv');
      dll = '${dir.path}/20261019-x86_64-v3/libmpv-2.dll';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    String read(String name) => File('${dir.path}/$name').readAsStringSync();
    bool exists(String name) => File('${dir.path}/$name').existsSync();

    test('a selected download is used from the next launch', () async {
      final state = LibmpvState(dir, loadedPath: null, bundled: base);
      await state.select(dll);
      expect(read('use.txt'), dll);
      expect(state.selected, const LibmpvBuild('20261019', LibmpvBuild.v3Variant));
      expect(state.current, base);
      expect(state.usesDownload, isFalse);
    });

    test('playback marks, then confirms, the loaded download', () async {
      final state = LibmpvState(dir, loadedPath: dll, bundled: base);
      await state.markPlaying();
      expect(read('pending.txt'), '$dll\nplaying\n');
      await state.confirm();
      expect(read('confirmed.txt'), dll);
      expect(exists('pending.txt'), isFalse);
      await state.markPlaying();
      expect(exists('pending.txt'), isFalse);
    });

    test('nothing is written when the bundled DLL is in use', () async {
      final state = LibmpvState(dir, loadedPath: null, bundled: base);
      await state.markPlaying();
      await state.confirm();
      expect(dir.listSync(), isEmpty);
    });

    test('rolling back blocks the download for good', () async {
      final state = LibmpvState(dir, loadedPath: dll, bundled: base);
      await state.select(dll);
      await state.rollBack();
      expect(exists('use.txt'), isFalse);
      expect(state.hasFailed(dll), isTrue);
      expect(state.selected, isNull);
    });

    test('an app update with a newer bundled DLL drops an older download', () async {
      await LibmpvState(dir, loadedPath: null, bundled: base).select('${dir.path}/20261017-x86_64-v3/libmpv-2.dll');
      await LibmpvState(dir, loadedPath: null, bundled: const LibmpvBuild('20261020', LibmpvBuild.baseVariant)).dropIfOutdated();
      expect(exists('use.txt'), isFalse);
      expect(exists('failed.txt'), isFalse);
    });

    test('a newer download survives an older bundled DLL', () async {
      final state = LibmpvState(dir, loadedPath: null, bundled: base);
      await state.select(dll);
      await state.dropIfOutdated();
      expect(exists('use.txt'), isTrue);
    });
  });
}
