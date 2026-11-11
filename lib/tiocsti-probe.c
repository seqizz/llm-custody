/* --selftest probe: is terminal input injection denied inside the jail?
 *
 * Issues ioctl(TIOCSTI) on stdin and reports by exit status. The seccomp
 * denylist is expected to refuse it with EPERM before the kernel ever sees
 * the request, so any other outcome - success, or an error the tty layer
 * itself would give (ENOTTY on a non-terminal, EIO under
 * dev.tty.legacy_tiocsti=0) - means the request reached the kernel and the
 * rule is not in effect. Checked on any fd rather than only a terminal for
 * exactly that reason: seccomp decides before the fd type matters, so a
 * headless selftest can verify the rule too.
 *
 * Exit 0: EPERM, the rule works. Exit 1: anything else, with the reason on
 * stdout for the selftest log.
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>

int main(void) {
  char byte = 'x';
  if (ioctl(0, TIOCSTI, &byte) == 0) {
    printf("ioctl(TIOCSTI) succeeded\n");
    return 1;
  }
  if (errno == EPERM) {
    return 0;
  }
  printf("ioctl(TIOCSTI) reached the kernel: %s\n", strerror(errno));
  return 1;
}
