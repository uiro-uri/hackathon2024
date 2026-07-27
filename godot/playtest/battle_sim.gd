class_name BattleSim
extends RefCounted

## 1戦を組み立てて解き、検査して、集計用の1レコードにする。
##
## Battle.gdが実プレイでやっていること(出現を決める→発射→resolve)を、
## シーンなしで同じ順に踏む。設定の既定値はBattleRequestの既定値
## (＝Battle.tscnの@exportの既定値)をそのまま使うので、何も上書きしなければ
## 本番と同じ条件になる。

## Battle.tscnと同じ出現条件。
const SPAWN_RING := 4.0
const SPAWN_SPREAD_DEG := 30.0


## 設定の上書き(スイープ用)。nullなら既定のまま。
class Overrides:
	extends RefCounted

	var stage_shape := -1  # -1なら既定
	var violence := -1.0

	func apply(request: BattleRequest) -> void:
		if stage_shape >= 0:
			request.stage_shape = stage_shape as SpinnerPhysics.StageShape
		if violence >= 0.0:
			request.violence = violence


## 何も指定されなかったときの土俵。BattleRequestの既定値(＝Battle.tscnの
## @export既定値)と一致させてあるので、fieldを渡さなければ従来どおりになる。
static func default_field() -> FieldData:
	var defaults := BattleRequest.new()
	return FieldData.make(
		"FIELD_DEFAULT", defaults.arena_bounds, defaults.wall_shape,
		defaults.stage_shape, defaults.stage_strength
	)


## 1戦。シードが同じなら結果も同じ。敵は複数体(乱戦)もありうる。
## fieldは戦う土俵。nullなら既定(現行の矩形すり鉢)。
static func play_one(
	seed_value: int,
	enemies: Array[EnemyData],
	policy: LaunchPolicy.Kind,
	player_stats: SpinnerStats,
	overrides: Overrides = null,
	field: FieldData = null,
	ghost_duration: float = 0.0
) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	if field == null:
		field = default_field()

	# Battle.build_request と同じ順。土俵を敷いてから、スイープの上書きを載せる
	# (上書きはフィールドより後でないと効かない)。
	var request := BattleRequest.new()
	request.arena_bounds = field.arena_bounds
	request.wall_shape = field.wall_shape
	request.obstacles = field.obstacles
	request.stage_strength = field.stage_strength
	request.stage_shape = field.stage_shape
	if overrides != null:
		overrides.apply(request)
	# ゴーストのすり抜け時間。取得済み札から算出した値をRunSimが渡す。
	request.ghost_duration = ghost_duration

	# Battle._spawn_enemy と同じ手順で、各敵の出現を index順に決める。
	var plans: Array[EnemySpawn.Plan] = []
	var enemy_launches: Array[BattleRequest.Launch] = []
	var top_level := 0
	for enemy in enemies:
		# 発射速度は実ゲーム(Battle._spawn_enemy)と同じく共通レンジから出現ごとに抽選。
		var plan := EnemySpawn.plan(
			field.center(), SPAWN_RING, LaunchSpeed.random(rng),
			SPAWN_SPREAD_DEG, rng, enemy.stats.radius, field.inradius()
		)
		plans.append(plan)
		enemy_launches.append(
			BattleRequest.Launch.new(enemy.stats, plan.position, plan.velocity)
		)
		top_level = maxi(top_level, enemy.level)

	# 発射方針には先頭の敵の予告を渡す。乱戦でもプレイヤーの発射は1回きりなので、
	# 狙う基準を1つに固定して決定性を保つ。
	var launch := LaunchPolicy.decide(policy, field, player_stats.radius, plans[0], rng)

	request.player = BattleRequest.Launch.new(player_stats, launch.position, launch.velocity)
	request.enemies = enemy_launches

	var result := BattleResolver.resolve(request)
	var violations := PlaytestInvariants.check(request, result)

	var record := {
		"seed": seed_value,
		"level": top_level,
		"count": enemies.size(),
		"enemy": enemies[0].display_name,
		"field": field.title_key,
		"policy": LaunchPolicy.NAMES[policy],
		"shape": int(request.stage_shape),
		"violence": request.violence,
		"win": result.player_won(),
		"outcome": int(result.outcome),
		"finish_time": result.finish_time,
		"timed_out": result.timed_out,
		"impacts": result.impacts.size(),
	}
	# 死因の内訳(一撃死かどうか、決着までの衝突回数)を足す。集計側が読む。
	record.merge(BattleMetrics.classify(request, result))
	if not violations.is_empty():
		record["violations"] = violations
		# from_dict()で即再現できるよう、入力を丸ごと残す
		record["request"] = request.to_dict()
	return record
