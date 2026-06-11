# OSC 52 対応計画: copy mode 発行 + ペイン内アプリのパススルー

## ゴール

zmux がローカル / リモート(SSH 越し)のどちらで動いていても、コピーが常に
「ユーザーが物理的に座っているマシン」のクリップボードに入るようにする。

- zmux の copy mode でコピーしたテキストを OSC 52 でクライアント端末へ送る
- ペイン内のアプリ(nvim の `"+y` など)が発行した OSC 52 を実ターミナルまで透過する

```
[ペイン内アプリ nvim] --OSC 52--> [zmux server] --socket--> [zmux client] --stdout--> [Ghostty] --> OS クリップボード
[zmux copy mode] ----------------^
```

## 現状

| 項目 | 状態 |
|---|---|
| copy mode の OSC 52 発行 | **実装済み** (`Server.zig` の `clipboard_copy` ハンドラ + `encodeOsc52`) |
| ペイン内アプリの OSC 52 透過 | **未実装** — 本計画の対象 |

### なぜ透過されないのか

ペイン出力は `Pane.feed` → ghostty-vt の `TerminalStream` に流れる。
ghostty-vt は OSC 52 を `.clipboard_contents` アクション(`kind: u8`, `data:
[]const u8`)としてパース済みだが、組み込みハンドラ
(`stream_terminal.zig`)はこれを「端末状態に影響しないアクション」として
無視している。`Effects` コールバックにも clipboard 用の口はない。

### 制約

- `zig-deps/ghostty` は gitignore された vendor なので、**ghostty 側には
  手を入れない**。zmux 側でハンドラをラップして割り込む。
- ghostty-vt は generic な `Stream(Handler)` と `StreamAction` を export
  しているので、独自ハンドラ型を差し込める。ハンドラに必要なのは
  `vt(comptime action, value)` と `deinit()` の 2 つ。

## 設計

### 1. Pane: ストリームハンドラのラップ

`Pane.zig` に ghostty の組み込みハンドラを包む `StreamHandler` を定義する。

- `vt()` で `.clipboard_contents` だけ横取りし、それ以外はそのまま
  `inner.vt(action, value)` へ委譲(comptime 分岐なので実行時コストなし)
- ハンドラから Pane へは既存の `writePty` と同じく
  `@fieldParentPtr("terminal", inner.terminal)` で戻る
- `vt_stream` の型を `ghostty.Stream(StreamHandler)` に変更し、
  `initStream` は `terminal.vtHandler()` を `inner` に包んで構築する

### 2. Pane: pending バッファ方式でサーバーへ受け渡し

コールバック配線を増やさず、Pane に `pending_clipboard:
std.ArrayList(u8)` を持たせる。横取りした OSC 52 は
`ESC ] 52 ; <kind> ; <base64> ESC \` に再構成してここへ追記するだけ。

サーバーのイベントループは `pane.feed()` の直後(呼び出し箇所は
`Server.zig` の 1 箇所のみ)に pending を見て、全クライアントへ
ブロードキャストして空にする。クライアントはサーバーフレームをそのまま
stdout へ書くので(copy mode の既存実装で実証済み)、追加変更は不要。

### 3. セキュリティ / 健全性のルール

転送するシーケンスは zmux が**自分で再構成**する(受信バイト列を鵜呑みに
しない)。その上で:

- **読み取り要求(`data == "?"`)は転送しない。** クリップボード読み出しは
  情報漏洩経路になるため、書き込み方向のみ通す(多くのターミナルと同方針)
- **kind は `c` / `p` / `s` / `0`-`7` のみ許可**(OSC 52 仕様の selection 文字)
- **data は base64 文字集合(`A-Z a-z 0-9 + / =`)のみ許可。** 不正バイトを
  含むペイロードを実ターミナルへ流さない
- **サイズ上限 64 KiB**(copy mode 側の `encodeOsc52` と同じ上限)。超過分は
  黙って捨てる。クライアントの受信バッファ(256 KiB)を超えるフレームは
  クライアントを落とすため、上限は必須

### 4. テスト

`Pty.init` が fork してシェルを起動するため、Pane 丸ごとのテストは重い。
シーケンス再構成・検証ロジックを純粋関数
`appendOsc52Passthrough(out, alloc, kind, data)` に切り出してユニットテスト
する(`zig build test` は main → Server → Pane の transitive import で
テストを拾う)。

- 正常系: `ESC]52;c;<base64>ESC\` が組み立てられる
- `?`(読み取り)が無視される
- 不正な kind / base64 外の文字が拒否される
- サイズ上限の enforcement
- 複数シーケンスの蓄積

## 実装ステップ

1. ~~copy mode の OSC 52 発行~~ — 実装済み(変更なし)
2. `Pane.zig`: `StreamHandler` ラッパー + `pending_clipboard` +
   `appendOsc52Passthrough` + ユニットテスト
3. `Server.zig`: `pane.feed()` 直後に pending をブロードキャスト
4. `zig build test` / 手動確認

## 手動確認手順

```sh
# 1. zmux を起動し、ペイン内で直接 OSC 52 を発行
printf '\x1b]52;c;%s\x1b\\' "$(printf 'hello from zmux' | base64)"
# → ホスト側 (macOS) で pbpaste が "hello from zmux" を返せば OK

# 2. nvim (0.10+) で
#    :lua vim.g.clipboard = 'osc52'
#    適当なテキストを "+y → pbpaste で確認

# 3. SSH 越し: リモートで zmux を起動して 1 と 2 を再実行
```

## スコープ外(将来課題)

- OSC 52 のクリップボード**読み取り**(`?`)への応答
- kitty clipboard protocol (OSC 5522) の透過
- 64 KiB を超える巨大ペイロードの分割転送
- クリップボード履歴や zmux 内部ペーストバッファとの統合
  (現状 `state.clipboard` は copy mode のコピーのみ保持)
