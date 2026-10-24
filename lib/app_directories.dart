import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The small set of directories owned by Lumtub.
///
/// They live under LocalAppData, so the installed package initialises without
/// elevation, or for the portable package in the userdata folder next to the
/// executable: the Windows runner (windows/runner/data_root.cpp) picks one
/// and passes it on as LUMTUB_HOME. Only files created by Lumtub are kept here.
class AppDirectories {
  final Directory root;
  final Directory config;
  final Directory data;
  final Directory cache;
  final Directory components;
  final Directory logs;

  const AppDirectories({
    required this.root,
    required this.config,
    required this.data,
    required this.cache,
    required this.components,
    required this.logs,
  });

  factory AppDirectories.at(Directory root) => AppDirectories(
        root: root,
        config: Directory('${root.path}${Platform.pathSeparator}config'),
        data: Directory('${root.path}${Platform.pathSeparator}data'),
        cache: Directory('${root.path}${Platform.pathSeparator}cache'),
        components: Directory('${root.path}${Platform.pathSeparator}components'),
        logs: Directory('${root.path}${Platform.pathSeparator}logs'),
      );

  static Future<AppDirectories> create({Map<String, String>? environment}) async {
    final env = environment ?? Platform.environment;
    final home = env['LUMTUB_HOME'];
    final localAppData = env['LOCALAPPDATA'];
    final root = home != null && home.trim().isNotEmpty
        ? Directory(home)
        : localAppData == null || localAppData.trim().isEmpty
        ? Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}Lumtub')
        : Directory('$localAppData${Platform.pathSeparator}Lumtub');
    final directories = AppDirectories.at(root);
    await directories.ensureExists();
    return directories;
  }

  Future<void> ensureExists() async {
    for (final directory in [root, config, data, cache, components, logs]) {
      await directory.create(recursive: true);
    }
  }
}
