# Where each pinned repository is fetched from since GitLab was archived (2026-11-19).
#
# Keys are the repositories' old gitlab.com URLs. They stay in apps.nix's gitSources because
# that is how the pinned Cargo.lock files name them (the recipes match a snapshot to a lock
# entry by that URL and revision), but nothing is fetched from them: velrune-apps.nix
# fetches every source from the value here (or its local mirror, git-mirrors.nix) and
# stops on a gitlab.com URL that has no entry. Same commits, checked by the same NAR
# hashes, so every derivation and output path is unchanged.
{
  "https://gitlab.com/urundead-labs/linux-handsets/fairphone6.git" = "https://github.com/URunDEAD/linux-fairphone6.git";
  "https://gitlab.com/velrune/applications/calculator.git" = "https://github.com/URunDEAD-Labs/velrune-calculator.git";
  "https://gitlab.com/velrune/applications/calendar.git" = "https://github.com/URunDEAD-Labs/velrune-calendar.git";
  "https://gitlab.com/velrune/applications/camera.git" = "https://github.com/URunDEAD-Labs/velrune-camera.git";
  "https://gitlab.com/velrune/applications/chat.git" = "https://github.com/URunDEAD-Labs/velrune-chat.git";
  "https://gitlab.com/velrune/applications/clock.git" = "https://github.com/URunDEAD-Labs/velrune-clock.git";
  "https://gitlab.com/velrune/applications/contacts.git" = "https://github.com/URunDEAD-Labs/velrune-contacts.git";
  "https://gitlab.com/velrune/applications/docviewer.git" = "https://github.com/URunDEAD-Labs/velrune-docviewer.git";
  "https://gitlab.com/velrune/applications/email.git" = "https://github.com/URunDEAD-Labs/velrune-email.git";
  "https://gitlab.com/velrune/applications/files-app.git" = "https://github.com/URunDEAD-Labs/velrune-files.git";
  "https://gitlab.com/velrune/applications/gallery.git" = "https://github.com/URunDEAD-Labs/velrune-gallery.git";
  "https://gitlab.com/velrune/applications/messages.git" = "https://github.com/URunDEAD-Labs/velrune-messages.git";
  "https://gitlab.com/velrune/applications/notes.git" = "https://github.com/URunDEAD-Labs/velrune-notes.git";
  "https://gitlab.com/velrune/applications/phone.git" = "https://github.com/URunDEAD-Labs/velrune-phone.git";
  "https://gitlab.com/velrune/applications/reminders.git" = "https://github.com/URunDEAD-Labs/velrune-reminders.git";
  "https://gitlab.com/velrune/applications/settings.git" = "https://github.com/URunDEAD-Labs/velrune-settings.git";
  "https://gitlab.com/velrune/core.git" = "https://github.com/URunDEAD-Labs/velrune-core.git";
  "https://gitlab.com/velrune/intelligence.git" = "https://github.com/URunDEAD-Labs/velrune-intelligence.git";
  "https://gitlab.com/velrune/media.git" = "https://github.com/URunDEAD-Labs/velrune-media.git";
  "https://gitlab.com/velrune/shell.git" = "https://github.com/URunDEAD-Labs/velrune-shell.git";
  "https://gitlab.com/velrune/system.git" = "https://github.com/URunDEAD-Labs/velrune-system.git";
  "https://gitlab.com/velrune/velrune-ui.git" = "https://github.com/URunDEAD-Labs/velrune-ui.git";
}
