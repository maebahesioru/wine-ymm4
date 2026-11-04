# Media Foundation に VP9 デコーダ MFT を追加する

対象: `dlls/winegstreamer/`（wine 11.18 で開発、11.20 で検証）
関連パッチ: `patches/winegstreamer/0001-winegstreamer-Add-a-VP9-decoder-MFT.patch`,
`0002-winegstreamer-Export-ARGB32-and-RGB32-output-types.patch`,
`0003-winegstreamer-Compatible-once-init-for-older-GLib.patch`

## 症状

Unity 製アプリ（実測: ブルーアーカイブ PC 版、Unity 2021.3.56f2）が起動時、タイトル動画の
読み込みで停止して黒画面になる。Player.log には次の順でエラーが出ていた。

```
WindowsVideoMedia error 0xc00d5212 while reading .../StreamingAssets/Video/title.mp4
Context: Setting media type for first video stream
Error details: No suitable transform was found to encode or decode the content.
Video Track [1920 x 1080], type: VP90
Audio Track, type: OPUS
```

`0xc00d5212` は `MF_E_TOPO_CODEC_NOT_FOUND`。動画ファイルは VP9（`vp09`）で、
Media Foundation のトポロジに VP9 のデコーダが載らないため `SetMediaType` で失敗し、
Unity はそれ以上フレームを進めないまま CPU 100% で待ち続ける。

Wine 側に VP9 の入口が無いことが根本原因で、次の 3 点がすべて欠けていた。

1. `wg_media_type.c` の `init_caps_from_video_subtype()` に VP90 → `video/x-vp9` の対応が無い
2. `wg_format.c` の `wg_format_from_caps()` / `wg_format_to_caps()` / `wg_format_compare()` に VP9 の枝が無い
3. `mfplat.c` に VP9 用の CLSID とクラスファクトリが無く、`MFTRegister` も呼ばれていない

なお GStreamer 側のデコード素子は既に存在する（`vp9dec` / `avdec_vp9`）。
winegstreamer の素子選択は caps 駆動（`unixlib.c` の `find_element()`）なので、
`video/x-vp9` の caps さえ正しく作れば素子名を書く必要はない。

## 実装

### 1. 列挙型と caps 変換

`dlls/winegstreamer/unixlib.h` の `enum wg_major_type` に `WG_MAJOR_TYPE_VIDEO_VP9` を追加し、
`wg_media_type.c` に `init_caps_from_video_vp9()` を足して
`init_caps_from_video_subtype()` から `MFVideoFormat_VP90` で分岐させる。
VP9 は H.264 と違い `codec_data` を必要としないので、`width` / `height` / `framerate` のみを扱う。

`wg_format.c` では次の 3 箇所を追加する。

- `wg_format_from_caps()` : `video/x-vp9` の枝（`wg_format_from_caps_video_vp9()`）
- `wg_format_to_caps()` : `WG_MAJOR_TYPE_VIDEO_VP9` の枝
- `wg_format_compare()` : 既定で `FIXME` + `FALSE` を返す switch に VP9 の case を足すだけ

### 2. MFT の登録と生成

`mfplat.c` に `CLSID_wg_vp9_decoder` を定義し、`class_objects[]` に
`{ &CLSID_wg_vp9_decoder, &vp9_decoder_create }` を追加する。
`DllGetClassObject()`（`main.c`）は `init_gstreamer()` の後に
`mfplat_get_class_object()` をまず試すので、`main.c` の分岐は変更不要。

デコーダ本体は `video_decoder.c` の `vp9_decoder_create()`。`h264_decoder_create()` と同じ流れで、

```c
static const GUID *const vp9_decoder_input_types[] = { &MFVideoFormat_VP90 };
/* 出力は video_decoder_output_types[] を共有（NV12/YV12/IYUV/I420/YUY2/ARGB32/RGB32） */
video_decoder_create_with_types(vp9_decoder_input_types, ARRAY_SIZE(vp9_decoder_input_types),
                                video_decoder_output_types, ARRAY_SIZE(video_decoder_output_types),
                                NULL, &decoder);
```

入力バッファは `WHOLE_SAMPLES | SINGLE_SAMPLE_PER_BUFFER | FIXED_SAMPLE_SIZE`、
`cbSize = 0x1000`。出力は `cbSize = 4096 * 4096 * 2`、
`wg_transform_attrs.output_plane_align = 15`、`allow_format_change = TRUE`。

登録は `main.c` の `DllRegisterServer()` で `MFTRegister()` を呼ぶ。
`MFTEnumEx()` は `HKCR\\MediaFoundation\\Transforms\\<clsid>` と
`...\\Transforms\\Categories\\<category>\\<clsid>` の両方が揃って初めて列挙するので、
`__wine_register_resources()` の直後に登録し、`DllUnregisterServer()` で `MFTUnregister()` する。

### 3. 出力に RGB32 / ARGB32 を足す（別パッチ）

`video_decoder_output_types[]` に `&MFVideoFormat_ARGB32` と `&MFVideoFormat_RGB32` を追加する。
これは VP9 専用ではなく **既存の H.264 など全デコーダに影響する**ので、
`0002-winegstreamer-Export-ARGB32-and-RGB32-output-types.patch` として分離してある。
不要ならこのパッチだけ外してよい（VP9 のデコード自体は I420 系で成立する）。

### 4. 古い GLib 向けの once-init 互換シム（環境依存・別パッチ）

ホストの GLib（実測: 2.90）のヘッダでビルドした `winegstreamer.so` を、
Steam Runtime（GLib 2.66）の中で dlopen すると次のシンボルが無くてロードに失敗する。

```
undefined symbol: g_once_init_enter_pointer
undefined symbol: g_once_init_leave_pointer
```

この状態では `CoCreateInstance` が `0xc00d36b2`（`MF_E_INVALIDMEDIATYPE` ではなく
ロード失敗由来のエラー）で返り、コーデックが存在しないのと同じ結果になる。
`dlls/winegstreamer/unixlib.c` の先頭でマクロを `#undef` した上で、
旧 API（`g_once_init_enter` / `g_once_init_leave`）へ転送する薄いラッパーを定義して回避する。

```c
gboolean g_once_init_enter_pointer(void *location) { return g_once_init_enter(location); }
void g_once_init_leave_pointer(void *location, gpointer result)
{ g_once_init_leave(location, (gsize)result); }
```

**このパッチは上流向けではない**（ビルド時と実行時で GLib のバージョンがずれる環境専用）。
自前ビルドを Steam Runtime 上で使う場合のみ必要になる。

## 実測結果

- ブルーアーカイブ PC 版のログ: `[VP9CodecChecker] VP9 decoders found: 0` → **2**
- `WindowsVideoMedia error 0xc00d5212` と `No suitable transform` が Player.log から消滅
- タイトル画面の背景動画（VP9 / 2340x1080）が実際に再生される（フレームが時間で変化）
- 残る警告は `WindowsVideoMedia error unhandled Color Standard: 0` のみ（描画への影響なし）

## 11.20 固有の注意

`dlls/winegstreamer/wm_reader.c` の `get_major_type_string()` は
`enum wg_major_type` を網羅する switch を持ち、`-Werror=switch` でビルドが落ちる（11.18 には無い関数）。
VP9 の case を追加する必要がある。

```c
case WG_MAJOR_TYPE_VIDEO_VP9: return "vp9";
```

## 配備

`winegstreamer.dll`（x86_64-windows）と `winegstreamer.so`（x86_64-unix）の 2 つを差し替える。
実測では Proton 10.0-4 の `files/lib/wine/` に wine 11.18 ビルドの PE/so を混載しても
`import_dll` エラーは出なかった（ただし ABI は保証されないので、可能なら同一ツリーの
フルビルドを使うのが安全）。
