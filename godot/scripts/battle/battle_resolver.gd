class_name BattleResolver
extends RefCounted

## 1戦を最初から最後まで計算する。BattleRequestを受けてBattleResultを返すだけの
## 純粋関数で、Nodeにもシーンにも乱数にも依存しない。
##
## 今はBattle.gdがローカルで呼ぶが、この resolve() がそのままサーバー化の
## 差し替え点になる。将来はサーバーが同じコードで解決し、結果だけを返す。
##
## 元はBattle.gdの_physics_processがDiscノードを直接書き換えていた。
## シーンがないと動かず、フレームレートに縛られ、同じ戦いを二度再現できなかった。
## ここへ移したことで、ヘッドレスで即座に何百戦でも回せる。


## 計算中の1体。Discノードの代わり。
class State:
	extends RefCounted

	var stats: SpinnerStats
	var position: Vector2
	var velocity: Vector2
	var rps: float

	## 力尽きたら偽。落ちたコマは削り合い(コマ同士の衝突)からも壁・障害物との
	## 当たり判定からも外れ、以後は誰にも触れずに勢いのまま流れていく。
	## 積分・自然減衰・軌跡の記録だけは続ける(そのまま止まってフェードアウトさせる)。
	var alive: bool = true

	func _init(launch: BattleRequest.Launch) -> void:
		stats = launch.stats
		position = launch.position
		velocity = launch.velocity
		rps = launch.stats.rps


static func resolve(request: BattleRequest) -> BattleResult:
	var result := BattleResult.new()
	result.time_step = request.time_step
	# 再生側のすり抜け表示のため、入力のすり抜け時間を結果へ写す。
	result.ghost_duration = request.ghost_duration

	var player := State.new(request.player)
	var enemies: Array[State] = []
	for launch in request.enemies:
		enemies.append(State.new(launch))
		var track: Array[BattleResult.Snapshot] = []
		result.enemy_tracks.append(track)
	var walls := ArenaWall.build(request.wall_shape, request.arena_bounds)
	var center := request.arena_bounds.get_center()
	# 楕円ボウルの傾斜ワープ軸。ELLIPSE以外はONEで従来と一致。全体で一定なので先に1回だけ求める。
	var slope_axes := FieldData.slope_axes_for(request.wall_shape, request.arena_bounds)

	var dt := request.time_step
	var max_steps := int(request.max_duration / dt)
	var t := 0.0

	# ゴースト窓の開始時刻。最初のプレイヤー対敵の衝突が起きるまではINF=窓なし。
	# 窓が開いたらresult.ghost_startにも写す(再生側のすり抜け表示用)。
	var ghost_start := INF

	for step in max_steps:
		# 現在の状態を記録してから進める。1フレーム目が初期状態になる。
		result.player_frames.append(_snapshot(player))
		for i in enemies.size():
			result.enemy_tracks[i].append(_snapshot(enemies[i]))

		_integrate(player, center, request, dt, slope_axes)
		for enemy in enemies:
			_integrate(enemy, center, request, dt, slope_axes)

		# 全ペアの衝突を固定順で解く。まずプレイヤー対各敵(index順)、次に敵同士
		# (i<j)。落ちたコマ(alive=false)は削り合いに参加しない。順序を固定するのは
		# 3体以上が同時に重なったときの逐次解決が順序依存になるため。決定性と
		# シリアライズ往復の一致がこの順序に依存する。
		# ゴーストは「最初の衝突の直後からghost_duration秒間」プレイヤーと敵の
		# 衝突を解かない(ヒット&ラン: 狙った初撃は必ず通り、直後の報復ラッシュを
		# すり抜けて離脱できる)。開始直後を無敵にする旧仕様は自分の初撃まで消して
		# いて、狙って撃つほど損をする自傷札だった。窓を開いた当のステップ
		# (t == ghost_start)は塞がない=同一ステップの他の敵との衝突は解く。
		# ghost_duration=0なら窓は開かず常に当たる。敵同士の衝突(下)は対象外。
		for i in enemies.size():
			if (
				player.alive and enemies[i].alive
				and not ghost_blocks(t, ghost_start, request.ghost_duration)
			):
				if _resolve_disc_collision(player, enemies[i], request, t, result):
					if request.ghost_duration > 0.0 and ghost_start == INF:
						ghost_start = t
						result.ghost_start = t
		for i in enemies.size():
			for j in range(i + 1, enemies.size()):
				if enemies[i].alive and enemies[j].alive:
					_resolve_disc_collision(enemies[i], enemies[j], request, t, result)

		# 壁・障害物・自然減衰を体ごとに。いずれも体単位で独立なので並び順は
		# 結果に影響しない。
		_resolve_body_field(player, walls, request, dt, t, result)
		for enemy in enemies:
			_resolve_body_field(enemy, walls, request, dt, t, result)
			enemy.alive = enemy.rps > request.lose_threshold

		t += dt

		# プレイヤーが力尽きたら負け。敵は全員力尽きれば勝ち。
		var player_out := player.rps <= request.lose_threshold
		var all_enemies_out := enemies.all(
			func(e: State) -> bool: return e.rps <= request.lose_threshold
		)
		if player_out or all_enemies_out:
			result.player_frames.append(_snapshot(player))
			for i in enemies.size():
				result.enemy_tracks[i].append(_snapshot(enemies[i]))
			result.finish_time = t
			if player_out and all_enemies_out:
				result.outcome = BattleResult.Outcome.DRAW
			elif player_out:
				result.outcome = BattleResult.Outcome.ENEMY_WIN
			else:
				result.outcome = BattleResult.Outcome.PLAYER_WIN
			return result

	# 上限に達した。自然減衰があるので普通は来ないが、調整次第では
	# ありうるので黙って無限に回さない。残っている回転で決める。
	# プレイヤーの回転が敵の最大より上なら勝ち。
	result.finish_time = t
	result.timed_out = true
	var top_enemy_rps := 0.0
	for enemy in enemies:
		top_enemy_rps = maxf(top_enemy_rps, enemy.rps)
	if is_equal_approx(player.rps, top_enemy_rps):
		result.outcome = BattleResult.Outcome.DRAW
	elif player.rps > top_enemy_rps:
		result.outcome = BattleResult.Outcome.PLAYER_WIN
	else:
		result.outcome = BattleResult.Outcome.ENEMY_WIN
	return result


static func _snapshot(s: State) -> BattleResult.Snapshot:
	return BattleResult.Snapshot.new(s.position, s.velocity, s.rps)


static func _integrate(
	s: State, center: Vector2, req: BattleRequest, dt: float, slope_axes: Vector2
) -> void:
	s.position += s.velocity * dt
	var accel := SpinnerPhysics.friction_accel(s.velocity, s.stats.friction)
	accel += SpinnerPhysics.stage_slope_accel(
		s.position, center, req.stage_strength, req.stage_shape, slope_axes
	)
	s.velocity += accel * dt


## ゴースト窓が時刻tの衝突を塞ぐか。窓は「最初の衝突(ghost_start)の直後」から
## duration秒間。窓が開く前(ghost_start=INF)は塞がない。境界のt == ghost_startは
## 窓を開いた衝突自身のステップなので塞がない(同一ステップの他の敵にも当たる)。
## 純粋関数としてテストが直接叩く。
static func ghost_blocks(t: float, ghost_start: float, duration: float) -> bool:
	return t > ghost_start and t < ghost_start + duration


## 2体の衝突を解く。プレイヤー対敵にも敵同士にも使う汎用の対処理。
## 接触点は共有の result.impacts に追記する(再生側は誰同士かを区別しない)。
## 実際に衝突を解いたら真を返す(ゴースト窓の開始検出に使う。敵同士は無視してよい)。
static func _resolve_disc_collision(
	a: State, b: State, req: BattleRequest, t: float, result: BattleResult
) -> bool:
	if not SpinnerPhysics.is_colliding(
		a.position, a.stats.radius, a.velocity,
		b.position, b.stats.radius, b.velocity
	):
		return false

	# 接触点。半径で重み付けした中点＝実際に触れている場所。
	var contact := (
		a.position * b.stats.radius + b.position * a.stats.radius
	) / (a.stats.radius + b.stats.radius)
	result.impacts.append(BattleResult.Impact.new(t, contact))

	# 削り量は衝突前の相対速さ（ぶつかる勢い）で決める。相手の絶対速度ではなく
	# 2体の相対速度に依存させる。弾性衝突で速度が変わる前に取っておく。
	# 相対速度は対称なので両者で同じ値を使い、削り量の非対称性は質量・半径だけが担う。
	var rel_speed := (a.velocity - b.velocity).length()

	# コマ同士の衝突の反発係数は両者restitutionの積。低い方に引きずられ、
	# プレイヤーの基礎restitution(0.75)ぶんだけ非弾性になる。Rage Reflectionで
	# restitutionが上がると弾性が戻り、当たったとき勢いを保って弾け返る。
	# 以前はe>1の発散を嫌って[0,1]にクランプしていたが、速度上限(max_speed)で
	# 毎tick発散を抑えるようになったのでクランプせず、反発>1を敵衝突にも効かせる。
	var pair_restitution := a.stats.restitution * b.stats.restitution
	var bounced := SpinnerPhysics.elastic_velocities(
		a.position, a.velocity, a.stats.mass,
		b.position, b.velocity, b.stats.mass,
		pair_restitution
	)
	a.velocity = bounced[0]
	b.velocity = bounced[1]

	var a_drain := SpinnerPhysics.spin_drain(
		b.stats.mass, rel_speed, a.stats.mass, a.stats.radius, req.violence
	)
	var b_drain := SpinnerPhysics.spin_drain(
		a.stats.mass, rel_speed, b.stats.mass, b.stats.radius, req.violence
	)

	a.velocity += SpinnerPhysics.spin_kick(
		a.position, b.position, a.stats.radius, a_drain, req.spin_kick_scale
	)
	b.velocity += SpinnerPhysics.spin_kick(
		b.position, a.position, b.stats.radius, b_drain, req.spin_kick_scale
	)

	a.rps = maxf(a.rps - a_drain, 0.0)
	b.rps = maxf(b.rps - b_drain, 0.0)
	return true


## 1体ぶんの土俵まわり: 壁・障害物・自然減衰。体ごとに独立しており、
## 他の体には触れないので、複数体でも並び順は結果に影響しない。
## 落ちたコマ(alive=false)は壁・障害物の当たり判定を持たず素通りする。
## 積分と自然減衰だけは続けるので、勢いのまま流れつつ止まっていく。
static func _resolve_body_field(
	s: State, walls: Array[ArenaWall], req: BattleRequest, dt: float, t: float, result: BattleResult
) -> void:
	if s.alive:
		_resolve_walls(s, walls, req, t, result)
		_resolve_obstacles(s, req, t, result)
	_apply_natural_decay(s, req, dt)
	# 積分・disc衝突(spin_kick)・壁/障害物反射(wall_bounce)の全速度増加経路の後で
	# 速度を頭打ちにする。反発>1で壁反射のたびに加速して脱出するのを防ぐ。
	s.velocity = SpinnerPhysics.clamp_speed(s.velocity, req.max_speed)


static func _resolve_walls(
	s: State, walls: Array[ArenaWall], req: BattleRequest, t: float, result: BattleResult
) -> void:
	for wall in walls:
		if not SpinnerPhysics.wall_hit(
			wall.point, wall.normal, s.position, s.velocity, s.stats.radius
		):
			continue
		# 接触点。法線は内向きなので、中心から壁側へ半径分ずらすとコマの縁＝
		# 壁面上の当たった点になる。位置は反射で変わらない(変わるのは速度だけ)。
		result.wall_impacts.append(
			BattleResult.Impact.new(t, s.position - wall.normal * s.stats.radius)
		)
		s.velocity = SpinnerPhysics.wall_bounce(s.velocity, wall.normal, s.stats.restitution)
		s.rps *= SpinnerPhysics.effective_wall_damping(req.wall_damping, s.stats.wall_keep)


## 障害物(固定円)との衝突。壁と同型で、法線が中心からの放射方向になるだけ。
## 衝撃波は壁と同じwall_impactsチャンネルに載せる（見た目も壁と同じ控えめな波）。
static func _resolve_obstacles(
	s: State, req: BattleRequest, t: float, result: BattleResult
) -> void:
	for o in req.obstacles:
		var obstacle_center := Vector2(o.x, o.y)
		var obstacle_radius := o.z
		if not SpinnerPhysics.obstacle_hit(
			obstacle_center, obstacle_radius, s.position, s.velocity, s.stats.radius
		):
			continue
		var normal := (s.position - obstacle_center).normalized()
		result.wall_impacts.append(
			BattleResult.Impact.new(t, s.position - normal * s.stats.radius)
		)
		s.velocity = SpinnerPhysics.wall_bounce(s.velocity, normal, s.stats.restitution)
		s.rps *= SpinnerPhysics.effective_wall_damping(req.wall_damping, s.stats.wall_keep)


static func _apply_natural_decay(s: State, req: BattleRequest, dt: float) -> void:
	# 減衰率は土俵のnatural_dampingにコマ自身のspin_decay倍率を掛ける。
	# Full Steam Aheadがspin_decayを下げると、ゆっくり回転を失う＝長く回る。
	s.rps = maxf(
		s.rps - SpinnerPhysics.natural_spin_decay(
			s.stats.radius, req.natural_damping * s.stats.spin_decay, dt
		),
		0.0
	)
