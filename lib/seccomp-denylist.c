/* Emits a seccomp BPF program (SCMP_ACT_ALLOW default, EPERM on the denied
 * list, ENOSYS for clone3) to stdout, for bwrap's `--seccomp FD`. bwrap applies this filter
 * right before the final execve of the sandboxed command - its own setup
 * (unshare/mount/pivot_root to build the sandbox) runs unfiltered beforehand,
 * same as upstream bwrap's own --seccomp semantics.
 *
 * Denylist is the same one already validated on llm-jail's g_harden branch
 * (guests/common.nix, SystemCallFilter= on llmjail-tool.service) for a
 * coding-agent workload: none of these are things `pi` (or its bash-tool
 * subprocesses - rg/git/jq/etc) has a legitimate reason to call. If the
 * sandboxed process calls one anyway, that's the escape attempt this exists
 * to catch, not a false positive to work around.
 *
 * Nested user namespaces are closed here, and only here. unshare is denied
 * outright, clone with any CLONE_NEW* flag gets EPERM, and clone3 gets
 * ENOSYS (see the rule below for why not EPERM). Denying unshare alone is
 * not enough: a jailed process reaches the same fresh userns, with a full
 * capability set inside it, through clone or clone3.
 *
 * bwrap's --disable-userns is passed as well but carries no weight: on
 * bwrap 0.13.1 it leaves /proc/sys/user/max_user_namespaces at INT_MAX in
 * the sandbox instead of the documented 1, measured both inside this jail
 * and from a plain bwrap on the host. The runner's --cap-drop ALL is what
 * backs these rules up, by taking away the CAP_SYS_RESOURCE that would let
 * the sandboxed process rewrite that limit anyway.
 */
/* For the CLONE_NEW* constants in sched.h. */
#define _GNU_SOURCE
#include <seccomp.h>
#include <errno.h>
#include <sched.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <unistd.h>

static const int denied[] = {
  SCMP_SYS(kexec_load), SCMP_SYS(kexec_file_load), SCMP_SYS(bpf),
  SCMP_SYS(create_module), SCMP_SYS(init_module), SCMP_SYS(finit_module),
  SCMP_SYS(add_key), SCMP_SYS(request_key), SCMP_SYS(iopl), SCMP_SYS(ioperm),
  SCMP_SYS(acct), SCMP_SYS(clock_settime), SCMP_SYS(mount), SCMP_SYS(umount2),
  SCMP_SYS(pivot_root), SCMP_SYS(chroot), SCMP_SYS(reboot),
  SCMP_SYS(swapoff), SCMP_SYS(swapon), SCMP_SYS(ptrace), SCMP_SYS(unshare),
  /* Namespace-escape and privileged-boundary probes. Each of these fails
   * with EPERM anyway for an unprivileged process, so blocking them costs
   * nothing at runtime - they only matter when a jailed process somehow got
   * a host-namespace fd (setns/pidfd_getfd) or an elevated capability
   * (process_vm_*, perf_event_open, open_by_handle_at, the fsopen mount
   * API), which is exactly the escape/privilege-gain case to stop.
   *
   * io_uring_* is deliberately NOT on the list: pi runs on the bun runtime,
   * which uses io_uring for filesystem I/O, and an EPERM there could break
   * the tool's normal operation instead of only an exploit. Re-test before
   * ever adding it. */
  SCMP_SYS(setns), SCMP_SYS(perf_event_open),
  SCMP_SYS(process_vm_readv), SCMP_SYS(process_vm_writev),
  SCMP_SYS(pidfd_getfd), SCMP_SYS(open_by_handle_at),
  SCMP_SYS(fsopen), SCMP_SYS(fsconfig), SCMP_SYS(fsmount), SCMP_SYS(fspick),
  /* The modern mount API calls that util-linux's `mount` actually uses
   * (open_tree + move_mount; mount_setattr for attr changes) - without
   * these, `mount --bind` silently bypasses the mount(2) deny above. The
   * real gate is bwrap's --cap-drop ALL (every mount syscall needs
   * CAP_SYS_ADMIN); this list is the belt for when that cap isn't dropped
   * (e.g. a future --cap-add use). */
  SCMP_SYS(open_tree), SCMP_SYS(move_mount), SCMP_SYS(mount_setattr),
  SCMP_SYS(userfaultfd),
};

int main(void) {
  scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);
  if (!ctx) {
    return 1;
  }

  for (size_t i = 0; i < sizeof(denied) / sizeof(denied[0]); i++) {
    if (seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), denied[i], 0) < 0) {
      seccomp_release(ctx);
      return 1;
    }
  }

  /* clone with a namespace-creating flag: the same set unshare would give,
   * refused per flag with a masked compare (one rule per bit, libseccomp
   * ORs rules on the same syscall). Arg 0 is the flags word on x86_64 and
   * aarch64. Plain fork/thread clones carry none of these bits and pass. */
  static const unsigned long clone_ns[] = {
    CLONE_NEWUSER, CLONE_NEWNET, CLONE_NEWNS, CLONE_NEWPID,
    CLONE_NEWIPC, CLONE_NEWUTS, CLONE_NEWCGROUP,
  };
  for (size_t i = 0; i < sizeof(clone_ns) / sizeof(clone_ns[0]); i++) {
    if (seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(clone), 1,
                         SCMP_A0(SCMP_CMP_MASKED_EQ, clone_ns[i], clone_ns[i])) < 0) {
      seccomp_release(ctx);
      return 1;
    }
  }

  /* clone3 keeps its flags in a userspace struct seccomp cannot read, so it
   * is refused as a whole. ENOSYS, not EPERM: glibc (pthread_create,
   * posix_spawn) treats ENOSYS as "kernel too old" and falls back to clone,
   * where the rules above apply; EPERM would make thread creation fail.
   * Same pattern as flatpak and Docker's default profile. */
  if (seccomp_rule_add(ctx, SCMP_ACT_ERRNO(ENOSYS), SCMP_SYS(clone3), 0) < 0) {
    seccomp_release(ctx);
    return 1;
  }

  /* Terminal input injection: TIOCSTI pushes bytes into the terminal's
   * input queue as if typed, TIOCLINUX can paste a console selection. The
   * sandboxed tool keeps the controlling terminal (no bwrap --new-session),
   * because a tool detached from it never receives SIGWINCH and keeps
   * painting at the launch width after the pane is resized or split; this
   * is the protection that replaces the detachment, and the one bwrap's
   * own documentation names for that case. Masked compare, as flatpak does:
   * the request number is an int that may arrive sign-extended in the
   * 64-bit argument register. */
  static const unsigned long tty_inject[] = { TIOCSTI, TIOCLINUX };
  for (size_t i = 0; i < sizeof(tty_inject) / sizeof(tty_inject[0]); i++) {
    if (seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(ioctl), 1,
                         SCMP_A1(SCMP_CMP_MASKED_EQ, 0xFFFFFFFFul, tty_inject[i])) < 0) {
      seccomp_release(ctx);
      return 1;
    }
  }

  int rc = seccomp_export_bpf(ctx, STDOUT_FILENO);
  seccomp_release(ctx);
  return rc < 0 ? 1 : 0;
}
