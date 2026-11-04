#!/bin/bash
# ba-netns / ba-launch 一式をこのマシンに設置する（冪等・要 sudo）
#   ./install.sh            … 設置のみ
#   ./install.sh --uninstall … 撤去
#
# sudo 経由で呼ばれると HOME=/root になるため、設置先は必ず「呼び出した
# ユーザー」のホームから求める（TARGET_USER / TARGET_HOME）。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUDO=${SUDO:-sudo}
TARGET_USER=${SUDO_USER:-$(id -un)}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TARGET_GROUP=$(id -gn "$TARGET_USER")
if [ -z "${TARGET_HOME:-}" ] || [ ! -d "$TARGET_HOME" ]; then
  echo "設置先ユーザーのホームが分かりません（TARGET_USER=$TARGET_USER）" >&2
  exit 1
fi
BIN_DIR="$TARGET_HOME/.local/bin"
APP_DIR="$TARGET_HOME/.local/share/applications"

install_all() {
  # 1. root 側: netns セットアップ + systemd unit
  "$SUDO" install -Dm755 "$HERE/ba-netns-setup.sh" /usr/local/sbin/ba-netns-setup.sh
  "$SUDO" install -Dm644 "$HERE/ba-netns.service" /etc/systemd/system/ba-netns.service
  "$SUDO" systemctl daemon-reload
  "$SUDO" systemctl enable ba-netns.service >/dev/null 2>&1 || true

  # netns がまだ無ければ今すぐ作る（稼働中に作り直すと DL が止まるので、あれば触らない）
  if ! ip netns list 2>/dev/null | awk '{print $1}' | grep -qx ba; then
    "$SUDO" systemctl start ba-netns.service
  fi

  # 2. ユーザー側: ランチャー + .desktop（@HOME@ を実パスへ展開）
  "$SUDO" install -dm755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$BIN_DIR"
  "$SUDO" install -Dm755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$HERE/ba-launch.sh" "$BIN_DIR/ba-launch.sh"
  "$SUDO" install -dm755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$APP_DIR"
  sed "s|@HOME@|$TARGET_HOME|g" "$HERE/bluearchive.desktop" > "$HERE/bluearchive.desktop.tmp"
  "$SUDO" install -Dm644 -o "$TARGET_USER" -g "$TARGET_GROUP" "$HERE/bluearchive.desktop.tmp" "$APP_DIR/bluearchive.desktop"
  rm -f "$HERE/bluearchive.desktop.tmp"
  if command -v update-desktop-database >/dev/null 2>&1; then
    "$SUDO" -u "$TARGET_USER" update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
  fi

  echo "設置しました（設置先ユーザー: $TARGET_USER）:"
  echo "  /usr/local/sbin/ba-netns-setup.sh"
  echo "  /etc/systemd/system/ba-netns.service (enabled)"
  echo "  $BIN_DIR/ba-launch.sh"
  echo "  $APP_DIR/bluearchive.desktop"
  echo
  echo "ゲーム本体の場所（既定 ~/Games/DMM/drive_c/YostarGames/BlueArchive_JP）が違う場合は"
  echo "$BIN_DIR/ba-launch.sh の GAME_DIR を書き換えてください。"
}

uninstall_all() {
  "$SUDO" systemctl disable --now ba-netns.service 2>/dev/null || true
  "$SUDO" rm -f /etc/systemd/system/ba-netns.service /usr/local/sbin/ba-netns-setup.sh
  "$SUDO" systemctl daemon-reload
  "$SUDO" ip netns delete ba 2>/dev/null || true
  rm -f "$BIN_DIR/ba-launch.sh" "$APP_DIR/bluearchive.desktop"
  echo "撤去しました（/etc/netns/ba は残置。不要なら sudo rm -rf /etc/netns/ba）"
}

case "${1:-}" in
  --uninstall) uninstall_all ;;
  "") install_all ;;
  *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac