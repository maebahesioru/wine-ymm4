# D3D11 共有テクスチャで Media Foundation のサンプルが繋がらない件

対象: `dlls/mfplat/`（`sample.c` / `buffer.c`）、`dlls/mfreadwrite/`（`reader.c`）
関連パッチ: `patches/mfplat/0001-mfplat-Share-D3D11-sample-allocator-textures.patch`,
`0002-mfplat-Pool-linear-buffers-for-DXGI-surface-lock.patch`,
`patches/mfreadwrite/0001-mfreadwrite-Skip-copy-for-DXGI-sample-buffers.patch`

共有テクスチャ側の原案は [FurkanDGN/wine-mfplat-shared-textures](https://github.com/FurkanDGN/wine-mfplat-shared-textures)
の 3 パッチ。wine 11.18 のツリーへ適用し、11.20 向けに移植した。

## 症状

Unity の `WindowsVideoMedia` が VP9 動画を読む段で、次のエラーが毎フレーム 60 回以上出る。

```
err: D3D11: Got null handle from IDXGIResource::GetSharedHandle.
```

同時に、MF のサンプルが 1 枚もデコーダへ渡らず（フレーム 0）、音声ストリームも空のまま
CPU 100% で回り続ける。ウィンドウは黒いまま。

## 原因

Unity は `MFCreateDXGIDeviceManager` + `MF_SA_D3D11_SHARED_WITHOUT_MUTEX` で
ソースリーダーを開き、返ってきたテクスチャを **別の D3D11 デバイス**で
`GetSharedHandle()` して共有しようとする。Wine のサンプルアロケータは
`D3D11_RESOURCE_MISC_SHARED` を付けずにテクスチャを作るため、
共有ハンドルが取得できず `NULL` が返る。

加えて 2 つの二次的な問題がある。

- `mfreadwrite` が DXGI バッファ付きサンプルをわざわざコピーしてしまい、
  共有テクスチャの経路から外れる
- `dxgi_surface_buffer_Lock()` / `Unlock()` が毎フレーム `malloc` / `free` しており、
  1920x1080 のサーフェスでは確保と解放がそのまま再生のボトルネックになる

## 修正

### 0001 サンプルアロケータのテクスチャを共有可能にする（`dlls/mfplat/sample.c`）

`sample_allocator_initialize()` で、usage が `D3D11_USAGE_DEFAULT` かつ
`D3D11_RESOURCE_MISC_SHARED` / `..._SHARED_KEYEDMUTEX` が未設定なら
`D3D11_RESOURCE_MISC_SHARED` を付与する。Windows と同じく、
DXGI device manager 経由で作られたサンプルを別デバイスから開けるようにする。

### 0002 線形バッファのプール（`dlls/mfplat/buffer.c`）

`dxgi_surface_buffer_Lock()` / `Unlock()` の `malloc` / `free` を、
4 スロットの固定プール（`SRWLOCK` で排他、サイズ一致のスロットを再利用、
空きが無ければ `free`）に置き換える。

### 0003 DXGI サンプルはコピーしない（`dlls/mfreadwrite/reader.c`）

`source_reader_sample_has_dxgi_buffer()`（`GetBufferByIndex(0)` → `QueryInterface(IID_IMFDXGIBuffer)`）を追加し、
`media_stream_pop_response()` の二重コピー条件を次にする。

```c
if (response->sample && stream->allocator && !source_reader_sample_has_dxgi_buffer(response->sample))
```

## 実測結果

- `Got null handle from IDXGIResource::GetSharedHandle.` の連発が **完全に消滅**
- その状態で VP9 デコーダ MFT（`patches/winegstreamer/0001`）と併用すると、
  黒画面 → タイトル画面（YOSTAR ログインモーダル）まで到達
- Player.log に残るのは `unhandled Color Standard: 0` の警告 2 行のみ
