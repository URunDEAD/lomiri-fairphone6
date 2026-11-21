# fp6-ims-online: VoLTE follows the modem's Online state (see fp6_ims_online.py). The
# check phase runs the state-machine and recovery tests with a fake oFono and systemd.
{ lib, stdenvNoCC, python3, makeWrapper, systemd, dbus, coreutils }:
stdenvNoCC.mkDerivation {
  pname = "fp6-ims-online";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./fp6_ims_online.py ./test_fp6_ims_online.py ];
  };
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${python3}/bin/python3 -B test_fp6_ims_online.py -v
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm644 fp6_ims_online.py $out/libexec/fp6_ims_online.py
    makeWrapper ${python3}/bin/python3 $out/bin/fp6-ims-online \
      --add-flags "-I -B $out/libexec/fp6_ims_online.py" \
      --set PATH ${lib.makeBinPath [ systemd dbus coreutils ]}
    runHook postInstall
  '';
  meta.mainProgram = "fp6-ims-online";
}
