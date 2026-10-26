# 日本語入力の変換ウィンドウが画面左上に出る問題（Wine imm32 のフォールバック）

2026-10-26 実測。YMM4 v4.56.1.1 / Wine 11.20 / fcitx5 5.1.23（XIM）/ Xvfb :99。

## 症状
YMM4 のテキスト入力欄で日本語を打つと、**前編集（「あ」）と候補一覧のウィンドウが画面の左上 (4,40) に出る**。
入力欄の近くには何も出ないので、目線を左上に移して変換しなければならない。

## 原因
1. WPF（`PresentationFramework.dll` の `System.Windows.Documents.ImmComposition.UpdateNearCaretCompositionWindow`）は
   `ImmSetCompositionWindow` を呼ぶ実装を持っているが、その呼び出し元は
   `ImmCompositionFilterMessage` / `OnWmImeChar` / `OnLayoutUpdated` / `OnSelectionChanged`。
   **XIM 経路では `WM_IME_COMPOSITION` がアプリに届かない**（実測: `WM_IME_SETCONTEXT` が2件のみ、
   `WM_IME_STARTCOMPOSITION`/`WM_IME_COMPOSITION` は 0 件）ため、この経路が動かず
   `ImmSetCompositionWindow` は **一度も呼ばれない**（`WINEDEBUG=+imm` で 0 件）。
2. Wine 側は `ImmSetCompositionWindow` → `NtUserCallTwoParam_SetIMECompositionRect` →
   `dlls/winex11.drv/xim.c` の `X11DRV_SetIMECompositionRect()` で `XNSpotLocation` を設定する仕組みしか持たない。
   呼ばれなければ spot は初期値 (0,0) のまま。
3. fcitx5 の XIM が提示するスタイルは **preedit position 系のみ**（callbacks / OnTheSpot は提供しない）:
   `0x104` `0x404` `0x804` `0x408` `0x808`。つまり前編集は必ず fcitx 側のウィンドウが描き、
   その位置は **XNSpotLocation だけで決まる**。

⇒ spot が (0,0) のままなので、fcitx の入力ウィンドウが画面左上に固定される。

（`InputStyle` を `overthespot` にしても 0x404 preedit position が選ばれるが、spot が設定されないので同じ位置になる。
`HKCU\Software\Wine\X11 Driver` の `InputStyle` だけでは直らない。）

## 修正
`dlls/imm32/ime.c` の `ImeToAsciiEx()`（キー入力ごとに呼ばれる）に、アプリが composition window を
設定していない場合のフォールバックを追加する。**カーソル位置（＝直前にクリックした入力欄の位置）**を
クライアント座標に変換して spot として渡す。

```c
static void update_composition_rect( HIMC himc )
{
    static POINT last = {INT_MIN, INT_MIN};
    INPUTCONTEXT *ctx;
    POINT pt;
    RECT rect;

    if (!(ctx = ImmLockIMC( himc ))) return;

    if (!(ctx->fdwInit & INIT_COMPFORM) && GetCursorPos( &pt ) && ScreenToClient( ctx->hWnd, &pt )
            && (pt.x != last.x || pt.y != last.y))
    {
        last = pt;
        SetRect( &rect, pt.x, pt.y, pt.x + 1, pt.y + 1 );
        TRACE( "composition window not set by the app, using cursor position %d,%d\n", (int)pt.x, (int)pt.y );
        NtUserCallTwoParam( (ULONG_PTR)ctx->hWnd, (ULONG_PTR)&rect, NtUserCallTwoParam_SetIMECompositionRect );
    }

    ImmUnlockIMC( himc );
}
```
（`ImeToAsciiEx` の `if (!is_ime_hkl( GetKeyboardLayout( 0 ) )) return 0;` の直後に `update_composition_rect( himc );`）

アプリが自分で `ImmSetCompositionWindow` を呼ぶ場合（notepad 等の Win32 アプリ）は
`ctx->fdwInit & INIT_COMPFORM` が立つのでこのフォールバックは動かず、従来の挙動を変えない。

パッチ: `patches/imm32/0001-imm32-fallback-composition-window-position.patch`
（wine 11.20 ツリーに `git apply` 可、`make -C dlls/imm32` rc=0 を実測）

## 検証（実測）
| | 修正前 | 修正後 |
|---|---|---|
| fcitx 入力ウィンドウの位置 | `152x285+4+40`（画面左上、メニューバーに重なる） | 入力欄の直上（カーソル位置 296,998 付近） |
| `WINEDEBUG=+imm` | `ImmSetCompositionWindow` 0 件 | `update_composition_rect composition window not set by the app, using cursor position 296,998` |

## 配備
```bash
sudo cp -a /opt/wine11up/lib/wine/x86_64-windows/imm32.dll{,.bak-$(date +%Y%m%d)}
sudo cp imm32.dll /opt/wine11up/lib/wine/x86_64-windows/imm32.dll
wineserver -k
```
prefix 側 `drive_c/windows/system32/imm32.dll` は Wine が起動時に builtin から自動同期する
（実測済み。同期されない場合は手動コピー）。

あわせて `HKCU\Software\Wine\X11 Driver` に `InputStyle = overthespot` を入れておくと
XIM が `preedit position` (0x404) で確定する（未設定でも 0x104 が選ばれ spot は効くが、
status area 付きになるため明示推奨）。

```bash
WINEPREFIX=~/.wine-ymm-test /opt/wine11up/bin/wine reg add 'HKCU\Software\Wine\X11 Driver' /v InputStyle /d overthespot /f
```

## 制約
- 位置の供給源はマウスカーソルなので、**マウスを動かしてからキーボードだけで別の欄に移った場合**は
  実際のキャレットとずれる（実用上は「クリックして入力」なので一致する）。
- WPF が `WM_IME_COMPOSITION` を受け取らない構造（fcitx5 が callbacks スタイルを提供しない）ため、
  前編集をアプリ内にインライン表示することは現状できない。今回の修正は「fcitx のウィンドウを
  入力位置の近くに出す」ところまで。
