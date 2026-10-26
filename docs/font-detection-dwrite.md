# YMM4 のフォント一覧が空になる問題（Wine dwrite の `IDWriteFontSet1::CreateFontFace` 未実装）

2026-10-26 実測。YMM4 v4.56.1.1 / Wine 11.20。

## 症状
YMM4 のフォント選択（テキストアイテムのフォント欄、フォント設定画面）に**フォントが1件も出ない**。
アプリは落ちず、エラーも出ず、`user/setting/<ver>/YukkuriMovieMaker.Settings.FontSettings.json` に

```json
{"SystemFonts":[],"MissingFonts":[],"CustomFonts":[],"Category":"None"}
```

が保存される（＝無音の失敗）。

## 原因
YMM4 は一覧を `FontSettings.SystemFonts` からのみ作る（`FontComboBox.get_AllFonts` が
`SystemFonts.Concat(CustomFonts)`）。その `SystemFonts` を埋めるのは
`FontSettings.GetDirectWriteFontsFromFontSet()` で、DirectWrite のフォントセットを
**1件ずつ `IDWriteFontSet1::CreateFontFace(index)` に通して** family/face 名を取る実装。

Wine 11.20（および upstream master）の `dlls/dwrite/font.c` では
`dwritefontset1_CreateFontFace()` が未実装スタブで、**常に `E_NOTIMPL (0x80004001)`** を返す:

```c
static HRESULT WINAPI dwritefontset1_CreateFontFace(IDWriteFontSet3 *iface, UINT32 index, IDWriteFontFace5 **fontface)
{
    FIXME("%p, %u, %p.\n", iface, index, fontface);
    return E_NOTIMPL;
}
```

YMM4 側はこの呼び出しだけ `try/catch` して `continue` するため、991件すべてが例外→0件になり、
空の `SystemFonts` がそのまま保存される。`FontSettings.Initialize` 自体は例外を投げないので
ログにも残らない（`user/log/*.log` に font/FontCache の記録は 0 件）。

## 実測（プローブ）
`DWriteCreateFactory` → QI(`IDWriteFactory6`) → `GetSystemFontSet` → 各 index で `CreateFontFace`
を叩く mingw プローブ（`DWriteCreateFactory hr=0`, `GetSystemFontSet hr=0`）:

| | 修正前 | 修正後 |
|---|---|---|
| `IDWriteFontSet::GetFontCount` | 991 | 991 |
| `IDWriteFontSet1::CreateFontFace(i)` | 全 991 件 `0x80004001`（E_NOTIMPL） | 成功 |
| family 名の取得 | 不可 | `Bebas Neue` / `コーポレート・ロゴ ver3` / `Noto Sans CJK JP` … |

`WINEDEBUG=+dwrite` では修正前に `fixme:dwrite:dwritefontset1_CreateFontFace` が 991 行出る。

## 修正
`dwritefontset1_CreateFontFace()` を、同 vtable ですでに実装済みの部品
（`CreateFontResource` が使っている `set->entries[index]->file` と
`IDWriteFactory7_CreateFontFaceReference_` + `IDWriteFontFaceReference1_CreateFontFace`）に委譲する。

```c
static HRESULT WINAPI dwritefontset1_CreateFontFace(IDWriteFontSet3 *iface, UINT32 index, IDWriteFontFace5 **fontface)
{
    struct dwrite_fontset *set = impl_from_IDWriteFontSet3(iface);
    IDWriteFontFaceReference *reference;
    HRESULT hr;

    TRACE("%p, %u, %p.\n", iface, index, fontface);

    if (!fontface) return E_INVALIDARG;

    *fontface = NULL;

    if (index >= set->count)
        return E_INVALIDARG;

    hr = IDWriteFactory7_CreateFontFaceReference_(set->factory, set->entries[index]->file,
            set->entries[index]->face_index, set->entries[index]->simulations, &reference);
    if (FAILED(hr))
        return hr;

    hr = IDWriteFontFaceReference1_CreateFontFace((IDWriteFontFaceReference1 *)reference, fontface);
    IDWriteFontFaceReference_Release(reference);

    return hr;
}
```

パッチ: `patches/dwrite/0001-dwrite-Implement-IDWriteFontSet1-CreateFontFace.patch`
（wine 11.20 ツリーに `git apply` / `patch -p1` 可、`make -C dlls/dwrite` rc=0 を実測）

## 検証（YMM4 実機）
Wine 11.20 を複製して `dwrite.dll` だけ差し替え、Xvfb :99 で YMM4 v4.56.1.1 を起動 → 終了後の設定ファイル:

| | 修正前 | 修正後 |
|---|---|---|
| `FontSettings.json` | `SystemFonts: []` | **179,703 bytes / `SystemFonts`: 692件**（`MissingFonts`: 0, `CustomFonts`: 0） |
| 例 | — | `Noto Sans CJK JP`, `しっぽり明朝`, `コーポレート・ロゴ ver3 Bold` |

（`GetFontCount` 991 に対し保存が 692 件なのは、YMM4 側が family+face 名で重複排除し
`<Initialize>b__16_0` で絞り込むため。）

## 配備
```bash
sudo cp -a /opt/wine11up/lib/wine/x86_64-windows/dwrite.dll{,.bak-$(date +%Y%m%d)}
sudo cp dwrite.dll /opt/wine11up/lib/wine/x86_64-windows/dwrite.dll
wineserver -k
```
prefix 側 `drive_c/windows/system32/dwrite.dll` は Wine が起動時に builtin から自動同期する
（実測: dll を置き換えただけで prefix 側も更新された）。

注意: ビルド済み `dwrite.dll` は `--wine-builtin` 付きなので
`WINEDLLOVERRIDES=dwrite=n`（native 上書き）ではロードできない（`status=c0000135`）。
検証は「wine install ごと複製して差し替える」か、`/opt` を直接置き換える。
