# The --selftest nested-userns probe (see userns-probe.c), built like the
# tiocsti probe: a tiny C program is the only way to issue clone/clone3 with
# specific flags without dragging an interpreter into the runner's closure.
{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "llm-custody-userns-probe";
  version = "1";
  src = ./userns-probe.c;
  dontUnpack = true;
  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -o userns-probe "$src"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 userns-probe $out/bin/userns-probe
    runHook postInstall
  '';
}
