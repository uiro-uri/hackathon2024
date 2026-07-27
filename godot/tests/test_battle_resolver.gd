extends RefCounted

## battle_resolver.gd / battle_request.gd / battle_result.gd のテスト。
##
## サーバーへ出す前提なので、ここで確かめるのは「同じ入力なら同じ結果か」と
## 「送って戻しても結果が変わらないか」。どちらも壊れているとサーバー化した
## 瞬間に破綻するが、ローカルで動かしているうちは表面化しない。

const EPS := 1e-4


func run(check: Callable) -> void:
	_test_deterministic(check)
	_test_serialization_round_trip(check)
	_test_terminates(check)
	_test_frames_and_time(check)
	_test_wall_impacts(check)
	_test_sampling(check)
	_test_outcome(check)
	_test_multi_enemy(check)
	_test_dead_ignores_walls(check)
	_test_ghost_hit_and_run(check)
	_test_relative_speed_drain(check)


func _stats(mass: float, radius: float, rps: float) -> SpinnerStats:
	var s := SpinnerStats.new()
	s.mass = mass
	s.radius = radius
	s.friction = 0.98
	s.restitution = 1.0
	s.rps = rps
	return s


func _request() -> BattleRequest:
	var r := BattleRequest.new()
	r.player = BattleRequest.Launch.new(_stats(1.5, 0.5, 15.0), Vector2(2, 8), Vector2(6, -6))
	r.enemies = [BattleRequest.Launch.new(_stats(1.0, 0.5, 15.0), Vector2(8, 2), Vector2(-3, 4))]
	return r


## ゴーストテスト用: 中央近くの正面衝突。弾け返ってもすり鉢の傾斜が中央へ
## 押し戻すので、短い間隔で何度も再衝突する(窓内の衝突消しを観測できる)。
func _ghost_request() -> BattleRequest:
	var r := BattleRequest.new()
	r.player = BattleRequest.Launch.new(_stats(1.5, 0.5, 15.0), Vector2(4.0, 5.0), Vector2(3, 0))
	r.enemies = [BattleRequest.Launch.new(_stats(1.0, 0.5, 15.0), Vector2(6.0, 5.0), Vector2(-3, 0))]
	return r


## 同じリクエストなら必ず同じ結果。これが崩れるとサーバーとクライアントで
## 違う勝者が出るので、サーバー化の前提そのもの。
func _test_deterministic(check: Callable) -> void:
	var a := BattleResolver.resolve(_request())
	var b := BattleResolver.resolve(_request())

	check.call(a.outcome == b.outcome, "解決: 同じ入力なら同じ勝者")
	check.call(
		absf(a.finish_time - b.finish_time) < EPS,
		"解決: 同じ入力なら同じ決着時刻 (%.4f / %.4f)" % [a.finish_time, b.finish_time]
	)
	check.call(
		a.player_frames.size() == b.player_frames.size(),
		"解決: 同じ入力なら同じフレーム数 (%d / %d)" % [a.player_frames.size(), b.player_frames.size()]
	)
	check.call(a.impacts.size() == b.impacts.size(), "解決: 同じ入力なら同じ衝突回数")
	check.call(
		a.wall_impacts.size() == b.wall_impacts.size(), "解決: 同じ入力なら同じ壁衝突回数"
	)

	# 軌跡が1フレームも違わないこと
	var worst := 0.0
	for i in mini(a.player_frames.size(), b.player_frames.size()):
		worst = maxf(worst, a.player_frames[i].position.distance_to(b.player_frames[i].position))
	check.call(worst < EPS, "解決: 軌跡が完全に一致する (最大ずれ %.6f)" % worst)


## ネットワークに載せる前提の確認。dictにして戻しても結果が変わらないこと。
func _test_serialization_round_trip(check: Callable) -> void:
	var original := _request()
	var revived := BattleRequest.from_dict(original.to_dict())

	var a := BattleResolver.resolve(original)
	var b := BattleResolver.resolve(revived)
	check.call(
		a.outcome == b.outcome and absf(a.finish_time - b.finish_time) < EPS,
		"リクエスト: dictを通しても同じ結果 (%.4f / %.4f)" % [a.finish_time, b.finish_time]
	)

	# 結果の方も往復できること。サーバーが返すのはこれ。
	var result_revived := BattleResult.from_dict(a.to_dict())
	check.call(result_revived.outcome == a.outcome, "結果: dictを通しても勝者が変わらない")
	check.call(
		absf(result_revived.finish_time - a.finish_time) < EPS,
		"結果: dictを通しても決着時刻が変わらない"
	)
	check.call(
		result_revived.player_frames.size() == a.player_frames.size(),
		"結果: dictを通してもフレーム数が変わらない"
	)
	check.call(
		result_revived.enemy_tracks.size() == a.enemy_tracks.size()
		and result_revived.enemy_tracks[0].size() == a.enemy_tracks[0].size(),
		"結果: dictを通しても敵トラックが変わらない"
	)
	check.call(
		result_revived.impacts.size() == a.impacts.size(),
		"結果: dictを通しても衝突回数が変わらない (%d / %d)" % [
			result_revived.impacts.size(), a.impacts.size()
		]
	)
	check.call(
		result_revived.wall_impacts.size() == a.wall_impacts.size(),
		"結果: dictを通しても壁衝突回数が変わらない (%d / %d)" % [
			result_revived.wall_impacts.size(), a.wall_impacts.size()
		]
	)
	var worst := 0.0
	for i in a.player_frames.size():
		worst = maxf(
			worst,
			a.player_frames[i].position.distance_to(result_revived.player_frames[i].position)
		)
	check.call(worst < EPS, "結果: dictを通しても軌跡が変わらない (最大ずれ %.6f)" % worst)

	# ghost_durationもdictに乗って往復すること。乗り忘れると無敵時間がサーバーへ
	# 届かず、ローカルとサーバーで別の勝者が出る。
	var ghosted := _request()
	ghosted.ghost_duration = 1.5
	check.call(
		is_equal_approx(BattleRequest.from_dict(ghosted.to_dict()).ghost_duration, 1.5),
		"リクエスト: ghost_durationがdict往復で保たれる (%.2f)" % [
			BattleRequest.from_dict(ghosted.to_dict()).ghost_duration
		]
	)
	# resolveは無敵時間を結果へ写し、結果もdict往復で保つ(再生はResultだけで完結する)。
	var gres := BattleResolver.resolve(ghosted)
	check.call(
		is_equal_approx(gres.ghost_duration, 1.5),
		"結果: resolveがghost_durationを結果へ写す (%.2f)" % gres.ghost_duration
	)
	check.call(
		is_equal_approx(BattleResult.from_dict(gres.to_dict()).ghost_duration, 1.5),
		"結果: ghost_durationがdict往復で保たれる"
	)

	# 実際にJSONへ通せること。文字列化できない値が混ざっていると
	# サーバーへ送る段になって初めて気づくことになる。
	var json := JSON.stringify(original.to_dict())
	check.call(json.length() > 0, "リクエスト: JSONにできる")
	var parsed = JSON.parse_string(json)
	check.call(parsed != null, "リクエスト: JSONから戻せる")
	if parsed != null:
		var from_json := BattleRequest.from_dict(parsed)
		var c := BattleResolver.resolve(from_json)
		check.call(
			c.outcome == a.outcome and absf(c.finish_time - a.finish_time) < EPS,
			"リクエスト: JSONを通しても同じ結果"
		)


## 必ず終わること。純粋関数で無限ループは許容できない。
func _test_terminates(check: Callable) -> void:
	# 自然減衰を0にすると回転が減らないので、上限に達するはず
	var r := _request()
	r.natural_damping = 0.0
	r.violence = 0.0
	r.wall_damping = 1.0
	r.max_duration = 3.0

	var result := BattleResolver.resolve(r)
	check.call(result.timed_out, "解決: 決着しなくても上限で打ち切る")
	check.call(
		absf(result.finish_time - 3.0) < 0.1,
		"解決: 打ち切りは上限の時刻 (%.2f)" % result.finish_time
	)
	# 打ち切っても勝敗は付ける（残っている回転で決める）
	check.call(result.outcome != null, "解決: 打ち切っても勝敗が決まる")

	# 通常は打ち切りにならない
	var normal := BattleResolver.resolve(_request())
	check.call(not normal.timed_out, "解決: 普通の戦いは上限前に決着する (%.2f秒)" % normal.finish_time)


func _test_frames_and_time(check: Callable) -> void:
	var result := BattleResolver.resolve(_request())

	check.call(result.player_frames.size() > 1, "解決: 軌跡が記録されている (%d)" % result.player_frames.size())
	check.call(
		result.player_frames.size() == result.enemy_tracks[0].size(),
		"解決: 両者のフレーム数が揃っている"
	)
	# フレーム数と決着時刻が刻み幅で整合すること
	var expected := result.finish_time / result.time_step
	check.call(
		absf(result.player_frames.size() - expected) <= 2.0,
		"解決: フレーム数と決着時刻が刻み幅で整合 (%d ≒ %.1f)" % [result.player_frames.size(), expected]
	)
	# 最初のフレームは発射直後の状態
	check.call(
		result.player_frames[0].position.is_equal_approx(Vector2(2, 8)),
		"解決: 1フレーム目が初期位置 (%s)" % result.player_frames[0].position
	)
	# 衝突が起きていること（この初期条件なら当たる）
	check.call(result.impacts.size() > 0, "解決: 衝突が記録されている (%d回)" % result.impacts.size())
	for impact in result.impacts:
		check.call(
			impact.time >= 0.0 and impact.time <= result.finish_time,
			"解決: 衝突時刻が戦闘中に収まる (%.3f)" % impact.time
		)


## 壁への衝突が記録されること。再生側(Battle.gd)が控えめな衝撃波を出すのに使う。
func _test_wall_impacts(check: Callable) -> void:
	# 壁際から壁へ真っ直ぐ撃つ。すり鉢の傾斜が中央へ引き戻すより先に必ず当たるよう、
	# 壁のすぐ内側から速く撃つ。敵は反対側で静止させ、コマ同士では当たらないようにする。
	var r := BattleRequest.new()
	r.player = BattleRequest.Launch.new(_stats(1.5, 0.5, 15.0), Vector2(0.8, 5), Vector2(-8, 0))
	r.enemies = [BattleRequest.Launch.new(_stats(1.0, 0.5, 15.0), Vector2(9, 5), Vector2.ZERO)]

	var result := BattleResolver.resolve(r)

	check.call(
		result.wall_impacts.size() > 0,
		"解決: 壁衝突が記録されている (%d回)" % result.wall_impacts.size()
	)
	var bounds := Arena.BOUNDS.grow(1.0)
	for impact in result.wall_impacts:
		check.call(
			impact.time >= 0.0 and impact.time <= result.finish_time,
			"解決: 壁衝突時刻が戦闘中に収まる (%.3f)" % impact.time
		)
		check.call(
			bounds.has_point(impact.point),
			"解決: 壁衝突の接触点がアリーナ付近にある (%s)" % impact.point
		)


## 再生側がフレーム間を補間できること。描画のfpsが刻み幅と違っても動くための土台。
func _test_sampling(check: Callable) -> void:
	var result := BattleResolver.resolve(_request())

	var at_zero := result.sample(result.player_frames, 0.0)
	check.call(at_zero.position.is_equal_approx(Vector2(2, 8)), "再生: t=0で初期位置")

	# 刻みのちょうど中間は前後の中点になる
	var half := result.time_step * 0.5
	var mid := result.sample(result.player_frames, half)
	var expected: Vector2 = result.player_frames[0].position.lerp(result.player_frames[1].position, 0.5)
	check.call(mid.position.distance_to(expected) < EPS, "再生: フレーム間を線形補間する")

	# 範囲外を頼まれても壊れない
	var before := result.sample(result.player_frames, -1.0)
	check.call(before.position.is_equal_approx(Vector2(2, 8)), "再生: 開始前は最初のフレーム")
	var after := result.sample(result.player_frames, 9999.0)
	var last: Vector2 = result.player_frames[result.player_frames.size() - 1].position
	check.call(after.position.is_equal_approx(last), "再生: 終了後は最後のフレーム")


func _test_outcome(check: Callable) -> void:
	# 圧倒的に有利な条件なら勝つ。数値ではなく向きを見る。
	var r := _request()
	r.player = BattleRequest.Launch.new(_stats(5.0, 1.0, 40.0), Vector2(2, 8), Vector2(6, -6))
	r.enemies = [BattleRequest.Launch.new(_stats(0.5, 0.5, 1.0), Vector2(8, 2), Vector2(-3, 4))]
	var strong := BattleResolver.resolve(r)
	check.call(
		strong.outcome == BattleResult.Outcome.PLAYER_WIN,
		"解決: 回転で大きく勝っていれば勝つ (%s)" % ["draw", "player", "enemy"][strong.outcome]
	)
	check.call(strong.player_won(), "解決: player_won()が勝者と一致する")

	# 逆なら負ける
	var r2 := _request()
	r2.player = BattleRequest.Launch.new(_stats(0.5, 0.5, 1.0), Vector2(2, 8), Vector2(6, -6))
	r2.enemies = [BattleRequest.Launch.new(_stats(5.0, 1.0, 40.0), Vector2(8, 2), Vector2(-3, 4))]
	var weak := BattleResolver.resolve(r2)
	check.call(
		weak.outcome == BattleResult.Outcome.ENEMY_WIN,
		"解決: 回転で大きく負けていれば負ける (%s)" % ["draw", "player", "enemy"][weak.outcome]
	)
	check.call(not weak.player_won(), "解決: 負けたらplayer_won()は偽")


## 複数敵(乱戦)。全敵を倒したときだけ勝ち、プレイヤーが落ちれば残っていても負け。
## 各トラックの長さが揃い、敵同士の衝突も記録され、決定性とJSON往復も保つこと。
func _test_multi_enemy(check: Callable) -> void:
	# 弱い敵3体をプレイヤーの周りに置く。強いプレイヤーが全部倒すはず。
	var r := _request()
	r.player = BattleRequest.Launch.new(_stats(5.0, 1.0, 40.0), Vector2(5, 5), Vector2(2, 1))
	r.enemies = [
		BattleRequest.Launch.new(_stats(0.5, 0.5, 2.0), Vector2(2, 2), Vector2(2, 2)),
		BattleRequest.Launch.new(_stats(0.5, 0.5, 2.0), Vector2(8, 2), Vector2(-2, 2)),
		BattleRequest.Launch.new(_stats(0.5, 0.5, 2.0), Vector2(8, 8), Vector2(-2, -2)),
	]
	var result := BattleResolver.resolve(r)

	check.call(result.enemy_tracks.size() == 3, "乱戦: 敵の数だけトラックがある (%d)" % result.enemy_tracks.size())
	# 全トラックの長さがプレイヤーと揃う
	var aligned := true
	for track in result.enemy_tracks:
		if track.size() != result.player_frames.size():
			aligned = false
	check.call(aligned, "乱戦: 全トラックの長さがプレイヤーと揃う")
	check.call(
		result.outcome == BattleResult.Outcome.PLAYER_WIN,
		"乱戦: 全敵を倒せば勝ち (%s)" % ["draw", "player", "enemy"][result.outcome]
	)

	# プレイヤーが圧倒的に弱ければ、敵が残っていても負ける。
	var r2 := _request()
	r2.player = BattleRequest.Launch.new(_stats(0.5, 0.5, 1.0), Vector2(5, 5), Vector2(1, 0))
	r2.enemies = [
		BattleRequest.Launch.new(_stats(5.0, 1.0, 40.0), Vector2(2, 5), Vector2(3, 0)),
		BattleRequest.Launch.new(_stats(5.0, 1.0, 40.0), Vector2(8, 5), Vector2(-3, 0)),
	]
	var loss := BattleResolver.resolve(r2)
	check.call(
		loss.outcome == BattleResult.Outcome.ENEMY_WIN,
		"乱戦: プレイヤーが落ちれば敵が残っていても負け (%s)" % ["draw", "player", "enemy"][loss.outcome]
	)

	# 敵同士の衝突が起きること。プレイヤーを隅で静止させ、2体を正面衝突させる。
	var r3 := BattleRequest.new()
	r3.player = BattleRequest.Launch.new(_stats(1.5, 0.5, 15.0), Vector2(0.6, 0.6), Vector2.ZERO)
	r3.enemies = [
		BattleRequest.Launch.new(_stats(1.0, 0.5, 15.0), Vector2(3, 5), Vector2(6, 0)),
		BattleRequest.Launch.new(_stats(1.0, 0.5, 15.0), Vector2(7, 5), Vector2(-6, 0)),
	]
	var clash := BattleResolver.resolve(r3)
	check.call(clash.impacts.size() > 0, "乱戦: 敵同士の衝突が記録される (%d回)" % clash.impacts.size())

	# 決定性: 同じ入力なら同じ結果。
	var again := BattleResolver.resolve(r)
	check.call(
		again.outcome == result.outcome and absf(again.finish_time - result.finish_time) < EPS,
		"乱戦: 同じ入力なら同じ結果"
	)

	# JSON往復しても結果が変わらない(サーバー化の前提)。
	var json := JSON.stringify(r.to_dict())
	var parsed = JSON.parse_string(json)
	check.call(parsed != null, "乱戦: リクエストがJSONを通る")
	if parsed != null:
		var revived := BattleResolver.resolve(BattleRequest.from_dict(parsed))
		check.call(
			revived.outcome == result.outcome and absf(revived.finish_time - result.finish_time) < EPS,
			"乱戦: JSONを通しても同じ結果"
		)


## 落ちたコマ(alive=false)は壁の当たり判定を失い、跳ね返らず場外へ素通りする。
## 生きているコマは同じ初速でも壁で跳ね返ってアリーナ内に留まる。
## 傾斜と自然減衰は切って、壁の有無だけが位置を分けるようにする。
func _test_dead_ignores_walls(check: Callable) -> void:
	var req := BattleRequest.new()
	req.stage_strength = 0.0
	req.natural_damping = 0.0
	var bounds := req.arena_bounds
	var walls := ArenaWall.build(req.wall_shape, bounds)
	# 右の壁(x=10)へ向かって速く撃つ。壁際から始めてすぐ当たる位置に置く。
	var launch := BattleRequest.Launch.new(_stats(1.0, 0.5, 15.0), Vector2(9.0, 5.0), Vector2(20, 0))

	var alive_state := BattleResolver.State.new(launch)
	var dead_state := BattleResolver.State.new(launch)
	dead_state.alive = false

	var alive_result := BattleResult.new()
	var dead_result := BattleResult.new()
	var center := bounds.get_center()
	var dt := req.time_step
	var t := 0.0
	var slope_axes := FieldData.slope_axes_for(req.wall_shape, bounds)
	for step in 40:
		BattleResolver._integrate(alive_state, center, req, dt, slope_axes)
		BattleResolver._integrate(dead_state, center, req, dt, slope_axes)
		BattleResolver._resolve_body_field(alive_state, walls, req, dt, t, alive_result)
		BattleResolver._resolve_body_field(dead_state, walls, req, dt, t, dead_result)
		t += dt

	check.call(
		alive_result.wall_impacts.size() > 0,
		"死亡壁抜け: 生きているコマは壁に当たる (%d回)" % alive_result.wall_impacts.size()
	)
	check.call(
		dead_result.wall_impacts.size() == 0,
		"死亡壁抜け: 落ちたコマは壁に当たらない (%d回)" % dead_result.wall_impacts.size()
	)
	check.call(
		bounds.grow(1.0).has_point(alive_state.position),
		"死亡壁抜け: 生きているコマは跳ね返ってアリーナ内に留まる (%s)" % alive_state.position
	)
	check.call(
		dead_state.position.x > bounds.end.x + 1.0,
		"死亡壁抜け: 落ちたコマは壁を素通りして場外へ抜ける (%s)" % dead_state.position
	)


## ゴーストはヒット&ラン: 最初の衝突は通り、その直後からghost_duration秒だけ
## プレイヤーと敵の衝突が消える(開始直後を無敵にする旧仕様は自分の初撃まで
## 消していた)。壁・障害物・敵同士には効かない。
func _test_ghost_hit_and_run(check: Callable) -> void:
	# ゴーストなしの基準。中央近くの正面衝突はすり鉢の傾斜が押し戻すので
	# 短い間隔で何度も再衝突する。窓内に基準の衝突がなければテストが
	# 何も守らないので前提ごと固定する。
	var base := BattleResolver.resolve(_ghost_request())
	check.call(
		base.impacts.size() >= 2,
		"ゴースト: ゴーストなしの基準は2回以上当たる (%d回)" % base.impacts.size()
	)
	var t0 := base.impacts[0].time
	var window := 3.0
	var base_inside := 0
	for impact in base.impacts:
		if impact.time > t0 + EPS and impact.time < t0 + window - EPS:
			base_inside += 1
	check.call(
		base_inside > 0,
		"ゴースト: 基準は初撃後の窓内にも衝突がある (%d回)" % base_inside
	)

	var g := _ghost_request()
	g.ghost_duration = window
	var ghosted := BattleResolver.resolve(g)

	# 初撃は必ず通り、時刻も基準と一致する(窓が開くのは初撃の後だから)。
	check.call(ghosted.impacts.size() >= 1, "ゴースト: 初撃は通る")
	check.call(
		absf(ghosted.impacts[0].time - t0) < EPS,
		"ゴースト: 初撃の時刻は基準と同じ (%.3f / %.3f)" % [ghosted.impacts[0].time, t0]
	)

	# 初撃の直後からwindow秒はプレイヤーと敵の衝突が消える。
	var inside := 0
	for impact in ghosted.impacts:
		if impact.time > t0 + EPS and impact.time < t0 + window - EPS:
			inside += 1
	check.call(inside == 0, "ゴースト: 初撃後の窓内は衝突が消える (%d回)" % inside)

	# 窓の開始時刻は初撃の時刻としてResultへ記録され、dict往復でも保たれる。
	check.call(
		absf(ghosted.ghost_start - t0) < EPS,
		"ゴースト: ghost_start=初撃時刻 (%.3f)" % ghosted.ghost_start
	)
	check.call(
		absf(BattleResult.from_dict(ghosted.to_dict()).ghost_start - ghosted.ghost_start) < EPS,
		"ゴースト: ghost_startがdict往復で保たれる"
	)
	check.call(
		base.ghost_start < 0.0,
		"ゴースト: 窓が開かなければghost_start=-1 (%.1f)" % base.ghost_start
	)
	var legacy := ghosted.to_dict()
	legacy.erase("ghost_start")
	check.call(
		BattleResult.from_dict(legacy).ghost_start < 0.0,
		"ゴースト: ghost_startのない旧dictは-1で読める"
	)

	# 窓判定の純関数境界。窓が開く前(INF)・開いた当のステップ・窓内・窓明け・duration=0。
	check.call(
		not BattleResolver.ghost_blocks(0.0, INF, 2.0), "ゴースト: 窓が開く前は塞がない"
	)
	check.call(
		not BattleResolver.ghost_blocks(1.0, 1.0, 2.0),
		"ゴースト: 窓を開いたステップ自身は塞がない"
	)
	check.call(BattleResolver.ghost_blocks(1.5, 1.0, 2.0), "ゴースト: 窓内は塞ぐ")
	check.call(
		not BattleResolver.ghost_blocks(3.0, 1.0, 2.0), "ゴースト: 窓明けは塞がない"
	)
	check.call(
		not BattleResolver.ghost_blocks(1.5, 1.0, 0.0), "ゴースト: duration=0は塞がない"
	)


## 削り量が相手の絶対速度ではなく2体の相対速度に依存することを確かめる。
## 相手の絶対速度が同じでも、自分も同方向に流れて相対速度が小さい衝突では
## 削られる量が小さくなる。旧実装(相手の絶対速度のみ依存)ではA/Bが等しくなり落ちる。
func _test_relative_speed_drain(check: Callable) -> void:
	var req := _request()
	var stats_a := _stats(1.5, 0.5, 15.0)
	var stats_b := _stats(1.0, 0.5, 15.0)

	# シナリオA: 自分は静止、相手が速さ3で正面から突っ込む。相対速さ=3。
	var drop_a := _collide_and_player_drop(
		req, stats_a, Vector2.ZERO, Vector2.ZERO,
		stats_b, Vector2(1, 0), Vector2(-3, 0)
	)
	# シナリオB: 相手の絶対速度はAと同じ(速さ3)だが、自分も同方向へ速さ2で流れる。
	# 相対速さ=1に下がる。旧実装は相手の絶対速度3だけを見るのでAと同じ削りになる。
	var drop_b := _collide_and_player_drop(
		req, stats_a, Vector2.ZERO, Vector2(-2, 0),
		stats_b, Vector2(1, 0), Vector2(-3, 0)
	)

	check.call(drop_a > 0.0, "相対速度削り: 正面衝突で削られる (%.4f)" % drop_a)
	check.call(drop_b > 0.0, "相対速度削り: 相対速度が小さくても削られる (%.4f)" % drop_b)
	check.call(
		drop_a > drop_b + EPS,
		"相対速度削り: 相手の絶対速度が同じでも相対速度が大きい方が削られる (A=%.4f > B=%.4f)"
			% [drop_a, drop_b]
	)


## a(プレイヤー)とb(敵)を1回だけ衝突させ、aのrps減少量を返す補助。
func _collide_and_player_drop(
	req: BattleRequest,
	stats_a: SpinnerStats, pos_a: Vector2, vel_a: Vector2,
	stats_b: SpinnerStats, pos_b: Vector2, vel_b: Vector2
) -> float:
	var a := BattleResolver.State.new(BattleRequest.Launch.new(stats_a, pos_a, vel_a))
	var b := BattleResolver.State.new(BattleRequest.Launch.new(stats_b, pos_b, vel_b))
	var before := a.rps
	BattleResolver._resolve_disc_collision(a, b, req, 0.0, BattleResult.new())
	return before - a.rps
