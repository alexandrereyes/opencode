// mac-controller (see custom-mac-controller.ts): runs a command as its child, sharing this process's stdio, and stays
// its parent until it exits. Signed as local.opencode.custom, it is the signed OpenCode ancestor that native helpers
// such as MacLock require, for commands a Linux runtime starts through `mac`.
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

extern char **environ;
static volatile pid_t child = 0;
#ifdef __APPLE__
static const char responsible[] = "OPENCODE_MAC_CONTROLLER_RESPONSIBLE";
#endif

static void forward(int number) {
  if (child > 0) kill(child, number);
}

static int run(const char *program, char *const arguments[], const posix_spawnattr_t *attributes, int search) {
  pid_t pid;
  int failure = search ? posix_spawnp(&pid, program, NULL, attributes, arguments, environ)
                       : posix_spawn(&pid, program, NULL, attributes, arguments, environ);
  if (failure) {
    fprintf(stderr, "mac-controller: %s: %s\n", program, strerror(failure));
    return 127;
  }
  child = pid;
  int status;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) {
      perror("mac-controller: waitpid");
      return 1;
    }
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int main(int argc, char *argv[]) {
  if (argc < 2) {
    fprintf(stderr, "usage: mac-controller <command> [arguments...]\n");
    return 64;
  }
  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_handler = forward;
  sigemptyset(&action.sa_mask);
  int forwarded[] = {SIGHUP, SIGINT, SIGQUIT, SIGTERM};
  for (unsigned i = 0; i < sizeof forwarded / sizeof *forwarded; i++) sigaction(forwarded[i], &action, NULL);
#ifdef __APPLE__
  // macOS attributes the privacy (TCC) checks of a process tree to its responsible process: whoever started this one
  // (OrbStack Helper, through `mac`). Running this executable again with responsibility disclaimed makes this bundle
  // (local.opencode.custom, holding the server's grants) responsible for the command instead.
  if (!getenv(responsible)) {
    int (*disclaim)(posix_spawnattr_t *, int) =
        (int (*)(posix_spawnattr_t *, int))dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    char self[PATH_MAX];
    uint32_t size = sizeof self;
    posix_spawnattr_t attributes;
    if (disclaim && _NSGetExecutablePath(self, &size) == 0 && posix_spawnattr_init(&attributes) == 0) {
      int status = disclaim(&attributes, 1) == 0 && setenv(responsible, "1", 1) == 0 ? run(self, argv, &attributes, 0) : -1;
      posix_spawnattr_destroy(&attributes);
      if (status >= 0) return status;
    }
    fprintf(stderr, "mac-controller: cannot disclaim responsibility; privacy checks stay with the caller\n");
  }
  unsetenv(responsible);
#endif
  return run(argv[1], argv + 1, NULL, 1);
}
