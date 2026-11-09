# velrune-gen-apps DIR PROFILE OWNER
#
# Turns org.velrune.*.desktop in PROFILE/share/applications into format-1 Shell
# manifests in DIR (replaced as a whole, atomically), owned by OWNER. Interim until
# the Shell discovers desktop entries itself (shell-plan T14). PATH is set by the
# Nix wrapper (coreutils, gawk). Never fails the session start: an entry it cannot
# turn into a manifest is skipped and logged.
set -u
dir="$1"; profile="$2"; owner="$3"
tmp="$dir.new.$$"
rm -rf "$tmp"; mkdir -p "$tmp"

for f in "$profile"/share/applications/org.velrune.*.desktop; do
  [ -e "$f" ] || continue
  base=$(basename "$f" .desktop)
  # org.velrune.DocViewer -> docviewer
  id=$(printf '%s' "${base#org.velrune.}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n-' '-')
  awk -v id="$id" -v profile="$profile" -v out="$tmp/$id.toml" '
    function q(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
    /^\[/ { in_entry = ($0 == "[Desktop Entry]"); next }
    !in_entry { next }
    /^Name=/       { name = substr($0, 6) }
    /^Icon=/       { icon = substr($0, 6) }
    /^Exec=/       { exec_line = substr($0, 6) }
    /^Categories=/ { cats = substr($0, 12) }
    /^(NoDisplay|Hidden)=true/ { hidden = 1 }
    /^Type=/       { type = substr($0, 6) }
    END {
      if (hidden || type != "Application" || exec_line == "" || name == "") exit 3
      if (exec_line ~ /["\\\047]/) exit 4          # quoting or escapes: not worth guessing
      gsub(/%[a-zA-Z%]/, "", exec_line)            # field codes (%u %F ...) mean nothing to the Shell
      n = split(exec_line, w, /[ \t]+/)
      cmd = ""; na = 0
      for (i = 1; i <= n; i++) { if (w[i] == "") continue; if (cmd == "") cmd = w[i]; else args[++na] = w[i] }
      if (cmd == "") exit 4
      if (cmd !~ /^\//) cmd = profile "/bin/" cmd
      # The Shell accepts: communication media utility productivity system games other.
      category = "utility"
      if      (cats ~ /(^|;)(Telephony|Email|Network|InstantMessaging|Chat|ContactManagement)(;|$)/) category = "communication"
      else if (cats ~ /(^|;)(Settings|System)(;|$)/)                                               category = "system"
      else if (cats ~ /(^|;)Game(;|$)/)                                                            category = "games"
      else if (cats ~ /(^|;)(AudioVideo|Audio|Video|Graphics|Photography)(;|$)/)                   category = "media"
      else if (cats ~ /(^|;)(Office|Calendar|TextEditor)(;|$)/)                                    category = "productivity"
      printf "format = 1\nid = %s\nkind = \"app\"\nname = %s\n", q(id), q(name) > out
      if (icon != "") printf "icon = %s\n", q(icon) > out
      printf "categories = [\"%s\"]\nexec = %s\nargs = [", category, q(cmd) > out
      for (i = 1; i <= na; i++) printf "%s%s", (i > 1 ? ", " : ""), q(args[i]) > out
      printf "]\n" > out
    }' "$f"
  rc=$?
  [ "$rc" -eq 0 ] && continue
  rm -f "$tmp/$id.toml"
  [ "$rc" -eq 3 ] || echo "velrune-gen-apps: skipped $f (awk exit $rc)"
done

chown -R "$owner" "$tmp"
rm -rf "$dir"
mv "$tmp" "$dir"
echo "velrune-gen-apps: $(ls "$dir" | wc -l) apps from $profile in $dir"
