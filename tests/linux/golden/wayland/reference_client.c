/* The reference Wayland client of the byte tests (US-079), built and run
 * by capture.sh in a gnome test session against libwayland-client: the
 * same requests as the native client of src/backend/linux/wire/wayland.zig
 * (registry, wl_compositor and wl_shm bound, a pool on a memfd, a buffer
 * attached to a surface, then everything destroyed). */
#define _GNU_SOURCE
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

static struct wl_compositor *compositor;
static struct wl_shm *shm;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, "wl_compositor") == 0)
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 6 ? version : 6);
    else if (strcmp(interface, "wl_shm") == 0)
        shm = wl_registry_bind(registry, name, &wl_shm_interface, version < 2 ? version : 2);
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data, (void)registry, (void)name;
}

static const struct wl_registry_listener listener = {global, global_remove};

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    wl_display_roundtrip(display);
    if (!compositor || !shm) return 2;
    int fd = memfd_create("nc-golden", MFD_CLOEXEC);
    ftruncate(fd, 64 * 64 * 4);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, 64 * 64 * 4);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, 64, 64, 64 * 4, WL_SHM_FORMAT_XRGB8888);
    struct wl_surface *surface = wl_compositor_create_surface(compositor);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, 64, 64);
    wl_surface_commit(surface);
    wl_display_roundtrip(display);
    wl_surface_destroy(surface);
    wl_buffer_destroy(buffer);
    wl_shm_pool_destroy(pool);
    wl_shm_release(shm);
    wl_display_roundtrip(display);
    close(fd);
    wl_display_disconnect(display);
    return 0;
}
