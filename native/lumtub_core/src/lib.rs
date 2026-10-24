//! Native helpers Lumtub calls through `dart:ffi` (see lib/native/core.dart).
//!
//! Every export is a plain C function; a missing DLL or symbol makes the Dart
//! side fall back to what it did before, so nothing here is required to run.

pub mod process_tree;

/// The version of this library's exports, bumped when one changes.
#[unsafe(no_mangle)]
pub extern "C" fn lumtub_core_version() -> u32 {
    1
}
