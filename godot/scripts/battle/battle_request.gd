class_name BattleRequest
extends RefCounted

## 1戦を計算するのに必要な入力の全部。
##
## 「発射内容を渡す → 全部計算 → 結果を再生」という形にするための入り口。
## 今はローカルのBattleResolverが受け取るが、将来オンライン対戦をやるときは
## そのままサーバーへ送るものになる。だからNodeにもシーンにも依存させず、
## to_dict()で丸ごと送れるようにしてある。
##
## 敵の出現内容(位置・初速)が結果ではなく入力なのは、発射前に決まって
## EnemyTelegraphが予告しているため。そうでないと予告が嘘になる。
## 本物のサーバーでは「開始時にサーバーが出現内容を配る → プレイヤーが発射を
## 送る → サーバーが解決」になるが、決める主体が変わるだけでこの形は変わらない。


class Launch:
	extends RefCounted

	var stats: SpinnerStats
	var position: Vector2
	var velocity: Vector2

	func _init(stats_: SpinnerStats, position_: Vector2, velocity_: Vector2) -> void:
		stats = stats_
		position = position_
		velocity = velocity_

	func to_dict() -> Dictionary:
		return {
			"mass": stats.mass,
			"radius": stats.radius,
			"friction": stats.friction,
			"restitution": stats.restitution,
			"rps": stats.rps,
			"spin_decay": stats.spin_decay,
			"wall_keep": stats.wall_keep,
			"pos": [position.x, position.y],
			"vel": [velocity.x, velocity.y],
		}

	static func from_dict(d: Dictionary) -> Launch:
		var stats_ := SpinnerStats.new()
		stats_.mass = d["mass"]
		stats_.radius = d["radius"]
		stats_.friction = d["friction"]
		stats_.restitution = d["restitution"]
		stats_.rps = d["rps"]
		# 旧いJSONにはspin_decay/wall_keepが無いので、既定で読む（往復の後方互換）。
		stats_.spin_decay = d.get("spin_decay", 1.0)
		stats_.wall_keep = d.get("wall_keep", 0.0)
		return Launch.new(
			stats_,
			Vector2(d["pos"][0], d["pos"][1]),
			Vector2(d["vel"][0], d["vel"][1])
		)


var player: Launch

## 敵は複数出うる（乱戦）。1体なら要素1の配列。順序はシリアライズ往復でも
## 保たれ、決定性のある衝突解決順(=index順)の土台になるので崩さないこと。
var enemies: Array[Launch] = []

## アリーナ。中心と壁はここから決まる。
var arena_bounds: Rect2 = Rect2(0, 0, 10, 10)

## 壁の形。矩形/八角形/円形。
var wall_shape: ArenaWall.WallShape = ArenaWall.WallShape.RECT

## 障害物。xy=中心、z=半径の固定円。
var obstacles: Array[Vector3] = []

## ステージの傾斜と、ぶつかり合いの調整値。Battle.tscnの@exportから来る。
var stage_strength: float = 4.9
var stage_shape: SpinnerPhysics.StageShape = SpinnerPhysics.StageShape.DISH
var violence: float = 0.04
var spin_kick_scale: float = 2.0
var natural_damping: float = 1.0
var wall_damping: float = 0.75
var lose_threshold: float = 0.03

## 速度(linear)の上限。反発>1(Rage Reflection)で壁反射のたびに加速して
## アリーナ外へ脱出するのを防ぐ。0以下で無制限。発射初速の上限はLaunchSpeed.MAX=12で、
## 30なら1tick移動が30/60=0.5<脱出マージン1.0に収まり通常プレイのピークにも余裕がある。
var max_speed: float = 30.0

## ゴーストのすり抜け時間(秒)。最初のプレイヤー対敵の衝突の直後から、この秒数だけ
## プレイヤーと敵の衝突判定を切る(ヒット&ラン)。0なら無効(常に当たる)。
## ゴースト札の枚数で決まる
## (CustomPartCatalog.total_ghost_seconds)。壁・障害物・敵同士の衝突には効かない。
var ghost_duration: float = 0.0

## 計算の刻み幅(秒)。描画のfpsとは独立。
var time_step: float = 1.0 / 60.0

## この時間を超えたら打ち切る。自然減衰があるので必ず決着するはずだが、
## 純粋関数で無限ループは許容できない。
var max_duration: float = 120.0


func to_dict() -> Dictionary:
	return {
		"player": player.to_dict(),
		"enemies": enemies.map(func(e: Launch) -> Dictionary: return e.to_dict()),
		"arena": [arena_bounds.position.x, arena_bounds.position.y,
			arena_bounds.size.x, arena_bounds.size.y],
		"wall_shape": int(wall_shape),
		"obstacles": obstacles.map(func(o: Vector3) -> Array:
			return [o.x, o.y, o.z]),
		"stage_strength": stage_strength,
		"stage_shape": int(stage_shape),
		"violence": violence,
		"spin_kick_scale": spin_kick_scale,
		"natural_damping": natural_damping,
		"wall_damping": wall_damping,
		"lose_threshold": lose_threshold,
		"max_speed": max_speed,
		"ghost_duration": ghost_duration,
		"time_step": time_step,
		"max_duration": max_duration,
	}


static func from_dict(d: Dictionary) -> BattleRequest:
	var r := BattleRequest.new()
	r.player = Launch.from_dict(d["player"])
	var enemies_: Array[Launch] = []
	for ed in d["enemies"]:
		enemies_.append(Launch.from_dict(ed))
	r.enemies = enemies_
	r.arena_bounds = Rect2(d["arena"][0], d["arena"][1], d["arena"][2], d["arena"][3])
	r.wall_shape = d["wall_shape"]
	var obstacles_: Array[Vector3] = []
	for o in d["obstacles"]:
		obstacles_.append(Vector3(o[0], o[1], o[2]))
	r.obstacles = obstacles_
	r.stage_strength = d["stage_strength"]
	r.stage_shape = d["stage_shape"]
	r.violence = d["violence"]
	r.spin_kick_scale = d["spin_kick_scale"]
	r.natural_damping = d["natural_damping"]
	r.wall_damping = d["wall_damping"]
	r.lose_threshold = d["lose_threshold"]
	# 旧い保存データにキーが無くても壊れないよう既定で補う。
	r.max_speed = d.get("max_speed", 30.0)
	r.ghost_duration = d.get("ghost_duration", 0.0)
	r.time_step = d["time_step"]
	r.max_duration = d["max_duration"]
	return r
