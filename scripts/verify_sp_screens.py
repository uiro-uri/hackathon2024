#!/usr/bin/env python3
"""スマホ縦画面でMap/Battleの見た目をスクショに残す。

verify.shの段階6(sp.png)は起動直後のTitleしか写らない。Map(ステージ選択)と
Battle(戦闘)の縦画面レイアウトを人が目視できるよう、実ブラウザで
Title→Map→Battle と遷移させて各画面を撮る。

Godotのcanvasはボタンを内部で描くのでDOMセレクタでは押せない。押す場所は2通りで出す:

  Title「ゲームスタート」: **描かれた画素からボタンを探す**。canvas中央の縦帯を走査し、
    横方向に連続して塗られた無彩色の帯＝ボタンの行を拾う。以前はここを
    「ボタン中心は画面中央+19base」という定数にしていたが、Titleの中身が変わるたびに
    静かにずれる(実際ずれていて、Titleを押せないままsp_map.pngにTitleが写り、
    それでも段階7は緑だった)。フォントサイズを変えると必ずずれるので画素検出にした。

  Map ノード: MapScreen.gd と同じ計算でbase座標を出し、device = base * scale に直す。
    こちらは幾何そのものなので計算で足りる。拡大率やbiasを変えたらここの既定も
    合わせること(クリックがノードから外れる)。

「押したのに画面が変わっていない」を検出するため、クリック前後のスクショの
変化画素の割合も出す。色数だけでは同じ暗い画面同士を区別できない。

  verify_sp_screens.py <port> <sp_map_out.png> <sp_battle_out.png> [width] [height]

標準出力に
  "<JS/Godotエラー数>|<map色数>|<battle色数>|<起動したか(1/0)>|<map変化%>|<battle変化%>"
を出す。

環境変数:
  WEB_BOOT_MS   Godotの起動を待つミリ秒 (既定: 15000)
  SP_BIAS       縦画面の縦寄せ(MapScreen/Battleのportrait_vertical_biasと一致させる, 既定0.7)
"""
import io
import os
import sys

import numpy as np
from PIL import Image
from playwright.sync_api import sync_playwright

DESIGN_W, DESIGN_H = 1280.0, 720.0

# MapScreen.gd / MapTree の定数。GDScript側と一致させること。
CELL = (64.0, 62.0)
NODE_RADIUS = 18.0
COLUMN_COUNT = 5
STEP_GOAL = 9
PANEL_RIGHT = 316.0
EDGE_MARGIN = 16.0
TITLE_BOTTOM = 52.0

# ボタン検出。中央から左右このbase幅だけを見る(ボタンは180base幅なので内側に収まる)。
BUTTON_PROBE_HALF_BASE = 60.0
# その帯のうち背景と違う画素がこの割合以上ある行を「塗り潰された帯」とみなす。
BUTTON_FILL_RATIO = 0.85
# 帯の色がボタンらしいか。ボタンの地は無彩色に近い暗色(実測 [21,20,26])。
# 明るさの下限は要らない(背景と違う画素が85%以上、という条件が既に効いている)。
# コマ(シアン)と文字(白)をここで落とす。
BUTTON_MAX_CHROMA = 20
BUTTON_MAX_LEVEL = 150
# 画面下端のこの割合はサウンドテストボタンなので除外する。
BUTTON_BOTTOM_EXCLUDE = 0.9
# 「ゲームスタート」と「言語」は縦に並ぶ。相方がこの倍率以内の隙間で続く帯を本命とみなす
# (大見出しの文字がたまたま帯に見えたときに、それを押しに行かないための保険)。
BUTTON_PAIR_GAP_FACTOR = 3.0

# canvasが単色(＝描画されていない)でないかを数える。verify_web.pyと同じ。
_CANVAS_COLORS_JS = """() => {
    const c = document.querySelector('canvas');
    if (!c) return -1;
    const gl = c.getContext('webgl2') || c.getContext('webgl');
    if (!gl) return -2;
    const px = new Uint8Array(4 * c.width * c.height);
    gl.readPixels(0, 0, c.width, c.height, gl.RGBA, gl.UNSIGNED_BYTE, px);
    const seen = new Set();
    for (let i = 0; i < px.length; i += 4) {
        seen.add(px[i] + ',' + px[i + 1] + ',' + px[i + 2]);
        if (seen.size > 4) break;
    }
    return seen.size;
}"""


def _fit_scale(cx, cy, tx, ty):
    if cx <= 0.0 or cy <= 0.0:
        return 1.0
    return min(tx / cx, ty / cy)


def _placement(sx, sy, vx, vy, hb, vb):
    return (max(0.0, vx - sx) * hb, max(0.0, vy - sy) * vb)


def _map_node_device(scale, base_w, base_h, bias, step, col):
    """MapScreen.gd の縦画面レイアウトを再現し、ノード中心のdevice座標を返す。"""
    span = ((COLUMN_COUNT - 1) * CELL[0], STEP_GOAL * CELL[1])
    content = (span[0] + 2 * NODE_RADIUS, span[1] + 2 * NODE_RADIUS)
    region_pos = (PANEL_RIGHT + EDGE_MARGIN, TITLE_BOTTOM)
    region_size = (base_w - PANEL_RIGHT - 2 * EDGE_MARGIN, base_h - TITLE_BOTTOM - EDGE_MARGIN)
    k = _fit_scale(content[0], content[1], region_size[0], region_size[1])
    scaled = (content[0] * k, content[1] * k)
    off = _placement(scaled[0], scaled[1], region_size[0], region_size[1], 0.5, bias)
    top_left = (region_pos[0] + off[0], region_pos[1] + off[1])
    cell = (CELL[0] * k, CELL[1] * k)
    node_radius = NODE_RADIUS * k
    half_span = (COLUMN_COUNT - 1) * 0.5 * cell[0]
    origin = (top_left[0] + node_radius + half_span, top_left[1] + node_radius)
    base = (origin[0] + (col - 2) * cell[0], origin[1] + step * cell[1])
    return (base[0] * scale, base[1] * scale)


def _to_array(png_bytes):
    return np.asarray(Image.open(io.BytesIO(png_bytes)).convert("RGB")).astype(int)


def _changed_percent(a, b):
    """2枚のスクショで色が変わった画素の割合(%)。押しても画面が変わらない事故の検出用。"""
    if a.shape != b.shape:
        return 100
    return int(round((np.abs(a - b).sum(axis=2) > 16).mean() * 100))


def _find_buttons(img, scale):
    """canvas中央の縦帯から、ボタンらしい塗り潰し帯の (上端, 下端) を上から順に返す。"""
    height, width, _ = img.shape
    cx = width // 2
    half = max(4, int(BUTTON_PROBE_HALF_BASE * scale))
    background = img[2, 2]
    band = img[:, max(0, cx - half):min(width, cx + half), :]
    filled = (np.abs(band - background).sum(axis=2) > 12).mean(axis=1)

    runs = []
    start = None
    for y, ratio in enumerate(filled):
        if ratio >= BUTTON_FILL_RATIO and start is None:
            start = y
        elif ratio < BUTTON_FILL_RATIO and start is not None:
            runs.append((start, y - 1))
            start = None
    if start is not None:
        runs.append((start, height - 1))

    buttons = []
    for top, bottom in runs:
        if (top + bottom) / 2 > height * BUTTON_BOTTOM_EXCLUDE:
            continue  # 画面下端のサウンドテストボタン
        color = np.median(band[top:bottom + 1].reshape(-1, 3), axis=0)
        if color.max() - color.min() <= BUTTON_MAX_CHROMA and color.mean() <= BUTTON_MAX_LEVEL:
            buttons.append((top, bottom))
    return buttons


def _start_button(buttons):
    """縦に並ぶ2つ組の上側＝「ゲームスタート」を返す。見つからなければ None。"""
    for i in range(len(buttons) - 1):
        top, bottom = buttons[i]
        gap = buttons[i + 1][0] - bottom
        if gap <= (bottom - top + 1) * BUTTON_PAIR_GAP_FACTOR:
            return buttons[i]
    return None


def main() -> int:
    if len(sys.argv) not in (4, 6):
        sys.exit("usage: verify_sp_screens.py <port> <sp_map.png> <sp_battle.png> [width] [height]")
    port, map_png, battle_png = sys.argv[1], sys.argv[2], sys.argv[3]
    width = int(sys.argv[4]) if len(sys.argv) == 6 else 390
    height = int(sys.argv[5]) if len(sys.argv) == 6 else 844
    bias = float(os.environ.get("SP_BIAS", "0.7"))
    boot_ms = int(os.environ.get("WEB_BOOT_MS", "15000"))

    # expandでは scale=min(W/1280, H/720)、base=device/scale。base(0,0)=device(0,0)。
    scale = min(width / DESIGN_W, height / DESIGN_H)
    base_w, base_h = width / scale, height / scale

    # Map 段1中央列(必ず到達可能)。
    node_dev = _map_node_device(scale, base_w, base_h, bias, 1, 2)

    errors: list[str] = []
    console: list[str] = []
    map_colors = battle_colors = -1
    map_moved = battle_moved = 0

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": width, "height": height})
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("console", lambda m: console.append(f"[{m.type}] {m.text}"))

        page.goto(f"http://127.0.0.1:{port}/index.html", wait_until="load")
        page.wait_for_timeout(boot_ms)  # wasm取得とGodotのブート

        title_shot = _to_array(page.screenshot())
        start = _start_button(_find_buttons(title_shot, scale))
        if start is None:
            # Title に「ゲームスタート」「言語」の2つが並んでいるはず。
            # 見つからないなら押す場所が分からないので、ここで諦めて理由を残す。
            errors.append("Titleのボタンを画素から検出できなかった")
        else:
            top, bottom = start
            page.mouse.click(width / 2.0, (top + bottom) / 2.0)
            page.wait_for_timeout(3000)

            page.screenshot(path=map_png)
            map_shot = _to_array(page.screenshot())
            map_colors = page.evaluate(_CANVAS_COLORS_JS)
            map_moved = _changed_percent(title_shot, map_shot)

            page.mouse.click(node_dev[0], node_dev[1])
            page.wait_for_timeout(3000)

            page.screenshot(path=battle_png)
            battle_shot = _to_array(page.screenshot())
            battle_colors = page.evaluate(_CANVAS_COLORS_JS)
            battle_moved = _changed_percent(map_shot, battle_shot)

        browser.close()

    booted = any("Godot Engine v" in m for m in console)
    godot_errors = [m for m in console if "ERROR" in m or "SCRIPT ERROR" in m]
    print(
        f"{len(errors) + len(godot_errors)}|{map_colors}|{battle_colors}"
        f"|{int(booted)}|{map_moved}|{battle_moved}"
    )

    for e in (errors + godot_errors)[:8]:
        print(f"  {e}", file=sys.stderr)
    if not booted:
        for m in console[-10:]:
            print(f"  console: {m}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
