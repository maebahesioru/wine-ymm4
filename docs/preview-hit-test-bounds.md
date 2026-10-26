# プレビューの画像をクリックしても選択できない／選択枠がアイテムに追従しない件（2026-10-20 修正）

## 症状
YMM4 v4.56.1.1 で、プレビューに描画されているアイテムをマウスでクリックしても選択されない。
右パネルは「アイテムが選択されていません」のまま。タイムラインで Ctrl+A しても、
プレビュー側に選択枠（ハンドル付きの破線枠）が出ない。

部分修正後は「クリックで選択はできるが、アイテムを移動しても選択枠が付いてこない
（常にキャンバス中央に描かれる）」という症状が残った。

## 当たり判定の作り方（アプリ側の IL 解析で確定）
`TimelineVideoPlayer.Child_MouseDown` はクリック座標を `currentCursorPosition` から取り、
`timelineVideo.TimelineItemRects`（描画ループが毎フレーム作るクアッド 4 点）との
`IsPointInQuad()`（外積符号一致）だけで当たり判定する。

`TimelineSource.Update` はそのクアッドを次の順で作る:

1. `DrawingEffect as IBoundsQuadProvider` が非 null なら `GetTransformedBoundsQuad()`
2. null なら `ID2D1DeviceContext::GetImageLocalBounds(effect.GetOutput())` の軸平行矩形を4点に展開

どちらの経路でも最終的な元データは **`GetImageLocalBounds()` の戻り値**である。

## 原因（2段階）

### 1) コマンドリストの bounds が空
Wine の `d2d1` は `ID2D1CommandList` に対して `GetImageLocalBounds()` が
**常に空矩形**（`(0,0)-(0,0)`）を返していた。クアッドが縮退するため
`IsPointInQuad()` が必ず false になり、クリックが常に外れる（同時に枠も描かれない）。

### 2) 記録時にアイテムの変換行列を畳んでいなかった
記録済み描画の範囲を累積するようにしても、`DrawImage()` に渡される
**エフェクト出力の「サイズ」だけ**を使っていたため、YMM4 が位置を載せている
効果行列（2DAffineTransform / 3DTransform）が bounds に反映されず、
どのアイテムも `(-640,-360)-(640,360)` になっていた。結果、選択枠とヒット領域が
キャンバス中央に固定される。

## 修正内容（`dlls/d2d1/`）

| ファイル | 変更 |
|---|---|
| `command_list.c` | `d2d_command_list_union_point()` / `union_rect()` を追加し、`fill_rectangle` / `draw_rectangle`（stroke幅/2 で膨らます）/ `draw_bitmap` / `draw_image` / `fill_geometry` の記録時に範囲を累積。`d2d_command_list_set_transform()` で `record_transform` を保持し、累積時に適用 |
| `command_list.c` | `d2d_command_list_image_bounds()` を新設。Bitmap → 実サイズ、CommandList → 記録済み bounds、Effect → 入力0へ再帰した後に `d2d_effect_apply_matrix_to_bounds()` で変換を畳む。`union_image()` はこの矩形を使う |
| `device.c` | `GetImageLocalBounds()` の COMMANDLIST 分岐が記録済み bounds をそのまま返す。空のときのみ描画ターゲットサイズでフォールバック |
| `device.c` | `d2d_effect_apply_matrix_to_bounds()` を公開（`d2d1_private.h` に宣言） |

## 実測（Wine 11.18 自前ビルド + DXVK 3.1.1 / Xvfb :99 / YMM4 v4.56.1.1）

`YMM4DIAG=1` の診断出力（本パッチには診断は含まない）で確認:

```
YMM4DIAG: union_image img=… off=(0.0,0.0) -> (-340,-360)-(940,360)   ← X=300 が畳まれている
YMM4DIAG: bounds COMMANDLIST raw=(-340,-360)-(940,360)
```

| 操作 | 結果 |
|---|---|
| X=300 のアイテムをクリック | 画像にぴったりの選択枠が出る（旧: 枠なし、または中央固定） |
| X を 300 → 0 に変更 | 枠が画像の新しい位置に移動 |
| プレビュー内でドラッグ移動 | ドラッグ中も枠が追従 |
| 2アイテム（A: X=0/不透明度100%、B: X=300/50%） | A だけの領域をクリック→A が選択（0.0px/100.0%）、B の領域→B が選択（300.0px/50.0%） |

`docs/preview-hit-test-bounds.png` は X=0 で枠が画像に一致している例、
`docs/preview-hit-test-drag.png` はドラッグ中に枠が追従している例。

## 2026-10-26 追記: テキストアイテムが選択できない件

画像・動画アイテムは選択できるのに **テキストアイテムだけプレビュー上でクリック選択できない**
（選択枠も出ない）という報告への修正。

YMM4 のテキストは `ID2D1DeviceContext::DrawTextLayout()` → `IDWriteTextLayout1::Draw()` の
コールバック経由で **`ID2D1CommandList` にグリフラン（`DrawGlyphRun`）として記録**される。
ところが記録側の境界累積（`d2d_command_list_union_rect/_point`）は矩形・ビットマップ・
ジオメトリしか見ておらず、**グリフランは bounds に一切寄与していなかった**ため、
テキストだけ `GetImageLocalBounds()` が空矩形 → 当たり判定クアッドが縮退していた。

`command_list.c` の `d2d_command_list_draw_glyph_run()` に、グリフランから境界を累積する処理を追加:

```c
/* YMM4 fix: accumulate the bounds of text recorded into a command list ... */
DWRITE_FONT_METRICS fm;
float width = 0.0f, top, bottom;

if (run->glyphAdvances)
    for (i = 0; i < run->glyphCount; ++i) width += run->glyphAdvances[i];
else
    width = run->glyphCount * run->fontEmSize * 0.5f;

memset(&fm, 0, sizeof(fm));
if (run->fontFace)
    IDWriteFontFace_GetMetrics(run->fontFace, &fm);   /* 戻り値は void */

if (fm.designUnitsPerEm)
{
    float scale = run->fontEmSize / (float)fm.designUnitsPerEm;
    top = origin.y - fm.ascent * scale;
    bottom = origin.y + (fm.descent + fm.lineGap) * scale;
}
else
{
    top = origin.y - run->fontEmSize;
    bottom = origin.y + run->fontEmSize * 0.25f;
}

d2d_command_list_union_point(command_list, origin.x, top);
d2d_command_list_union_point(command_list, origin.x + width, bottom);
```

### 実測（Wine 11.20 + patched d2d1 / Xvfb :99 / YMM4 v4.56.1.1）

`WINEDEBUG=+d2d` で記録されていることを確認（チャンネル名は `d2d`。`+d2d1` では出ない）:

```
trace:d2d:d2d_command_list_draw_glyph_run glyph run: 4 glyphs, origin 0.0,0.0 width 86.9, bounds y -24.8..12.3.
```

| 操作 | 修正前 | 修正後 |
|---|---|---|
| テキストアイテムにカーソルを乗せる | 選択枠が出ない | **文字を囲む選択枠（四隅ハンドル）が出る** |
| テキストをクリック | 選択できない | 選択できる（パネルがテキストのプロパティに切り替わる） |
| 2つのテキスト（Y=0 と Y=-250）を交互にクリック | — | Y=0 側→レイヤー0/Y=0.0px、Y=-250 側→レイヤー1/Y=-250.0px と正しく入れ替わる |

d2d1.dll のサイズは 6,506,429 → **6,510,687 bytes**（+4,258）。テキストの描画そのものには
影響せず、記録される bounds だけが広がる（画像・動画アイテムの挙動は不変）。
