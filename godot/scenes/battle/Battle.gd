extends Node2D

## 1戦分の進行。ここは計算せず、BattleResolverが返した結果を再生するだけ。
##
## 発射された瞬間に戦いは全部決まっている(発射は1回きりで、以後入力がない)ので、
## その場で最後まで計算してしまい、あとは時刻を進めながら軌跡をなぞる。
## 将来オンライン対戦をやるときは、この resolve() の呼び先がサーバーになる。
##
## プロトタイプ(simulation.py)もサーバーで全ステップを先に計算していた。
## あれが駄目だったのは結果をCSSキーフレームで再生していたからで、権威を
## サーバーに置く構造自体は正しかった。ここでは同じ構造をGodotの描画で再生する。
##
## 数値はすべて手触りで調整する前提。プロトタイプの値は出発点でしかない。

signal finished(player_won: bool)

const COLLISION_SPARK: PackedScene = preload("res://scenes/battle/CollisionSpark.tscn")
const DISC: PackedScene = preload("res://scenes/battle/Disc.tscn")

## 敵ディスクの色。プレイヤー(青)と対になる赤。元はBattle.tscnのEnemyDiscに
## 直接置いていたが、敵を動的に生成するようになったのでここへ移した。
const ENEMY_COLOR := Palette.ENEMY

## 衝撃波・予告・狙いを置くレイヤー。コマは回転数に応じてz_indexを上げる
## (Disc.draw_order_z、上限Disc.DRAW_ORDER_Z_MAX)ので、そのままだと勢いのあるコマが
## これらを覆い隠してしまう。コマの上限より確実に手前へ出して従来の重なり順を保つ。
const OVERLAY_Z := 1000

## 横画面(設計)でのArenaRoot/UIの既定値。縦画面から横へ戻すときここへ復元する。
const LAND_ARENA_POS := Vector2(390.0, 110.0)
const LAND_ARENA_SCALE := Vector2(50.0, 50.0)
const LAND_MESSAGE_RECT := Rect2(390.0, 300.0, 500.0, 60.0)
const LAND_BARS_RECT := Rect2(390.0, 622.0, 500.0, 60.0)

## アリーナの1辺(10ユニット×既定スケール50=500px)。当てはめの基準。
const ARENA_PX := 500.0
## 予告の揺れの中心をずらす向きの散らし幅(ラジアン)。基本は中心向きだが、
## この範囲で回して「常に同じ方向にずれる」と読まれないようにする。約±50度。
const BIAS_DIR_SPREAD := 0.9
## アリーナの下に確保するバー帯の設計上の高さ。当てはめで縦にこのぶん余分を取る。
const BAR_BAND := 90.0
## バー帯とアリーナの隙間、およびメッセージ/バー行の高さ(px)。
const BAND_GAP := 12.0
const BAR_ROW_H := 60.0

## ステージの傾斜の強さ。
@export_range(0.0, 20.0, 0.1) var stage_strength: float = 4.9

## すり鉢(外側ほど急)か円錐(一定傾斜)か。どちらが気持ちいいかは動かして決める。
@export var stage_shape: SpinnerPhysics.StageShape = SpinnerPhysics.StageShape.DISH

## ぶつかり合いの激しさ。大きいほど1回の衝突で削れるRPSが増える。
@export_range(0.0, 1.0, 0.01) var violence: float = 0.04

## 削れたRPSがどれだけ弾き飛ばしに変わるか。
## violenceを半減したぶん、弾き合いの勢いは維持するため2倍にして相殺している。
@export_range(0.0, 5.0, 0.05) var spin_kick_scale: float = 2.0

## 何もしなくても失われる回転(毎秒、半径に比例)。
@export_range(0.0, 5.0, 0.05) var natural_damping: float = 1.0

## 壁にぶつかった時に残る回転の割合。
@export_range(0.0, 1.0, 0.01) var wall_damping: float = 0.75

## これを下回ったら負け。
@export_range(0.0, 1.0, 0.01) var lose_threshold: float = 0.03

## 速度(linear)の上限。反発>1(Rage Reflection)で壁反射のたびに加速して
## アリーナ外へ脱出するのを防ぐ。0以下で無制限。
@export_range(0.0, 100.0, 1.0) var max_speed: float = 30.0

## 決着後、余韻を見せてから次へ進むまでの秒数。
@export_range(0.0, 5.0, 0.1) var finish_delay: float = 2.0

@export_group("決着演出")

## 決着を付けたコマ同士の衝突に合わせて、カメラを衝突点へ寄せてスローにする。
## 見た目だけの演出で、勝敗や軌跡(BattleResult)には一切影響しない。

## 決着衝突でどこまで寄るか。1.0で等倍(寄らない)。
@export_range(1.0, 4.0, 0.05) var finish_zoom: float = 2.0

## スローの底。1.0で等速、小さいほど遅くなる。Engine.time_scaleに掛ける。
@export_range(0.05, 1.0, 0.05) var finish_time_scale: float = 0.35

## 決着衝突の何秒前から演出を効かせ始めるか(再生時間)。
@export_range(0.0, 2.0, 0.02) var finish_zoom_lead: float = 0.28

## 末尾のコマ衝突を「決着衝突」と見なす、finish_timeとの最大差(秒)。これより
## 前の衝突しかなければ消耗戦とみなして演出しない。時間切れでも演出しない。
@export_range(0.0, 2.0, 0.05) var finish_effect_window: float = 0.5

## 決着後、ズームしたまま見せてから引くまでの秒数。finish_delayの内数。
@export_range(0.0, 3.0, 0.1) var finish_zoom_hold: float = 0.7

## ズームを元へ引き戻すのにかける秒数。finish_delayの内数。
@export_range(0.05, 3.0, 0.1) var finish_zoom_release: float = 0.5

## 勝敗ジングルを鳴らすまでの遅延(秒)。決着の瞬間に重ねず、少し余韻を置いてから鳴らす。
@export_range(0.0, 3.0, 0.05) var result_se_delay: float = 0.8

## 力尽きたコマが、消え始めるまでの待機(秒)。この間は最後の姿のまま残す。
## 乱戦の戦闘中に倒れた敵にも、決着で力尽きたコマ(敗者・引き分けの両者)にも同じ尺を使う。
@export_range(0.0, 5.0, 0.05) var enemy_fadeout_delay: float = EnemyFadeout.DEFAULT_DELAY

## 力尽きたコマのフェードにかける秒数。
@export_range(0.0, 5.0, 0.05) var enemy_fadeout_duration: float = EnemyFadeout.DEFAULT_DURATION

## 敵の初期状態。M3でマップから選ばれた敵に差し替える。
## 敵が出現する円周の、中心からの距離。壁とコマの半径より内側に取ること。
@export_range(1.0, 5.0, 0.1) var enemy_spawn_radius: float = 4.0

## 敵の狙いが中心からどれだけ外れうるか(度)。0なら必ず中心へ、
## 大きいほど読みにくくなる。
@export_range(0.0, 90.0, 5.0) var enemy_spread_deg: float = 30.0

## 発射前の初期表示で、敵をプレイヤーや他の敵からこれだけ離して出す余白(ユニット)。
## コマの縁同士がこの分だけ空く。予告の揺れ(表示のみ、揺れ幅±1.2+中心ずらしは
## 主に中心向き)ぶんも吸えるよう少し大きめ。
@export_range(0.0, 3.0, 0.05) var spawn_clearance: float = 0.6

## Battle.tscn単体で走らせたときの敵の性能。本編ではEnemyDataから来る。
## GameState.pending_enemiesが空のときだけ使う。
@export var fallback_enemy_stats: SpinnerStats

@export_group("縦画面(スマホ)")

## 縦画面のとき、コンテンツを画面幅のどれだけまで使うか。横画面では効かない。
@export_range(0.5, 1.0, 0.01) var portrait_fill: float = 0.9

## 縦画面のときの縦位置。0.5で中央、0.7で中央より下(親指で届きやすい)。横画面では効かない。
@export_range(0.0, 1.0, 0.05) var portrait_vertical_bias: float = 0.7

@export_group("壁エフェクト")

## 壁に当たった時の衝撃波。コマ同士(CollisionSpark既定)より小さく・短く・薄くして
## 控えめにする。色は壁(Arena.WALL_COLOR)に寄せ、当たった感を壁と結びつける。
## 手触りで詰める前提なので値はInspectorから触れるようにしてある。

## 広がりきる半径(ユニット)。コマ同士は2.4。
@export_range(0.2, 20.0, 0.1) var wall_spark_radius: float = 0.9

## 消えるまでの秒数。コマ同士は0.45。
@export_range(0.05, 3.0, 0.05) var wall_spark_duration: float = 0.3

## 出た瞬間の色。壁色を薄くしたもの。消える時は同色のままalpha 0へ抜ける。
@export var wall_spark_color: Color = Color(Palette.NEON_MAGENTA, 0.5)

@export_group("調整用")

## ドラッグを待たずに即開始する。このシーンだけをF5で走らせて挙動を見る用。
## 本編ではMainがドラッグ発射で始めるので false のままにしておくこと。
@export var auto_start: bool = false

## auto_start時のプレイヤーの初期位置と初速。
@export var auto_start_pos: Vector2 = Vector2(2, 8)
@export var auto_start_vel: Vector2 = Vector2(6, -6)

@onready var _arena_root: Node2D = $ArenaRoot
@onready var _arena: Arena = $ArenaRoot/Arena
@onready var _player: Disc = $ArenaRoot/PlayerDisc
@onready var _enemy_discs_root: Node2D = $ArenaRoot/EnemyDiscs
@onready var _enemy_telegraphs_root: Node2D = $ArenaRoot/EnemyTelegraphs
@onready var _launcher: LaunchController = $ArenaRoot/LaunchController
@onready var _message: Label = $UI/Message
@onready var _bars: VBoxContainer = $UI/Bars
@onready var _player_bar: ProgressBar = $UI/Bars/PlayerBar

var _max_rps: float = 1.0

## この戦闘の土俵。ランから来る。null ならシーンの@export値とArena.BOUNDSを使う
## （Battle.tscn単体で調整するとき用）。
var _field: FieldData = null

## この戦闘での敵たち。1体でも複数体(乱戦)でも同じ配列で扱う。
## 4つの配列は同じindexで対応する(_enemies[i]の予告が_telegraphs[i])。
var _enemies: Array[Disc] = []
var _telegraphs: Array[EnemyTelegraph] = []
var _enemy_bars: Array[ProgressBar] = []

## 各敵の出現内容。発射前に決めて予告しておく。
var _enemy_plans: Array[EnemySpawn.Plan] = []

## 各敵が rps を尽かした時刻(秒)。未撃破は -1.0。再生開始時に軌跡から確定する。
## 乱戦(敵が複数体)のときだけ、この時刻を基準に時間差で敵をフェードアウトさせる。
var _enemy_defeat_times: Array[float] = []

## 再生中の結果と、その中での現在時刻。
var _result: BattleResult = null
var _playback_time: float = 0.0

## まだ出していない衝突イベントの位置。時刻が来たら順に衝撃波を出す。
var _next_impact: int = 0

## 壁への衝突も同様に、時刻が追いついた順に控えめな衝撃波を出す。
var _next_wall_impact: int = 0

## いまのレイアウトのArenaRoot変換。決着演出でズームを掛けても必ずここへ戻す。
## _recompute_layout()が更新するので、縦横切り替え後も正しい基準を保つ。
var _arena_base_pos: Vector2 = Vector2.ZERO
var _arena_base_scale: Vector2 = Vector2.ONE

## 決着を付けたコマ衝突の時刻。負なら演出しない(play()で決める)。
var _decisive_time: float = -1.0

## いまゴースト(すり抜け)中か。窓の境目でプレイヤーの見た目とSEを切り替える。
var _ghost_active: bool = false


func _ready() -> void:
	set_physics_process(false)
	_launcher.launched.connect(_on_launched)
	_launcher.aim_moved.connect(_on_aim_moved)

	# メッセージは暗紫の床の上に出るので、明色文字＋暗色縁取りで読ませる。
	# 下を明るいネオンのコマやスパークが通っても縁取りで浮く。色はPaletteが唯一の出所。
	_message.text = "BATTLE_DRAG_TO_SHOOT"
	_message.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	_message.add_theme_color_override("font_outline_color", Palette.TEXT_OUTLINE)
	_message.add_theme_constant_override("outline_size", Palette.MESSAGE_OUTLINE_SIZE)

	# プレイヤーのコマ色もPalette由来にする(tscnのリテラルではなくここが権威)。
	# 本体グラデーションはプレイヤー=明側へ振る。
	_player.body_color = Palette.PLAYER
	_player.gradient_toward_light = true

	# コマは回転数でz_indexを上げる(勢いのある方が手前)。予告・狙い・衝撃波は
	# それより手前へ退避させ、コマに覆い隠されないようにする(従来の重なり順を保つ)。
	_enemy_telegraphs_root.z_index = OVERLAY_Z
	_launcher.z_index = OVERLAY_Z

	# 画面比に合わせてアリーナとUIを置き直す。縦画面のときだけ効く。
	get_viewport().size_changed.connect(_recompute_layout)
	_recompute_layout()

	_apply_run_state()

	# 敵の出現をここで決めてしまい、発射前から予告しておく。毎回変わるが、
	# プレイヤーは狙う前に相手の軌道を読める。
	#
	# 予告は確定値の周りで揺らして見せる(読み切らせないため)が、揺れるのは
	# 見た目だけ。撃つときは必ず_enemy_plansの確定値を使う。
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_max_rps = _player.stats.rps
	for data in _enemy_datas():
		_spawn_enemy(data, rng)
	set_process(true)

	_player.reset_spin()
	for enemy in _enemies:
		enemy.reset_spin()
	_update_bars()

	if auto_start:
		_begin(auto_start_pos, auto_start_vel)


## 画面比に応じてアリーナとUIを置き直す。横画面(設計比16:9)はシーン既定のまま。
## 縦画面のときだけ、アリーナ(正方)を幅fillの領域へアスペクト維持で拡大し、
## 中央やや下へ寄せる。バーはアリーナ直下、メッセージはアリーナ中央あたりへ。
##
## 発射入力はLaunchControllerが get_local_mouse_position() で読むので、ArenaRootの
## scale/positionを変えてもドラッグ発射は自動で整合する(clampもarena単位で不変)。
func _recompute_layout() -> void:
	var visible := get_viewport().get_visible_rect().size
	if not ScreenLayout.is_portrait(visible):
		_arena_root.scale = LAND_ARENA_SCALE
		# 非正方の土俵(横長楕円など)は正方footprintの中央へ寄せる。10x10ならオフセット0で従来通り。
		_arena_root.position = LAND_ARENA_POS + _footprint_offset(LAND_ARENA_SCALE.x, ARENA_PX)
		_record_arena_base()
		_set_rect(_message, LAND_MESSAGE_RECT)
		_set_rect(_bars, LAND_BARS_RECT)
		return

	# アリーナ＋下のバー帯を、幅fillの領域へアスペクト維持で収める。
	var content := Vector2(ARENA_PX, ARENA_PX + BAR_BAND)
	var target := Vector2(visible.x * portrait_fill, visible.y)
	var k := ScreenLayout.fit_scale(content, target)
	var arena_px := ARENA_PX * k
	var block := Vector2(arena_px, content.y * k)
	var top_left := ScreenLayout.placement(block, visible, 0.5, portrait_vertical_bias)

	_arena_root.scale = LAND_ARENA_SCALE * k
	# 非正方の土俵はアリーナ正方領域(arena_px)の中央へ寄せる。10x10ならオフセット0。
	_arena_root.position = top_left + _footprint_offset(LAND_ARENA_SCALE.x * k, arena_px)
	_record_arena_base()

	# メッセージはアリーナ幅に合わせ、アリーナの縦中央あたりへ。
	_set_rect(_message, Rect2(top_left.x, top_left.y + arena_px * 0.4, arena_px, BAR_ROW_H))
	# バーはアリーナ直下、幅いっぱい。
	_set_rect(_bars, Rect2(top_left.x, top_left.y + arena_px + BAND_GAP, arena_px, BAR_ROW_H))


## 土俵(bounds)を正方footprintの中央へ寄せるためのピクセルオフセット。
## px_per_unitはArenaRootのスケール(1ユニット当たりpx)。10x10ならbounds*scale=footprintで
## オフセット0＝従来の左上詰めのまま。横長楕円など縦が短い土俵は下方向へ寄って中央に来る。
func _footprint_offset(px_per_unit: float, footprint: float) -> Vector2:
	var scaled := _bounds().size * px_per_unit
	return (Vector2(footprint, footprint) - scaled) * 0.5


## いまのレイアウトのArenaRoot変換を決着演出の起点として控える。演出はここを
## 基準にズームし、終わったら必ずここへ戻す。レイアウトが変わるたびに更新する
## ので、縦横切り替えやリサイズ後も正しい基準を保つ。
func _record_arena_base() -> void:
	_arena_base_pos = _arena_root.position
	_arena_base_scale = _arena_root.scale


## CanvasLayer上のControl(アンカー0=左上)の矩形を offset で設定する。
func _set_rect(control: Control, rect: Rect2) -> void:
	control.offset_left = rect.position.x
	control.offset_top = rect.position.y
	control.offset_right = rect.position.x + rect.size.x
	control.offset_bottom = rect.position.y + rect.size.y


## この戦闘に出す敵の一覧。ランの状態があればそれを、なければ(Battle.tscn単体で
## 走らせたとき)フォールバックの1体を返す。
func _enemy_datas() -> Array[EnemyData]:
	if not GameState.pending_enemies.is_empty():
		return GameState.pending_enemies
	var stats := fallback_enemy_stats if fallback_enemy_stats != null else SpinnerStats.new()
	return [EnemyData.make(1, "ENEMY_1_1", stats)]


## 敵を1体ぶん生成する。ディスク・予告・HPバーを作り、出現内容を決めて予告する。
## 4つの配列(_enemies/_telegraphs/_enemy_bars/_enemy_plans)へindexを揃えて積む。
func _spawn_enemy(data: EnemyData, rng: RandomNumberGenerator) -> void:
	var disc := DISC.instantiate() as Disc
	disc.stats = data.stats
	disc.body_color = ENEMY_COLOR
	# 本体グラデーションは敵=暗側へ振る。
	disc.gradient_toward_light = false
	_enemy_discs_root.add_child(disc)

	var telegraph := EnemyTelegraph.new()
	# 強い敵ほど予告が大きくブレて読みにくくする。
	if data != null:
		telegraph.apply_level(data.level)
	# 発射速度は0まで下がりうるので、予告がこのコマの下に隠れないよう半径を渡す。
	telegraph.readable_radius = disc.stats.radius
	_enemy_telegraphs_root.add_child(telegraph)

	# HPバーの見た目はプレイヤーバー(Battle.tscnで設定)に合わせる。背景は共有し、
	# 塗りだけ敵色で作る。動的生成なのでtscnのサブリソースは使えず、コードで組む。
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 22)
	bar.show_percentage = false
	var bg := _player_bar.get_theme_stylebox("background")
	if bg != null:
		bar.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = ENEMY_COLOR
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("fill", fill)
	_bars.add_child(bar)

	# 発射速度は自機と共通のレンジから出現ごとに抽選する(位置・向きと同じ扱い)。
	# EnemyTelegraphがplan.velocityをそのまま予告するので、速度も自動で予告される。
	var speed := LaunchSpeed.random(rng)

	# 発射前の表示が重ならないよう、プレイヤーの初期位置と既に決めた敵の位置を
	# 除け所として渡す。min_gapはコマの縁同士がspawn_clearanceだけ空く距離。
	# 相手半径はプレイヤー・既出の敵で違うので、一番大きい相手半径で見積もる。
	var avoid: Array[Vector2] = [_player.position]
	var opponent_radius := _player.stats.radius
	for other in _enemies:
		avoid.append(other.position)
		opponent_radius = maxf(opponent_radius, other.stats.radius)
	var min_gap := opponent_radius + disc.stats.radius + spawn_clearance

	var plan := EnemySpawn.plan(
		_center(), enemy_spawn_radius, speed, enemy_spread_deg, rng,
		disc.stats.radius, _inradius(), avoid, min_gap
	)
	disc.position = plan.position
	disc.velocity = Vector2.ZERO
	# 予告の揺れの中心を確定値からずらす向き。平均を取っても真の位置を割り出せない
	# ようにするため。基本は中心向き(壁から離れる側)にして、揺れが壁を突き抜けない
	# ようにしつつ、±で散らして「常に真下」のような読み方を許さない。
	var to_center := _center() - plan.position
	var inward := to_center.normalized() if to_center.length() > 0.001 else Vector2.UP
	var bias_dir := inward.rotated(rng.randf_range(-BIAS_DIR_SPREAD, BIAS_DIR_SPREAD))
	telegraph.show_plan(plan.position, plan.velocity, bias_dir)

	_enemies.append(disc)
	_telegraphs.append(telegraph)
	_enemy_bars.append(bar)
	_enemy_plans.append(plan)
	_max_rps = maxf(_max_rps, data.stats.rps)


## 発射前は、各コマを自分の予告の三角形の頂点に合わせて漂わせる。
## 揺らすのは見た目だけなので、ここで_enemy_plansは書き換えない。
func _process(_delta: float) -> void:
	if _result != null:
		set_process(false)
		return
	for i in _enemies.size():
		_enemies[i].position = _telegraphs[i].display_position()


## ランの状態があればプレイヤーの性能と土俵に使う。Battle.tscn単体で走らせたときは
## シーンに置いてある値のままにして、単体で調整できるようにしておく。
## 敵の性能は_spawn_enemyがEnemyDataから直接ディスクへ入れる。
func _apply_run_state() -> void:
	if GameState.player_stats != null:
		_player.stats = GameState.player_stats
	_field = GameState.pending_field
	# 土俵の見た目(壁の位置・形状・障害物・等高線)を反映してから最初の描画に入る。
	# フィールドが無い単体調整時は、シーンの@export(stage_shape/strength)を等高線に使う。
	_arena.setup(_field, stage_shape, stage_strength)


## 土俵の矩形。フィールドがあればそれ、なければシーン既定のArena.BOUNDS。
func _bounds() -> Rect2:
	return _field.arena_bounds if _field != null else Arena.BOUNDS


func _center() -> Vector2:
	return _bounds().get_center()


func _wall_shape() -> ArenaWall.WallShape:
	return _field.wall_shape if _field != null else ArenaWall.WallShape.RECT


func _inradius() -> float:
	if _field != null:
		return _field.inradius()
	return ArenaWall.inradius_for(ArenaWall.WallShape.RECT, Arena.BOUNDS)


## 発射地点を土俵の内側へ寄せる。矩形は矩形クランプ、楕円は楕円クランプ、
## その他の非矩形は内接円クランプ。
func _clamp_launch(pos: Vector2) -> Vector2:
	match _wall_shape():
		ArenaWall.WallShape.RECT:
			return ArenaWall.clamp_inside(_bounds(), pos, _player.stats.radius)
		ArenaWall.WallShape.ELLIPSE:
			return ArenaWall.clamp_inside_ellipse(
				_center(), _bounds().size * 0.5, pos, _player.stats.radius)
		_:
			return ArenaWall.clamp_inside_circle(
				_center(), _inradius(), pos, _player.stats.radius)


## 狙っている間、コマを三角形の頂点(＝発射地点)へ置く。ここから飛ぶ、が
## 見たままになる。以前はどこをクリックしても発射の瞬間にコマが飛んでいた。
func _on_aim_moved(origin: Vector2) -> void:
	if _result != null:
		return
	_player.position = _clamp_launch(origin)


func _on_launched(pos: Vector2, velocity: Vector2) -> void:
	AudioManager.play("launch")
	_begin(_clamp_launch(pos), velocity)


## 発射して戦闘へ入る。auto_startもここを通す。
##
## 以前はauto_startが独自に組み立てていて hide_plan() を呼び忘れており、
## 予告の三角形が戦闘中ずっと画面に残っていた。調整用の経路とはいえ、
## 挙動を見るために使う経路が本編と違う絵を出すのは困る。
func _begin(player_pos: Vector2, player_vel: Vector2) -> void:
	_launcher.set_enabled(false)
	for telegraph in _telegraphs:
		telegraph.hide_plan()
	_message.text = ""
	start(player_pos, player_vel)


## 初期位置と初速を与えて開始する。座標はアリーナのユニット系。敵の発射内容は
## _enemy_plansの確定値を使う(予告の揺れは見た目だけなので混ぜない)。
##
## ここで戦いを最後まで計算してしまい、以降は再生するだけ。
func start(player_pos: Vector2, player_vel: Vector2) -> void:
	var request := build_request(player_pos, player_vel)
	play(BattleResolver.resolve(request))


## 今の調整値で、この発射内容のリクエストを組み立てる。
## 将来サーバーへ送るのはこれ。
func build_request(player_pos: Vector2, player_vel: Vector2) -> BattleRequest:
	var request := BattleRequest.new()
	request.player = BattleRequest.Launch.new(_player.stats, player_pos, player_vel)
	var enemies: Array[BattleRequest.Launch] = []
	for i in _enemies.size():
		enemies.append(BattleRequest.Launch.new(
			_enemies[i].stats, _enemy_plans[i].position, _enemy_plans[i].velocity
		))
	request.enemies = enemies
	# 土俵(壁の位置・形状、傾斜、障害物)はフィールドから。
	# フィールドが無い単体調整時はシーンの@export値とArena.BOUNDSを使う。
	if _field != null:
		request.arena_bounds = _field.arena_bounds
		request.wall_shape = _field.wall_shape
		request.obstacles = _field.obstacles
		request.stage_strength = _field.stage_strength
		request.stage_shape = _field.stage_shape
	else:
		request.arena_bounds = Arena.BOUNDS
		request.wall_shape = ArenaWall.WallShape.RECT
		request.stage_strength = stage_strength
		request.stage_shape = stage_shape
	request.violence = violence
	request.spin_kick_scale = spin_kick_scale
	request.natural_damping = natural_damping
	request.wall_damping = wall_damping
	request.lose_threshold = lose_threshold
	request.max_speed = max_speed
	# 取得済みのゴースト札からすり抜け時間を決める。単体調整時は取得0で0秒になり従来どおり。
	request.ghost_duration = CustomPartCatalog.total_ghost_seconds(GameState.acquired_part_ids)
	return request


## 計算済みの結果を再生する。ローカルで解いた結果でも、将来サーバーから
## 返ってきた結果でも、ここから先は同じ。
func play(result: BattleResult) -> void:
	_result = result
	_playback_time = 0.0
	_next_impact = 0
	_next_wall_impact = 0
	# 決着を付けたコマ衝突があればその時刻を控える。無ければ -1(演出なし)。
	_decisive_time = FinishFocus.decisive_impact_time(result, finish_effect_window)

	_player.reset_spin()
	for enemy in _enemies:
		enemy.reset_spin()

	# 各敵が rps を尽かす時刻を軌跡から確定しておく。乱戦のフェードアウトはこの時刻を基準にする。
	# reset_spin() は defeated を戻すが不透明度は戻さないので、ここで明示的に元へ戻す。
	_enemy_defeat_times.clear()
	for i in _enemies.size():
		_enemy_defeat_times.append(
			EnemyFadeout.defeat_time(_result.enemy_tracks[i], lose_threshold, _result.time_step)
		)
		_enemies[i].modulate.a = 1.0
		_enemy_bars[i].modulate.a = 1.0

	_apply_frame(0.0)
	# ゴースト(すり抜け)の見た目とSEをt=0の状態に合わせる。窓が開くのは最初の衝突の
	# 直後なので、t=0では常に不活性。開始SEは再生が窓に入った瞬間に鳴る。
	_ghost_active = false
	_update_ghost(0.0)
	# 戦闘中ずっと鳴る回転音を鳴らし始める。周波数・振幅は毎フレーム rps で更新する。
	AudioManager.start_rotation()
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if _result == null:
		return

	_playback_time += delta
	_apply_frame(_playback_time)
	_update_ghost(_playback_time)
	# 自分のコマの残り回転で回転音を鳴らす。力尽きれば AudioLevels 側で無音になる。
	AudioManager.update_rotation(_player.rps, _max_rps, lose_threshold)
	_emit_due_impacts(_playback_time)
	_emit_due_wall_impacts(_playback_time)
	_apply_finish_focus(_playback_time)

	if _playback_time >= _result.finish_time:
		_finish()


## ゴースト(すり抜け)の見た目とSEを、時刻tが窓の内か外かに合わせる。
## 窓はリゾルバが記録した「最初の衝突(ghost_start)の直後からghost_duration秒」。
## 窓が開かなかった戦い(ghost_start<0)は常に不活性。
## 境目をまたいだ瞬間だけSEを鳴らし、コマのシマー表示を切り替える。
func _update_ghost(t: float) -> void:
	var active := (
		_result.ghost_start >= 0.0
		and t > _result.ghost_start
		and t < _result.ghost_start + _result.ghost_duration
	)
	if active == _ghost_active:
		return
	_ghost_active = active
	_player.set_ghosting(active)
	AudioManager.play("ghost_start" if active else "ghost_end")


## 決着衝突に近づくほど、時間をスローにしカメラを衝突点へ寄せる。演出なし
## (_decisive_time<0)なら強さは常に0で、time_scaleもArenaRootも素のままになる。
##
## スローはEngine.time_scaleで掛ける。_physics_processのdelta・SceneTreeTimer・
## スパークの_processが同じ倍率で遅くなり、コマもスパークも一緒にスローになる。
## _playback_timeはtime_scale済みのdeltaで進むので追加のスケールは要らない。
func _apply_finish_focus(t: float) -> void:
	var s := FinishFocus.strength_at(t, _decisive_time, finish_zoom_lead)
	Engine.time_scale = lerpf(1.0, finish_time_scale, s)
	var xform := FinishFocus.arena_transform(
		_arena_base_pos, _arena_base_scale,
		FinishFocus.decisive_impact_point(_result),
		get_viewport_rect().size, finish_zoom, s
	)
	_arena_root.position = xform["position"]
	_arena_root.scale = xform["scale"]


## 時刻に応じた状態をコマへ反映する。フレーム間はBattleResultが補間するので、
## 描画のfpsが計算の刻み幅と違っていても滑らかに動く。
func _apply_frame(t: float) -> void:
	var p := _result.sample(_result.player_frames, t)
	_player.position = p.position
	_player.velocity = p.velocity
	_player.rps = p.rps

	for i in _enemies.size():
		var e := _result.sample(_result.enemy_tracks[i], t)
		_enemies[i].position = e.position
		_enemies[i].velocity = e.velocity
		_enemies[i].rps = e.rps
		# 乱戦のときだけ、倒れた敵を「暗くしてから時間差で消す」。1体戦闘は現状維持。
		if _enemies.size() > 1:
			_apply_fadeout(i, t)

	_update_bars()


## 乱戦で倒れた敵 i を、rpsを尽かした瞬間に暗転させ、一定時間後に不透明度を落として消す。
## ディスクとHPバーを揃えて消し、生き残った敵と混ざらないようにする。
func _apply_fadeout(i: int, t: float) -> void:
	var td := _enemy_defeat_times[i]
	if td >= 0.0 and t >= td:
		# rps=0 の姿(暗転・尾なし)を見せてから消す。以後の_finishのdefeated設定とも矛盾しない。
		_enemies[i].defeated = true
	var a := EnemyFadeout.alpha_at(t, td, enemy_fadeout_delay, enemy_fadeout_duration)
	_enemies[i].modulate.a = a
	_enemy_bars[i].modulate.a = a


## 衝突は計算中に起きているので、再生時刻が追いついたところで衝撃波を出す。
func _emit_due_impacts(t: float) -> void:
	while _next_impact < _result.impacts.size() and _result.impacts[_next_impact].time <= t:
		_spawn_spark(_result.impacts[_next_impact].point)
		AudioManager.play("impact")
		_next_impact += 1


## 壁への衝突も同じ要領で、時刻が来たところで控えめな衝撃波を出す。
## コマ同士とは別のカーソルで独立に進むだけで、互いに干渉しない。
func _emit_due_wall_impacts(t: float) -> void:
	while (
		_next_wall_impact < _result.wall_impacts.size()
		and _result.wall_impacts[_next_wall_impact].time <= t
	):
		_spawn_wall_spark(_result.wall_impacts[_next_wall_impact].point)
		AudioManager.play("wall")
		_next_wall_impact += 1


func _update_bars() -> void:
	_player_bar.max_value = _max_rps
	_player_bar.value = _player.rps
	for i in _enemy_bars.size():
		_enemy_bars[i].max_value = _max_rps
		_enemy_bars[i].value = _enemies[i].rps


## 衝撃波をアリーナのユニット系に生やす。自分で消えるので後始末は要らない。
func _spawn_spark(at: Vector2) -> void:
	var spark := COLLISION_SPARK.instantiate()
	spark.position = at
	spark.z_index = OVERLAY_Z
	$ArenaRoot.add_child(spark)


## 壁用の控えめな衝撃波。同じCollisionSparkを、小さく・短く・壁色に寄せた値で使い回す。
func _spawn_wall_spark(at: Vector2) -> void:
	var spark := COLLISION_SPARK.instantiate()
	spark.position = at
	spark.z_index = OVERLAY_Z
	spark.max_radius = wall_spark_radius
	spark.duration = wall_spark_duration
	spark.start_color = wall_spark_color
	# 終わりは同じ色のまま透明へ抜ける。コマ同士のような色相の変化はさせない。
	spark.end_color = Color(wall_spark_color.r, wall_spark_color.g, wall_spark_color.b, 0.0)
	$ArenaRoot.add_child(spark)


## 再生が結果の終わりまで来た。勝敗はもう決まっているので、見せるだけ。
func _finish() -> void:
	set_physics_process(false)

	# 戦闘が終わったので回転音を止める(フェードアウトして消える)。
	AudioManager.stop_rotation()

	# スローはここで解除する。決着後の余韻タイマーは実時間で回す。
	Engine.time_scale = 1.0

	# 最後のフレームをそのまま残す。補間の途中で止まると中途半端な絵になる。
	_apply_frame(_result.finish_time)
	# 万一まだすり抜け中(=窓が閉じる前に決着)でも、決着したら必ず実体化して終了SEを
	# 鳴らす。通常は決着が窓明けより後なので_physics_process側で既に解除済み。
	if _ghost_active:
		_ghost_active = false
		_player.set_ghosting(false)
		AudioManager.play("ghost_end")

	var player_won := _result.player_won()

	match _result.outcome:
		BattleResult.Outcome.DRAW:
			_message.text = "BATTLE_DRAW"
			_play_result_se("lose")
		BattleResult.Outcome.PLAYER_WIN:
			_message.text = "BATTLE_WIN"
			_play_result_se("win")
		_:
			_message.text = "BATTLE_LOSE"
			_play_result_se("lose")

	# 力尽きたコマは即グレーアウトさせず、最後の姿を一拍見せてからフェードで消す。
	var fade := _start_defeated_fadeout()

	await _linger_then_reset_view()
	# フェードが余韻より長くチューニングされていても切れないよう、残っていれば待つ。
	if fade != null and fade.is_valid() and fade.is_running():
		await fade.finished
	finished.emit(player_won)


## 勝敗ジングルを result_se_delay 秒だけ遅らせて鳴らす。ここで戦闘の流れ(_finish)は
## 待たせない。Battle が先に解放されても AudioManager は autoload で生きており、
## SceneTreeTimer もツリー側に残るので、ノード解放の影響を受けず安全に鳴らせる。
func _play_result_se(key: String) -> void:
	if result_se_delay <= 0.0:
		AudioManager.play(key)
		return
	get_tree().create_timer(result_se_delay).timeout.connect(
		func() -> void: AudioManager.play(key)
	)


## 決着で力尽きたコマ(敗者、引き分けなら両者)を、最後の姿のまま enemy_fadeout_delay 待って
## から enemy_fadeout_duration かけて消す。コマとHPバーを揃えて落とす。勝者は rps が残るので
## 対象外(回ったまま残る)。乱戦で戦闘中に既に消えた敵も、不透明度が尽きているので触らない。
## 対象が無ければ null を返す。
func _start_defeated_fadeout() -> Tween:
	var items: Array[CanvasItem] = []
	if EnemyFadeout.should_fade(_player.rps, lose_threshold, _player.modulate.a):
		# 乱戦最終フレームの暗転を打ち消し、明るい最後の姿から消す(プレイヤーは暗転しないが揃える)。
		_player.defeated = false
		items.append(_player)
		items.append(_player_bar)
	for i in _enemies.size():
		if EnemyFadeout.should_fade(_enemies[i].rps, lose_threshold, _enemies[i].modulate.a):
			_enemies[i].defeated = false
			items.append(_enemies[i])
			items.append(_enemy_bars[i])

	if items.is_empty():
		return null

	# 全員まとめて delay 待ってから同時にフェード。tween.finished は delay+duration で立つ。
	var tween := create_tween().set_parallel(true)
	for item in items:
		tween.tween_property(item, "modulate:a", 0.0, enemy_fadeout_duration).set_delay(enemy_fadeout_delay)
	return tween


## 決着の余韻。演出があったときはズームしたまま少し見せてから、カメラを本来の
## 位置へ滑らかに引き戻す。演出が無ければ従来どおり素の待ちだけ。合計は概ね
## finish_delay に収める。
func _linger_then_reset_view() -> void:
	if _decisive_time < 0.0:
		await get_tree().create_timer(finish_delay).timeout
		return

	await get_tree().create_timer(finish_zoom_hold).timeout

	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.parallel().tween_property(_arena_root, "position", _arena_base_pos, finish_zoom_release)
	tween.parallel().tween_property(_arena_root, "scale", _arena_base_scale, finish_zoom_release)
	await tween.finished

	var rest := finish_delay - finish_zoom_hold - finish_zoom_release
	if rest > 0.0:
		await get_tree().create_timer(rest).timeout


## 演出の途中でシーンが切り替わっても、スローが 1.0 未満のまま残らないようにする。
## Engine.time_scale はグローバルなので、ここで必ず戻す。
func _exit_tree() -> void:
	Engine.time_scale = 1.0
	# 決着前にシーンが切り替わっても回転音が鳴りっぱなしにならないよう必ず止める。
	AudioManager.stop_rotation()
