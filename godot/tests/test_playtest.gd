extends RefCounted

## テストプレイハーネス自体のテスト。
##
## 検査器(PlaytestInvariants)が本当に壊れた結果を拾えるかを、壊れた結果を
## 手で作って確かめる。ここが節穴だと大量試行の意味がなくなる。
## リゾルバへの細工(sabotage)は開発時に手でやったが、これは常設の裏付け。

const EPS := 1e-4


func run(check: Callable) -> void:
	_test_invariants_catch_bad_results(check)
	_test_invariants_pass_healthy_result(check)
	_test_battle_sim_deterministic(check)
	_test_policies_stay_legal(check)
	_test_field_reaches_battle(check)
	_test_overrides_beat_field(check)
	_test_run_sim_consistent(check)
	_test_run_sim_forced_pick(check)
	_test_run_sim_continues(check)
	_test_run_sim_spare_core(check)


func _request() -> BattleRequest:
	var r := BattleRequest.new()
	r.player = BattleRequest.Launch.new(SpinnerStats.default_player(), Vector2(2, 8), Vector2(6, -6))
	var enemy := EnemyRoster.of_level(1)[0]
	r.enemies = [BattleRequest.Launch.new(enemy.stats, Vector2(8, 2), Vector2(-3, 4))]
	return r


func _healthy_result(request: BattleRequest) -> BattleResult:
	return BattleResolver.resolve(request)


func _test_invariants_catch_bad_results(check: Callable) -> void:
	var request := _request()

	# nan
	var bad := _healthy_result(request)
	bad.player_frames[3] = BattleResult.Snapshot.new(Vector2(NAN, 1.0), Vector2.ZERO, 5.0)
	check.call(
		not PlaytestInvariants.check(request, bad).is_empty(),
		"検査器: nanを拾う"
	)

	# アリーナ脱出
	bad = _healthy_result(request)
	bad.enemy_tracks[0][2] = BattleResult.Snapshot.new(Vector2(30.0, 5.0), Vector2.ZERO, 5.0)
	check.call(
		not PlaytestInvariants.check(request, bad).is_empty(),
		"検査器: アリーナ脱出を拾う"
	)

	# rpsの増加
	bad = _healthy_result(request)
	var f := bad.player_frames[5]
	bad.player_frames[5] = BattleResult.Snapshot.new(f.position, f.velocity, 999.0)
	check.call(
		not PlaytestInvariants.check(request, bad).is_empty(),
		"検査器: rpsの増加を拾う"
	)

	# 落ちたコマ(rps <= lose_threshold)は壁を抜けて場外へ出るのが仕様なので、
	# アリーナ外にいても脱出違反にはしない。生きているコマ(上の脱出テスト)とは扱いを分ける。
	# 以降のフレームもrpsを下げて閾値以下に揃える(rps増加違反を誘発しないため)。
	var dead := _healthy_result(request)
	for i in range(2, dead.enemy_tracks[0].size()):
		dead.enemy_tracks[0][i] = BattleResult.Snapshot.new(Vector2(30.0, 5.0), Vector2.ZERO, 0.0)
	check.call(
		PlaytestInvariants.check(request, dead).is_empty(),
		"検査器: 落ちたコマの場外脱出は見逃す (%s)" % [PlaytestInvariants.check(request, dead)]
	)

	# 戦闘の外の衝突時刻
	bad = _healthy_result(request)
	bad.impacts.append(BattleResult.Impact.new(bad.finish_time + 10.0, Vector2(5, 5)))
	check.call(
		not PlaytestInvariants.check(request, bad).is_empty(),
		"検査器: 範囲外の衝突時刻を拾う"
	)

	# フレーム数の不一致
	bad = _healthy_result(request)
	bad.enemy_tracks[0].pop_back()
	check.call(
		not PlaytestInvariants.check(request, bad).is_empty(),
		"検査器: フレーム数の不一致を拾う"
	)


func _test_invariants_pass_healthy_result(check: Callable) -> void:
	var request := _request()
	var violations := PlaytestInvariants.check(request, _healthy_result(request))
	check.call(
		violations.is_empty(),
		"検査器: 健全な結果は素通しする (%s)" % [violations]
	)


func _test_battle_sim_deterministic(check: Callable) -> void:
	var enemy := EnemyRoster.of_level(2)[0]
	var enemies: Array[EnemyData] = [enemy]
	var stats := SpinnerStats.default_player()

	var a := BattleSim.play_one(42, enemies, LaunchPolicy.Kind.INTERCEPT, stats)
	var b := BattleSim.play_one(42, enemies, LaunchPolicy.Kind.INTERCEPT, stats)
	check.call(
		JSON.stringify(a) == JSON.stringify(b),
		"battle_sim: 同じシードなら同じレコード"
	)

	for key in ["seed", "level", "count", "policy", "win", "finish_time", "impacts"]:
		check.call(a.has(key), "battle_sim: レコードに %s がある" % key)

	var c := BattleSim.play_one(43, enemies, LaunchPolicy.Kind.INTERCEPT, stats)
	check.call(
		JSON.stringify(a) != JSON.stringify(c),
		"battle_sim: シードが違えば別の戦いになる"
	)


## どの土俵でも、ボットの発射が壁の内側から上限速度以下で出ること。
##
## 円形・八角形は矩形より内接円のぶん狭い。矩形クランプで済ませると角の方向で
## 壁の外から撃ててしまい、「外から助走をつける」ズルになる(実プレイでは
## Battle._clamp_launchが塞いでいる穴)。全フィールドを回して確かめる。
func _test_policies_stay_legal(check: Callable) -> void:
	var radius := 0.5
	var rng := RandomNumberGenerator.new()
	var worst_speed := 0.0

	for field in FieldRoster.all():
		var out_of_bounds := 0
		var limit := field.inradius() - radius
		for kind in LaunchPolicy.NAMES:
			for i in 50:
				rng.seed = i
				var plan := EnemySpawn.plan(
					field.center(), 4.0, 5.0, 30.0, rng, 0.5, field.inradius()
				)
				var launch := LaunchPolicy.decide(kind, field, radius, plan, rng)
				worst_speed = maxf(worst_speed, launch.velocity.length())
				if field.wall_shape == ArenaWall.WallShape.RECT:
					var b := field.arena_bounds
					if (launch.position.x < b.position.x + radius - EPS
							or launch.position.x > b.end.x - radius + EPS
							or launch.position.y < b.position.y + radius - EPS
							or launch.position.y > b.end.y - radius + EPS):
						out_of_bounds += 1
				elif launch.position.distance_to(field.center()) > limit + EPS:
					out_of_bounds += 1
		check.call(
			out_of_bounds == 0,
			"発射方針: %s の内側から撃つ (%d件はみ出し)" % [field.title_key, out_of_bounds]
		)

	check.call(
		worst_speed <= LaunchPolicy.MAX_SPEED + EPS,
		"発射方針: 初速が上限以下 (最大 %.2f / 上限 %.0f)" % [worst_speed, LaunchPolicy.MAX_SPEED]
	)


## 土俵がリゾルバまで届くこと。ここが切れていると、計測だけが実プレイに存在
## しない土俵(既定の矩形すり鉢)で回り、数字が実態とずれる。
func _test_field_reaches_battle(check: Callable) -> void:
	var enemies: Array[EnemyData] = [EnemyRoster.of_level(1)[0]]
	var stats := SpinnerStats.default_player()

	for field in FieldRoster.all():
		var record := BattleSim.play_one(
			5, enemies, LaunchPolicy.Kind.INTERCEPT, stats, null, field
		)
		check.call(
			record["field"] == field.title_key,
			"battle_sim: 土俵がレコードに載る (%s)" % field.title_key
		)
		check.call(
			record["shape"] == int(field.stage_shape),
			"battle_sim: 土俵の傾斜がリクエストへ届く (%s)" % field.title_key
		)

	# 土俵が違えば戦いも違う。同じ結果になるなら、どこかで捨てられている。
	var plate: FieldData = null
	var pillars: FieldData = null
	for field in FieldRoster.all():
		if field.title_key == "FIELD_PLATE":
			plate = field
		elif field.title_key == "FIELD_PILLARS":
			pillars = field
	var a := BattleSim.play_one(5, enemies, LaunchPolicy.Kind.INTERCEPT, stats, null, plate)
	var b := BattleSim.play_one(5, enemies, LaunchPolicy.Kind.INTERCEPT, stats, null, pillars)
	check.call(
		a["finish_time"] != b["finish_time"] or a["impacts"] != b["impacts"],
		"battle_sim: 土俵が変われば戦いも変わる"
	)


## スイープの上書きは土俵より後に載ること。逆だとフィールドが上書きを潰して、
## スイープ表が全部同じ数字になる。
func _test_overrides_beat_field(check: Callable) -> void:
	var enemies: Array[EnemyData] = [EnemyRoster.of_level(1)[0]]
	var stats := SpinnerStats.default_player()
	var bowl: FieldData = null
	for field in FieldRoster.all():
		if field.title_key == "FIELD_BOWL":  # DISH固定の土俵
			bowl = field
	var overrides := BattleSim.Overrides.new()
	overrides.stage_shape = int(SpinnerPhysics.StageShape.CONE)

	var record := BattleSim.play_one(
		5, enemies, LaunchPolicy.Kind.INTERCEPT, stats, overrides, bowl
	)
	check.call(
		record["shape"] == int(SpinnerPhysics.StageShape.CONE),
		"battle_sim: スイープの上書きが土俵に勝つ"
	)


func _test_run_sim_consistent(check: Callable) -> void:
	for seed_value in [7, 8, 9]:
		var r := RunSim.play_one(seed_value, LaunchPolicy.Kind.INTERCEPT, RunSim.RewardPolicy.GREEDY)
		check.call(not r.has("error"), "run_sim: ランが完走する (seed %d)" % seed_value)
		check.call(r["battles"].size() > 0, "run_sim: 戦闘が記録される (seed %d)" % seed_value)

		# パーツはボス以外の勝利ごとに「倒した頭数」枚(乱戦は頭数ぶん報酬)。
		# クリアなら最後の勝利(ボス=単体)には付かないので1枚ぶん差し引く。
		var expected_parts := 0
		for b in r["battles"]:
			if b["win"]:
				expected_parts += int(b["count"])
		if r["cleared"]:
			expected_parts -= 1
		check.call(
			r["parts"].size() == expected_parts,
			"run_sim: パーツ数が倒した頭数と整合 (seed %d: %d枚 / 期待 %d)" % [
				seed_value, r["parts"].size(), expected_parts
			]
		)

		if r["cleared"]:
			check.call(r["died_at_step"] == -1, "run_sim: クリアなら死亡段がない")
		else:
			check.call(r["died_at_step"] >= 1, "run_sim: 死亡段が記録される")


## FORCED方針: 対象idが3択にあれば必ずそれを取る。ステータスを変えないSET_LIVES
## (greedyのtoughness選好では絶対選ばれない)を強制できることが肝。
func _test_run_sim_forced_pick(check: Callable) -> void:
	var rng := RandomNumberGenerator.new()
	var stats := SpinnerStats.default_player()

	# 3択にSPARE_CORE(id8)を混ぜる。greedyなら硬さの上がるGiant Growth(id2)を選ぶが、
	# FORCEDならid8を選ぶ。
	var with_target: Array[CustomPart] = [
		CustomPartCatalog.by_id(2), CustomPartCatalog.by_id(8), CustomPartCatalog.by_id(5)
	]
	var picked := RunSim._choose_part(
		with_target, RunSim.RewardPolicy.FORCED, rng, stats, 8
	)
	check.call(picked.id == 8, "run_sim: FORCEDは対象id(残機札)を必ず取る (実際 %d)" % picked.id)

	# 対象が3択に無い回はgreedyに委譲する(3択の中から選ぶ)。
	var without_target: Array[CustomPart] = [
		CustomPartCatalog.by_id(2), CustomPartCatalog.by_id(5), CustomPartCatalog.by_id(6)
	]
	var fallback := RunSim._choose_part(
		without_target, RunSim.RewardPolicy.FORCED, rng, stats, 8
	)
	var ids := without_target.map(func(p): return p.id)
	check.call(
		ids.has(fallback.id),
		"run_sim: FORCEDは対象不在ならgreedyに委譲 (実際 %d)" % fallback.id
	)


## 残機(コンティニュー)の模擬。敗北しても残機がある限り再挑戦し、残機が尽きて
## 初めて力尽きる。実プレイのGameStateと同じ。SPARE_COREを取らないFORCED(質量)で
## 回すので残機の底上げは起きず、初期3から消費した分だけ減る。
## 発射方針は2つ回す。interceptだけだとバランス次第で30シード全部クリアしてしまい、
## 死亡分岐を一度も通らないことがある(実際、札の調整でそうなった)。腕の悪い
## random発射なら確実に力尽きるランが混ざるので、分岐の検証がバランスに依存しない。
func _test_run_sim_continues(check: Callable) -> void:
	var died_checked := false
	for policy in [LaunchPolicy.Kind.INTERCEPT, LaunchPolicy.Kind.RANDOM]:
		died_checked = _check_continues_for(check, policy) or died_checked
	check.call(died_checked, "run_sim: 残機の死亡分岐を少なくとも1回検証した")


func _check_continues_for(check: Callable, policy: LaunchPolicy.Kind) -> bool:
	var died_checked := false
	for seed_value in range(0, 30):
		var r := RunSim.play_one(
			seed_value, policy, RunSim.RewardPolicy.FORCED, null, 3
		)
		# SPARE_COREを取らないので残機は増えない: 消費+残 == 初期。
		check.call(
			r["continues_used"] + r["final_continues"] == RunSim.START_CONTINUES,
			"run_sim: 残機の収支が初期値と整合 (seed %d)" % seed_value
		)
		check.call(
			r["continues_used"] <= RunSim.START_CONTINUES,
			"run_sim: 消費残機が初期値以下 (seed %d)" % seed_value
		)
		# 肝: 残機がある限り死なない。死んだなら残機は必ず0。
		if not r["cleared"]:
			died_checked = true
			check.call(
				r["final_continues"] == 0,
				"run_sim: 残機がある限り死なない(死亡時は残0) (seed %d, 残%d)" % [
					seed_value, r["final_continues"]
				]
			)
	return died_checked


## SPARE_CORE(id8)を取ると残機が5へ底上げされる(GameState.apply_partのmaxiと同じ)。
## 取得後に一度も敗北しなければ残機は5のまま。固定シード集合なので決定的。
func _test_run_sim_spare_core(check: Callable) -> void:
	var acquired_any := false
	var max_continues := 0
	for seed_value in range(0, 60):
		var r := RunSim.play_one(
			seed_value, LaunchPolicy.Kind.INTERCEPT, RunSim.RewardPolicy.FORCED, null, 8
		)
		if r["parts"].has(8):
			acquired_any = true
			max_continues = maxi(max_continues, r["final_continues"])
	check.call(acquired_any, "run_sim: SPARE_COREを取得したランがある")
	check.call(
		max_continues > RunSim.START_CONTINUES,
		"run_sim: SPARE_COREで残機が初期(%d)を超える (最大 %d)" % [
			RunSim.START_CONTINUES, max_continues
		]
	)
