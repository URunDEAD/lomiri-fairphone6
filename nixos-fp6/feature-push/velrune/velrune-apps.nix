# Builds the Velrune apps and the Shell of apps.nix from their pinned git sources.
#
# Each package is its repository's own aarch64 recipe (ci/cross-device.nix and the
# like), called the way the app teams call it, with every source fetched by commit and
# checked against the NAR hash of its tree. The result must be the output path recorded
# in apps.nix (the build that is on the phone); a mismatch stops evaluation, so a pin can
# never silently produce a different app.
#
# mirrors: { "<canonical git url>" = "/local/clone"; }. A mirror is used when its folder
# exists (this desktop's clones hold every pinned commit); otherwise the canonical URL
# is fetched, which for the private gitlab.com repositories needs credentials in git's
# own configuration. The content is the same either way: the NAR hash decides.
# checkOutputs = false skips the output-path check (to inspect a mismatch).
{ data ? import ./apps.nix, mirrors ? import ./git-mirrors.nix, checkOutputs ? true }:
let
  mirror = url:
    if mirrors ? ${url} && builtins.pathExists mirrors.${url} then "file://${mirrors.${url}}" else url;
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
  apps = builtins.mapAttrs app data.apps;
  # Each app's pinned source tree, for parts other than the app itself (Messages' oFono plugin).
  sources = builtins.mapAttrs (_: spec: fetch spec.src) data.apps;
  shell = shell data.shell;
}
