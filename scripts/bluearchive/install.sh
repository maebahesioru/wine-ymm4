#!/bin/bash
# ba-netns / ba-launch 一式をこのマシンに設置する（冪等・要 sudo）
#   ./install.sh            … 設置のみ
#   ./install.sh --uninstall … 撤去
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUDO=${SUDO:-sudo}

install_all() {
  # 1. root 側: netns セットアップ + systemd unit
  "$SUDO" install -Dm755 "$HERE/ba-netns-setup.sh" /usr/local/sbin/ba-netns-setup.sh
  "$SUDO" install -Dm644 "$HERE/ba-netns.service" /etc/systemd/system/ba-netns.service
  "$SUDO" systemctl daemon-reload
  "$SUDO" systemctl enable ba-netns.service

  # 2. ユーザー側: ランチャー + .desktop（@HOME@ を実パスへ展開）
  install -Dm755 "$HERE/ba-launch.sh" "$HOME/.local/bin/ba-launch.sh"
  mkdir -p "$HOME/.local/share/applications"
  sed "s|@HOME@|$HOME|g" "$HERE/bluearchive.desktop" \
    > "$HOME/.local/share/applications/bluearchive.desktop"
  chmod 644 "$HOME/.local/share/applications/bluearchive.desktop"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$HOME/.local/share/applications" || true

  echo "設置しました:"
  echo "  /usr/local/sbin/ba-netns-setup.sh"
  echo "  /etc/systemd/system/ba-netns.service (enabled)"
  echo "  $HOME/.local/bin/ba-launch.sh"
  echo "  $HOME/.local/share/applications/bluearchive.desktop"
  echo
  echo "ゲーム本体の場所（既定 ~/Games/DMM/drive_c/YostarGames/BlueArchive_JP）が違う場合は"
  echo "ba-launch.sh の GAME_DIR を書き換えてください。"
}

uninstall_all() {
  "$SUDO" systemctl disable --now ba-netns.service 2>/dev/null || true
  "$SUDO" rm -f /etc/systemd/system/ba-netns.service /usr/local/sbin/ba-netns-setup.sh
  "$SUDO" systemctl daemon-reload
  "$SUDO" ip netns delete ba 2>/dev/null || true
  rm -f "$HOME/.local/bin/ba-launch.sh" "$HOME/.local/share/applications/bluearchive.desktop"
  echo "撤去しました（/etc/netns/ba は残置。不要なら sudo rm -rf /etc/netns/ba）"
}

case "${1:-}" in
  --uninstall) uninstall_all ;;
  "") install_all ;;
  *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac
