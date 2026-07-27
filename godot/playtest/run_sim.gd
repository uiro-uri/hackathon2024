class_name RunSim
extends RefCounted

## 1ラン(タイトル→マップ→戦闘→報酬→…→ボスorゲームオーバー)を丸ごと回す。
##
## ローグライクのバランス(パーツの強弱、どの段で死ぬか、RPSのインフレ)は
## ラン全体でしか測れない。Main.gdの進行(段→敵と土俵、勝利→倒した頭数ぶん
## 報酬3枚から1枚ずつ)を最小限に写しているので、Main.gd側の進行を変えたらここも
## 見ること。1回あたりの報酬枚数はCustomPartCatalog.REWARD_CHOICES(画面と共有)を参照。

enum RewardPolicy {
	## 3枚から一様ランダム。何も考えない人。
	RANDOM,
	## 一番硬くなる札を取る。人間の柔軟さには届かないが「考えて選ぶ人」の近似。
	GREEDY,
	## 特定の札(force_part_id)を、出るたびに必ず取る。単独強化の因果を測るための計測用。
	## greedyのtoughness選好では絶対選ばれないSET_LIVES/GHOST札も測れる。
	## 3択に対象が無い回はgreedyに委譲する。
	FORCED,
}

const REWARD_NAMES := {
	RewardPolicy.RANDOM: "random",
	RewardPolicy.GREEDY: "greedy",
	RewardPolicy.FORCED: "forced",
}

## ランの開始残機。autoloadのGameStateは--script実行から参照できない
## (spinner_stats.gdの同趣旨コメント参照)ので、GameState.MAX_CONTINUES(=3)を
## ここに鏡写しにする。片方を変えたら両方合わせること。
const START_CONTINUES := 3


static func reward_by_name(name: String) -> RewardPolicy:
	for kind in REWARD_NAMES:
		if REWARD_NAMES[kind] == name:
			return kind
	push_error("RunSim: 未知の報酬方針 '%s'" % name)
	return RewardPolicy.RANDOM


## 1ラン。シードが同じなら結果も同じ。
## force_part_id: FORCED方針のとき優先して取る札のid(0で指定なし)。他方針では無視。
static func play_one(
	seed_value: int,
	launch_policy: LaunchPolicy.Kind,
	reward_policy: RewardPolicy,
	overrides: BattleSim.Overrides = null,
	force_part_id: int = 0
) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var stats := SpinnerStats.default_player()
	var tree := MapTree.generate(rng)
	if tree == null:
		return {"seed": seed_value, "error": "map_generation_failed"}

	var battles: Array = []
	var parts: Array[int] = []
	# 残機(コンティニュー)。実プレイのGameStateと同じく開始3。敗北しても残機が
	# あれば同じ相手・同じ土俵で再挑戦する(Main._on_continue_requested)。
	var continues := START_CONTINUES
	var continues_used := 0
	var won_all := false

	while true:
		# 経路はランダムに選ぶ(人間の経路選びは今のマップでは差がつかない:
		# ノード種別が全部敵なので、どこを通っても戦闘数は同じ)
		var nexts := tree.next_coords()
		if nexts.is_empty():
			break
		tree.advance_to(nexts[rng.randi_range(0, nexts.size() - 1)])

		# Main._on_map_node_chosen と同じく、進んだノードに確定済みの遭遇を使う
		# （マップ生成時に決まっている。実戦とシミュレーションの遭遇を一致させる）。
		var node: MapTree.MapNode = tree.nodes[tree.current_coord]
		var group := node.enemies
		var field := node.field
		# 取得済みのゴースト札からすり抜け時間を出して戦闘に渡す。Battle.build_requestと同じ。
		var ghost_duration := CustomPartCatalog.total_ghost_seconds(parts)

		# その段の戦闘。敗北しても残機がある限り、同じノードで再挑戦する
		# (Main._on_continue_requestedはpending/coordを触らず同グループ再戦)。
		# 毎回の記録は1回=1レコードで残す(段ごとの1戦あたり勝率は従来どおりの意味)。
		var record: Dictionary = {}
		var attempt := 0
		while true:
			record = BattleSim.play_one(
				rng.randi(), group, launch_policy, stats, overrides, field, ghost_duration
			)
			var entry := {
				"step": tree.current_step(),
				"level": record["level"],
				"count": record["count"],
				"field": record["field"],
				"win": record["win"],
				"attempt": attempt,
				"finish_time": record["finish_time"],
				"rps_before": stats.rps,
				"mass_before": stats.mass,
				"radius_before": stats.radius,
				"death_cause": record.get("death_cause", "none"),
				"loser": record.get("loser", "none"),
				"fatal_hit_index": record.get("fatal_hit_index", 0),
				"hits_taken": record.get("hits_taken", 0),
			}
			if record.has("violations"):
				entry["violations"] = record["violations"]
			battles.append(entry)

			if record["win"]:
				break
			# 敗北: 残機があれば1消費して再挑戦、無ければこの段で力尽きる。
			if continues > 0:
				continues -= 1
				continues_used += 1
				attempt += 1
				continue
			break

		if not record["win"]:
			break

		if tree.is_goal():
			won_all = true
			break

		# 勝利報酬。Main._on_battle_finished/_on_part_chosen(GameState.apply_part)と
		# 同じく、倒した頭数ぶん報酬を選ぶ(乱戦はrps据え置きで手強いぶん見返りも頭数ぶん)。
		# 各回: ステータス倍率に加え、SET_LIVES札(SPARE_CORE)は残機をmaxiで底上げする。
		# 倒した敵のレベルほどレアが出やすい。
		for _r in maxi(group.size(), 1):
			var choices := CustomPartCatalog.pick_choices(
				CustomPartCatalog.REWARD_CHOICES, rng, int(record["level"])
			)
			var part := _choose_part(choices, reward_policy, rng, stats, force_part_id)
			part.apply_to(stats)
			continues = maxi(continues, part.lives)
			parts.append(part.id)

	return {
		"seed": seed_value,
		"policy": LaunchPolicy.NAMES[launch_policy],
		"reward_policy": REWARD_NAMES[reward_policy],
		"force_part_id": force_part_id,
		"cleared": won_all,
		"died_at_step": -1 if won_all else tree.current_step(),
		"battles_won": battles.filter(func(b): return b["win"]).size(),
		"parts": parts,
		"continues_used": continues_used,
		"final_continues": continues,
		"final_rps": stats.rps,
		"final_radius": stats.radius,
		"final_mass": stats.mass,
		"battles": battles,
	}


## 「耐えられる衝突回数」の目安。
##
## 1衝突で失うRPSは violence×(相手質量×相手速さ)÷(自分質量×自分半径²) なので、
## 何発耐えられるかは rps×自分質量×自分半径² に比例する。この式が
## 勝敗をほぼ決めているので、これを最大化する札を取るのが「考えて選ぶ人」。
##
## 最初はステータスごとの好みを手で並べていたが、それだと半径が2乗で効くことを
## 見落として Shrink(半径×0.5) を良い札として選んでしまい、「上手い人」のはずが
## 耐久を1/4にしていた。式から出す方が間違えない。
static func toughness(stats: SpinnerStats) -> float:
	return stats.rps * stats.mass * stats.radius * stats.radius


static func _choose_part(
	choices: Array[CustomPart], policy: RewardPolicy, rng: RandomNumberGenerator,
	stats: SpinnerStats, force_part_id: int = 0
) -> CustomPart:
	if policy == RewardPolicy.RANDOM:
		return choices[rng.randi_range(0, choices.size() - 1)]

	# FORCED: 対象idが3択にあれば必ずそれを取る。無い回はgreedyに委譲する。
	if policy == RewardPolicy.FORCED:
		for part in choices:
			if part.id == force_part_id:
				return part

	var best: CustomPart = choices[0]
	var best_score := -INF
	for part in choices:
		# 実際に適用してみて測る。上限に当たって効かない札もここで分かる。
		var probe := stats.duplicate_stats()
		part.apply_to(probe)
		var score := toughness(probe)
		# 硬さが変わらない札(摩擦・反発)は速さで比べる。摩擦が低いほど、
		# 反発が高いほど、当たったときに削れる量が増える。
		score += (2.0 - probe.friction) * 0.01 + probe.restitution * 0.01
		if score > best_score:
			best_score = score
			best = part
	return best
