# 大きな文字サイズで一部の文字だけ欠ける件（コマンドリスト内ポインタの無効化）

2026-10-26 実測。YMM4 v4.56.1.1 / Wine 11.20 / コーポレート・ロゴ ver3（FontSize 373.47）。

## 症状
テキストアイテムのフォントサイズが大きい（例 373px / 615px）とき、プレビューで
**文字列の一部だけが描かれず、残りは微小な破片**になる。
例: 「起こる胸騒ぎ」→ 実測では `起` と `ぎ` だけが正しく描かれ、`こる` `胸騒` は
数ピクセルの断片になった。

DWrite 側（cmap・シェーピング・HasCharacter・GetGlyphRunOutline・
単純な D2D 描画・コマンドリスト記録→リプレイの小さいサイズ）は
すべて正常であることをプローブで確認済み（`docs/` の他文書と同じ手法）。

## 原因
`dlls/d2d1/command_list.c` の `d2d_command_list_draw_glyph_run()` は、
グリフ列の可変長データ（`glyphIndices` / `glyphAdvances` / `glyphOffsets`、
および `run_desc` の `localeName` / `string` / `clusterMap`）を
**コマンドバッファ内にコピーし、その絶対ポインタを `DWRITE_GLYPH_RUN` に保存**していた。

バッファは `d2d_command_list_require_space()` →
`d2d_array_reserve(&command_list->data, ...)` で伸長されるため、
後続コマンドの追記で **realloc が起きると既存コマンドの内部ポインタが無効化**される。
無効化されたポインタをリプレイ時に読むと、グリフ ID が別の値（例 `0000 0020`）に化け、
「別の（小さい）グリフ」として描かれる＝欠けて見える。

実測（記録時 → リプレイ時、`TRACE` を一時追加して比較）:

| run | 記録時の indices | リプレイ時の indices |
|---|---|---|
| `起`（1 glyph） | `04db` | `04db`（正常） |
| `こる`（2 glyphs） | `01ee 0226` | **`0000 0020`**（壊れる） |
| `胸騒`（2 glyphs） | `0545 098f` | **`0000 0000`**（壊れる） |
| `ぎ`（1 glyph） | `01e9` | `01e9`（正常） |

リプレイ時の `adv` ポインタも `0x2B703BAA` / `0x2B703CC6` と**奇数（未アライン）**になっており、
バッファ移動後に再計算されていないことを示す。

## 修正
可変長データを**バッファ先頭からのオフセット**として保存し、ストリーム時に実ポインタへ戻す。

```c
static inline void d2d_command_list_write_field_offset(BYTE **data, void *dst, const void *src,
        size_t size, const BYTE *base)
{
    void **ptr = dst;

    if (!src)
    {
        *ptr = NULL;
        return;
    }

    *ptr = (void *)(uintptr_t)(*data - base);
    memcpy(*data, src, size);
    *data = *data + size;
}
```

- 記録: 3 配列と `run_desc`（およびその `localeName`/`string`/`clusterMap`）をオフセットで保存。
- リプレイ（`d2d_command_list_Stream()` の `case D2D_COMMAND_DRAW_GLYPH_RUN`）:
  `base = command_list->data` として `run` と `desc` をローカルにコピーし、
  各ポインタを `base + offset` に戻してから `ID2D1CommandSink_DrawGlyphRun()` に渡す。

パッチ: `patches/d2d1/wine-11.20-d2d1-ymm4-complete.patch` に含まれる
（`command_list.c` の `d2d_command_list_draw_glyph_run` / `d2d_command_list_Stream` 周辺）。

## 検証（実測）
- 修正後、同じプロジェクト（`起こる胸騒ぎ` / 373.47px、`ナニカが` / 615.83px）で
  プレビューに **「起こる胸騒ぎ」が6文字すべて描画**されることをスクリーンショットで確認。
- リプレイ時の TRACE が `01ee 0226` / `0545 098f` を正しく報告（修正前は `0000 0020` / `0000 0000`）。

## 配備
```bash
sudo cp -a /opt/wine11up/lib/wine/x86_64-windows/d2d1.dll{,.bak-$(date +%Y%m%d)}
sudo cp d2d1.dll /opt/wine11up/lib/wine/x86_64-windows/d2d1.dll
wineserver -k
```
ビルド: `make -C dlls/d2d1 -j8`（wine 11.20 ツリー、rc=0）
