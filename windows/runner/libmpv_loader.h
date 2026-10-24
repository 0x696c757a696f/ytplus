#ifndef RUNNER_LIBMPV_LOADER_H_
#define RUNNER_LIBMPV_LOADER_H_

// Loads an updated libmpv-2.dll, if one was downloaded and has not failed,
// before any plugin loads. Must run before the Flutter engine registers
// plugins. Sets LUMTUB_LIBMPV to the loaded path so Dart opens the same copy.
void LoadPreferredLibmpv();

#endif  // RUNNER_LIBMPV_LOADER_H_
