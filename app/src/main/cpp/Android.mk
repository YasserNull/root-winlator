LOCAL_PATH := $(call my-dir)

JNI_LIBS_DIR := $(LOCAL_PATH)/../jniLibs/arm64-v8a

# ---------------------------------------------------------------------------
# linkernsbypass (static)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := linkernsbypass
LOCAL_SRC_FILES := libadrenotools/lib/linkernsbypass/android_linker_ns.cpp \
                   libadrenotools/lib/linkernsbypass/elf_soname_patcher.cpp
LOCAL_C_INCLUDES := $(LOCAL_PATH)/libadrenotools/lib/linkernsbypass
LOCAL_EXPORT_C_INCLUDES := $(LOCAL_PATH)/libadrenotools/lib/linkernsbypass
LOCAL_CPPFLAGS := -Wall -Wextra
include $(BUILD_STATIC_LIBRARY)

# ---------------------------------------------------------------------------
# adrenotools (static)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := adrenotools
LOCAL_SRC_FILES := libadrenotools/src/bcenabler.cpp \
                   libadrenotools/src/driver.cpp
LOCAL_C_INCLUDES := $(LOCAL_PATH)/libadrenotools \
                    $(LOCAL_PATH)/libadrenotools/include
LOCAL_EXPORT_C_INCLUDES := $(LOCAL_PATH)/libadrenotools/include
LOCAL_CPPFLAGS := -Wall -Wextra
LOCAL_STATIC_LIBRARIES := linkernsbypass
include $(BUILD_STATIC_LIBRARY)

# ---------------------------------------------------------------------------
# hook_impl (shared)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := hook_impl
LOCAL_SRC_FILES := libadrenotools/src/hook/hook_impl.cpp
LOCAL_C_INCLUDES := $(LOCAL_PATH)/libadrenotools \
                    $(LOCAL_PATH)/libadrenotools/include
LOCAL_CPPFLAGS := -Wall -Wextra -fvisibility=hidden
LOCAL_STATIC_LIBRARIES := linkernsbypass
LOCAL_LDLIBS := -landroid -ldl -llog
include $(BUILD_SHARED_LIBRARY)

# ---------------------------------------------------------------------------
# main_hook (shared)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := main_hook
LOCAL_SRC_FILES := libadrenotools/src/hook/main_hook.c
LOCAL_CFLAGS := -Wall -Wextra
LOCAL_LDFLAGS := -Wl,-z,global
LOCAL_SHARED_LIBRARIES := hook_impl
include $(BUILD_SHARED_LIBRARY)

# ---------------------------------------------------------------------------
# file_redirect_hook (shared)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := file_redirect_hook
LOCAL_SRC_FILES := libadrenotools/src/hook/file_redirect_hook.c
LOCAL_CFLAGS := -Wall -Wextra
LOCAL_LDFLAGS := -Wl,-z,global
LOCAL_SHARED_LIBRARIES := hook_impl
include $(BUILD_SHARED_LIBRARY)

# ---------------------------------------------------------------------------
# gsl_alloc_hook (shared)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := gsl_alloc_hook
LOCAL_SRC_FILES := libadrenotools/src/hook/gsl_alloc_hook.c
LOCAL_CFLAGS := -Wall -Wextra
LOCAL_LDFLAGS := -Wl,-z,global
LOCAL_SHARED_LIBRARIES := hook_impl
include $(BUILD_SHARED_LIBRARY)

# ---------------------------------------------------------------------------
# winlator (shared)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := winlator
LOCAL_SRC_FILES := winlator/src/drawable.c \
                   winlator/src/gpu_image.c \
                   winlator/src/gpu_helper.c \
                   winlator/src/sysvshared_memory.c \
                   winlator/src/xconnector_epoll.c \
                   winlator/src/xinput_stream.c \
                   winlator/src/xoutput_stream.c \
                   winlator/src/arrays.c \
                   winlator/src/ring_buffer.c \
                   winlator/src/wine_registry_editor.c
LOCAL_C_INCLUDES := $(LOCAL_PATH)/winlator/include
LOCAL_EXPORT_C_INCLUDES := $(LOCAL_PATH)/winlator/include
LOCAL_CFLAGS := -O2 -Wno-unused-function -Wimplicit-function-declaration
LOCAL_LDLIBS := -llog -landroid -ljnigraphics -lEGL -lGLESv2 -lGLESv3
include $(BUILD_SHARED_LIBRARY)

# ---------------------------------------------------------------------------
# virglrenderer (shared)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := virglrenderer
LOCAL_SRC_FILES := virglrenderer/src/iov.c \
                   virglrenderer/src/vrend_blitter.c \
                   virglrenderer/src/vrend_decode.c \
                   virglrenderer/src/vrend_formats.c \
                   virglrenderer/src/vrend_object.c \
                   virglrenderer/src/vrend_renderer.c \
                   virglrenderer/src/vrend_shader.c \
                   virglrenderer/server/virgl_server.c \
                   virglrenderer/server/virgl_server_shm.c \
                   virglrenderer/server/virgl_server_renderer.c \
                   virglrenderer/src/gallium/auxiliary/util/u_format.c \
                   virglrenderer/src/gallium/auxiliary/util/u_format_table.c \
                   virglrenderer/src/gallium/auxiliary/util/u_texture.c \
                   virglrenderer/src/gallium/auxiliary/util/u_hash_table.c \
                   virglrenderer/src/gallium/auxiliary/util/u_debug.c \
                   virglrenderer/src/gallium/auxiliary/util/u_cpu_detect.c \
                   virglrenderer/src/gallium/auxiliary/util/u_bitmask.c \
                   virglrenderer/src/gallium/auxiliary/util/u_surface.c \
                   virglrenderer/src/gallium/auxiliary/util/u_math.c \
                   virglrenderer/src/gallium/auxiliary/util/u_debug_describe.c \
                   virglrenderer/src/gallium/auxiliary/cso_cache/cso_cache.c \
                   virglrenderer/src/gallium/auxiliary/cso_cache/cso_hash.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_dump.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_ureg.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_build.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_scan.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_info.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_parse.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_text.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_strings.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_sanity.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_iterate.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_util.c \
                   virglrenderer/src/gallium/auxiliary/tgsi/tgsi_transform.c \
                   virglrenderer/src/gallium/auxiliary/os/os_misc.c
LOCAL_C_INCLUDES := $(LOCAL_PATH)/virglrenderer/src \
                    $(LOCAL_PATH)/virglrenderer/src/gallium/include \
                    $(LOCAL_PATH)/virglrenderer/src/gallium/auxiliary \
                    $(LOCAL_PATH)/virglrenderer/src/gallium/auxiliary/util \
                    $(LOCAL_PATH)/virglrenderer/server
LOCAL_CFLAGS := -O2 -Wno-unused-function -Wimplicit-function-declaration
LOCAL_SHARED_LIBRARIES := winlator
LOCAL_LDLIBS := -llog -landroid -lEGL -lGLESv2 -lGLESv3
include $(BUILD_SHARED_LIBRARY)

# ---------------------------------------------------------------------------
# vortekrenderer (shared)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := vortekrenderer
LOCAL_SRC_FILES := vortekrenderer/src/main.c \
                   vortekrenderer/src/vk_object.c \
                   vortekrenderer/src/request_handler.c \
                   vortekrenderer/src/vulkan_helper.c \
                   vortekrenderer/src/vk_context.c \
                   vortekrenderer/src/resource_memory.c \
                   vortekrenderer/src/xwindow_swapchain.c \
                   vortekrenderer/src/texture_decoder.c \
                   vortekrenderer/src/shader_inspector.c \
                   vortekrenderer/src/async_pipeline_creator.c \
                   vortekrenderer/src/timeline_semaphore.c
LOCAL_C_INCLUDES := $(LOCAL_PATH)/vortekrenderer/include \
                    $(LOCAL_PATH)/winlator/include \
                    $(LOCAL_PATH)/libadrenotools/include
LOCAL_CFLAGS := -O2 -Wno-unused-function -Wimplicit-function-declaration \
                -DVK_USE_PLATFORM_ANDROID_KHR
LOCAL_STATIC_LIBRARIES := adrenotools linkernsbypass
LOCAL_SHARED_LIBRARIES := winlator
LOCAL_LDLIBS := -llog -landroid -ldl
include $(BUILD_SHARED_LIBRARY)

# ---------------------------------------------------------------------------
# gladiorenderer (shared)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := gladiorenderer
LOCAL_SRC_FILES := gladiorenderer/src/main.c \
                   gladiorenderer/src/gl_context.c \
                   gladiorenderer/src/gl_renderer.c \
                   gladiorenderer/src/request_handler.c \
                   gladiorenderer/src/shader_material.c \
                   gladiorenderer/src/shader_converter.c \
                   gladiorenderer/src/gl_formats.c \
                   gladiorenderer/src/gl_texture.c \
                   gladiorenderer/src/attrib_stack.c \
                   gladiorenderer/src/gl_query.c \
                   gladiorenderer/src/compressed_texture.c \
                   gladiorenderer/src/arb_program.c \
                   gladiorenderer/src/gl_buffer.c \
                   gladiorenderer/src/gl_vao.c \
                   gladiorenderer/src/gl_framebuffer.c
LOCAL_C_INCLUDES := $(LOCAL_PATH)/gladiorenderer/include \
                    $(LOCAL_PATH)/winlator/include \
                    $(LOCAL_PATH)/vortekrenderer/include
LOCAL_CFLAGS := -O2 -Wno-unused-function -Wimplicit-function-declaration \
                -Werror=incompatible-pointer-types
LOCAL_SHARED_LIBRARIES := winlator
LOCAL_LDLIBS := -llog -landroid -lEGL -lGLESv2 -lGLESv3
include $(BUILD_SHARED_LIBRARY)

# ---------------------------------------------------------------------------
# midihandler (shared)
# ---------------------------------------------------------------------------
include $(CLEAR_VARS)
LOCAL_MODULE := midihandler
LOCAL_SRC_FILES := midihandler/midihandler.c
LOCAL_C_INCLUDES := $(LOCAL_PATH)/midihandler/fluidsynth/include
LOCAL_LDLIBS := -llog -fopenmp \
                -L$(JNI_LIBS_DIR) \
                -lFLAC \
                -lfluidsynth-assetloader \
                -lgio-2.0 \
                -lglib-2.0 \
                -lgmodule-2.0 \
                -lgobject-2.0 \
                -lgthread-2.0 \
                -linstpatch-1.0 \
                -loboe \
                -logg \
                -lopus \
                -lpcre \
                -lpcreposix \
                -lsndfile \
                -lvorbis \
                -lvorbisenc \
                -lvorbisfile \
                -lfluidsynth
include $(BUILD_SHARED_LIBRARY)
