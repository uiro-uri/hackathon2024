extends Control

## 分岐マップの画面。今いるノードと、そこから進める先だけを押せる。
##
## プロトタイプはHTMLのtableとJinjaのforで矢印を1マスずつ組み立てていたが、
## ここは_draw()で線を引き、ノードだけをButtonとして置く。
##
## 見た目の演出(選択可能マスの明滅・マウスオーバー・現在地リング・入場フェード)は
## _process()で時刻を溜めて毎フレームqueue_redraw()する。演出の数式はテストできる
## よう MapGlow の純粋関数に切り出してある。

## 進める先が選ばれた。遷移先の判断はMainがする。
signal node_chosen(coord: Vector2i)

const CELL := Vector2(64.0, 62.0)

## 中央列(2)が画面中央に来る位置。設計解像度1280x720に合わせている。
## 段0からゴールの段9までがCELL.y間隔で並ぶので、上端はタイトル表示の下に置く。
const ORIGIN := Vector2(640.0, 80.0)
const NODE_RADIUS := 18.0

const COLOR_LINE := Palette.MAP_LINE
const COLOR_VISITED := Palette.MAP_VISITED
const COLOR_CURRENT := Palette.MAP_CURRENT
const COLOR_NEXT := Palette.MAP_NEXT
const COLOR_PLAIN := Palette.MAP_PLAIN

## 現在地から進める先へ伸びる線の強調色。COLOR_NEXTに寄せた明るい緑。
const COLOR_PATH := Palette.MAP_PATH
## 選択可能マスの背後に敷く淡いグロー。低アルファで、明滅で濃さが動く。
const COLOR_GLOW := Palette.MAP_GLOW
## マウスオーバー中のマスの輪郭。
const COLOR_HOVER_RING := Palette.MAP_HOVER_RING
## 現在地を示す常時リング。
const COLOR_CURRENT_RING := Palette.MAP_CURRENT_RING
## ノードの縁取り。
const COLOR_OUTLINE := Palette.MAP_OUTLINE

## グロー環が明滅で広がる最大の追加半径(px)。
const GLOW_EXTRA := 7.0
## グローのアルファの下限/上限。下限>0にして消え切らない「淡い明滅」にする。
const GLOW_ALPHA_MIN := 0.12
const GLOW_ALPHA_MAX := 0.4
## マウスオーバーでマスが膨らむ量(px)。
const HOVER_GROW := 3.0
## 入場フェードの長さ(秒)。
const ENTRANCE_DURATION := 0.35

## 遭遇表示。ノード内に実レベルの数字、下辺の外側に敵数ぶんのピップを並べる。
## 数字はノード塗り（明るい緑/青〜中間の灰）に対して常に読める暗色（大きめ文字なので
## 最も暗いPLAIN地でも大文字コントラスト基準を満たす）。ピップは脅威色の赤。
const LEVEL_FONT := 20.0
const COLOR_LEVEL_TEXT := Palette.TEXT_OUTLINE
const PIP_RADIUS := 2.6
const PIP_GAP := 7.0
const PIP_OFFSET := 6.0
const COLOR_PIP := Palette.ENEMY

## 選択不能を表す番兵。どのノード座標(段0〜9)とも一致しない。
const NO_HOVER := Vector2i(-1, -1)

## 縦画面(スマホ)向けの調整。横画面(設計比16:9)では効かない。
@export_range(0.5, 1.0, 0.01) var portrait_fill: float = 0.9
@export_range(0.0, 1.0, 0.05) var portrait_vertical_bias: float = 0.7

## 縦画面で、左の取得済みパネル(tscnで右端316)とタイトルを避けるための境界。
## この3つは scripts/verify_sp_screens.py が同じ値を持っている(段階7のクリック位置を
## 同じ式で出すため)。変えるならあちらも同時に変えること。
const PANEL_RIGHT := 316.0
const EDGE_MARGIN := 16.0
const TITLE_BOTTOM := 52.0

## 取得済みパネルの設計上の上端/下端(tscnと一致)。縦画面ではここへ倍率を掛けて
## 縦にだけ伸ばす。横は PANEL_RIGHT を動かせないので触らない。
const PANEL_TOP := 210.0
const PANEL_BOTTOM := 680.0

## レイアウトの実効値。既定は設計値(横画面)。縦画面では_recompute_layoutが差し替える。
var _origin := ORIGIN
var _cell := CELL
var _node_radius := NODE_RADIUS
## 縦画面での拡大率。線幅やグローなどの装飾px にも掛ける。
var _draw_scale := 1.0

var _tree: MapTree
var _buttons: Dictionary = {}

var _time := 0.0
var _entrance := 0.0
var _hovered_coord := NO_HOVER

@onready var _acquired_list: VBoxContainer = $AcquiredPanel/VBox/Scroll/List


func _ready() -> void:
	# 画面比に合わせてノードの大きさ・間隔・位置を決める。縦画面のときだけ効く。
	get_viewport().size_changed.connect(_recompute_layout)
	_recompute_layout()


func setup(tree: MapTree) -> void:
	# 先にレイアウトを確定させてからノードを組む(ボタンが正しい大きさで並ぶ)。
	_recompute_layout()
	_tree = tree
	_rebuild()
	_rebuild_acquired()


func _process(delta: float) -> void:
	# マップ画面のみ・描画も軽いので毎フレーム再描画で問題ない(battleも同様)。
	_time += delta
	_entrance += delta
	queue_redraw()


func _rebuild() -> void:
	for button in _buttons.values():
		button.queue_free()
	_buttons.clear()

	# 表示し直すたびに入場フェードとホバー状態をやり直す。
	_entrance = 0.0
	_hovered_coord = NO_HOVER

	if _tree == null:
		return

	var reachable := _tree.next_coords()
	for coord in _tree.nodes:
		var button := Button.new()
		button.size = Vector2(_node_radius, _node_radius) * 2.0
		button.position = _to_pixel(coord) - button.size * 0.5
		button.flat = true
		# ノードIDはメタ情報なので出さない（プロトタイプも同じ判断をしている）。
		button.text = ""

		var is_next: bool = coord in reachable
		button.disabled = not is_next
		button.mouse_default_cursor_shape = (
			Control.CURSOR_POINTING_HAND if is_next else Control.CURSOR_ARROW
		)
		if is_next:
			button.pressed.connect(_on_node_pressed.bind(coord))
			# 選択可能マスだけホバーに反応させる。
			button.mouse_entered.connect(_on_node_hover.bind(coord))
			button.mouse_exited.connect(_on_node_unhover.bind(coord))
		add_child(button)
		_buttons[coord] = button

	queue_redraw()


func _on_node_pressed(coord: Vector2i) -> void:
	node_chosen.emit(coord)


func _on_node_hover(coord: Vector2i) -> void:
	_hovered_coord = coord


func _on_node_unhover(coord: Vector2i) -> void:
	# 別のマスへ移った直後の取りこぼしを避け、離れたのが今のマスの時だけ消す。
	if _hovered_coord == coord:
		_hovered_coord = NO_HOVER


## このランで取得済みのパーツ一覧を組み直す。組み立てはクリア画面と共有する
## AcquiredUpgradeList に任せる(集約はさらにその先のカタログ純関数)。
## 効果説明は省いて名前だけでコンパクトに並べる(show_description=false)。ステータスの
## 中身は左上の常時オーバーレイ(StatPanel)がバーで見せるので、ここは取得の一覧に徹する。
func _rebuild_acquired() -> void:
	AcquiredUpgradeList.populate(_acquired_list, GameState.acquired_part_ids, false)


func _to_pixel(coord: Vector2i) -> Vector2:
	# 列は中央(2)を基準に左右へ振り分ける。
	return _origin + Vector2((coord.y - 2) * _cell.x, coord.x * _cell.y)


## 入場フェードのアルファを掛けた色を返す。
func _faded(color: Color, e: float) -> Color:
	return Color(color.r, color.g, color.b, color.a * e)


func _draw() -> void:
	if _tree == null:
		return

	var reachable := _tree.next_coords()
	var e := MapGlow.entrance(_entrance, ENTRANCE_DURATION)
	var g := MapGlow.pulse(_time)

	# --- 辺 ---
	for coord in _tree.nodes:
		var node: MapTree.MapNode = _tree.nodes[coord]
		var from := _to_pixel(coord)
		for target in node.targets():
			if not _tree.nodes.has(target):
				continue
			var to := _to_pixel(target)
			# ノードの縁から縁へ引く。
			var dir := (to - from).normalized()
			var a := from + dir * _node_radius
			var b := to - dir * _node_radius
			# 現在地から進める先の辺だけ、明るく太く・薄く明滅させて経路を強調する。
			if coord == _tree.current_coord and target in reachable:
				var path_color := COLOR_PATH
				path_color.a *= lerpf(0.7, 1.0, g)
				draw_line(a, b, _faded(path_color, e), 3.0 * _draw_scale, true)
			else:
				draw_line(a, b, _faded(COLOR_LINE, e), 2.0 * _draw_scale, true)

	# --- 選択可能マスのグロー(ノード本体の背後) ---
	for coord in reachable:
		var center := _to_pixel(coord)
		var glow := COLOR_GLOW
		glow.a = lerpf(GLOW_ALPHA_MIN, GLOW_ALPHA_MAX, g)
		draw_circle(center, _node_radius + GLOW_EXTRA * g * _draw_scale, _faded(glow, e))

	# --- ノード本体（輪郭＝土俵形状・中にレベル・下に敵数） ---
	for coord in _tree.nodes:
		var center := _to_pixel(coord)
		var node: MapTree.MapNode = _tree.nodes[coord]
		var color := COLOR_PLAIN
		if coord == _tree.current_coord:
			color = COLOR_CURRENT
		elif coord in reachable:
			color = COLOR_NEXT
		elif coord.x < _tree.current_step():
			color = COLOR_VISITED

		var radius := _node_radius
		if coord == _hovered_coord:
			radius += HOVER_GROW * _draw_scale

		# 戦闘ノードは土俵の外周形状で、スタート（遭遇なし）は従来どおり円で描く。
		var shape := ArenaWall.WallShape.ROUND
		if node.has_encounter():
			shape = node.wall_shape()
		_draw_node_body(center, radius, shape, _faded(color, e), e)

		# マウスオーバー中のマスは明るい太リングで強調する（形状問わず円で囲う）。
		if coord == _hovered_coord:
			draw_arc(
				center, radius + 1.0 * _draw_scale, 0, TAU, 32,
				_faded(COLOR_HOVER_RING, e), 3.0 * _draw_scale, true
			)

		# 実レベルの数字と敵数ピップ（戦闘ノードのみ）。
		if node.has_encounter():
			_draw_encounter_info(center, radius, node, e)

	# --- 現在地マーカー(常時・明滅させない) ---
	if _tree.nodes.has(_tree.current_coord):
		var here := _to_pixel(_tree.current_coord)
		draw_arc(
			here, _node_radius + 4.0 * _draw_scale, 0, TAU, 40,
			_faded(COLOR_CURRENT_RING, e), 2.0 * _draw_scale, true
		)


## ノード本体を土俵の外周形状で描く。矩形/八角/円をそれぞれ塗り＋枠線で。
## fill は呼び出し側で入場フェード済み。枠線だけここでフェードを掛ける。
func _draw_node_body(center: Vector2, radius: float, shape: int, fill: Color, e: float) -> void:
	var outline := _faded(COLOR_OUTLINE, e)
	var width := 2.0 * _draw_scale
	match shape:
		ArenaWall.WallShape.RECT:
			var half := Vector2(radius, radius)
			var rect := Rect2(center - half, half * 2.0)
			draw_rect(rect, fill, true)
			draw_rect(rect, outline, false, width)
		ArenaWall.WallShape.OCTAGON:
			var pts := _polygon_points(center, radius, 8, PI / 8.0)
			draw_colored_polygon(pts, fill)
			_draw_closed_polyline(pts, outline, width)
		_:
			draw_circle(center, radius, fill)
			draw_arc(center, radius, 0, TAU, 32, outline, width, true)


## 中心・半径・辺数・回転から正多角形の頂点列を作る。
func _polygon_points(
	center: Vector2, radius: float, sides: int, rotation_offset: float
) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in sides:
		var a := rotation_offset + TAU * float(i) / float(sides)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	return pts


## 頂点列を閉じた輪郭として描く（draw_polylineは閉じないので先頭を末尾に足す）。
func _draw_closed_polyline(pts: PackedVector2Array, color: Color, width: float) -> void:
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, color, width, true)


## 実レベルの数字（中央）と敵数ぶんのピップ（下辺の外側）を描く。
func _draw_encounter_info(center: Vector2, radius: float, node: MapTree.MapNode, e: float) -> void:
	var font := ThemeDB.fallback_font
	var fs := maxi(1, int(round(LEVEL_FONT * _draw_scale)))
	var text := str(node.level())
	var ssize := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	# draw_stringはベースライン基準。中央に来るよう昇り/降りの差で縦位置を合わせる。
	var pos := Vector2(
		center.x - ssize.x * 0.5,
		center.y + (font.get_ascent(fs) - font.get_descent(fs)) * 0.5
	)
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, _faded(COLOR_LEVEL_TEXT, e))

	var count := node.enemy_count()
	if count <= 0:
		return
	var pip_r := PIP_RADIUS * _draw_scale
	var gap := PIP_GAP * _draw_scale
	var y := center.y + radius + PIP_OFFSET * _draw_scale
	var x0 := center.x - (count - 1) * gap * 0.5
	for i in count:
		draw_circle(Vector2(x0 + i * gap, y), pip_r, _faded(COLOR_PIP, e))


## 画面比に応じてノードの大きさ・間隔・位置を決める。横画面(設計比16:9)は設計値のまま。
## 縦画面のときだけ、左の取得済みパネルとタイトルを避けた領域へノード群をアスペクト維持で
## 拡大し、横は領域中央、縦は中央やや下へ寄せる。
func _recompute_layout() -> void:
	var visible := get_viewport().get_visible_rect().size
	_stretch_acquired_panel(ScreenLayout.is_portrait(visible))
	if not ScreenLayout.is_portrait(visible):
		_origin = ORIGIN
		_cell = CELL
		_node_radius = NODE_RADIUS
		_draw_scale = 1.0
		_reposition_buttons()
		return

	# ノード群の設計bbox(中心の広がり＋左右上下のノード半径ぶん)。
	var span := Vector2((MapTree.COLUMN_COUNT - 1) * CELL.x, MapTree.STEP_GOAL * CELL.y)
	var content := span + Vector2(NODE_RADIUS, NODE_RADIUS) * 2.0
	# 左パネルとタイトルを避けた領域。
	var region_pos := Vector2(PANEL_RIGHT + EDGE_MARGIN, TITLE_BOTTOM)
	var region_size := Vector2(
		visible.x - PANEL_RIGHT - EDGE_MARGIN * 2.0, visible.y - TITLE_BOTTOM - EDGE_MARGIN
	)
	var k := ScreenLayout.fit_scale(content, region_size)
	var scaled := content * k
	var top_left := region_pos + ScreenLayout.placement(
		scaled, region_size, 0.5, portrait_vertical_bias
	)

	_draw_scale = k
	_cell = CELL * k
	_node_radius = NODE_RADIUS * k
	# 中央列(2)のx。左端ノードの左端が top_left.x に来るよう原点を決める。
	var half_span := (MapTree.COLUMN_COUNT - 1) * 0.5 * _cell.x
	_origin = Vector2(top_left.x + _node_radius + half_span, top_left.y + _node_radius)
	_reposition_buttons()


## 取得済みパネルを縦画面で縦方向にだけ伸ばす。
##
## 横(PANEL_RIGHT=316)は動かさない。地図の領域はそこを避けて決まっており、同じ計算を
## scripts/verify_sp_screens.py が持っている(そちらが段階7のクリック位置を出す)ので、
## 横を動かすと検証のクリックが黙って外れる。
##
## 縦だけ伸ばすのは、縦画面では文字が2倍になり StatPanel(左上、自動高)が下へ伸びて
## 設計値 y=210 のこのパネルと重なるため。上端も下端も同じ倍率でずらせば両方避けられる。
func _stretch_acquired_panel(portrait: bool) -> void:
	var panel := $AcquiredPanel as Control
	var scale := FontScale.chrome_scale(portrait)
	panel.offset_top = PANEL_TOP * scale
	panel.offset_bottom = PANEL_BOTTOM * scale


## 既存ボタンの大きさと位置を今のレイアウト値で貼り直す。入場フェードは巻き戻さない。
func _reposition_buttons() -> void:
	for coord in _buttons:
		var button: Button = _buttons[coord]
		button.size = Vector2(_node_radius, _node_radius) * 2.0
		button.position = _to_pixel(coord) - button.size * 0.5
	queue_redraw()
