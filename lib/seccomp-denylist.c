/* Emits a seccomp BPF program (SCMP_ACT_ALLOW default, EPERM on the denied
 * list) to stdout, for bwrap's `--seccomp FD`. bwrap applies this filter
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
 */
#include <seccomp.h>
#include <errno.h>
#include <stddef.h>
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

  int rc = seccomp_export_bpf(ctx, STDOUT_FILENO);
  seccomp_release(ctx);
  return rc < 0 ? 1 : 0;
}
