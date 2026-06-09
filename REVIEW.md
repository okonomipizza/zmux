# zmux コードレビュー記録

実施日: 2026-06-09
対象: main ブランチ (v1.1.0 時点)
範囲: src/ 配下の全 Zig ソース + build/Nix 設定

---

## 🔴 高優先度（バグ修正）

### 1. `Renderer.zig:782, 825` — 未初期化バッファ書き込み
`utf8Encode catch 1` で失敗時に `len=1` にしているが、`utf8_buf[0]` は未設定のまま書き込まれる。
**修正方針**: `catch { writeAll(" "); continue; }` に変更。

### 2. `WorkspaceManager.zig:53-57` — ゼロ除算クラッシュ
workspaces が空のとき `len-1` で wrap → `% 0` で例外発生。
**修正方針**: `len == 0` の早期 return。

### 3. `WorkspaceManager.zig:43` — 境界判定ミス
`if (idx > len) return;` は `>=` であるべき。`idx == len` の時に範囲外アクセス。

### 4. `WorkspaceManager.zig:84-97` — メモリリーク
`movePaneToWorkspace` で source workspace の `floating_pane` (+ 内部の Pty/Terminal/vt_stream) が解放されない。
**修正方針**: `src_ws.deinit` 相当の処理を追加。

### 5. `Workspace.zig:103-107` — コンパイル不可なデッドコード
`deinitPanes` の `switch (node)` は型エラー (`node.*` でないと不可)。`leaf => node` も無意味。
**修正方針**: 関数全体を削除。

### 6. `Workspace.zig:229, 235` — relayout の 1セル消失
`@intFromFloat(... * ratio) -| 1` で「-1」しているのは境界線を引いた後の `first_cols` から更に1減らしており、`second_cols = cols - first_cols - 1` と合わせると合計が `cols - 1` で 1 セル損失。
**修正方針**: `first_cols = floor(cols * ratio)` に修正。

### 7. `Server.zig:147-159` — Use-after-free リスク
同じ `wait` iter 内で `removeClient` 後に同じ tag の後続イベントが来ると `*Client` ポインタで UAF。kqueue では `EV_EOF` と `readable` が同時に立ち得るので特に注意。
**修正方針**: 世代カウンタ or 「削除済みクライアント」のスキップロジック。

### 8. `loop.zig:53-75` — addSignal のエラーパス不整合
`epoll_ctl` 失敗時に slot に sfd が代入されたまま残り、二重解放/リーク。`TooManySignals` 時に `sigprocmask(BLOCK)` の戻しも未実装。
**修正方針**: errdefer で slot を null に戻す、sigprocmask の復元を追加。

### 9. `protocol.zig:327, 398` — `usize → u8` の silent truncation
`workspace.index > 255` で silent truncation/panic。
**修正方針**: `if (s.index > 255) return error.IndexTooLarge` を追加。

### 10. `main.zig:174` — tcgetattr の戻り値を捨てている
失敗時 `original_termios` は `undefined` のまま Server に渡る未定義動作。
**修正方針**: 戻り値チェックと TTY でない場合の早期エラー。

---

## 🟡 中優先度（パフォーマンス / 設計）

### A. `Renderer.zig:420-426` — borders 毎フレーム alloc/free
`drawBorders` で毎フレーム W×H 分の alloc/free。差分管理対象でないホットパス。
**修正方針**: `Renderer` フィールドに昇格して resize 時のみ再確保。

### B. `Server.zig:548-594` — protocol コマンド重複
`.yank` (414行) / `.clipboard_copy` (548行) が完全重複。`.paste` (451行) / `.clipboard_paste` (583行) も同じ。
**修正方針**: protocol 一本化または内部ヘルパに集約。

### C. `Renderer.zig` (841行) — 巨大ファイル
`DiffRenderer` / `BorderRenderer` / `OverlayRenderer` / `DirtyTracker` への分割余地。`Cell` / `DirtyRect` も独立ファイルへ。

### D. `nix/packages.nix:9` — バージョン不整合
`1.0.2` のまま (build.zig.zon は `1.1.0`)。

### E. `nix/packages.nix:49` — platforms に darwin が含まれない
macOS 対応したのに `platforms = linux only`。

### F. `Server.zig:140` — posix.read の全エラー継続
`error.WouldBlock` だけでなく全エラーで `continue` し、bad fd 時にループ燃焼の可能性。

### G. `Server.zig:147` — client.stream.read のエラー判定が `error.Closed` 限定
EOF 以外は `continue` だけで fd は残ったまま。

### H. `loop.zig:187` — kqueue EV_EOF + 残データの取りこぼし
`EV_EOF` でも未読データが残ることがある (`ev.data > 0`)。`.disconnect` を即返すと残データが捨てられる。client.zig:135 で `break :outer` するので sock 切断時の末尾を取りこぼす可能性。

### I. `CopyMode.zig:102` — saturating sub の誤用
`(self.cursor_y + half) -| (pane.rows - 1)` は saturating sub で常に >0 になり overflow 検知が壊れている。

### J. `Renderer.zig:319-326` — grapheme cluster 表示の壊れ
`utf8Encode catch continue` で base のみ出力し続きをスキップ → 表示が壊れる可能性。

### K. `StatusBar.zig:38` — East Asian Ambiguous 幅の固定仮定
`written += 4` は 大字を「2 列幅」と仮定。端末によって 1 列になり status bar が崩れる。

### L. `Config.zig:114, 117, 127` — パース失敗を黙って無視
設定ミス時にユーザーが気づけない。stderr に warning 推奨。

### M. `main.zig:188-190` — fd 0/1/2 の順序依存
`dup2` 推奨。

### N. `main.zig:196, 205` — sleep + リトライのレース
socket 作成完了の同期点がない。

---

## 🟢 低優先度（クリーンアップ）

- `client.zig:529-568` — `isSgrMousePrefix` / `looksLikeMouseSequenceFragment` 未使用
- `client.zig:356` — `if (!was_repeatable or !stay_in_prefix)` の冗長な条件
- `Renderer.zig:108-116` — `isPointDirty` 未使用
- `Stream.zig:19-31` — `read` (blocking) と `receiveData`+`nextMessage` (non-blocking) の二系統共存、片方 dead の可能性
- `build.zig:30-51, 104-114` — テンプレート由来の dead コメント大量
- `build.zig.zon:19-21` — テンプレート由来コメント
- `Server.zig:609` — `_ = encoded;` の冗長コード
- `Config.zig:117` — color 設定に 1MB は過剰
- `Config.zig:105-107` — `init()` が `load` から使われておらず未使用
- `Config.zig:77-80` — `toAnsiSeq` の "backward compatibility" コメント、内部用途なら削除可
- `loop.zig:54` — `linux.sigset_t = .{0}` は `std.mem.zeroes(...)` で統一すべき (Server.zig:63 と非対称)
- `loop.zig:82` — `EINTR` ハンドリングなし
- `loop.zig:173` — `kevent` 失敗を `catch 0` で握りつぶし
- `main.zig:65-71` — 不明コマンドのエラーが stdout、終了コード 0
- `main.zig:268` — `path_buf: [256]u8` が unix sockaddr の `sun_path` 制限 (~104) とずれている
- `Config.zig:110` — `XDG_CONFIG_HOME` 非対応
- `Pty.zig:78` — `ioctl(TIOCSWINSZ, &ws)` を slave_fd に呼んでいる (master 推奨)
- `CopyMode.zig:45` — `cursor_x + 1` の u16 オーバーフロー可能性

---

## 推奨アクションプラン

1. **クラッシュ系 (#1, #2, #3, #5)** をまず1コミットに
2. **macOS リリース整合性** — `nix/packages.nix` の version と platforms 更新
3. **リーク・UAF (#4, #7, #8, #9)** を順に対処
4. **クリーンアップ** は時間がある時にまとめて
