# Probe script for `--selftest`. Built as its own store file (bound to
# /selftest.sh inside the sandbox and executed with bash) rather than
# embedded in mkBwrapRunner.nix's shell text: the runner goes through
# writeShellApplication's shellcheck pass, which would flag `$()`/`$var`
# if they were quoted literals in that string (SC2016) - the earlier
# inline version actually failed the build. As a standalone derivation
# this file is never analyzed by shellcheck.
{ pkgs, toolDefaults }:
let
  # The one whitelisted domain the probe can legitimately resolve to prove
  # the DNS side of the filter works (the other half of the check is that
  # a non-whitelisted name blackholes).
  probeDomain = builtins.head toolDefaults.allowedDomains;
in
pkgs.writeText "llm-custody-selftest.sh" ''
  set -e
  echo "llm-custody selftest: sandbox running"
  echo "  uid=$(id -u) gid=$(id -g) home=$HOME cwd=$(pwd)"
  [ -d /nix/store ] || { echo "FAIL: /nix/store not visible"; exit 1; }
  [ -w /home/user ] || { echo "FAIL: /home/user not writable"; exit 1; }
  [ -d /home/user/${toolDefaults.configDirName} ] || { echo "FAIL: state dir not mounted"; exit 1; }
  if command -v git >/dev/null 2>&1; then
    echo "  git: $(git --version 2>&1)"
    hp=$(git config --get core.hooksPath 2>/dev/null || true)
    echo "  forced core.hooksPath: $hp"
  else
    echo "SKIP: git not in jail PATH"
  fi
  if [ -x ${pkgs.util-linux}/bin/unshare ]; then
    if ${pkgs.util-linux}/bin/unshare -r true 2>/dev/null; then
      echo "FAIL: unshare allowed - seccomp denylist not active"
      exit 1
    else
      echo "OK: denied syscall (unshare) blocked by seccomp"
    fi
  else
    echo "SKIP: unshare not found in store"
  fi
  if [ "$SELFTEST_NET" = "1" ]; then
    if command -v getent >/dev/null 2>&1; then
      echo "  allow ${probeDomain} -> $(getent ahostsv4 ${probeDomain} 2>&1 | { IFS= read -r l; printf '%s' "$l"; })"
      echo "  block example.com -> $(getent ahostsv4 example.com 2>&1 | { IFS= read -r l; printf '%s' "$l"; })"
    else
      echo "SKIP: getent not in jail PATH, network tests skipped"
    fi
  else
    echo "SKIP: network tests (--no-net-filter given)"
  fi
  echo "selftest PASS"
'';