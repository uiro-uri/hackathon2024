#!/usr/bin/env bash
#
# Slay the Spinner — 検証スクリプト
#
# 終了コードだけを信用しない。実際に「フォントと翻訳が焼き込まれていない
# 壊れたWebビルド」がexit 0で通った事故があったため、各段階に実質的な
# 判定基準を置いている。
#
#   scripts/verify.sh            全段階
#   scripts/verify.sh --quick    描画確認(5,6)を省略して速く回す
#
# 環境変数:
#   GODOT_BIN   godotバイナリのパス (既定: PATHのgodot4/godot, なければ ~/bin/godot4)
#   WEB_PORT    Web確認で使うポート (既定: 8099)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_PROJECT="$REPO_ROOT/godot"
BUILD_DIR="$REPO_ROOT/build"
ARTIFACT_DIR="$BUILD_DIR/verify"
VENV_DIR="$HOME/.cache/slay-the-spinner/venv"
WEB_PORT="${WEB_PORT:-8099}"

# 正常なpckは約11MB(うちフォントが約6MB)。フォントと翻訳が焼き漏れた
# 壊れたビルドは4.6MBだった。8MBならどちらからも十分離れている。
# 資産は増える一方なので下限として機能し続ける。
PCK_MIN_BYTES=$((8 * 1024 * 1024))

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

if [[ -z "${GODOT_BIN:-}" ]]; then
  if command -v godot4 >/dev/null 2>&1; then
    GODOT_BIN="$(command -v godot4)"
  elif command -v godot >/dev/null 2>&1; then
    GODOT_BIN="$(command -v godot)"
  else
    GODOT_BIN="$HOME/bin/godot4"
  fi
fi

FAILURES=()
SKIPS=()

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_dim=$'\e[2m'; c_rst=$'\e[0m'
stage() { printf '\n%s== %s ==%s\n' "$c_dim" "$1" "$c_rst"; }
ok()    { printf '  %sok  %s %s\n' "$c_grn" "$c_rst" "$1"; }
fail()  { printf '  %sFAIL%s %s\n' "$c_red" "$c_rst" "$1"; FAILURES+=("$1"); }
skip()  { printf '  %sSKIP%s %s\n' "$c_yel" "$c_rst" "$1"; SKIPS+=("$1"); }
detail(){ sed 's/^/         /' <<<"$1"; }

# --- 0. preflight -----------------------------------------------------------
# Godotが書くファイルがroot所有になっていないか。
#
# WSLでは、Windows側から \\wsl.localhost\ 経由で書いたファイルがroot所有に
# なる(9Pファイルサーバーがroot権限で動くため。sudoは関係ない)。つまり
# Windows版のGodotでこのプロジェクトを開くだけで、project.godotも.godot/も
# root所有になる。sudoでエディタを起動した場合も同じ結果になる。
#
# こうなるとインポートが権限エラーで失敗して.importがvalid=falseに書き換わり、
# フォントや翻訳が抜けた壊れたビルドが黙って出来上がる。gitがブランチを
# 切り替えられなくもなる。実際に両方踏んだので最初に検出する。
stage "0. preflight"

if [[ ! -x "$GODOT_BIN" ]]; then
  fail "godotバイナリが見つからない: $GODOT_BIN (GODOT_BIN で指定可)"
  printf '\n  %s1件失敗%s\n' "$c_red" "$c_rst"
  exit 1
fi
ok "godot: $("$GODOT_BIN" --version 2>/dev/null | head -1)"

# .godot/ だけでなくGodotが書き換えるファイル全部を見る。project.godotが
# root所有だとgitがブランチを切り替えられなくなる(実際に踏んだ)。
# .godot/の中はshader_cacheのように深い階層だけがrootになることもある。
foreign="$(find "$GODOT_PROJECT" ! -user "$(id -un)" -print 2>/dev/null | head -20)"
if [[ -n "$foreign" ]]; then
  count="$(find "$GODOT_PROJECT" ! -user "$(id -un)" -print 2>/dev/null | wc -l)"
  fail "godot/ に自分の所有でないものが ${count} 件ある。Windows版のGodotで開くか、sudoで起動すると起きる(下記参照)"
  detail "$(head -5 <<<"$foreign" | sed "s|$REPO_ROOT/||")"
  detail "直し方: 親ディレクトリが自分の所有なら sudo なしで消せる。"
  detail "  rm -rf godot/.godot && git checkout -- godot/project.godot"
  detail "再発を防ぐには、Windows版ではなくWSL側のGodotで開くこと(WSLgで窓が出る):"
  detail "  ~/bin/godot4 --path godot -e"
else
  ok "godot/ は全部自分の所有"
fi

# --- 1. import --------------------------------------------------------------
# 1回目は正当にエラーが出る: project.godotが参照する.translationとフォントが
# 起動時点でまだ生成されていないため。2回目に残っていたら本物のエラー。
stage "1. import (2回)"

log1="$(mktemp)"; log2="$(mktemp)"
"$GODOT_BIN" --headless --path "$GODOT_PROJECT" --import >"$log1" 2>&1
n1="$(grep -cE '^ERROR' "$log1")"
printf '  %s     1回目のエラー %s件 (生成物が未作成のため想定内)%s\n' "$c_dim" "$n1" "$c_rst"

"$GODOT_BIN" --headless --path "$GODOT_PROJECT" --import >"$log2" 2>&1
if grep -qE '^ERROR' "$log2"; then
  fail "2回目のimportでエラー"
  detail "$(grep -E '^ERROR' "$log2" | head -5)"
else
  ok "2回目のimportはエラーなし"
fi
rm -f "$log1" "$log2"

# --- 2. tests ---------------------------------------------------------------
# GDScriptの実行時エラーは例外として捕捉できず該当関数を中断するだけなので、
# 終了コードに加えてランナー側の完走報告も確認する。
stage "2. ヘッドレステスト"

log="$(mktemp)"
"$GODOT_BIN" --headless --path "$GODOT_PROJECT" --script res://tests/run_tests.gd >"$log" 2>&1
rc=$?
if [[ $rc -eq 0 ]] && grep -q 'すべて成功' "$log"; then
  ok "$(grep 'すべて成功' "$log" | head -1 | sed 's/^ *//')"
else
  fail "テスト失敗 (exit $rc)"
  detail "$(grep -E 'FAIL|失敗|SCRIPT ERROR' "$log" | head -8)"
fi
rm -f "$log"

# --- 3. headless run --------------------------------------------------------
stage "3. ヘッドレス起動"

log="$(mktemp)"
"$GODOT_BIN" --headless --path "$GODOT_PROJECT" --quit-after 30 >"$log" 2>&1
if grep -qE '^(ERROR|SCRIPT ERROR)' "$log"; then
  fail "起動時にエラー"
  detail "$(grep -E '^(ERROR|SCRIPT ERROR)' "$log" | head -5)"
else
  ok "メインシーンがエラーなく起動"
fi
rm -f "$log"

# --- 4. export --------------------------------------------------------------
# 壊れたビルドもexit 0で通るため、pckサイズで焼き漏れを捕まえる。
stage "4. 書き出し (Web/Linux/Windows)"

# Webプリセットのthread_supportを有効にすると、GodotはSharedArrayBufferを
# 要求する。それにはCOOP/COEPヘッダが要るが、配信先のGitHub Pagesは独自
# ヘッダを付けられないため、本番でだけゲームが起動しなくなる。しかも
# 書き出しは成功し、下のChromium確認もローカルのhttp.server経由では通って
# しまうので、ここで明示的に弾かないと誰も気づけない。
if grep -q '^variant/thread_support=true' "$GODOT_PROJECT/export_presets.cfg"; then
  fail "Webプリセットの variant/thread_support が有効. SharedArrayBufferにCOOP/COEPヘッダが必要になり、GitHub Pagesでは起動しなくなる (ローカルの確認は通ってしまう)"
else
  ok "Webプリセットは thread_support 無効 (GitHub Pagesにヘッダ不要)"
fi

mkdir -p "$BUILD_DIR/web" "$BUILD_DIR/linux" "$BUILD_DIR/windows"
for preset in Web Linux Windows; do
  log="$(mktemp)"
  "$GODOT_BIN" --headless --path "$GODOT_PROJECT" --export-release "$preset" >"$log" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]] || grep -qE '^ERROR' "$log"; then
    fail "$preset の書き出しに失敗 (exit $rc)"
    detail "$(grep -E '^ERROR' "$log" | head -3)"
  else
    ok "$preset 書き出し成功"
  fi
  rm -f "$log"
done

for pck in "$BUILD_DIR/web/index.pck" \
           "$BUILD_DIR/linux/slay-the-spinner.pck" \
           "$BUILD_DIR/windows/slay-the-spinner.pck"; do
  label="$(basename "$(dirname "$pck")")/$(basename "$pck")"
  if [[ ! -f "$pck" ]]; then
    fail "pckがない: $label"
    continue
  fi
  size="$(stat -c '%s' "$pck")"
  if [[ $size -lt $PCK_MIN_BYTES ]]; then
    fail "$label が $((size / 1024 / 1024))MB しかない (下限 $((PCK_MIN_BYTES / 1024 / 1024))MB). フォントか翻訳が焼き込まれていない可能性が高い"
  else
    ok "$label $((size / 1024 / 1024))MB"
  fi
done

# --- venv (5,6が使う) -------------------------------------------------------
ensure_venv() {
  if "$VENV_DIR/bin/python" -c 'import playwright, PIL' >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$(dirname "$VENV_DIR")"
  [[ -x "$VENV_DIR/bin/python" ]] || python3 -m venv "$VENV_DIR" >/dev/null 2>&1 || return 1
  "$VENV_DIR/bin/pip" install --quiet playwright pillow >/dev/null 2>&1 || return 1
  "$VENV_DIR/bin/python" -m playwright install chromium >/dev/null 2>&1 || return 1
  "$VENV_DIR/bin/python" -c 'import playwright, PIL' >/dev/null 2>&1
}

# --- 5. native render -------------------------------------------------------
# 配布するバイナリそのものを起動して絵が出るかまで見る。
#
# ここでプロジェクト(--path godot)を動かしても意味がない。それはエディタが
# ソースから直接動かしているだけで、書き出したバイナリとpckの組み合わせが
# 壊れていても素通りする。Steamやブラウザに載るのは書き出した方なので、
# 書き出した方を起動する。
#
# Movie Makerモードで固定FPS描画させPNG連番を得るので、ffmpeg等は要らない。
stage "5. ネイティブ描画 (書き出したバイナリ)"

native_bin="$BUILD_DIR/linux/slay-the-spinner.x86_64"

if [[ $QUICK -eq 1 ]]; then
  skip "--quick のため省略"
elif [[ -z "${DISPLAY:-}" ]]; then
  skip "DISPLAYがない (WSLg等のGUIが必要)"
elif [[ ! -x "$native_bin" ]]; then
  fail "書き出したバイナリがない: $native_bin"
elif ! ensure_venv; then
  skip "venvを用意できない ($VENV_DIR)"
else
  frames="$ARTIFACT_DIR/frames"
  rm -rf "$frames"; mkdir -p "$frames"
  log="$(mktemp)"
  timeout 90 "$native_bin" \
    --write-movie "$frames/f.png" --fixed-fps 10 --quit-after 15 >"$log" 2>&1
  frame="$(find "$frames" -name '*.png' | sort | tail -1)"
  if [[ -z "$frame" ]]; then
    fail "描画フレームが出力されなかった"
    detail "$(tail -5 "$log")"
  else
    info="$("$VENV_DIR/bin/python" "$REPO_ROOT/scripts/check_image.py" "$frame" 2>&1)"
    ncolors="${info%% *}"
    if [[ ! "$ncolors" =~ ^[0-9]+$ ]]; then
      fail "描画フレームを判定できなかった: $info"
    elif [[ "$ncolors" -lt 3 ]]; then
      fail "ネイティブ描画が実質ブランク (色数 $ncolors)"
    else
      cp "$frame" "$ARTIFACT_DIR/native.png"
      ok "ネイティブ描画OK ($info) -> build/verify/native.png"
    fi
  fi
  rm -rf "$frames"; rm -f "$log"
fi

# --- 6. web render ----------------------------------------------------------
# 横(1280x720)と縦(SP=スマホ縦画面)の両方で描画を確認する。SP版とはWeb版を
# スマホの縦画面ブラウザで開いた状態のこと(専用ビルドはない)。判定基準は
# ビューポートに依らず同じ(起動/JSエラー0/単色でない)。崩れ具合はそれぞれ
# 残すスクリーンショットを人が見て確認する。SP縦の寸法は SP_W/SP_H で変えられる。
stage "6. Web描画 (Chromium, 横1280x720 と 縦SP)"

SP_W="${SP_W:-390}"; SP_H="${SP_H:-844}"
# 段階7で「クリック前後に画面が変わった」とみなす変化画素の下限(%)。
SP_MOVE_MIN="${SP_MOVE_MIN:-3}"

# チェック対象: "キー|ラベル|幅|高さ|出力png"
web_specs=(
  "web|横 1280x720|1280|720|web.png"
  "sp|縦 SP ${SP_W}x${SP_H}|${SP_W}|${SP_H}|sp.png"
)

if [[ $QUICK -eq 1 ]]; then
  skip "--quick のため省略"
elif ! ensure_venv; then
  skip "venvを用意できない ($VENV_DIR)"
elif [[ ! -f "$BUILD_DIR/web/index.html" ]]; then
  skip "Web書き出しがない"
elif ss -tln 2>/dev/null | grep -q ":${WEB_PORT} "; then
  # ここで握られたままだと自分のサーバーはbindに失敗し、古いビルドを
  # 検証して誤って緑になる。黙って進むより落とす。
  fail "ポート ${WEB_PORT} が既に使用中。古いサーバーを止めるか WEB_PORT を変えてください"
else
  mkdir -p "$ARTIFACT_DIR"
  # サーバーは一度だけ立て、横と縦を同じビルドに対して確認する。
  (cd "$BUILD_DIR/web" && exec python3 -m http.server "$WEB_PORT" >/dev/null 2>&1) &
  server_pid=$!
  sleep 2

  for spec in "${web_specs[@]}"; do
    IFS='|' read -r _key label w h png <<<"$spec"
    out="$("$VENV_DIR/bin/python" "$REPO_ROOT/scripts/verify_web.py" "$WEB_PORT" "$ARTIFACT_DIR/$png" "$w" "$h")"
    web_rc=$?
    if [[ $web_rc -ne 0 || -z "$out" ]]; then
      fail "Web描画の確認を実行できなかった ($label)"
      continue
    fi
    IFS='|' read -r n_err n_colors booted <<<"$(tail -1 <<<"$out")"
    [[ "$booted" == "1" ]] && ok "ブラウザでGodotが起動 ($label)" || fail "ブラウザでGodotが起動しなかった ($label)"
    [[ "$n_err" == "0" ]] && ok "JSエラーなし ($label)" || fail "JSエラー ${n_err}件 ($label)"
    if [[ ! "$n_colors" =~ ^[0-9]+$ ]] || [[ "$n_colors" -lt 3 ]]; then
      fail "canvasが実質ブランク ($label, 色数 $n_colors)"
    else
      ok "canvas描画OK ($label, 色数 $n_colors) -> build/verify/$png"
    fi
  done

  kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null
fi

# --- 7. SP画面遷移描画 ------------------------------------------------------
# 段階6のsp.pngは起動直後のTitleしか写らない。Map(ステージ選択)とBattle(戦闘)の
# 縦画面レイアウトを人が目視できるよう、実ブラウザでTitle→Map→Battleと遷移させて
# 各画面を撮る。canvas単色でない・起動・エラー0・遷移で画面が変わったことは自動判定するが、
# 拡大や中央やや下の当否は残す sp_map.png / sp_battle.png を人が見て確かめる
# (既存の「画像を見る」方針)。色数だけを見ていた頃は、Titleを押し損ねてTitleのままの
# スクショが撮れていても緑になっていた。
stage "7. SP画面遷移描画 (Map/Battle, 縦${SP_W}x${SP_H})"

if [[ $QUICK -eq 1 ]]; then
  skip "--quick のため省略"
elif ! ensure_venv; then
  skip "venvを用意できない ($VENV_DIR)"
elif [[ ! -f "$BUILD_DIR/web/index.html" ]]; then
  skip "Web書き出しがない"
elif ss -tln 2>/dev/null | grep -q ":${WEB_PORT} "; then
  fail "ポート ${WEB_PORT} が既に使用中。古いサーバーを止めるか WEB_PORT を変えてください"
else
  mkdir -p "$ARTIFACT_DIR"
  (cd "$BUILD_DIR/web" && exec python3 -m http.server "$WEB_PORT" >/dev/null 2>&1) &
  server_pid=$!
  sleep 2
  out="$("$VENV_DIR/bin/python" "$REPO_ROOT/scripts/verify_sp_screens.py" \
    "$WEB_PORT" "$ARTIFACT_DIR/sp_map.png" "$ARTIFACT_DIR/sp_battle.png" "$SP_W" "$SP_H")"
  sp_rc=$?
  kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null

  if [[ $sp_rc -ne 0 || -z "$out" ]]; then
    fail "SP画面遷移の確認を実行できなかった"
  else
    IFS='|' read -r n_err map_colors battle_colors booted map_moved battle_moved \
      <<<"$(tail -1 <<<"$out")"
    [[ "$booted" == "1" ]] && ok "ブラウザでGodotが起動 (SP遷移)" || fail "ブラウザでGodotが起動しなかった (SP遷移)"
    [[ "$n_err" == "0" ]] && ok "JS/Godotエラーなし (SP遷移)" || fail "SP遷移中にエラー ${n_err}件"
    if [[ ! "$map_colors" =~ ^[0-9]+$ ]] || [[ "$map_colors" -lt 3 ]]; then
      fail "Map(縦)が実質ブランク (色数 $map_colors)"
    else
      ok "Map(縦)描画OK (色数 $map_colors) -> build/verify/sp_map.png"
    fi
    if [[ ! "$battle_colors" =~ ^[0-9]+$ ]] || [[ "$battle_colors" -lt 3 ]]; then
      fail "Battle(縦)が実質ブランク (色数 $battle_colors)"
    else
      ok "Battle(縦)描画OK (色数 $battle_colors) -> build/verify/sp_battle.png"
    fi
    # 色数だけでは「押せずにTitleのままのスクショ」を弾けない(実際それで緑になっていた)。
    # クリック前後で画面が実際に変わったかを別に見る。
    if [[ ! "$map_moved" =~ ^[0-9]+$ ]] || [[ "$map_moved" -lt "$SP_MOVE_MIN" ]]; then
      fail "Title→Mapで画面が変わっていない (変化 ${map_moved}% < ${SP_MOVE_MIN}%)"
    else
      ok "Title→Map遷移OK (画面変化 ${map_moved}%)"
    fi
    if [[ ! "$battle_moved" =~ ^[0-9]+$ ]] || [[ "$battle_moved" -lt "$SP_MOVE_MIN" ]]; then
      fail "Map→Battleで画面が変わっていない (変化 ${battle_moved}% < ${SP_MOVE_MIN}%)"
    else
      ok "Map→Battle遷移OK (画面変化 ${battle_moved}%)"
    fi
  fi
fi

# --- 結果 -------------------------------------------------------------------
stage "結果"
if [[ ${#SKIPS[@]} -gt 0 ]]; then
  printf '  %s省略した確認が%d件あります:%s\n' "$c_yel" "${#SKIPS[@]}" "$c_rst"
  for s in "${SKIPS[@]}"; do printf '    - %s\n' "$s"; done
fi
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  printf '  %sすべて成功%s\n' "$c_grn" "$c_rst"
  exit 0
fi
printf '  %s%d件失敗:%s\n' "$c_red" "${#FAILURES[@]}" "$c_rst"
for f in "${FAILURES[@]}"; do printf '    - %s\n' "$f"; done
exit 1
