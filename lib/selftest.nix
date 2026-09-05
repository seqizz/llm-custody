# Probe script for `--selftest`. Built as its own store file, bound to
# /selftest.sh inside the sandbox and executed with bash.
#
# Everything the probe needs is passed via env vars (SELFTEST_*) set by the
# runner with regular Nix interpolations - the runner owns those values
# (config dir, unshare binary, probe domain, net-filter state). That keeps
# the writeText string below completely free of ${...} interpolations, so
# Nix only ever has to parse a plain shell script as a string, and the
# runner's writeShellApplication shellcheck pass never sees this file at
# all (it would flag every $()/$var fragment as SC2016 if inlined).
{ pkgs }:
pkgs.writeText "llm-custody-selftest.sh" ''
  set -e
  echo "llm-custody selftest: sandbox running"
  echo "  uid=$(id -u) gid=$(id -g) home=$HOME cwd=$(pwd)"
  [ -d /nix/store ] || { echo "FAIL: /nix/store not visible"; exit 1; }
  [ -w /home/user ] || { echo "FAIL: /home/user not writable"; exit 1; }
  [ -d "$SELFTEST_CONFIGDIR" ] || { echo "FAIL: state dir not mounted"; exit 1; }
  if command -v git >/dev/null 2>&1; then
    echo "  git: $(git --version 2>&1)"
    hp=$(git config --get core.hooksPath 2>/dev/null || true)
    echo "  forced core.hooksPath: $hp"
  else
    echo "SKIP: git not in jail PATH"
  fi
  if [ -x "$SELFTEST_UNSHARE" ]; then
    if "$SELFTEST_UNSHARE" -r true 2>/dev/null; then
      echo "FAIL: unshare allowed - seccomp denylist not active"
      exit 1
    else
      echo "OK: denied syscall (unshare) blocked by seccomp"
    fi
  else
    echo "SKIP: unshare binary not present"
  fi
  if [ "$SELFTEST_NET" = "1" ]; then
    if command -v getent >/dev/null 2>&1; then
      # getent ahostsv4 is broken/empty in this glibc (rc=2 even for names
      # that clearly resolve), so use `getent hosts` and take the first
      # whitespace field (the address).
      allow_ip=$(getent hosts "$SELFTEST_DOMAIN" 2>/dev/null | { IFS=' ' read -r ip _; printf '%s' "$ip"; })
      if [ -z "$allow_ip" ] || [ "$allow_ip" = "0.0.0.0" ] || [ "$allow_ip" = "::" ]; then
        echo "FAIL: allowed domain $SELFTEST_DOMAIN did not resolve to a real IP"
        exit 1
      fi
      echo "  allow $SELFTEST_DOMAIN -> $allow_ip"
      block_ip=$(getent hosts example.com 2>/dev/null | { IFS=' ' read -r ip _; printf '%s' "$ip"; })
      case "$block_ip" in
        0.0.0.0|::) echo "  block example.com -> $block_ip" ;;
        *) echo "FAIL: example.com not blackholed (resolved to $block_ip)"; exit 1 ;;
      esac
    else
      echo "SKIP: getent not in jail PATH, network tests skipped"
    fi
  else
    echo "SKIP: network tests (--no-net-filter given)"
  fi
  echo "selftest PASS"
''
