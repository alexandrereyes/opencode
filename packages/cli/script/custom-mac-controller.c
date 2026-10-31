// bin/mac-controller (see custom-mac-controller.ts): runs a command as its child, sharing this process's stdio, and
// stays its parent until it exits. Signed as local.opencode.custom, it is the signed OpenCode ancestor that native
// helpers such as MacLock require, for commands a Linux runtime starts through `mac`.
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>

extern char **environ;
static volatile pid_t child = 0;

static void forward(int number) {
  if (child > 0) kill(child, number);
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
  pid_t pid;
  int failure = posix_spawnp(&pid, argv[1], NULL, NULL, argv + 1, environ);
  if (failure) {
    fprintf(stderr, "mac-controller: %s: %s\n", argv[1], strerror(failure));
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
