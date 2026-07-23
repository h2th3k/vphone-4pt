#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void write_marker(const char *path, const char *msg) {
  if (!path || !path[0])
    return;
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0)
    return;
  (void)write(fd, msg, strlen(msg));
  close(fd);
}

static void dirname_copy(const char *path, char *out, size_t outLen) {
  if (!path || !out || outLen == 0)
    return;
  out[0] = '\0';
  const char *slash = strrchr(path, '/');
  if (!slash || slash == path)
    return;
  size_t n = (size_t)(slash - path);
  if (n + 1 >= outLen)
    n = outLen - 1;
  memcpy(out, path, n);
  out[n] = '\0';
}

__attribute__((constructor)) static void vphone_noop_inject_init(void) {
  char msg[128];
  snprintf(msg, sizeof(msg), "loaded pid=%d\n", getpid());

  // Always try TMPDIR / HOME (LaunchServices sets these for containerized apps).
  const char *tmpdir = getenv("TMPDIR");
  const char *home = getenv("HOME");
  char path[1024];

  if (tmpdir && tmpdir[0]) {
    snprintf(path, sizeof(path), "%s/vphone-noop-inject-loaded.txt", tmpdir);
    write_marker(path, msg);
  }
  if (home && home[0]) {
    snprintf(path, sizeof(path), "%s/Library/Caches/vphone-noop-inject-loaded.txt",
             home);
    write_marker(path, msg);
    snprintf(path, sizeof(path), "%s/tmp/vphone-noop-inject-loaded.txt", home);
    write_marker(path, msg);
  }

  // Also write next to this dylib (same Caches dir you already ls).
  Dl_info info;
  if (dladdr((const void *)&vphone_noop_inject_init, &info) && info.dli_fname) {
    char dir[1024];
    dirname_copy(info.dli_fname, dir, sizeof(dir));
    if (dir[0]) {
      snprintf(path, sizeof(path), "%s/vphone-noop-inject-loaded.txt", dir);
      write_marker(path, msg);
    }
  }

  // Best-effort console / ASL (no `log` binary required to create the file).
  fprintf(stderr, "[VPhoneNoopInject] loaded pid=%d\n", getpid());
  NSLog(@"[VPhoneNoopInject] loaded pid=%d", getpid());
}
