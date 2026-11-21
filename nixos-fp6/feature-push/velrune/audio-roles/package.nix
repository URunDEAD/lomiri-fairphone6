# velrune-fixed-speaker (see fixed_speaker.py); the check phase runs its selection tests.
{ lib, stdenvNoCC, python3, makeWrapper, pipewire, wireplumber }:
stdenvNoCC.mkDerivation {
  pname = "velrune-fixed-speaker";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./fixed_speaker.py ./test_fixed_speaker.py ];
  };
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${python3}/bin/python3 -B test_fixed_speaker.py -v
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm644 fixed_speaker.py $out/libexec/fixed_speaker.py
    makeWrapper ${python3}/bin/python3 $out/bin/velrune-fixed-speaker \
      --add-flags "-I -B $out/libexec/fixed_speaker.py" \
      --prefix PATH : ${lib.makeBinPath [ pipewire wireplumber ]}
    runHook postInstall
  '';
  meta.mainProgram = "velrune-fixed-speaker";
}
