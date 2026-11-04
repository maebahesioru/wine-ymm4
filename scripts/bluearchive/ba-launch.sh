#!/bin/bash
# ブルーアーカイブ(JP) を Mullvad VPN 有効のまま起動するランチャー（ユーザー側の入口・.desktop から呼ばれる）
# 実体は root 側ラッパー /usr/local/sbin/ba-launch-root を sudo NOPASSWD で呼ぶだけ。
# netns の用意・環境変数の収集・systemd-run はすべてラッパー側で行う。
set -u

if ! sudo -n true 2>/dev/null; then
  kdialog --title "ブルーアーカイブ" --error "sudo の設定が見つかりません。ターミナルで次を実行してください: sudo /usr/local/sbin/ba-launch-root" 2>/dev/null
  exit 1
fi

sudo -n /usr/local/sbin/ba-launch-root
rc=$?
if [ $rc -eq 3 ]; then
  notify-send -a "ブルーアーカイブ" "すでに起動中です" 2>/dev/null
elif [ $rc -ne 0 ]; then
  kdialog --title "ブルーアーカイブ" --error "起動に失敗しました（exit $rc）。ターミナルで次を実行すると詳細が出ます: sudo /usr/local/sbin/ba-launch-root" 2>/dev/null
fi
exit $rc
