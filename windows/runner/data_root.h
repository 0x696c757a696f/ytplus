#ifndef RUNNER_DATA_ROOT_H_
#define RUNNER_DATA_ROOT_H_

#include <string>

// The folder Lumtub keeps its settings, data, cache, components and logs in,
// without a trailing backslash; empty when there is none.
//
// The portable package ships portable.txt next to the executable: then it is
// the userdata folder beside it, so everything stays where the ZIP was
// unpacked. Otherwise, or when that folder cannot be written (an unpacked
// copy under Program Files), it is %LOCALAPPDATA%\Lumtub. The first call
// also sets LUMTUB_HOME, which lib/app_directories.dart reads.
const std::wstring& DataRoot();

#endif  // RUNNER_DATA_ROOT_H_
