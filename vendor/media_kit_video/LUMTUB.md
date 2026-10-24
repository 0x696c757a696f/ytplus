# media_kit_video 2.0.1, patched for Lumtub

Copied from pub.dev (MIT, see LICENSE) with only the Windows plugin kept.
The changes, marked "Lumtub" in the code:

- `windows/angle_surface_manager.cc` (`Read`): wait for the copy into the
  shared texture to finish before Flutter samples it, which otherwise shows
  black frames on some GPUs.
- `windows/video_output.cc` (`Resize`): resizing the texture freed it while
  Flutter's raster thread could still read it, and the texture callback
  used `at()` on a map entry that was not stored yet; both crashed the app
  when a video opened or the player changed size.
- `lib/src/subtitle/subtitle_view.dart`: the secondary subtitle (the second
  entry of `Player.state.subtitle`) is drawn above the main one, not below.
