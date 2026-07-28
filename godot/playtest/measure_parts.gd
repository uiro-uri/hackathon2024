extends SceneTree

## 単独パーツの「1枚あたりの戦闘価値」を測る計測スクリプト。
##
## run_sim(--parts)のforce-partはラン全体を測るので、greedy完全ビルドに対する
## 「1札に固執する機会損失」が混じり、札そのものの強さと切り分けにくい。
## こちらは他条件を完全に固定し、初期性能に対象札を0〜N枚だけ足して、同じ敵に
## 多数の発射シードで挑ませ、勝率の増分だけを見る。純粋な限界効果。
##
##   godot --headless --path godot --script res://playtest/measure_parts.gd -- [--count=800] [--policy=intercept]
##
## --policy で発射方針を変える。半径(GIANT_GROWTH)の攻撃価値は衝突頻度を介する
## ので、当たりに行く方針(aim_spawn/aim_center)では intercept より強く出る。
##
## 残機(SPARE_CORE)は1戦では価値が出ない(コンティニューはラン跨ぎ)ので、ここでは
## ステータス札とGHOSTのみを測る。SPARE_COREはラン単位(--parts)で評価する。

const LEVELS := [1, 3, 5]
const COPIES := [0, 1, 2, 3]
# 測る札。SET_LIVES(id8)は1戦では無意味なので外す。
const PART_IDS := [2, 3, 5, 6, 7, 9]
const PART_LABEL := {
	2: "GIANT_GROWTH  直径×1.1 質量×1.2",
	3: "OVERENCUMBERED 質量+0.75",
	5: "FULL_STEAM     勢い維持×0.8",
	6: "RAGE_REFLECT   反発+壁保持",
	7: "SPIN_ENGINE    RPS ×1.25",
	9: "GHOST          初衝突後すり抜け2s/枚",
}


func _init() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			var eq := arg.find("=")
			args[arg.substr(2, eq - 2)] = arg.substr(eq + 1)
	var count := int(args.get("count", "800"))
	var policy := LaunchPolicy.by_name(args.get("policy", "intercept"))
	var policy_name: String = LaunchPolicy.NAMES[policy]

	print("# 単独パーツの1戦あたり勝率 (発射=%s, count=%d/セル)" % [policy_name, count])
	print("# baselineは0枚。+1/+2/+3は初期性能に対象札をその枚数だけ適用した勝率。")

	for level in LEVELS:
		var pool := EnemyRoster.of_level(level)
		print("\n## 敵レベル %d" % level)
		# baseline(0枚)はどの札でも同じなので先に出す。
		var base_rate := _win_rate(_stats_with(0, 0), 0.0, pool, count, policy)
		print("baseline(0枚): %.1f%%" % (base_rate * 100.0))
		print("| パーツ | +1枚 | +2枚 | +3枚 | (Δ+1 / Δ+3) |")
		print("|---|---|---|---|---|")
		for pid in PART_IDS:
			var cells: Array[String] = []
			var rates: Array[float] = []
			for copies in COPIES:
				if copies == 0:
					continue
				var ghost: float = 2.0 * copies if pid == 9 else 0.0
				var rate := _win_rate(_stats_with(pid, copies), ghost, pool, count, policy)
				rates.append(rate)
				cells.append("%.1f%%" % (rate * 100.0))
			var d1 := (rates[0] - base_rate) * 100.0
			var d3 := (rates[2] - base_rate) * 100.0
			print("| %s | %s | %s | %s | %+.1f / %+.1f pt |" % [
				PART_LABEL[pid], cells[0], cells[1], cells[2], d1, d3
			])
	quit(0)


## 初期性能に、指定idの札をcopies枚だけ適用したstatsを返す。0枚なら素の初期性能。
func _stats_with(pid: int, copies: int) -> SpinnerStats:
	var stats := SpinnerStats.default_player()
	if pid == 0 or copies == 0:
		return stats
	var part := CustomPartCatalog.by_id(pid)
	for i in copies:
		part.apply_to(stats)
	return stats


## 与えたstats/ghostで、poolの敵にcount回挑んだ勝率。敵個体と発射はシードで決まる
## (playtest_mainのbattleモードと同じ振り方)。
func _win_rate(
	stats: SpinnerStats, ghost: float, pool: Array[EnemyData], count: int,
	policy: LaunchPolicy.Kind
) -> float:
	var wins := 0
	for i in count:
		var pick_rng := RandomNumberGenerator.new()
		pick_rng.seed = i
		var enemy := pool[pick_rng.randi_range(0, pool.size() - 1)]
		var enemies: Array[EnemyData] = [enemy]
		var record := BattleSim.play_one(i, enemies, policy, stats, null, null, ghost)
		if record["win"]:
			wins += 1
	return float(wins) / float(count)
