# フェードイン／フェードアウトと不透明度が効かない件（ColorMatrix エフェクトの無視）

2026-10-27 実測。YMM4 v4.56.1.1 / Wine 11.20。

## 症状
アイテムの「フェードイン」「フェードアウト」「不透明度」を設定しても、プレビューが変化しない
（フェードの区間でも文字・画像が不透明のまま）。

## 原因
YMM4 はこれらの値を **Direct2D の ColorMatrix エフェクト**で適用している。

- `EffectItemDrawingEffect.Update()`（RVA=AD63C, IL=508B）が
  `fadeIn = Math.Min(1.0, elapsed.TotalSeconds / FadeIn)` /
  `fadeOut = Math.Min(1.0, (duration - elapsed).TotalSeconds / FadeOut)` を計算し、
  `DrawDescription.Opacity * Math.Min(fadeIn, fadeOut)` を作る。
- `DrawLazyEffectEffect.Update()`（RVA=ACD7C, IL=1271B）がその値を保持し、変化したとき
  **`Matrix5x4`（M11..M33 = 1、M44 = opacity）を ColorMatrix エフェクトに設定**する
  （IL 実測: `+0407 stfld F:opacity`、`+02cf ldfld F:opacityEffect`、以降 M11/M12/…/M44 を構築）。

Wine 側の d2d1 には以前から「YMM4 用のエフェクト近似」があり、`dlls/d2d1/device.c` の
`d2d_device_context_DrawImage()` 内で **2DAffineTransform / 3DTransform / Crop のみ**を処理して
いた。**ColorMatrix は処理対象外**で、そのまま入力 0 を描画していたため、M44（不透明度）が
完全に無視されていた。

## 修正
`context` に「囲んでいるエフェクトの不透明度」を持たせ、描画時に掛ける。

1. `struct d2d_device_context`（`dlls/d2d1/d2d1_private.h`）に `float effect_opacity;` を追加し、
   `d2d_device_context_init()` で `1.0f` に初期化（`calloc` のゼロ初期化対策）。
2. エフェクト近似の分岐に ColorMatrix を追加:
   `CLSID_D2D1ColorMatrix = {0x921f03d6,0x641c,0x47df,{0x85,0x2d,0xb4,0xbb,0x61,0x53,0xae,0x11}}`。
   `ID2D1Effect_GetValue(effect, 0 /*COLOR_MATRIX*/, D2D1_PROPERTY_TYPE_MATRIX_5X4, ...)` で行列を取得し、
   `M44 < 1` なら `context->effect_opacity *= M44` してから入力 0 を再帰描画し、戻したら復元。
3. `d2d_device_context_update_ps_cb()` でブラシの不透明度に掛ける:
   `cb_data->colour_brush.opacity *= context->effect_opacity;`
   （`opacity_brush.opacity` も同様）。これでテキスト・図形などブラシ描画すべてに効く。
4. `d2d_device_context_ID2D1DeviceContext_DrawBitmap()` の
   `brush_desc.opacity = opacity * context->effect_opacity;` で画像・動画にも効く。

## 検証（実測）
- 検証用プロジェクト `.work/op30.ymmp`（`起こる胸騒ぎ` の不透明度 **30%**）:
  修正前は不透明のまま → 修正後は**半透明**で描画（赤背景が透ける）。
- 検証用プロジェクト `.work/fade.ymmp`（同アイテムに **FadeIn=2.0 / FadeOut=2.0**）:
  `Home` でフレーム 0 に移動 → **文字が完全に消えている**、3 秒再生後 → **完全に表示**。
- ビルド: `make -C dlls/d2d1 -j8` rc=0。`d2d1.dll` = 6,510,740 bytes / md5 `4f02c5e9ab8b086383824cf9245ce2df`。

## 配備
```bash
sudo cp -a /opt/wine11up/lib/wine/x86_64-windows/d2d1.dll{,.bak-$(date +%Y%m%d)}
sudo cp d2d1.dll /opt/wine11up/lib/wine/x86_64-windows/d2d1.dll
wineserver -k
```
