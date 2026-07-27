extends SceneTree

## ボスがrpsを「どのソースで」失うかのダメージ割合を測る診断。
##
## death_cause(最後の一撃)は誤解を招く: 壁で大半を失っても、閾値を割る最後の
## 1tickがたまたま自然減衰なら死因=decayに見える。ここは戦闘全体でボスが
## 削り(drain)/壁(wall)/自然減衰(decay)に何割rpsを失ったかを、BattleResultの
## 軌跡から再構成する。新スタットは足さない(既存の物理と記録だけで出す)。
##
##   godot --headless --path godot --script res://playtest/measure_boss_launch.gd -- [--count=1000]
##
## 発射速度(いまは自機と共通のレンジ LaunchSpeed から出現ごとに抽選)と半径(既存の
## 物理量)を振り、無敵0/6秒の勝率とボスのダメージ割合を出す。壁割合が高ければ共通
## レンジの上限を下げる=壁への突撃が減り自滅が減る。自然減衰割合が高ければ半径を
## 下げる=減衰は半径に比例。速度は診断のため固定値をplanに直接渡して振る。

const SPAWN_RING := 4.0
const SPAWN_SPREAD_DEG := 30.0
const GHOSTS := [0.0, 6.0]


func _init() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			var eq := arg.find("=")
			args[arg.substr(2, eq - 2)] = arg.substr(eq + 1)
	var count := int(args.get("count", "1000"))
	var policy := LaunchPolicy.by_name(args.get("policy", "intercept"))

	var boss := EnemyRoster.of_level(5)[0]
	# 共通レンジ(LaunchSpeed)の上限を基準に速度を振る。実ゲームは[MIN,MAX]から抽選。
	var base_speed := LaunchSpeed.MAX
	var base_radius := boss.stats.radius
	print("# ボスのダメージ割合診断 (発射=%s, count=%d)" % [LaunchPolicy.NAMES[policy], count])
	print("# 共通レンジ上限=%.1f, 実効radius=%.2f。壁1回で25%%喪失(wall_damping=0.75)" % [
		base_speed, base_radius])

	print("\n## 発射速度スイープ (radius=%.2f 固定)" % base_radius)
	_table(boss, count, policy, _speeds(base_speed), [base_radius])

	print("\n## 半径スイープ (速度=%.1f 固定)" % base_speed)
	_table(boss, count, policy, [base_speed], _radii(base_radius))
	quit(0)


func _speeds(base: float) -> Array:
	return [base, base * 0.85, base * 0.77, base * 0.68, base * 0.5]


func _radii(base: float) -> Array:
	return [base, base * 0.8, base * 0.6, base * 0.45]


func _table(boss: EnemyData, count: int, policy: LaunchPolicy.Kind,
		speeds: Array, radii: Array) -> void:
	print("| 速度 | radius | 無敵0s勝率 | 無敵6s勝率 | ボス被ダメ割合 削り/壁/減衰 |")
	print("|---|---|---|---|---|")
	for speed in speeds:
		for radius in radii:
			var stats := boss.stats.duplicate_stats()
			stats.radius = radius
			var b := EnemyData.make(boss.level, boss.display_name, stats)
			var win0 := 0
			var win6 := 0
			var drain := 0.0
			var wall := 0.0
			var decay := 0.0
			for i in count:
				var r0 := _resolve(b, speed, SpinnerStats.default_player(), policy, i, 0.0)
				if r0["win"]:
					win0 += 1
				var r6 := _resolve(b, speed, SpinnerStats.default_player(), policy, i, 6.0)
				if r6["win"]:
					win6 += 1
				# ダメージ割合はすり抜け6秒側(GHOSTが刺さる状況)のボスの内訳を積む。
				drain += r6["drain"]
				wall += r6["wall"]
				decay += r6["decay"]
			var total := drain + wall + decay
			var prop := "n/a"
			if total > 0.0:
				prop = "%.0f%% / %.0f%% / %.0f%%" % [
					100.0 * drain / total, 100.0 * wall / total, 100.0 * decay / total]
			print("| %.1f | %.2f | %.1f%% | %.1f%% | %s |" % [
				speed, radius, 100.0 * win0 / count, 100.0 * win6 / count, prop])


## 1戦を解いて、勝敗とボスのrps喪失内訳(drain/wall/decay)を返す。
## BattleSim.play_oneと同じ手順で組み立て、resolverの生の結果から再構成する。
func _resolve(enemy: EnemyData, speed: float, player_stats: SpinnerStats, policy: LaunchPolicy.Kind,
		seed_value: int, ghost: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var field := BattleSim.default_field()

	var request := BattleRequest.new()
	request.arena_bounds = field.arena_bounds
	request.wall_shape = field.wall_shape
	request.obstacles = field.obstacles
	request.stage_strength = field.stage_strength
	request.stage_shape = field.stage_shape
	request.ghost_duration = ghost

	var plan := EnemySpawn.plan(
		field.center(), SPAWN_RING, speed, SPAWN_SPREAD_DEG,
		rng, enemy.stats.radius, field.inradius())
	var launch := LaunchPolicy.decide(policy, field, player_stats.radius, plan, rng)
	request.player = BattleRequest.Launch.new(player_stats, launch.position, launch.velocity)
	request.enemies = [BattleRequest.Launch.new(enemy.stats, plan.position, plan.velocity)]

	var result := BattleResolver.resolve(request)
	var breakdown := _boss_damage(request, result, enemy.stats)
	breakdown["win"] = result.player_won()
	return breakdown


## ボス(enemy_tracks[0])のrps喪失を drain/wall/decay に分解する。
## 減衰は毎ステップ radius*natural_damping*dt(spin_decay=1想定の敵)で一定。
## 壁は boss近傍のwall_impactごとに その時刻のrps*(1-wall_damping)。
## 削りは残り(全喪失 - 減衰 - 壁)。resolverの順(削り→壁→減衰)に沿う近似。
func _boss_damage(request: BattleRequest, result: BattleResult,
		boss_stats: SpinnerStats) -> Dictionary:
	var track: Array = result.enemy_tracks[0]
	var dt := request.time_step
	var thr := request.lose_threshold
	var decay_step := boss_stats.radius * request.natural_damping * boss_stats.spin_decay * dt

	var init_rps: float = track[0].rps
	var final_rps: float = track[track.size() - 1].rps

	# 生きている間の自然減衰の総量。
	var alive_steps := 0
	for i in track.size():
		if track[i].rps <= thr:
			break
		alive_steps += 1
	var decay_total := decay_step * alive_steps

	# 壁での喪失。boss近傍のwall_impactを拾い、その時刻のrpsから25%喪失を積む。
	var player_track: Array = result.player_frames
	var wall_total := 0.0
	for imp in result.wall_impacts:
		var frame := int(round(imp.time / dt))
		if frame < 0 or frame >= track.size():
			continue
		var boss_pos: Vector2 = track[frame].position
		var player_pos: Vector2 = player_track[frame].position if frame < player_track.size() else Vector2.INF
		# 接触点がボス側か(プレイヤーより近いか)で敵の壁ヒットだけを拾う。
		if imp.point.distance_to(boss_pos) <= imp.point.distance_to(player_pos):
			var rps_here: float = track[frame].rps
			wall_total += rps_here * (1.0 - request.wall_damping)

	var total_loss := maxf(init_rps - final_rps, 0.0)
	var drain_total := maxf(total_loss - decay_total - wall_total, 0.0)
	# 近似の取りこぼしは削り側に寄るので、合計を全喪失に正規化して割合を安定させる。
	return {"drain": drain_total, "wall": wall_total, "decay": minf(decay_total, total_loss)}
