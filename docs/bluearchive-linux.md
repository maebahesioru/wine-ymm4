# ブルーアーカイブ（PC 版 / Yostar ランチャー）を Linux + Wine で動かす

2026-11-04 実測。**Mullvad VPN（DAITA・Multihop・Quantum-resistant すべて有効）のまま、
タイトル → ログイン → チュートリアル再生 → リソース 19,986.55MB のダウンロード完走**まで確認した構成。

- 対象: Blue Archive JP PC 版（Yostar の `BlueArchive_JP_Gamelauncher`）
- 環境: CachyOS（Arch 系）/ KDE Wayland / Proton は UMU-Proton-10.0-4 / プレフィックス `~/Games/DMM`
- ロンチは `umu-run`（素の Wine では Electron ランチャーのレンダラーが起動しない）

## 結論（先に要点）

1. **VP9 デコーダ MFT が無いと黒画面で固まる** → `patches/winegstreamer/` を当てた
   `winegstreamer.dll`/`.so` を配備する（詳細: [vp9-decoder-mft.md](vp9-decoder-mft.md)）。
2. **共有テクスチャ未対応だと `Got null handle from IDXGIResource::GetSharedHandle.` を延々と吐いて固まる**
   → `patches/mfplat/` + `patches/mfreadwrite/` の 3 点（詳細: [mf-shared-textures.md](mf-shared-textures.md)）。
3. **XIGNCODE NEO は「VPN が有効だと」必ず落ちる。原因は出口 IP ではなく `wg0` インターフェースの存在**
   → ゲームを専用 netns に隔離すれば、VPN 設定を一切変えずに通る（本ドキュメントの主眼）。
4. ランチャーの整合性チェックは改変ファイルを弾くので、**ゲーム本体は `BlueArchive.exe` を直起動**する。

## 症状 1: XIGNCODE NEO「セキュリティモジュールの初期化に失敗しました」

- `xm.exe` のエラーコードは **0xE0191009**（一般には「Security Program の更新失敗／容量不足か FW・AV ブロック」）。
- **容量説は否定**: ディスク空き 226G。
- **A/B 実測**: Mullvad を切ると通る／有効だと 2〜18 分で必ず失敗する。
- **出口 IP・ASN 説も否定**: 東京出口（`jp-tyo-wg-001` = 138.199.21.241, DataPacket）でも同じ。
- **split-tunnel（`mullvad-exclude`）では直らない**: 除外した curl は 120.75.187.71
  （自宅回線・`mullvad_exit_ip:false`）に直通するのに、Wine 側の socket は
  `getsockname` が 10.170.159.58（`wg0-mullvad`）のままで失敗する。除外は新規接続の一部にしか効かない。
- **真因の判断**: 経路ではなく **VPN インターフェース／デーモンの存在そのもの**。
  Wine の `iphlpapi` は Linux の全インターフェースをゲストに見せるため、アダプタ列挙で検知される。
- `xigncode.log` は暗号化されており解読不可（切り分けは上記の A/B のみで行った）。

## 解決: netns 隔離（VPN の設定は一切変更しない）

ゲームを専用ネットワーク名前空間に入れると `wg0` が見えないので XIGNCODE が通る。
DAITA / Multihop / PQ はそのまま維持される（VPN デーモンにも触らない）。

### 構成ファイル（`scripts/bluearchive/`）

| ファイル | 設置先 | 役割 |
|---|---|---|
| `ba-netns-setup.sh` | `/usr/local/sbin/` | netns + veth + NAT + DNS を冪等に用意（root） |
| `ba-netns.service` | `/etc/systemd/system/` | 起動時に上記を実行（oneshot + RemainAfterExit） |
| `ba-launch.sh` | `~/.local/bin/` | ゲームを netns 内で `umu-run` するランチャー |
| `bluearchive.desktop` | `~/.local/share/applications/` | メニュー登録 |
| `install.sh` | — | 上 4 つを設置／撤去する（要 sudo・冪等） |

```bash
sudo ./scripts/bluearchive/install.sh          # 設置
sudo ./scripts/bluearchive/install.sh --uninstall
```

ゲーム本体の場所が既定（`~/Games/DMM/drive_c/YostarGames/BlueArchive_JP`）と違う場合は
`ba-launch.sh` の `GAME_DIR` を書き換える。

### 中身の要点

- netns `ba` + veth `vba`(10.200.0.1/24) ↔ `vbn`(10.200.0.2/24)、ns の default は 10.200.0.1。
- DNS は `/etc/netns/ba/resolv.conf` に 1.1.1.1 / 8.8.8.8 を直書き
  （host の `127.0.0.53` は netns から見えない）。
- **Mullvad の nft を通すための必須マーク**。これが無いと forward が `policy drop` で落ちる:
  ```
  nft add table inet ba_ns
  nft add chain inet ba_ns pre '{ type filter hook prerouting priority mangle; policy accept; }'
  nft add rule inet ba_ns pre iifname "vba" ct mark set 0x00000f41 meta mark set 0x6d6f6c65
  nft add chain inet ba_ns post '{ type nat hook postrouting priority srcnat; policy accept; }'
  nft add rule inet ba_ns post oifname "$UPLINK" ip saddr 10.200.0.0/24 masquerade
  ```
  （`0x6d6f6c65` は ASCII で "mole"＝Mullvad の split-tunnel マーク。ct mark の `0xf41` も併せて付ける）
- **libvirt 等の FORWARD drop を外す**:
  `iptables -I FORWARD 1 -s 10.200.0.0/24 -j ACCEPT` と `-d ... -j ACCEPT`。
  これが無いと **TCP だけ silently drop** される（ICMP は通るので原因が見えにくい）。
- netns をユーザープロセスに与えるには **root が要る**（非 root の `ip netns exec` は `Operation not permitted`）。
  そのため `sudo -n systemd-run` → `ip netns exec ba` → `setpriv --reuid/--regid/--init-groups` → `umu-run` の三層で起動する。
- **GUI 環境変数は `systemctl --user show-environment` から拾う**。`XAUTHORITY` は
  `/run/user/1000/xauth_XXXXXX` でログインごとに変わる（`~/.Xauthority` も
  `/run/pressure-vessel/Xauthority` も存在しない）。`ba-launch.sh` は取れなかった場合
  `/run/user/$(id -u)/xauth_*` の最新をフォールバックに使う。
- bash の子プロセスは呼び出し終了時に殺されるため、**常駐起動は `systemd-run` 必須**。
  停止は `sudo systemctl stop 'ba-game*'`。

### 起動確認

```bash
~/.local/bin/ba-launch.sh        # メニューの「ブルーアーカイブ」でも同じ
pgrep -af '[x]m.exe'             # 0 件なら XIGNCODE は通っている
kdotool search --name Security   # 空なら初期化失敗モーダルは出ていない
```

## 症状 2: 黒画面のまま固まる（`Got null handle ...` / `0xc00d5212`）

- `0xc00d5212` = `MF_E_TOPO_CODEC_NOT_FOUND`。title.mp4 は VP9 なので、
  Media Foundation に VP9 デコーダ MFT が無いと
  `WindowsVideoMedia error 0xc00d5212 ... Video Track [320 x 240], type: AV01` で止まる。
- `Got null handle from IDXGIResource::GetSharedHandle.` の連発（%CPU 90% でハング）は
  共有テクスチャ非対応が原因。ビデオフレームも音声も来ないビジーループになる。
- 対処は [vp9-decoder-mft.md](vp9-decoder-mft.md) / [mf-shared-textures.md](mf-shared-textures.md)。
- 確認: ビルドした `winegstreamer.dll` / `mfplat.dll` / `mfreadwrite.dll` / `winegstreamer.so` を
  `UMU-Proton-10.0-4/files/lib/wine/` の該当サブディレクトリへ上書き配備し、Player.log に
  `[VP9CodecChecker] VP9 decoders found: 2` が出れば OK。

## 症状 3: ランチャーの整合性チェック

- `xldr_..._loader_x64.exe` は起動時にリソースのハッシュを検証する。
  改造した動画（例: title.mp4 を H.264 に差し替え）を置くと弾かれる。
- そのため `ba-launch.sh` は **`BlueArchive.exe` を直接起動**している
  （ローダーは `xldr_..._loader_x64.exe` を第 1 引数として渡す形で経由）。
- なお VP9 MFT を入れた構成では **title.mp4 を改変する必要は無い**（原本 VP9 のままで再生できる）。

## 既知の一過性エラー（無害・リトライで通る）

- タイトル直後に「ネットワークへの接続に失敗しました」→ OK → もう一度タップで解消。
  ゲーム発の 443 が CLOSE-WAIT になるが、netns の DNS・疎通は正常。
- Player.log の `WindowsVideoMedia error unhandled Color Standard: 0` は無害。

## 画面の撮影・入力（同じ PC をユーザーが使っている前提）

- 隠れた窓でも撮れるのは `DISPLAY=:0 magick import -window <X11 id> out.png` だけ。
  `spectacle -f` は最前面しか撮らない。
- 入力は `kdotool windowactivate <uuid>` → `xdotool mousemove --window <id> <x> <y>` → `xdotool click 1`。
  モーダルの OK は `xdotool key Return`。
- **操作後はマウス位置と元のアクティブ窓を復元する**。
- netns の nft テーブルをゲーム稼働中に作り直すと DL が止まる（ゲーム自体は落ちない）。