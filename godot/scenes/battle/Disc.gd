class_name Disc
extends Node2D

## コマ1体。座標も半径もアリーナのユニット系で、表示上の拡大は親のArenaRootの
## scaleが担う。
##
## 物理の計算そのものはBattleResolverが持ち、Battleが結果を流し込む。
## このノードは状態の保持と描画だけを受け持つ。
##
##
## 回転の見せ方について
##
## RPSは体力そのものなので、残りがどれだけあるかが見た目で読めないと困る。
## ところが素直に実速度で回すと、速すぎて読めないどころか止まって見える。
##
## 60fpsでは rps=15(初期値) が 90°/frame、上限の rps=40 なら 240°/frame。
## 一方、模様が正しく見える限界(ナイキスト)は「模様の周期の半分/frame」。
## 以前の破線8本は周期45°なので限界が 3.75rps しかなく、初期値の15rpsでは
## ちょうど2周期分/frameとなって完全に静止して見えていた。
##
## そこで2本立てにしている:
##
##  1. **非対称なマーク**が回転そのものを示す。周期が360°なので限界は30rps。
##     破線8本の8倍で、通常の戦闘域(15rpsから下)を丸ごと賄える。
##  2. **速さの尾**が速度の大きさを示す。マークから伸びる弧の長さがRPSに比例し、
##     速いほど長く、上限付近では円周を一周して"ブレたリング"になる。
##
## 高速域でマークが破綻するのは避けられない(40rpsは非対称でも限界30rpsを超える)
## が、そこでは尾が一周してマークを覆うので、破綻したマークは目立たない。
## そもそも毎秒40回転するコマは現実でもただのブレなので、これは嘘ではない。
##
##  3. **半透明のオーラとパーティクル**が勢いの存在感を示す。コマの背後に本体色の
##     薄いオーラを敷き、縁から粒が流れ出る。勢い(RPS比)が減ればオーラは細り、
##     粒は減り、力尽きれば消える。数式は SpinAura(純粋関数)が持つ。粒は回転する
##     ローカル座標系に描くので visual_rps() で自動的に公転する(実rpsで公転させると
##     マークと同じくナイキストを超えて逆回転に見えるため、そちらはしない)。
##
## マークの回転は限界の手前で頭打ちにしてある。超えた分は逆回転に見えてしまい、
## それは明確な嘘になるため。速さは尾が担うので情報は失われない。

## 非対称マークの角度の幅。狭いほど位置がはっきりするが、速いと見失う。
const MARK_ARC := 0.5

## 尾の太さ(半径に対する割合)。
const TAIL_WIDTH_RATIO := 0.28

## 描画順(z_index)の分解能。回転数をz_indexへ写すときの倍率。差が小さくても
## 手前/奥がはっきり決まるよう、rpsをそのまま丸めるより細かく刻む。
const DRAW_ORDER_SCALE := 8

## z_indexの上限。RPSの上限(CustomPartCatalog.RPS_CAP=40)×分解能ぶん。衝撃波や
## 予告・狙い(Battle.OVERLAY_Z)はこれより上へ退避させてあるので、回転数を上げても
## コマがそれらを覆い隠さない。
const DRAW_ORDER_Z_MAX := 320

## 60fpsを前提にしたときの、マークが正しく見える上限(rps)。
## ナイキスト(30rps)の手前に置く。ちょうど30だと前後どちらに回っているか
## 定まらず、超えると逆回転に見える。
@export_range(1.0, 30.0, 0.5) var max_visual_rps: float = 25.0

## 尾が円周を一周しきるRPS。これ以上は見た目が変わらない。
## 上限(40)に合わせてあるので、上限のコマは完全なリングになる。
@export_range(1.0, 60.0, 1.0) var tail_full_rps: float = 40.0

## 本体グラデーションのリム頂点数。円をこれだけの多角形で近似する。直線勾配は
## 位置の一次関数なので、リム頂点色を勾配で決めればgouraud補間が内部を厳密に
## 再現する(中心頂点は不要)。数が多いほど輪郭が滑らか。
const GRADIENT_SEGMENTS := 48

@export var stats: SpinnerStats
@export var body_color: Color = Palette.PLAYER

## 本体グラデーションの明度の振れ方。true=明側へ(プレイヤー既定)、false=暗側へ(敵)。
## 方向は陣営で固定。数式は DiscGradient が持つ。
@export var gradient_toward_light: bool = true

## 本体グラデーションの勾配軸(ローカル系・度)。マークは局所RIGHT=0°にあるので、
## 既定90°でマークと直交させ被りを避ける。ローカル系に描くのでコマと一緒に回る。
@export_range(0.0, 360.0, 1.0) var gradient_axis_deg: float = 90.0

var velocity: Vector2 = Vector2.ZERO

## 現在の回転数。尽きた方が負け。stats.rpsは初期値としてだけ使う。
var rps: float = 0.0

## 決着後に色を落とすためのフラグ。
var defeated: bool = false

## ゴースト(すり抜け)中か。真の間、本体を半透明シマーで描いて「敵をすり抜け中」を示す。
## 見た目だけで、当たり判定はBattleResolverがすり抜け窓として別に処理する。
var _ghosting: bool = false

## パーティクルの流れの位相に使う経過時刻。_processで進める。
var _time: float = 0.0


func _ready() -> void:
	if stats == null:
		stats = SpinnerStats.new()
	reset_spin()


## statsの初期値から回転をやり直す。
func reset_spin() -> void:
	rps = stats.rps
	defeated = false
	z_index = draw_order_z(rps)
	queue_redraw()


## 回転数が高いコマほど手前(z_indexが大)に描く。重なったとき勢いのある方が上に
## 見えるように。0以上に保つのは、床(Arena、z=0・不透明)より後ろへ落とさないため。
## 純粋関数なのでヘッドレスでテストできる。
static func draw_order_z(spin: float) -> int:
	return clampi(int(round(spin * DRAW_ORDER_SCALE)), 0, DRAW_ORDER_Z_MAX)


## 見た目を回す速さ。実速度そのままではナイキストを超えて逆回転に見えるので、
## 正しく見える範囲で頭打ちにする。速さの情報は尾が持つ。
func visual_rps() -> float:
	return minf(rps, max_visual_rps)


## 尾が円周のどれだけを占めるか(0〜1)。速さの大きさはこれが持つ。
func tail_ratio() -> float:
	if tail_full_rps <= 0.0:
		return 0.0
	return clampf(rps / tail_full_rps, 0.0, 1.0)


## オーラとパーティクルに使う勢い(0〜1)。尾と同じ尺度を使い、力尽きたコマは
## 勢いゼロ扱いにする(オーラも粒も消える)。ヘッドレスでテストできるよう関数にする。
func aura_ratio() -> float:
	return 0.0 if defeated else tail_ratio()


## ゴースト(すり抜け)中の表示を切り替える。再生側(Battle)がすり抜け窓の内外で呼ぶ。
## オフに戻すときは実体化(modulateを白へ)して、以後_processが触らないようにする。
func set_ghosting(on: bool) -> void:
	if _ghosting == on:
		return
	_ghosting = on
	if not on:
		modulate = Color(1.0, 1.0, 1.0, 1.0)
		queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	rotation += visual_rps() * TAU * delta
	# 回転数は再生中に変わるので、重なり順も毎フレーム追従させる。
	z_index = draw_order_z(rps)
	# ゴースト中は半透明シマーで揺らす。数式はGhostVisual(純粋関数)が持つ。
	if _ghosting:
		modulate = GhostVisual.modulate(_time)
	queue_redraw()


func _draw() -> void:
	var radius := stats.radius

	# 本体の前に、勢いを示すオーラと流れる粒を敷く。力尽きた/止まったコマでは
	# aura_ratio()が0になり、このブロックは丸ごと素通りする(敗北表示は不変)。
	var ar := aura_ratio()
	if ar > 0.001:
		_draw_aura(radius, ar)
		_draw_particles(radius, ar)

	_draw_body_gradient(radius)

	if defeated:
		# 力尽きたコマは回っていない。マークだけ残して尾は出さない。
		_draw_mark(radius, Color(Palette.SPIN_MARK, 0.25))
		return

	_draw_tail(radius)
	_draw_mark(radius, Color(Palette.SPIN_MARK, 0.95))


## 本体を直線グラデーションで塗る。リム多角形の各頂点色を、勾配軸への射影
## t=0.5+0.5*(p·axis)/radius から DiscGradient で決め、draw_polygon の gouraud 補間に
## 内部を任せる。ローカル系(rotationが乗る系)に描くのでコマと一緒に勾配が回る。
## 力尽きたコマは従来どおり暗転させる(基準色を暗く落としてから勾配を作る)。
func _draw_body_gradient(radius: float) -> void:
	var base := body_color.darkened(0.7) if defeated else body_color
	var axis := Vector2.RIGHT.rotated(deg_to_rad(gradient_axis_deg))
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	for i in GRADIENT_SEGMENTS:
		var ang := TAU * float(i) / float(GRADIENT_SEGMENTS)
		var p := Vector2.RIGHT.rotated(ang) * radius
		var t := 0.5 + 0.5 * (p.dot(axis) / radius)
		points.push_back(p)
		colors.push_back(DiscGradient.sample(base, gradient_toward_light, t))
	draw_polygon(points, colors)


## 本体色の薄い同心円を重ねて、勢いのオーラにする。回転不変なので回転座標系の
## ままでよい。色はbody_color由来+呼び出し側alpha(SPIN_MARKと同じ規約)。
func _draw_aura(radius: float, ratio: float) -> void:
	# 外側の淡い輪から内側の濃い輪へ重ねて、柔らかいグラデーションに見せる。
	for k in range(SpinAura.RING_COUNT - 1, -1, -1):
		var ring := SpinAura.aura_ring(ratio, radius, k)
		draw_circle(Vector2.ZERO, ring.radius, Color(body_color, ring.alpha))


## コマの縁から流れ出る半透明の粒。回転座標系に描くので自動的に公転する。
## 本体色を少し白へ寄せて、地のコマより明るく浮かせる。
func _draw_particles(radius: float, ratio: float) -> void:
	var tint := body_color.lerp(Color.WHITE, 0.35)
	for i in SpinAura.PARTICLE_COUNT:
		var p := SpinAura.particle_state(_time, i, ratio, radius)
		if p.alpha > 0.003:
			draw_circle(p.offset, p.radius, Color(tint, p.alpha))


## マークの後ろへ伸びる弧。長いほど速い。一周すればブレたリングになる。
func _draw_tail(radius: float) -> void:
	var ratio := tail_ratio()
	if ratio <= 0.001:
		return

	var width := radius * TAIL_WIDTH_RATIO
	var span := TAU * ratio
	# マークの手前(回転方向の後ろ)へ伸ばす。回転は反時計回りが正。
	var start := -MARK_ARC * 0.5
	# 根元を濃く、先を薄く。どちらが先端かが分かる。
	var steps := maxi(int(span / 0.15), 3)
	for i in steps:
		var t := float(i) / steps
		var a0 := start - span * t
		var a1 := start - span * (t + 1.0 / steps)
		var color := Color(Palette.SPIN_MARK, lerpf(0.55, 0.0, t))
		draw_arc(Vector2.ZERO, radius - width * 0.5, a1, a0, 4, color, width)


## 回転そのものを示す非対称なマーク。回転方向へ先細るくさび(彗星の頭)。
## 1つしかないので周期は360°。頭が前方(反時計回り)、太い尻に尾が続く。
func _draw_mark(radius: float, color: Color) -> void:
	var width := radius * TAIL_WIDTH_RATIO
	var a_tail := -MARK_ARC * 0.5   # 後方。太い背。尾の根元と噛み合う
	var a_tip := MARK_ARC * 0.5     # 前方。一点に収束する頭
	var steps := 8
	var poly := PackedVector2Array()
	# 外周は常に縁(radius)と面一。飛び出させない。尻→頭
	for i in steps + 1:
		var t := float(i) / steps
		poly.push_back(Vector2.RIGHT.rotated(lerpf(a_tail, a_tip, t)) * radius)
	# 内周を頭→尻へ戻す。厚みを頭の0から尻のwidthへ広げる。
	for i in steps + 1:
		var t := float(steps - i) / steps
		var thick := width * (1.0 - t)
		poly.push_back(Vector2.RIGHT.rotated(lerpf(a_tail, a_tip, t)) * (radius - thick))
	draw_colored_polygon(poly, color)
