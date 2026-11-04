#!/bin/bash
# ブルーアーカイブ(JP) の netns 隔離 + メニュー/パネル起動 一式を設置する（冪等・要 root）
#
#   sudo ./install.sh              … 設置（netns・root ラッパー・sudoers・ランチャー・メニュー・アイコン）
#   sudo ./install.sh --uninstall  … 撤去
#   sudo ./install.sh --dry-run     … 何をするかだけ表示
#
# sudo 経由で呼ばれると HOME=/root になるため、設置先は必ず「呼び出した
# ユーザー」のホームから求める（TARGET_USER / TARGET_HOME）。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SUDO=${SUDO:-sudo}
[ "$(id -u)" = 0 ] && SUDO=""
TARGET_USER=${SUDO_USER:-$(id -un)}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TARGET_GROUP=$(id -gn "$TARGET_USER")
TARGET_UID=$(id -u "$TARGET_USER")
if [ -z "${TARGET_HOME:-}" ] || [ ! -d "$TARGET_HOME" ]; then
  echo "設置先ユーザーのホームが分かりません（TARGET_USER=$TARGET_USER）" >&2
  exit 1
fi
BIN_DIR="$TARGET_HOME/.local/bin"
APP_DIR="$TARGET_HOME/.local/share/applications"
ICON_SRC_DIR="$TARGET_HOME/.local/share/icons/bluearchive"
HICOLOR="$TARGET_HOME/.local/share/icons/hicolor"
ROOT_LAUNCHER=/usr/local/sbin/ba-launch-root
SUDOERS_FILE=/etc/sudoers.d/bluearchive
EXE="$TARGET_HOME/Games/DMM/drive_c/YostarGames/BlueArchive_JP_Gamelauncher/BlueArchive_JP_Gamelauncher.exe"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

run() { if [ "$DRY" = 1 ]; then echo "+ $*"; else "$@"; fi; }
asuser() { run $SUDO -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$TARGET_UID" "$@"; }

# ゲーム同梱の .ico からアロナのアイコンを取り出して hicolor に置く。
# ICO 内の大きなエントリは壊れていることがあり、その状態で icotool -x を一括実行すると
# 全滅するため、1 枚ずつ取り出して pngcheck.py で実体検証してから採用する。
# 取り出せない環境（icoutils 無し等）では既定アイコン（applications-games）のままで動く。
install_icons() {
  if ! command -v icotool >/dev/null 2>&1; then
    echo "icotool が無いのでアイコンは既定のままにします（pacman -S icoutils）" >&2
    return 0
  fi
  local ico="$ICON_SRC_DIR/BlueArchive_JP_Gamelauncher.exe_14_1.ico"
  local tmp; tmp=$(mktemp -d)
  if [ ! -f "$ico" ] && [ -f "$EXE" ] && command -v wrestool >/dev/null 2>&1; then
    run $SUDO install -dm755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$ICON_SRC_DIR"
    run $SUDO -u "$TARGET_USER" wrestool -x -t14 -o "$ico" "$EXE" >/dev/null 2>&1 || rm -f "$ico"
  fi
  if [ ! -f "$ico" ]; then
    echo "アイコン素材（.ico）が見つからないため既定アイコンのままにします" >&2
    rm -rf "$tmp"; return 0
  fi

  local idxs idx f wh n=0
  idxs=$(icotool -l "$ico" 2>/dev/null | grep -o "index=[0-9]\+" | cut -d= -f2 || true)
  [ -n "$idxs" ] || idxs="1 2 3 4 5 6 7 8 9 10"
  for idx in $idxs; do
    mkdir -p "$tmp/i$idx"
    icotool -x -i "$idx" -o "$tmp/i$idx" "$ico" >/dev/null 2>&1 || true   # 壊れたエントリがあると rc=1 だが PNG は出る
    for f in "$tmp/i$idx"/*.png; do
      [ -f "$f" ] || continue
      wh=$(python3 "$HERE/pngcheck.py" "$f" 2>/dev/null) || { echo "壊れたアイコンをスキップ: $(basename "$f")" >&2; continue; }
      run $SUDO install -Dm644 -o "$TARGET_USER" -g "$TARGET_GROUP" "$f" "$HICOLOR/$wh/apps/bluearchive.png"
      n=$((n + 1))
    done
  done
  rm -rf "$tmp"
  if [ "$n" -gt 0 ]; then
    asuser gtk-update-icon-cache -f -t "$HICOLOR" >/dev/null 2>&1 || true
    echo "アイコンを $n サイズ設置しました（$HICOLOR/*/apps/bluearchive.png）"
  else
    echo "アイコンの抽出に失敗したため既定アイコンのままにします" >&2
  fi
}

install_all() {
  # 1. root 側: netns セットアップ + systemd unit + root ラッパー
  run $SUDO install -Dm755 "$HERE/ba-netns-setup.sh" /usr/local/sbin/ba-netns-setup.sh
  run $SUDO install -Dm644 "$HERE/ba-netns.service" /etc/systemd/system/ba-netns.service
  run $SUDO install -Dm755 "$HERE/ba-launch-root" "$ROOT_LAUNCHER"
  run $SUDO systemctl daemon-reload
  run $SUDO systemctl enable ba-netns.service >/dev/null 2>&1 || true

  # netns がまだ無ければ今すぐ作る（稼働中に作り直すと DL が止まるので、あれば触らない）
  if [ "$DRY" = 0 ] && ! ip netns list 2>/dev/null | sed "s/ .*//" | grep -qx ba; then
    $SUDO systemctl start ba-netns.service
  fi

  # 2. sudoers: 専用ラッパーだけをパスワード無しで許可（systemd-run を直接許可してはいけない）
  local tmpd; tmpd=$(mktemp)
  sed "s|@TARGET_USER@|$TARGET_USER|g" "$HERE/ba-sudoers.in" > "$tmpd"
  if [ "$DRY" = 1 ]; then
    echo "+ install -Dm440 (root:root) $SUDOERS_FILE"; cat "$tmpd"
  else
    visudo -cf "$tmpd" >/dev/null
    install -Dm440 -o root -g root "$tmpd" "$SUDOERS_FILE"
  fi
  rm -f "$tmpd"

  # 3. ユーザー側: 入口ランチャー + .desktop（@HOME@ を実パスへ展開）
  run $SUDO install -dm755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$BIN_DIR"
  run $SUDO install -Dm755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$HERE/ba-launch.sh" "$BIN_DIR/ba-launch.sh"
  run $SUDO install -dm755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$APP_DIR"
  sed "s|@HOME@|$TARGET_HOME|g" "$HERE/bluearchive.desktop" > "$HERE/.bluearchive.desktop.tmp"
  run $SUDO install -Dm644 -o "$TARGET_USER" -g "$TARGET_GROUP" "$HERE/.bluearchive.desktop.tmp" "$APP_DIR/bluearchive.desktop"
  rm -f "$HERE/.bluearchive.desktop.tmp"

  # 4. アイコン（取れなければ既定のまま）
  install_icons

  asuser update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
  asuser kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

  echo "設置しました（設置先ユーザー: $TARGET_USER）:"
  echo "  /usr/local/sbin/ba-netns-setup.sh"
  echo "  /etc/systemd/system/ba-netns.service (enabled)"
  echo "  $ROOT_LAUNCHER"
  echo "  $SUDOERS_FILE (0440)"
  echo "  $BIN_DIR/ba-launch.sh"
  echo "  $APP_DIR/bluearchive.desktop"
  echo "  $HICOLOR/*/apps/bluearchive.png"
  echo
  echo "メニュー（またはパネル）の「ブルーアーカイブ」から起動できます。"
  echo "ゲーム本体の場所（既定 ~/Games/DMM/drive_c/YostarGames/BlueArchive_JP）が違う場合は"
  echo "BA_GAME_DIR を指定するか $ROOT_LAUNCHER の GAME_DIR を書き換えてください。"
}

uninstall_all() {
  run $SUDO systemctl disable --now ba-netns.service 2>/dev/null || true
  run $SUDO rm -f /etc/systemd/system/ba-netns.service /usr/local/sbin/ba-netns-setup.sh
  run $SUDO rm -f "$ROOT_LAUNCHER" "$SUDOERS_FILE"
  run $SUDO systemctl daemon-reload
  run $SUDO ip netns delete ba 2>/dev/null || true
  run rm -f "$BIN_DIR/ba-launch.sh" "$APP_DIR/bluearchive.desktop"
  run rm -rf "$ICON_SRC_DIR"
  if [ -d "$HICOLOR" ]; then
    find "$HICOLOR" -path "*/apps/bluearchive.png" -delete 2>/dev/null || true
  fi
  asuser update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
  asuser kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  echo "撤去しました（/etc/netns/ba は残置。不要なら sudo rm -rf /etc/netns/ba）"
}

case "${1:-}" in
  --uninstall) uninstall_all ;;
  --dry-run) install_all ;;
  "") install_all ;;
  *) echo "usage: $0 [--uninstall|--dry-run]" >&2; exit 2 ;;
esac
