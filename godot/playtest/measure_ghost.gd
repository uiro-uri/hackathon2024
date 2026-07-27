extends SceneTree

## GHOSTがボスに刺さる根本原因＝「すり抜け中に敵が自滅する」を定量化する診断。
## (ヒット&ラン化以降、すり抜け窓は開始直後ではなく最初の衝突の直後から開く。
## この診断の見方自体は変わらない。)
##
## すり抜け(ghost)秒数を変えて、敵(特にボスLv5)が **どう死ぬか** を death_cause で分解する:
##  - drain: プレイヤーの削り(コマ同士の衝突)で死ぬ＝正当な撃破
##  - decay: 自然回転減衰で勝手に死ぬ＝自滅
##  - wall : 壁でのrps喪失で死ぬ＝自滅
## すり抜けを伸ばすほど「自滅(decay+wall)」比率が上がるなら、GHOSTは敵の自滅を
## 安全に待つ札。ここを下げる調整の前後で比較する。
##
##   godot --headless --path godot --script res://playtest/measure_ghost.gd -- [--count=1500] [--policy=intercept]

const LEVELS := [3, 4, 5]
const GHOSTS := [0.0, 2.0, 4.0, 6.0]


func _init() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			var eq := arg.find("=")
			args[arg.substr(2, eq - 2)] = arg.substr(eq + 1)
	var count := int(args.get("count", "1500"))
	var policy := LaunchPolicy.by_name(args.get("policy", "intercept"))
	# 敵の自然回転減衰の倍率。<1で敵が自滅しにくくなる（GHOSTの効き検証用）。
	var enemy_decay := float(args.get("enemy-decay", "1.0"))
	if not is_equal_approx(enemy_decay, 1.0):
		print("# 敵spin_decay=%.2f（自滅しにくく調整）" % enemy_decay)

	print("# すり抜け秒数別: 敵の死因分解 (発射=%s, count=%d/セル)" % [LaunchPolicy.NAMES[policy], count])
	print("# 素の初期性能。勝率と、プレイヤー勝ち(敵敗北)の内訳を death_cause で分ける。")
	print("# 自滅=decay+wall。すり抜けを伸ばして自滅比率が上がる＝GHOSTが刺さる余地。")

	for level in LEVELS:
		var pool := EnemyRoster.of_level(level)
		print("\n## 敵レベル %d" % level)
		print("| すり抜けs | 勝率 | 敵敗北のうち drain(撃破) / decay+wall(自滅) |")
		print("|---|---|---|")
		for ghost in GHOSTS:
			var wins := 0
			var drain := 0
			var selfdestruct := 0
			for i in count:
				var pick_rng := RandomNumberGenerator.new()
				pick_rng.seed = i
				var enemy := pool[pick_rng.randi_range(0, pool.size() - 1)]
				# 敵の自然回転減衰を倍率で弱める（自滅頻度を下げる検証）。共有Resourceを
				# 壊さないようstatsを複製してから触る。
				if not is_equal_approx(enemy_decay, 1.0):
					var es := enemy.stats.duplicate_stats()
					es.spin_decay = enemy_decay
					enemy = EnemyData.make(enemy.level, enemy.display_name, es)
				var enemies: Array[EnemyData] = [enemy]
				var stats := SpinnerStats.default_player()
				var record := BattleSim.play_one(i, enemies, policy, stats, null, null, ghost)
				if record["win"]:
					wins += 1
				if record.get("loser", "none") == "enemy":
					var cause: String = record.get("death_cause", "decay")
					if cause == "drain":
						drain += 1
					else:
						selfdestruct += 1
			var enemy_deaths := drain + selfdestruct
			var win_pct := 100.0 * wins / count
			var drain_pct := 100.0 * drain / enemy_deaths if enemy_deaths > 0 else 0.0
			var self_pct := 100.0 * selfdestruct / enemy_deaths if enemy_deaths > 0 else 0.0
			print("| %.0f | %.1f%% | %.1f%% / %.1f%% |" % [ghost, win_pct, drain_pct, self_pct])
	quit(0)
