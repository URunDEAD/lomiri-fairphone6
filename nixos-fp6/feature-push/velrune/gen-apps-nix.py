#!/usr/bin/env python3
"""Writes velrune/apps.nix: the Velrune apps of the phone, as source pins.

usage: gen-apps-nix.py MIRRORS STORE_PATH... > apps.nix
       (MIRRORS: git-mirrors.nix, or a JSON file of the same map)

For each given aarch64 app build (a store path built by its repo's device recipe) this
reads the build's derivation and records how to rebuild exactly that output from git:

  * the app's own source: its repository, the commit whose tree has the same NAR hash as
    the source the build used, and that hash;
  * the recipe file in that source and the argument name it takes the source under;
  * every git dependency in the source's Cargo.lock (url, commit, NAR hash of the tree);
  * extra source arguments some recipes take (Files and Gallery: docviewer; Camera:
    hardware), found the same way;
  * the expected output path, which velrune-apps.nix checks after evaluation.

Nothing is guessed: a commit is accepted only when its tree hashes to the NAR hash the
build used, so evaluating apps.nix gives back the same derivations and output paths.
MIRRORS maps each canonical git URL to a local clone that holds the commits; it is
used only to find commits and hash trees, never written into apps.nix.
"""
import json, os, re, subprocess, sys, tempfile

NIXPKGS = {"owner": "NixOS", "repo": "nixpkgs",
           "rev": "31ecbaca1bdefa45dffc409f0250bd8039ea0010",
           "narHash": "sha256-dhoW6VgFWlaodSY5jrBn+CF2FLmaUvDVgM7+C7T2+NM="}

# pname -> (app key, canonical url of the app's repository, recipe argument name)
APPS = {
    "velrune-chat": ("chat", "https://gitlab.com/velrune/applications/chat.git", "chat"),
    "velrune-phone-app": ("phone", "https://gitlab.com/velrune/applications/phone.git", "phone"),
    "velrune-docviewer-device": ("docviewer", "https://gitlab.com/velrune/applications/docviewer.git", "docviewer"),
    "velrune-gallery-device": ("gallery", "https://gitlab.com/velrune/applications/gallery.git", "gallery"),
    "velrune-email-device": ("email", "https://gitlab.com/velrune/applications/email.git", "email"),
    "velrune-files-device": ("files", "https://gitlab.com/velrune/applications/files-app.git", "files"),
    "velrune-contacts-device": ("contacts", "https://gitlab.com/velrune/applications/contacts.git", "contacts"),
    "velrune-messages-device": ("messages", "https://gitlab.com/velrune/applications/messages.git", "messages"),
    "velrune-notes-device": ("notes", "https://gitlab.com/velrune/applications/notes.git", "notes"),
    "velrune-calendar-device": ("calendar", "https://gitlab.com/velrune/applications/calendar.git", "calendar"),
    "velrune-clock-device": ("clock", "https://gitlab.com/velrune/applications/clock.git", "clock"),
    "velrune-reminders-device": ("reminders", "https://gitlab.com/velrune/applications/reminders.git", "reminders"),
    "velrune-settings-device": ("settings", "https://gitlab.com/velrune/applications/settings.git", "settings"),
    "velrune-calculator-device": ("calculator", "https://gitlab.com/velrune/applications/calculator.git", "calculator"),
    "velrune-camera-device": ("camera", "https://gitlab.com/velrune/applications/camera.git", "camera"),
    "velrune-consent": ("consent", "https://gitlab.com/velrune/core.git", "core"),
    # The Shell's recipe takes { snapshots, shell, nixpkgs } instead (see velrune-apps.nix).
    "velrune-shell-direct": ("shell", "https://gitlab.com/velrune/shell.git", "shell"),
}
# Extra source arguments: recipe argument -> (canonical url, NAR-hash argument or None)
EXTRAS = {
    "docviewer": ("https://gitlab.com/velrune/applications/docviewer.git", "docviewerNarHash"),
    "hardware": ("https://gitlab.com/urundead-labs/linux-handsets/fairphone6.git", "hardwareNarHash"),
}
RECIPES = ["ci/cross-device.nix", "ci/cross-phone-app.nix", "ci/cross-phone.nix"]


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def nar_hash(path):
    info = json.loads(run("nix", "path-info", "--json", "--json-format", "1", path))
    return next(iter(info.values()))["narHash"]


def tree_of(repo, path):
    """The git tree id the files under PATH would have, computed in REPO's object store."""
    with tempfile.TemporaryDirectory() as tmp:
        # New objects go to a scratch object directory; the clone is only read.
        objects = os.path.join(tmp, "objects")
        os.makedirs(objects)
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(tmp, "index"), GIT_OBJECT_DIRECTORY=objects,
                   GIT_ALTERNATE_OBJECT_DIRECTORIES=os.path.join(git_dir(repo), "objects"))
        run("git", "--git-dir", git_dir(repo), "--work-tree", path,
            "-c", "core.excludesFile=/dev/null", "add", "-A", "-f", ".", env=env)
        return run("git", "--git-dir", git_dir(repo), "write-tree", env=env).strip()


def git_dir(repo):
    return run("git", "-C", repo, "rev-parse", "--absolute-git-dir").strip()


def commit_for(repo, path):
    """A commit of REPO whose tree is exactly PATH's content, or None."""
    tree = tree_of(repo, path)
    for line in run("git", "-C", repo, "log", "--all", "--format=%H %T").splitlines():
        commit, t = line.split()
        if t == tree:
            return commit
    return None


def subtree_commit(repo, prefix, path):
    """A commit of REPO whose PREFIX subtree is exactly PATH's content, or None."""
    tree = tree_of(repo, path)
    for commit in run("git", "-C", repo, "log", "--all", "--format=%H").split():
        got = subprocess.run(["git", "-C", repo, "rev-parse", "-q", "--verify", f"{commit}:{prefix}"],
                             capture_output=True, text=True).stdout.strip()
        if got == tree:
            return commit
    return None


_tree_hash = {}
def tree_nar_hash(mirror, rev):
    key = (mirror, rev)
    if key not in _tree_hash:
        expr = f'(builtins.fetchGit {{ url = "file://{mirror}"; rev = "{rev}"; allRefs = true; }}).narHash'
        _tree_hash[key] = json.loads(run("nix-instantiate", "--eval", "--json", "-E", expr))
    return _tree_hash[key]


def nix_str(s):
    return json.dumps(s)


def main():
    if sys.argv[1].endswith(".nix"):
        mirrors = json.loads(run("nix-instantiate", "--eval", "--strict", "--json", sys.argv[1]))
    else:
        mirrors = json.load(open(sys.argv[1]))
    entries = []
    for out in sys.argv[2:]:
        drv = run("nix-store", "-q", "--deriver", out).strip()
        env = next(iter(json.loads(run("nix", "derivation", "show", drv))["derivations"].values()))["env"]
        key, url, arg = APPS[env["pname"]]
        src = env["src"]
        rev = commit_for(mirrors[url], src)
        if rev is None:
            sys.exit(f"{out}: no commit of {url} has the tree of {src}")
        recipe = next(r for r in RECIPES if os.path.exists(os.path.join(src, r)))
        lock = open(os.path.join(src, "Cargo.lock")).read()
        deps = sorted(set(re.findall(r'git\+([^"?#]+)\?[^"#]*#([0-9a-f]{40})', lock)))
        git = [{"url": u, "rev": r, "narHash": tree_nar_hash(mirrors[u], r)} for u, r in deps]
        # Extra source arguments: the recipe's own NAR-hash argument names the content.
        recipe_text = open(os.path.join(src, recipe)).read()
        # The recipe's argument set: the first "{ ... }:" at the start of a line.
        m = re.search(r"^\{([^}]*)\}:", recipe_text, re.M)
        header = m.group(1) if m else ""
        extras = []
        closure = run("nix-store", "-qR", drv).split()
        for name, (xurl, hash_arg) in EXTRAS.items():
            if not re.search(rf"\b{name}\b", header) or name == arg:
                continue
            # The recipe copies the argument to the store under a fixed name; that copy, in
            # the build's closure, is the content the build used.
            store_name = re.search(rf"path = {name};\s*name = \"([^\"]+)\"", recipe_text).group(1)
            found = [q for q in closure if q.endswith("-" + store_name) and not q.endswith(".drv")]
            if len(found) != 1:
                sys.exit(f"{out}: expected one {store_name} in the closure, found {found}")
            xrev, keep = commit_for(mirrors[xurl], found[0]), None
            if xrev is None:
                # A `git archive <rev> <dir>` snapshot: only one subtree, under its own path.
                keep, inner = "", found[0]
                while len(os.listdir(inner)) == 1 and os.path.isdir(os.path.join(inner, os.listdir(inner)[0])):
                    keep = os.path.join(keep, os.listdir(inner)[0]); inner = os.path.join(found[0], keep)
                xrev = subtree_commit(mirrors[xurl], keep, inner) if keep else None
            if xrev is None:
                sys.exit(f"{out}: no commit of {xurl} has the tree of {found[0]}")
            extras.append((name, xurl, hash_arg, xrev, nar_hash(found[0]), keep))
            # The recipe also vendors the extra source's own git dependencies (Docviewer's
            # Cargo.lock for the document plugins), from the same gitSources list.
            xlock = os.path.join(found[0], "Cargo.lock")
            if os.path.exists(xlock):
                for u, r in sorted(set(re.findall(r'git\+([^"?#]+)\?[^"#]*#([0-9a-f]{40})', open(xlock).read()))):
                    if not any(g["url"] == u and g["rev"] == r for g in git):
                        git.append({"url": u, "rev": r, "narHash": tree_nar_hash(mirrors[u], r)})
        closure = run("nix-store", "-qR", drv).split()
        if key == "shell":
            # Its own nixpkgs pin (ci/flake.lock); velrune-apps.nix reads it from the source.
            extras = []
        # Files, Docviewer and Gallery take one shared document-plugins package, built from
        # Docviewer's source (ci/cross-doc-plugins.nix): record the one this build used.
        doc_plugins = None
        if re.search(r"\bdocPlugins\b", header):
            found = [q for q in closure if re.search(r"-velrune-doc-plugins-[^/]*\.drv$", q)]
            if len(found) != 1:
                sys.exit(f"{out}: expected one doc-plugins derivation in the closure, found {found}")
            doc_plugins = run("nix-store", "-q", "--outputs", found[0]).split()[0]
        entry = {"key": key, "out": out, "arg": arg, "recipe": recipe, "docPlugins": doc_plugins,
                 "src": {"url": url, "rev": rev, "name": src.split("-", 1)[1], "narHash": nar_hash(src)},
                 "gitSources": git, "extras": extras,
                 "package": env["pname"] if env["pname"] == "velrune-consent" else None}
        entries.append(entry)

    w = sys.stdout.write
    w("# Generated by gen-apps-nix.py from the app builds on the phone. Do not edit by hand:\n")
    w("# rerun the generator with the new store paths. Every source is a git commit pinned by\n")
    w("# the NAR hash of its tree; velrune-apps.nix rebuilds each app from these pins and\n")
    w("# checks that the result is the recorded output path.\n{\n")
    w(f"  nixpkgs = {{ owner = {nix_str(NIXPKGS['owner'])}; repo = {nix_str(NIXPKGS['repo'])};\n"
      f"    rev = {nix_str(NIXPKGS['rev'])}; narHash = {nix_str(NIXPKGS['narHash'])}; }};\n")
    plugins = sorted({e["docPlugins"] for e in entries if e["docPlugins"]})
    if len(plugins) > 1:
        sys.exit(f"the apps use different doc-plugins builds: {plugins}")
    if plugins:
        w("  # Built from apps.docviewer's source with ci/cross-doc-plugins.nix; shared by the apps\n")
        w("  # marked usesDocPlugins, so the system holds one copy.\n")
        w(f"  docPlugins = {{ out = {nix_str(plugins[0])}; recipe = \"ci/cross-doc-plugins.nix\"; }};\n")
    w("  apps = {\n")
    for e in [e for e in entries if e["key"] != "shell"] + [e for e in entries if e["key"] == "shell"]:
        if e["key"] == "shell":
            w("  };\n  # The Shell (velrune-compositor and velrune-shell), the session's default.\n  shell = {\n")
        s = e["src"]
        if e["key"] != "shell":
            w(f"    {e['key']} = {{\n")
        w(f"      out = {nix_str(e['out'])};\n")
        w(f"      recipe = {nix_str(e['recipe'])}; arg = {nix_str(e['arg'])};\n")
        if e["docPlugins"]:
            w("      usesDocPlugins = true;\n")
        if e["package"]:
            w(f"      package = {nix_str(e['package'])};\n")
        w(f"      src = {{ url = {nix_str(s['url'])}; rev = {nix_str(s['rev'])};\n"
          f"        name = {nix_str(s['name'])}; narHash = {nix_str(s['narHash'])}; }};\n")
        if e["extras"]:
            w("      extras = {\n")
            for name, xurl, hash_arg, xrev, xhash, keep in e["extras"]:
                w(f"        {name} = {{ url = {nix_str(xurl)}; rev = {nix_str(xrev)};\n"
                  f"          narHash = {nix_str(xhash)}; hashArg = {nix_str(hash_arg)};"
                  + (f" keep = {nix_str(keep)};" if keep else "") + " };\n")
            w("      };\n")
        w("      gitSources = [\n")
        for g in e["gitSources"]:
            w(f"        {{ url = {nix_str(g['url'])}; rev = {nix_str(g['rev'])}; narHash = {nix_str(g['narHash'])}; }}\n")
        w("      ];\n    };\n" if e["key"] != "shell" else "      ];\n")
    if not any(e["key"] == "shell" for e in entries):
        w("  };\n")
    w("  };\n}\n" if any(e["key"] == "shell" for e in entries) else "}\n")


if __name__ == "__main__":
    main()
