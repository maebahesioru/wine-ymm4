#!/bin/bash
# BlueArchive 用ネットワーク名前空間のセットアップ（冪等・root で実行）
#
# 目的: Mullvad VPN（DAITA / Multihop / PQ を含む）の設定を一切変えずに、
#       ゲームの XIGNCODE NEO が wg0 インターフェースを検知しないよう
#       専用 netns に隔離して素の回線から出る。
set -e
NS=ba
HOST_IF=vba
NS_IF=vbn
HOST_ADDR=10.200.0.1/24
NS_ADDR=10.200.0.2/24
UPLINK=$(ip route show default | awk '{print $5; exit}')
UPLINK=${UPLINK:-enp34s0}

# netns
ip netns list | grep -qw "$NS" || ip netns add "$NS"

# veth
if ! ip link show "$HOST_IF" >/dev/null 2>&1; then
  ip link add "$HOST_IF" type veth peer name "$NS_IF"
  ip link set "$NS_IF" netns "$NS"
fi
ip addr replace "$HOST_ADDR" dev "$HOST_IF"
ip link set "$HOST_IF" up
ip netns exec "$NS" ip addr replace "$NS_ADDR" dev "$NS_IF"
ip netns exec "$NS" ip link set "$NS_IF" up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip route replace default via 10.200.0.1

# DNS（host の resolv.conf は 127.0.0.53 なので上流を直書き）
mkdir -p /etc/netns/$NS
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/netns/$NS/resolv.conf

# Mullvad の split-tunnel マーク/ctmark を与えて「除外扱い」にし、UP リンク経由で NAT
nft delete table inet ba_ns 2>/dev/null || true
nft add table inet ba_ns
nft add chain inet ba_ns pre '{ type filter hook prerouting priority mangle; policy accept; }'
nft add rule inet ba_ns pre iifname "$HOST_IF" ct mark set 0x00000f41 meta mark set 0x6d6f6c65
nft add chain inet ba_ns post '{ type nat hook postrouting priority srcnat; policy accept; }'
nft add rule inet ba_ns post oifname "$UPLINK" ip saddr 10.200.0.0/24 masquerade

# libvirt 等の FORWARD drop を回避（これが無いと TCP だけ silently drop される）
iptables -C FORWARD -s 10.200.0.0/24 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -s 10.200.0.0/24 -j ACCEPT
iptables -C FORWARD -d 10.200.0.0/24 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -d 10.200.0.0/24 -j ACCEPT

echo "ba-netns ready (uplink=$UPLINK)"
