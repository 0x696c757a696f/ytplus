// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output.h"

#include <algorithm>

// Limit the frame size to 1080p in software rendering.
// This is for performance reasons & to avoid allocating too much memory.
#define SW_RENDERING_MAX_WIDTH 1920
#define SW_RENDERING_MAX_HEIGHT 1080
#define SW_RENDERING_PIXEL_BUFFER_SIZE \
  (SW_RENDERING_MAX_WIDTH) * (SW_RENDERING_MAX_HEIGHT) * (4)

VideoOutput::VideoOutput(int64_t handle,
                         VideoOutputConfiguration configuration,
                         flutter::PluginRegistrarWindows* registrar,
                         ThreadPool* thread_pool_ref)
    : handle_(reinterpret_cast<mpv_handle*>(handle)),
      width_(configuration.width),
      height_(configuration.height),
      configuration_(configuration),
      registrar_(registrar),
      thread_pool_ref_(thread_pool_ref) {
  // The constructor must be invoked through the thread pool, because
  // |ANGLESurfaceManager| & libmpv render context creation can conflict with
  // the existing |Render| or |Resize| calls from another |VideoOutput|
  // instances (which will result in access violation).
  auto future = thread_pool_ref_->Post([&]() {
    mpv_set_option_string(handle_, "video-sync", "audio");
    mpv_set_option_string(handle_, "video-timing-offset", "0");
    // First try to initialize video playback with hardware acceleration &
    // |ANGLESurfaceManager|, use S/W API as fallback.
    auto is_hardware_acceleration_enabled = false;
    // Attempt to use H/W rendering.
    if (configuration.enable_hardware_acceleration) {
      try {
        // OpenGL context needs to be set before |mpv_render_context_create|.
        surface_manager_ = std::make_unique<ANGLESurfaceManager>(
            static_cast<int32_t>(width_.value_or(1)),
            static_cast<int32_t>(height_.value_or(1)));
        surface_manager_->MakeCurrent(true);
        mpv_opengl_init_params gl_init_params{
            [](auto, auto name) {
              return reinterpret_cast<void*>(eglGetProcAddress(name));
            },
            nullptr,
        };
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init_params},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        // Create render context.
        if (mpv_render_context_create(&render_context_, handle_, params) == 0) {
          Resize(width_.value_or(1), height_.value_or(1));
          mpv_render_context_set_update_callback(
              render_context_,
              [](void* context) {
                // Notify Flutter that a new frame is available. The actual
                // rendering will take place in the |Render| method, which will
                // be called by Flutter on the render thread.
                auto that = reinterpret_cast<VideoOutput*>(context);
                that->NotifyRender();
              },
              reinterpret_cast<void*>(this));
          // Set flag to true, indicating that H/W rendering is supported.
          is_hardware_acceleration_enabled = true;
          std::cout << "media_kit: VideoOutput: Using H/W rendering."
                    << std::endl;
        }
      } catch (...) {
        // Do nothing.
        // Likely received an |std::runtime_error| from |ANGLESurfaceManager|,
        // which indicates that H/W rendering is not supported.
      }
    }
    if (!is_hardware_acceleration_enabled) {
      surface_manager_.reset();
      std::cout << "media_kit: VideoOutput: Using S/W rendering." << std::endl;
      // Allocate a "large enough" buffer ahead of time.
      pixel_buffer_ =
          std::make_unique<uint8_t[]>(SW_RENDERING_PIXEL_BUFFER_SIZE);
      Resize(width_.value_or(1), height_.value_or(1));
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      if (mpv_render_context_create(&render_context_, handle_, params) == 0) {
        mpv_render_context_set_update_callback(
            render_context_,
            [](void* context) {
              // Notify Flutter that a new frame is available. The actual
              // rendering will take place in the |Render| method, which will be
              // called by Flutter on the render thread.
              auto that = reinterpret_cast<VideoOutput*>(context);
              that->NotifyRender();
            },
            reinterpret_cast<void*>(this));
      }
    }
  });
  future.get();
}

VideoOutput::~VideoOutput() {
  destroyed_ = true;
  // Stop libmpv callbacks and drain rendering before releasing any surfaces.
  thread_pool_ref_->Post([this]() {
    if (render_context_) {
      if (surface_manager_) {
        surface_manager_->MakeCurrent(true);
      }
      mpv_render_context_set_update_callback(render_context_, nullptr, nullptr);
      mpv_render_context_free(render_context_);
      render_context_ = nullptr;
      if (surface_manager_) {
        surface_manager_->MakeCurrent(false);
      }
    }
  }).get();

  int64_t texture_id;
  {
    std::lock_guard<std::mutex> lock(textures_mutex_);
    texture_id = texture_id_;
    texture_id_ = 0;
  }
  if (texture_id) {
    UnregisterTexture(texture_id);
  }
  {
    std::unique_lock<std::mutex> lock(textures_mutex_);
    textures_unregistered_.wait(
        lock, [this]() { return pending_texture_unregistrations_ == 0; });
    assert(texture_variants_.empty());
  }

  thread_pool_ref_->Post([this]() { surface_manager_.reset(); }).get();
}

void VideoOutput::NotifyRender() {
  if (destroyed_ || render_pending_.exchange(true)) {
    return;
  }
  // Keep at most one pending render while the current frame is being drawn.
  thread_pool_ref_->Post([this]() {
    render_pending_ = false;
    if (!destroyed_) {
      CheckAndResize();
      Render();
    }
  });
}

void VideoOutput::Render() {
  if (texture_id_) {
    // H/W
    if (surface_manager_ != nullptr) {
      surface_manager_->Draw([&]() {
        mpv_opengl_fbo fbo{
            0,
            surface_manager_->width(),
            surface_manager_->height(),
            0,
        };
        mpv_render_param params[]{
            {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        mpv_render_context_render(render_context_, params);
      });
    }
    // S/W
    if (pixel_buffer_ != nullptr) {
      int32_t size[]{
          static_cast<int32_t>(pixel_buffer_textures_.at(texture_id_)->width),
          static_cast<int32_t>(pixel_buffer_textures_.at(texture_id_)->height),
      };
      auto pitch = 4 * size[0];
      mpv_render_param params[]{
          {MPV_RENDER_PARAM_SW_SIZE, size},
          {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
          {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
          {MPV_RENDER_PARAM_SW_POINTER, pixel_buffer_.get()},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      mpv_render_context_render(render_context_, params);
    }
    try {
      // Notify Flutter that a new frame is available.
      registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
    } catch (...) {
      // Prevent any redundant exceptions if the texture is unregistered etc.
    }
  }
}

void VideoOutput::SetTextureUpdateCallback(
    std::function<void(int64_t, int64_t, int64_t)> callback) {
  thread_pool_ref_->Post([this, callback]() {
    texture_update_callback_ = callback;
    texture_update_callback_(texture_id_, GetVideoWidth(), GetVideoHeight());
  }).get();
}

void VideoOutput::SetSize(std::optional<int64_t> width,
                          std::optional<int64_t> height) {
  thread_pool_ref_->Post([&, width, height]() {
    if (width.has_value()) {
      // H/W
      if (surface_manager_ != nullptr) {
        width_ = width.value();
      }
      // S/W
      if (pixel_buffer_ != nullptr) {
        // Limit width if software rendering is being used.
        width_ = std::clamp(width.value(), static_cast<int64_t>(0),
                            static_cast<int64_t>(SW_RENDERING_MAX_WIDTH));
      }
    } else {
      width_ = std::nullopt;
    }
    if (height.has_value()) {
      // H/W
      if (surface_manager_ != nullptr) {
        height_ = height.value();
      }
      // S/W
      if (pixel_buffer_ != nullptr) {
        // Limit width if software rendering is being used.
        height_ = std::clamp(height.value(), static_cast<int64_t>(0),
                             static_cast<int64_t>(SW_RENDERING_MAX_HEIGHT));
      }
    } else {
      height_ = std::nullopt;
    }
  });
}

void VideoOutput::CheckAndResize() {
  // Check if a new texture with different dimensions is needed.
  auto required_width = GetVideoWidth(), required_height = GetVideoHeight();
  if (required_width < 1 || required_height < 1) {
    // Invalid.
    return;
  }
  int64_t current_width = -1, current_height = -1;
  if (surface_manager_ != nullptr) {
    current_width = surface_manager_->width();
    current_height = surface_manager_->height();
  }
  if (pixel_buffer_ != nullptr) {
    current_width = pixel_buffer_textures_.at(texture_id_)->width;
    current_height = pixel_buffer_textures_.at(texture_id_)->height;
  }
  // Currently rendered video output dimensions.
  // Either H/W or S/W rendered.
  assert(current_width > 0);
  assert(current_height > 0);
  if (required_width == current_width && required_height == current_height) {
    // No creation of new texture required.
    return;
  }
  Resize(required_width, required_height);
}

void VideoOutput::Resize(int64_t required_width, int64_t required_height) {
  std::cout << required_width << " " << required_height << std::endl;
  // Unregister previously registered texture & delete underlying objects.
  if (texture_id_) {
    UnregisterTexture(texture_id_);
    // Lumtub: under the lock, so Flutter's texture callback sees 0 and
    // returns no frame instead of reading the textures freed below.
    std::lock_guard<std::mutex> lock(textures_mutex_);
    texture_id_ = 0;
  }
  // H/W
  if (surface_manager_ != nullptr) {
    // Destroy internal ID3D11Texture2D & EGLSurface & create new with updated
    // dimensions while preserving previous EGLDisplay & EGLContext.
    {
      // Lumtub: Flutter's raster thread copies from these textures in
      // |Read|; freeing them meanwhile crashed the app.
      std::lock_guard<std::mutex> lock(textures_mutex_);
      surface_manager_->SetSize(static_cast<int32_t>(required_width),
                                static_cast<int32_t>(required_height));
    }
    auto texture = std::make_unique<FlutterDesktopGpuSurfaceDescriptor>();
    texture->struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    texture->handle = surface_manager_->handle();
    texture->width = texture->visible_width = surface_manager_->width();
    texture->height = texture->visible_height = surface_manager_->height();
    texture->release_context = nullptr;
    texture->release_callback = [](void*) {};
    texture->format = kFlutterDesktopPixelFormatBGRA8888;
    auto texture_variant =
        std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle, [&](auto, auto) {
              std::lock_guard<std::mutex> lock(textures_mutex_);
              // Lumtub: find, not at(). Between registering a texture and
              // storing its descriptor, at() threw and ended the app.
              auto it = textures_.find(texture_id_);
              if (texture_id_ && it != textures_.end()) {
                surface_manager_->Read();
                return it->second.get();
              } else {
                return (FlutterDesktopGpuSurfaceDescriptor*)nullptr;
              }
            }));
    // Register new texture.
    auto id =
        registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
    std::cout << "media_kit: VideoOutput: Create Texture: " << id
              << std::endl;
    std::lock_guard<std::mutex> lock(textures_mutex_);
    texture_id_ = id;
    textures_.emplace(std::make_pair(texture_id_, std::move(texture)));
    texture_variants_.emplace(
        std::make_pair(texture_id_, std::move(texture_variant)));
    // Notify public texture update callback.
    texture_update_callback_(texture_id_, required_width, required_height);
  }
  // S/W
  if (pixel_buffer_ != nullptr) {
    auto pixel_buffer_texture = std::make_unique<FlutterDesktopPixelBuffer>();
    pixel_buffer_texture->buffer = pixel_buffer_.get();
    pixel_buffer_texture->width = required_width;
    pixel_buffer_texture->height = required_height;
    pixel_buffer_texture->release_context = nullptr;
    pixel_buffer_texture->release_callback = [](void*) {};
    auto texture_variant = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture([&](auto, auto) {
          std::lock_guard<std::mutex> lock(textures_mutex_);
          if (texture_id_) {
            return pixel_buffer_textures_.at(texture_id_).get();
          } else {
            return (FlutterDesktopPixelBuffer*)nullptr;
          }
        }));
    // Register new texture.
    texture_id_ =
        registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
              << std::endl;
    std::lock_guard<std::mutex> lock(textures_mutex_);
    pixel_buffer_textures_.emplace(
        std::make_pair(texture_id_, std::move(pixel_buffer_texture)));
    texture_variants_.emplace(
        std::make_pair(texture_id_, std::move(texture_variant)));
    // Notify public texture update callback.
    texture_update_callback_(texture_id_, required_width, required_height);
  }
}

void VideoOutput::UnregisterTexture(int64_t texture_id) {
  {
    std::lock_guard<std::mutex> lock(textures_mutex_);
    ++pending_texture_unregistrations_;
  }
  registrar_->texture_registrar()->UnregisterTexture(
      texture_id, [this, texture_id]() {
        std::lock_guard<std::mutex> lock(textures_mutex_);
        texture_variants_.erase(texture_id);
        textures_.erase(texture_id);
        pixel_buffer_textures_.erase(texture_id);
        --pending_texture_unregistrations_;
        textures_unregistered_.notify_all();
      });
}

int64_t VideoOutput::GetVideoWidth() {
  // Fixed width.
  if (width_) {
    return width_.value();
  }
  // Video resolution dependent width.
  int64_t width = 0;
  int64_t height = 0;

  mpv_node params;
  mpv_get_property(handle_, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (pixel_buffer_ != nullptr) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect-ratio.
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return SW_RENDERING_MAX_WIDTH;
    }
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return width / height * SW_RENDERING_MAX_HEIGHT;
    }
  }

  return width;
}

int64_t VideoOutput::GetVideoHeight() {
  // Fixed height.
  if (height_) {
    return height_.value();
  }
  // Video resolution dependent height.
  int64_t width = 0;
  int64_t height = 0;

  mpv_node params;
  mpv_get_property(handle_, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (pixel_buffer_ != NULL) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect-ratio.
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return SW_RENDERING_MAX_HEIGHT;
    }
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return height / width * SW_RENDERING_MAX_WIDTH;
    }
  }

  return height;
}
