# fp6-ims-recover: escalating VoLTE recovery (see fp6-ims-recover.sh). The check phase runs
# test-ims-recover.sh against the script with stand-ins for systemctl, busctl and logger.
{ lib, stdenvNoCC, bash, makeWrapper, systemd, util-linux, gnugrep, coreutils }:
stdenvNoCC.mkDerivation {
  pname = "fp6-ims-recover";
  version = "0.1.1";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./fp6-ims-recover.sh ./test-ims-recover.sh ];
  };
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${bash}/bin/bash test-ims-recover.sh ./fp6-ims-recover.sh
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm644 fp6-ims-recover.sh $out/libexec/fp6-ims-recover.sh
    makeWrapper ${bash}/bin/bash $out/bin/fp6-ims-recover \
      --add-flags $out/libexec/fp6-ims-recover.sh \
      --set PATH ${lib.makeBinPath [ systemd util-linux gnugrep coreutils ]}
    runHook postInstall
  '';
  meta.mainProgram = "fp6-ims-recover";
}
