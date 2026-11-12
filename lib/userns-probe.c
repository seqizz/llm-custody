/* --selftest probe: can a jailed process create a nested user namespace?
 *
 * Tries clone() and a raw clone3() with CLONE_NEWUSER|CLONE_NEWNET, the
 * pair that would hand the caller a full capability set over a fresh
 * network stack. unshare(2) is not tried here: the selftest already covers
 * it with util-linux unshare, and the point of this probe is the two paths
 * a denylist entry for unshare alone does not close.
 *
 * Any failure counts as blocked, whatever the errno: EPERM from the seccomp
 * clone rule, ENOSYS from the clone3 rule, or ENOSPC from a
 * max_user_namespaces limit. Which layer refused is not the question;
 * whether a namespace was created is.
 *
 * Exit 0: both calls failed. Exit 1: one line per call that succeeded on
 * stdout for the selftest log.
 */
#define _GNU_SOURCE
#include <linux/sched.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SYS_clone3
#define SYS_clone3 435
#endif

#define NS_FLAGS (CLONE_NEWUSER | CLONE_NEWNET)

static char child_stack[64 * 1024];

static int child_fn(void *arg) {
  (void)arg;
  return 0;
}

/* 1 if clone() created the namespaces, 0 if it was refused. */
static int try_clone(void) {
  pid_t pid = clone(child_fn, child_stack + sizeof(child_stack),
                    NS_FLAGS | SIGCHLD, NULL);
  if (pid < 0) {
    return 0;
  }
  waitpid(pid, NULL, 0);
  return 1;
}

/* 1 if clone3() created the namespaces, 0 if it was refused. Raw syscall
 * without CLONE_VM, so the child runs on a copy of this stack and can
 * leave straight away. */
static int try_clone3(void) {
  struct clone_args args;
  memset(&args, 0, sizeof(args));
  args.flags = NS_FLAGS;
  args.exit_signal = SIGCHLD;
  long pid = syscall(SYS_clone3, &args, sizeof(args));
  if (pid < 0) {
    return 0;
  }
  if (pid == 0) {
    _exit(0);
  }
  waitpid((pid_t)pid, NULL, 0);
  return 1;
}

int main(void) {
  int rc = 0;
  if (try_clone()) {
    printf("clone(CLONE_NEWUSER|CLONE_NEWNET) succeeded\n");
    rc = 1;
  }
  if (try_clone3()) {
    printf("clone3(CLONE_NEWUSER|CLONE_NEWNET) succeeded\n");
    rc = 1;
  }
  return rc;
}
