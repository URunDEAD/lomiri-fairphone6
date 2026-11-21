# Builds the Velrune apps and the Shell of apps.nix from their pinned git sources.
#
# Each package is its repository's own aarch64 recipe (ci/cross-device.nix and the
# like), called the way the app teams call it, with every source fetched by commit and
# checked against the NAR hash of its tree. The result must be the output path recorded
# in apps.nix (the build that is on the phone); a mismatch stops evaluation, so a pin can
# never silently produce a different app.
#
# release-pins.nix: components taken from the signed CI channel instead (Shell, Settings).
# Each is its recipe called the way velrune-release's entry.nix calls it (native
# aarch64-linux, `native = true`), so it evaluates to the very store path the channel
# names and the release cache holds; the same output-path check applies. Such an entry
# replaces apps.nix's entry of the same name.
#
# Sources are fetched from GitHub (URunDEAD-Labs; the hardware repository from URunDEAD):
# source-hosts.nix maps the old gitlab.com names, which the pinned Cargo.lock files and so
# gitSources still use, to their GitHub location. Nothing is fetched from gitlab.com
# (archived 2026-11-19): a gitlab.com URL without an entry stops evaluation.
# mirrors: { "<fetch url>" = "/local/clone"; }. A mirror is used when its folder exists
# (this desktop's clones hold every pinned commit); otherwise the GitHub URL is fetched,
# which for the private URunDEAD-Labs repositories needs read access in git's own
# configuration (gh's credential helper). The content is the same either way: the NAR
# hash decides.
# checkOutputs = false skips the output-path check (to inspect a mismatch).
{ data ? import ./apps.nix, release ? import ./release-pins.nix, mirrors ? import ./git-mirrors.nix
, hosts ? import ./source-hosts.nix, systemPin ? import ./system-pin.nix, checkOutputs ? true }:
let
  location = url:
    let at = hosts.${url} or url; in
    if builtins.match "https://gitlab[.]com/.*" at != null
    then throw "velrune-apps.nix: ${url} is on the archived gitlab.com and has no GitHub location in source-hosts.nix"
    else at;
  mirror = url:
    let at = location url; in
    if mirrors ? ${at} && builtins.pathExists mirrors.${at} then "file://${mirrors.${at}}" else at;
  fetch = { url, rev, narHash ? null, name ? "source", ... }:
    builtins.fetchGit ({ url = mirror url; inherit rev name; allRefs = true; }
      // (if narHash == null then { } else { inherit narHash; }));
  # A `git archive <rev> <keep>` snapshot: only that subtree, under its own path.
  subtree = x:
    let
      full = fetch (removeAttrs x [ "narHash" ]);
      prefix = toString full;
    in
    builtins.path {
      path = full;
      name = "source";
      sha256 = x.narHash;
      filter = path: _type:
        let rel = builtins.substring (builtins.stringLength prefix + 1) (-1) path; in
        builtins.substring 0 (builtins.stringLength rel + 1) (x.keep + "/") == rel + "/"
        || builtins.substring 0 (builtins.stringLength x.keep + 1) (rel + "/") == x.keep + "/";
    };
  extraSource = x: if x ? keep then subtree x else fetch x;
  nixpkgsSource = builtins.fetchTree ({ type = "github"; } // data.nixpkgs);
  withPaths = map (g: g // { path = fetch g; });
  check = name: spec: pkg:
    if !checkOutputs || pkg.outPath == spec.out then pkg
    else throw "velrune-apps.nix: ${name} evaluates to ${pkg.outPath}, apps.nix records ${spec.out}; rerun gen-apps-nix.py";

  # The shared document plugins: Docviewer's source and every git source the apps pin
  # (the recipe picks entries by url and revision, so extra entries change nothing).
  allGitSources = builtins.attrValues (builtins.listToAttrs (map (g: { name = "${g.url}@${g.rev}"; value = g; })
    (builtins.concatLists (map (a: a.gitSources) (builtins.attrValues data.apps)))));
  docPlugins = if data ? docPlugins then
    let src = fetch data.apps.docviewer.src; in
    check "docPlugins" data.docPlugins (import (src + "/${data.docPlugins.recipe}") {
      inherit nixpkgsSource;
      docviewer = src;
      gitSources = withPaths allGitSources;
    })
  else null;

  app = name: spec:
    let
      src = fetch spec.src;
      extras = spec.extras or { };
      args = {
        inherit nixpkgsSource;
        ${spec.arg} = src;
        gitSources = withPaths spec.gitSources;
      }
      // builtins.mapAttrs (_: extraSource) extras
      // builtins.listToAttrs (map (x: { name = extras.${x}.hashArg; value = extras.${x}.narHash; })
        (builtins.attrNames extras))
      // (if spec ? package then { inherit (spec) package; } else { })
      // (if spec.usesDocPlugins or false then { inherit docPlugins; } else { });
    in
    check name spec (import (src + "/${spec.recipe}") args);

  # A CI release: velrune-release's entry.nix call. Its own source is `nix flake prefetch`'s
  # snapshot (named "source"), passed as a path value (`--arg self (/. + "/nix/store/…")`),
  # which Nix copies into the store once more (as <hash>-source) where the recipe uses it;
  # the same is done here, or the derivation would differ from the released one.
  releaseNixpkgs = builtins.fetchTree ({ type = "github"; } // release.nixpkgs);
  released = name: spec:
    let
      snapshot = fetch (spec.src // { name = "source"; });
      self = /. + builtins.unsafeDiscardStringContext "${snapshot}";
    in
    check name spec (import (snapshot + "/${spec.recipe}") {
      nixpkgsSource = releaseNixpkgs;
      ${spec.arg} = self;
      gitSources = withPaths spec.gitSources;
      native = true;
    });
  releasedApps = builtins.mapAttrs released (release.apps or { });

  # The Shell's recipe: { snapshots, shell, nixpkgs } (nixpkgs defaults to its ci/flake.lock).
  shell = spec:
    let
      src = fetch spec.src;
      snapshotName = url: builtins.replaceStrings [ ".git" ] [ "" ] (baseNameOf url);
    in
    check "shell" spec (import (src + "/${spec.recipe}") {
      shell = src;
      snapshots = builtins.listToAttrs (map (g: { name = snapshotName g.url; value = fetch g; }) spec.gitSources);
    });
in
{
  apps = builtins.mapAttrs app (removeAttrs data.apps (builtins.attrNames releasedApps)) // releasedApps;
  # Each app's pinned source tree, for parts other than the app itself (Messages' oFono plugin).
  sources = builtins.mapAttrs (_: spec: fetch spec.src) (data.apps // (release.apps or { }));
  shell = if release ? shell then released "shell" release.shell else shell data.shell;
  # Velrune System's source (system-pin.nix): its NixOS modules and application registry.
  system = fetch systemPin;
  # What each component is and where its pin comes from (check-session.nix, nix eval).
  inventory = builtins.mapAttrs (_: spec: { out = spec.out; from = "apps.nix"; }) data.apps
    // builtins.mapAttrs (_: spec: { inherit (spec) out version id; from = "release channel ${toString release.channel.serial}"; }) (release.apps or { })
    // { shell = if release ? shell
                 then { inherit (release.shell) out version id; from = "release channel ${toString release.channel.serial}"; }
                 else { out = data.shell.out; from = "apps.nix"; }; };
}
