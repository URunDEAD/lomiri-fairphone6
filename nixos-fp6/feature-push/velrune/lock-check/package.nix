# velrune-lock-check: the root PIN check for the Shell's secure lock (see the C file).
# The check phase builds the test variant and runs test_lock_check.py against a private
# PAM stack (faillock + pam_exec), so it runs wherever the package is built natively.
{ lib, stdenv, linux-pam, systemdLibs, pkg-config, python3 }:
stdenv.mkDerivation {
  pname = "velrune-lock-check";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./velrune-lock-check.c ./test_lock_check.py ];
  };
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ linux-pam systemdLibs ];
  nativeCheckInputs = [ python3 ];
  buildPhase = ''
    runHook preBuild
    flags="-std=c11 -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2 -fstack-protector-strong"
    $CC $flags -o velrune-lock-check velrune-lock-check.c -lpam $(pkg-config --libs libsystemd)
    $CC $flags -DVELRUNE_LOCK_TESTING -o velrune-lock-check-test velrune-lock-check.c -lpam
    runHook postBuild
  '';
  doCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  checkPhase = ''
    runHook preCheck
    TEST_SHELL=${stdenv.shell} python3 test_lock_check.py ./velrune-lock-check-test ${linux-pam}/lib/security
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 velrune-lock-check $out/bin/velrune-lock-check
    runHook postInstall
  '';
  meta = {
    description = "Root PIN check for the Velrune Shell's lock screen (PAM velrune-lock, pam_faillock)";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "velrune-lock-check";
  };
}
