# Velrune System, the repository that composes the OS: the image imports its NixOS
# modules (velrune-session.nix) and takes its first-party application registry
# (packaging/applications.json). Pinned by commit and NAR hash like every other source;
# fetched from GitHub (or its git-mirrors.nix clone) by velrune-apps.nix.
# System main 0.1.53: session module with chargeLimit (decision 0118) and
# monochromeEmoji (decision 0119).
{
  url = "https://github.com/URunDEAD-Labs/velrune-system.git";
  rev = "d29301dbb43c59927229e57aba26d2bbfdfc9ee5";
  narHash = "sha256-FUUtkBvbL+HlHEdxybLbqTgCN7E2FT45B1DZ3C7mYYk=";
}
