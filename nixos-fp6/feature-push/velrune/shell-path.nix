# The one place the Shell build is named. velrune-session.nix reads this file;
# the coordinator switches Shell versions by changing the path below and
# rebuilding, or without editing: nix-instantiate --argstr velruneShellPath <path> ...
# (see trial-velrune-session.nix). The path must already be in the store
# (builtins.storePath), and its closure then ships with the system closure.
#
# Shell 0.1.26 (Shell repo agent/shell-phone 6542b4d, Core pin e613633).
"/nix/store/zhqc655jz21x6mwfiwa74pk51j9x3s16-velrune-shell-direct-aarch64-unknown-linux-gnu-0.1.26"
