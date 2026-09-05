# Builds the seccomp-denylist emitter (see seccomp-denylist.c) as a real
# derivation instead of the bwrap-pi.sh prototype's runtime-cached `cc`
# invocation - that trick only existed because the prototype was a
# standalone script outside the flake and had to resolve libseccomp's
# dev/lib outputs via `nix eval` at run time. Here libseccomp is just a
# normal buildInput.
{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "llm-custody-seccomp-denylist";
  version = "1";
  src = ./seccomp-denylist.c;
  dontUnpack = true;
  buildInputs = [ pkgs.libseccomp ];
  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -o seccomp-denylist "$src" -lseccomp
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 seccomp-denylist $out/bin/seccomp-denylist
    runHook postInstall
  '';
}
