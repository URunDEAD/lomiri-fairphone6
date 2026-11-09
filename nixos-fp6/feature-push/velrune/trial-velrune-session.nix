# The kernel6 full-features Lomiri target plus velrune-session.nix: Velrune
# Shell on the panel at boot, Lomiri installed and startable by hand.
# See velrune-session.nix and .local/teams/os-phone/rebuild-runbook.md.
#
#   nix-instantiate --option max-jobs 1 --option cores 4 \
#     feature-push/velrune/trial-velrune-session.nix -A config.system.build.toplevel
#
# Build/eval only. Never writes a boot image, slot or partition.
{ nixpkgs ? (import ../../upstream/mobile-nixos/npins).nixpkgs
  # Shell store path, if not the one in shell-path.nix: --argstr velruneShellPath /nix/store/...
, velruneShellPath ? null
}:
let
  base = import ../trial-lomiri-full-kernel6-fp6.nix { inherit nixpkgs; };
  evaluated = base.eval.extendModules { modules = [ ./velrune-session.nix
    ({ lib, ... }: lib.mkIf (velruneShellPath != null) { velrune.shellPath = velruneShellPath; }) ]; };
in base // {
  eval = evaluated;
  inherit (evaluated) config pkgs options;
  outputs = evaluated.config.mobile.outputs
    // evaluated.config.mobile.outputs.${evaluated.config.mobile.system.type};
}
