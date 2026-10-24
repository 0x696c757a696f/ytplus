import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

/// Loads a thumbnail from Lumtub's `thumbnails` cache folder, downloading it
/// there on first use. Scrolling back or reopening the app then needs no
/// network request.
@immutable
class CachedThumbnail extends ImageProvider<CachedThumbnail> {
  const CachedThumbnail(this.url, this.file, {this.fallback});

  final String url;
  final File file;
  /// Loaded instead when [url] fails, such as YouTube's own thumbnail
  /// when DeArrow's frame is not ready; not cached under [file].
  final String? fallback;

  static final http.Client _client = http.Client();
  static final Random _random = Random();

  /// The cache file for [videoId]; ids are validated YouTube ids, so they are
  /// safe as file names.
  /// Sizes other than the default `hqdefault` are cached under their own
  /// name, so switching sizes never shows a stale image.
  static File fileFor(Directory directory, String videoId, [String size = 'hqdefault']) =>
      File('${directory.path}${Platform.pathSeparator}$videoId${size == 'hqdefault' ? '' : '_$size'}.jpg');

  @override
  Future<CachedThumbnail> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CachedThumbnail key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1.0, debugLabel: url);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    Uint8List? bytes;
    try {
      if (await file.exists()) bytes = await file.readAsBytes();
    } on FileSystemException {
      bytes = null;
    }
    if (bytes == null || bytes.isEmpty) {
      var response = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      // The larger sizes exist only for some videos; hqdefault always does.
      if (response.statusCode == 404 && RegExp(r'/(maxresdefault|sddefault)\.jpg$').hasMatch(url)) {
        response = await _client.get(Uri.parse(url.replaceFirst(RegExp(r'(maxresdefault|sddefault)\.jpg$'), 'hqdefault.jpg'))).timeout(const Duration(seconds: 20));
      }
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        final fallback = this.fallback;
        if (fallback != null) {
          final other = await _client.get(Uri.parse(fallback)).timeout(const Duration(seconds: 20));
          if (other.statusCode == 200 && other.bodyBytes.isNotEmpty) return decode(await ui.ImmutableBuffer.fromUint8List(other.bodyBytes));
        }
        throw HttpException('Thumbnail HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      bytes = response.bodyBytes;
      await _store(bytes);
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  /// Writes through a unique temporary file so two cards loading the same
  /// video never leave a half-written image behind. Failures only skip caching.
  Future<void> _store(Uint8List bytes) async {
    final temp = File('${file.path}.${_random.nextInt(1 << 32)}.part');
    try {
      await file.parent.create(recursive: true);
      await temp.writeAsBytes(bytes);
      await temp.rename(file.path);
    } on FileSystemException {
      try {
        if (await temp.exists()) await temp.delete();
      } on FileSystemException {
        // Leave it for the next cache clean-up.
      }
    }
  }

  @override
  bool operator ==(Object other) => other is CachedThumbnail && other.url == url && other.file.path == file.path;

  @override
  int get hashCode => Object.hash(url, file.path);
}
