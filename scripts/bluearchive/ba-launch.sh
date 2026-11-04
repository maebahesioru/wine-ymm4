#!/bin/bash
# ブルーアーカイブ(JP) を Mullvad VPN 有効のまま起動するランチャー
# 仕組み: 専用 netns にゲームを隔離 → VPN の split-tunnel マークで素の回線から直接出る
#        （VPN 本体の DAITA / Multihop / Quantum-resistant は一切変更しない）
set -u
NS=ba
GAME_DIR="$HOME/Games/DMM/drive_c/YostarGames/BlueArchive_JP"
LAUNCHER=./xldr_BlueArchiveOnline_JP_loader_x64.exe
GAME=./BlueArchive.exe

if pgrep -f '[B]lueArchive.exe' >/dev/null; then
  echo "既に起動中です（'sudo systemctl stop ba-game*' で停止）" >&2
  exit 1
fi

# netns / NAT / DNS を毎回冪等に用意
sudo -n /usr/local/sbin/ba-netns-setup.sh || { echo "netns の準備に失敗" >&2; exit 1; }

# GUI 環境変数は systemd ユーザー環境から拾う（XAUTHORITY のパスはログインごとに変わる）
UE=$(systemctl --user show-environment)
XA=$(printf '%s\n' "$UE" | sed -n 's/^XAUTHORITY=//p')
DISP=$(printf '%s\n' "$UE" | sed -n 's/^DISPLAY=//p')
WL=$(printf '%s\n' "$UE" | sed -n 's/^WAYLAND_DISPLAY=//p')
XR=$(printf '%s\n' "$UE" | sed -n 's/^XDG_RUNTIME_DIR=//p')
: "${XA:=$(ls -t /run/user/$(id -u)/xauth_* 2>/dev/null | head -1)}"
: "${DISP:=:0}"; : "${WL:=wayland-1}"; : "${XR:=/run/user/$(id -u)}"

UNIT=ba-game$(date +%H%M%S)
sudo -n systemd-run --unit="$UNIT" --collect --property=Type=simple \
  --setenv=HOME="$HOME" --setenv=DISPLAY="$DISP" --setenv=WAYLAND_DISPLAY="$WL" \
  --setenv=XDG_RUNTIME_DIR="$XR" --setenv=XAUTHORITY="$XA" \
  --setenv=WINEPREFIX="$HOME/Games/DMM" --setenv=UMU_DATA_PATH="$HOME/Games/umu" --setenv=UMU_LOG=1 \
  --working-directory="$GAME_DIR" \
  /usr/bin/ip netns exec "$NS" /usr/bin/setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups \
  /usr/bin/umu-run "$LAUNCHER" "$GAME"

echo "起動しました: $UNIT（停止は sudo systemctl stop $UNIT）"
