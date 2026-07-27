class_name FontScale
extends RefCounted

## フォントサイズの唯一の出所。役割(role)ごとの寸法と、そこから Theme を組む純粋関数。
##
## ゲームは1280x720の横画面設計 + stretch=canvas_items/expand。スマホ縦持ち(幅390px)では
## canvas のスケールが0.3倍ほどになり、base単位のフォントはそのぶん小さく描かれる
## (既定16pxが5px相当)。横画面の寸法をそのまま使うと縦画面では読めないので、
## 役割ごとに縦画面用の寸法を別に持つ。
##
## 倍率は「小さい文字ほど強く上げる」形にしてある(CAPTION 2.0倍 〜 DISPLAY 1.33倍)。
## 地図と同じ約3倍を一律に掛けると大見出しが1280の幅を超えるので、読めない下の段ほど
## 強く持ち上げ、元から読める上の段は控えめにする。
##
## Palette と同じ理由でここを唯一の出所にする。.tscn 側は役割名(theme_type_variation)
## だけを持ち、寸法は持たない。両方に書くと必ずずれる(実際 Palette の色は .tscn へ
## 手写しされて二重持ちになっている)。tests/test_font_scale.gd が
## 「.tscn に theme_override_font_sizes が残っていないこと」を見張っている。
##
## 分掌: 色は Palette、サイズは FontScale。Theme はその射影にすぎないので、
## Theme に色やスタイルを足し始めないこと。

## 役割名。そのまま Theme の type variation 名になり、.tscn の
## theme_type_variation = &"Display" と対応する。
const DISPLAY := &"Display"
const TITLE := &"Title"
const SUBTITLE := &"Subtitle"
const HEADING := &"Heading"
const BODY := &"Body"
const CAPTION := &"Caption"

## 役割 -> Vector2i(横画面のpx, 縦画面のpx)。
##
## 横画面の値は .tscn に散っていた既存の値をそのまま引き継いでいる(48/40/32/24/20/16)。
## 唯一 Battle のメッセージだけ 36 から SUBTITLE の 32 へ丸めた。7段階の刻みを役割で
## 説明できなかったため。横画面で見た目が変わるのはこの1箇所だけ。
const SIZES := {
	DISPLAY: Vector2i(48, 64),
	TITLE: Vector2i(40, 56),
	SUBTITLE: Vector2i(32, 48),
	HEADING: Vector2i(24, 40),
	BODY: Vector2i(20, 36),
	CAPTION: Vector2i(16, 32),
}

## 小さい順。テストが階層と倍率の単調性を確かめるのに使う。
const ROLES: Array[StringName] = [CAPTION, BODY, HEADING, SUBTITLE, TITLE, DISPLAY]

## 役割を振っていないノード(ボタン、StatPanelの行など)が拾う既定サイズの役割。
## 横画面では16、つまりGodotの既定と同じなので、役割なしノードの横の見た目は変わらない。
const DEFAULT_ROLE := CAPTION

## type variation の土台。役割はすべて Label 基準で作る。ボタンに役割を付けたく
## なったら、Label の font_color まで拾わないよう Button 基準の変種を別に作ること。
const VARIATION_BASE := &"Label"


## 役割の文字サイズ(px)。portrait は ScreenLayout.is_portrait() の結果を渡す。
static func size_for(role: StringName, portrait: bool) -> int:
	if not SIZES.has(role):
		push_error("FontScale: 未知の役割 %s" % role)
		return SIZES[DEFAULT_ROLE].x
	var pair: Vector2i = SIZES[role]
	return pair.y if portrait else pair.x


## 画面向きに応じたサイズを theme へ書き込む。
##
## Main は Theme を1つだけ持ち回して中身を書き換える。Theme は書き換えると changed を
## 出し、それを使っている Control が最小サイズから組み直すので、向きが変わっても
## 貼り直しは要らない(実測済み)。
static func fill_theme(theme: Theme, portrait: bool) -> void:
	theme.default_font_size = size_for(DEFAULT_ROLE, portrait)
	for role in ROLES:
		theme.set_type_variation(role, VARIATION_BASE)
		theme.set_font_size(&"font_size", role, size_for(role, portrait))


## 画面向きに応じた Theme を新しく作る。純関数(Node非依存)なのでテストから直接呼べる。
##
## フォント本体は project.godot の gui/theme/custom_font が出所なので触らない。
## default_font を空のままにしておけば探索がプロジェクト既定テーマへ抜けて、
## 日本語グリフを持つ Noto Sans JP がそのまま使われる(ここに Font を入れると豆腐になる)。
static func build_theme(portrait: bool) -> Theme:
	var theme := Theme.new()
	fill_theme(theme, portrait)
	return theme


## theme を「そこから下がまとめて拾える一番上の Control」に貼り、貼った数を返す。
##
## Godot のテーマ継承は Control と Window しか辿らず、間に Node / Node2D / CanvasLayer が
## 挟まるとそこで切れる(実測済み)。このゲームは ScreenHolder が Node、Battle のルートが
## Node2D、StatPanel が CanvasLayer なので、ウィンドウに貼るだけでは**どの画面にも届かない**。
## しかも届かなくてもエラーは出ず、既定の16のまま静かに描かれる。だから木を降りて
## 最初に見つけた Control へ貼り、そこから先は Godot の伝播に任せる。
##
## 戻り値は「1つも貼れていない」を呼び出し側とテストが検出するための数。
static func apply(node: Node, theme: Theme) -> int:
	if node is Control:
		(node as Control).theme = theme
		return 1
	if node is Window:
		(node as Window).theme = theme
		return 1
	var applied := 0
	for child in node.get_children():
		applied += apply(child, theme)
	return applied


## 固定サイズの器(パネル、カード、バー)を縦画面で広げる倍率。
##
## 文字だけ大きくすると固定 offset の器から溢れるので、器にもこれを掛ける。
## 一番強く拡大される DEFAULT_ROLE に合わせてあり、器の拡大率の出所をここ1箇所にする。
static func chrome_scale(portrait: bool) -> float:
	if not portrait:
		return 1.0
	var pair: Vector2i = SIZES[DEFAULT_ROLE]
	return float(pair.y) / float(pair.x)
