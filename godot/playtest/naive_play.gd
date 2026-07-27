extends SceneTree

## 事前知識ゼロの初見プレイを1手ずつ回すための対話ドライバ(テストプレイ専用・使い捨て)。
##
## 使い方(状態はJSONファイルに永続化する):
##   new    --seed=N --state=path            ラン開始。マップと開始位置を出す
##   status --state=path                      現在のステータス/所持パーツ/残機/進める先
##   enter  --state=path --col=C --bseed=B    次ノードへ入り、敵の予告(テレグラフ)を出す
##   launch --state=path --bseed=B --from-deg=D --target=center|enemyK|x,y --force=F
##                                            自分の発射を決めて1戦解決。勝敗を出す
##   reward --state=path --bseed=B            勝利後、報酬3枚の効果を出す
##   pick   --state=path --id=ID              報酬を1枚取り、次のマップ選択へ
##   retry  --state=path --bseed=B            残機を1消費して同ノードを再抽選(新しい予告)
##   giveup --state=path                      あきらめてラン終了
##
## 予告(enter/retry)と解決(launch)は同じ --bseed を渡すこと(敵の出現が一致する)。

const MAX_SPEED := 20.0
const SPAWN_RING := 4.0
const SPAWN_SPREAD_DEG := 30.0


func _init() -> void:
	var a := _args()
	var cmd: String = a.get("cmd", "")
	var path: String = a.get("state", "")
	match cmd:
		"new": _new(int(a.get("seed", "0")), path)
		"status": _status(_load(path), path)
		"enter": _enter(_load(path), path, int(a["col"]), int(a["bseed"]))
		"launch": _launch(_load(path), path, int(a["bseed"]), float(a.get("from-deg","0")), a.get("target","enemy1"), float(a.get("force","1.0")))
		"reward": _reward(_load(path), path, int(a["bseed"]))
		"pick": _pick(_load(path), path, int(a["id"]))
		"retry": _retry(_load(path), path, int(a["bseed"]))
		"giveup": _giveup(_load(path), path)
		_: printerr("unknown cmd: ", cmd)
	quit(0)


# ---- 状態の入出力 ----

func _default_state(seed_value: int) -> Dictionary:
	var s := SpinnerStats.default_player()
	return {
		"seed": seed_value,
		"path": [],            # 突破済みノードの列 [[step,col],...]
		"pending": null,       # 交戦中ノードの col (未突破)
		"stats": _stats_dict(s),
		"parts": [],
		"continues": 3,
		"cleared": false,
		"dead": false,
	}

func _stats_dict(s: SpinnerStats) -> Dictionary:
	return {"mass": s.mass, "radius": s.radius, "friction": s.friction, "restitution": s.restitution, "rps": s.rps}

func _stats_from(d: Dictionary) -> SpinnerStats:
	var s := SpinnerStats.new()
	s.mass = d["mass"]; s.radius = d["radius"]; s.friction = d["friction"]; s.restitution = d["restitution"]; s.rps = d["rps"]
	return s

func _load(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text())

func _save(state: Dictionary, path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(state, "  "))
	f.close()

## seedからツリーを作り、突破済みpathに沿って現在ノードまで進める。
func _tree_at(state: Dictionary) -> MapTree:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(state["seed"])
	var tree := MapTree.generate(rng)
	for step_col in state["path"]:
		tree.advance_to(Vector2i(int(step_col[0]), int(step_col[1])))
	return tree


# ---- コマンド ----

func _new(seed_value: int, path: String) -> void:
	var state := _default_state(seed_value)
	_save(state, path)
	var tree := _tree_at(state)
	print("=== NEW RUN seed=%d 残機=%d ===" % [seed_value, state["continues"]])
	_print_tree(tree)
	_print_reachable(tree)

func _status(state: Dictionary, path: String) -> void:
	var tree := _tree_at(state)
	print("=== STATUS ===")
	print("残機=%d  クリア=%s  死亡=%s" % [state["continues"], state["cleared"], state["dead"]])
	_print_stats(state)
	_print_parts(state)
	print("現在段=%d 交戦中col=%s" % [tree.current_step(), str(state["pending"])])
	_print_tree(tree)
	_print_reachable(tree)

func _enter(state: Dictionary, path: String, col: int, bseed: int) -> void:
	var tree := _tree_at(state)
	var target := Vector2i(tree.current_step() + 1, col)
	if not target in tree.next_coords():
		printerr("そのノードへは進めない: ", target, " 進める先=", tree.next_coords()); return
	state["pending"] = col
	_save(state, path)
	# pathには勝ってから足す。ここでは表示のためadvanceした木を使う
	tree.advance_to(target)
	_reveal(state, tree, bseed)

func _retry(state: Dictionary, path: String, bseed: int) -> void:
	if int(state["continues"]) <= 0:
		print("残機なし。giveupへ。"); return
	state["continues"] = int(state["continues"]) - 1
	_save(state, path)
	var tree := _tree_at(state)
	tree.advance_to(Vector2i(tree.current_step() + 1, int(state["pending"])))
	print("=== RETRY 残機を1消費 (残り%d) 敵を再抽選 ===" % state["continues"])
	_reveal(state, tree, bseed)

## 交戦中ノードの敵予告と土俵を出す。プレイヤーが撃つ前に見える情報。
func _reveal(state: Dictionary, tree: MapTree, bseed: int) -> void:
	var node: MapTree.MapNode = tree.nodes[tree.current_coord]
	var field: FieldData = node.field
	print("=== BATTLE 段%d %s ===" % [tree.current_step(), field.title_key])
	print("土俵: 形状=%s 中心=%s 内接半径=%.2f 範囲=%s" % [
		_wall_name(field.wall_shape), str(field.center()), field.inradius(), str(field.arena_bounds)])
	print("自分: mass=%.2f radius=%.2f rps=%.1f friction=%.3f rest=%.2f  発射リング半径=%.2f" % [
		state["stats"]["mass"], state["stats"]["radius"], state["stats"]["rps"],
		state["stats"]["friction"], state["stats"]["restitution"],
		field.inradius() - float(state["stats"]["radius"]) - 0.5])
	print("ゴースト(初衝突後すり抜け): %.1fs" % CustomPartCatalog.total_ghost_seconds(_ids(state)))
	var plans := _enemy_plans(node.enemies, field, bseed)
	print("敵 %d体 (bseed=%d):" % [node.enemies.size(), bseed])
	for i in node.enemies.size():
		var e: EnemyData = node.enemies[i]
		var pl: EnemySpawn.Plan = plans[i]
		var dir := pl.velocity.normalized()
		print("  enemy%d Lv%d '%s': 出現=%s 速度=%.1f 向き=%.0f° radius=%.2f rps=%.1f" % [
			i + 1, e.level, e.display_name, str(pl.position), pl.velocity.length(),
			rad_to_deg(dir.angle()), e.stats.radius, e.stats.rps])
	print("→ launch --bseed=%d --from-deg=<0-360> --target=center|enemy1..|x,y --force=<0-1>" % bseed)

func _launch(state: Dictionary, path: String, bseed: int, from_deg: float, target: String, force: float) -> void:
	var tree := _tree_at(state)
	tree.advance_to(Vector2i(tree.current_step() + 1, int(state["pending"])))
	var node: MapTree.MapNode = tree.nodes[tree.current_coord]
	var field: FieldData = node.field
	var plans := _enemy_plans(node.enemies, field, bseed)
	var pstats := _stats_from(state["stats"])

	var pos := _ring_pos(field, pstats.radius, from_deg)
	var tgt := _target_point(field, plans, target)
	var vel := (tgt - pos).normalized() * clampf(force, 0.0, 1.0) * MAX_SPEED

	var req := BattleRequest.new()
	req.arena_bounds = field.arena_bounds
	req.wall_shape = field.wall_shape
	req.obstacles = field.obstacles
	req.stage_strength = field.stage_strength
	req.stage_shape = field.stage_shape
	req.ghost_duration = CustomPartCatalog.total_ghost_seconds(_ids(state))
	req.player = BattleRequest.Launch.new(pstats, pos, vel)
	var elaunch: Array[BattleRequest.Launch] = []
	for i in node.enemies.size():
		elaunch.append(BattleRequest.Launch.new(node.enemies[i].stats, plans[i].position, plans[i].velocity))
	req.enemies = elaunch

	var result := BattleResolver.resolve(req)
	var metrics := BattleMetrics.classify(req, result)
	var won := result.player_won()
	print("=== 発射: pos=%s vel=%.1f@%.0f° target=%s force=%.2f ===" % [
		str(pos), vel.length(), rad_to_deg(vel.angle()), target, force])
	print("結果: %s  決着=%.2fs 衝突=%d timed_out=%s" % [
		("★勝利★" if won else "敗北"), result.finish_time, result.impacts.size(), result.timed_out])
	print("  死因=%s loser=%s hits_taken=%s" % [
		metrics.get("death_cause","?"), metrics.get("loser","?"), str(metrics.get("hits_taken","?"))])
	if won:
		print("→ reward --bseed=<R> で報酬を見る")
	else:
		print("→ retry --bseed=<新B> (残機%d) か giveup" % state["continues"])

func _reward(state: Dictionary, path: String, bseed: int) -> void:
	var tree := _tree_at(state)
	tree.advance_to(Vector2i(tree.current_step() + 1, int(state["pending"])))
	var level := EnemyRoster.level_for_step(tree.current_step())
	var rng := RandomNumberGenerator.new(); rng.seed = bseed
	var choices := CustomPartCatalog.pick_choices(CustomPartCatalog.REWARD_CHOICES, rng, level)
	print("=== REWARD 段%d(Lv%d)撃破 3枚から1枚 (bseed=%d) ===" % [tree.current_step(), level, bseed])
	for c in choices:
		print("  id=%d '%s' [%s] %s" % [c.id, c.title_key, _rarity(c.rarity), _card_text(c)])
	print("→ pick --id=<ID>")

func _pick(state: Dictionary, path: String, id: int) -> void:
	var tree := _tree_at(state)
	var col := int(state["pending"])
	tree.advance_to(Vector2i(tree.current_step() + 1, col))
	var part := CustomPartCatalog.by_id(id)
	if part == null: printerr("不明なパーツid ", id); return
	var stats := _stats_from(state["stats"])
	part.apply_to(stats)
	state["stats"] = _stats_dict(stats)
	state["continues"] = maxi(int(state["continues"]), part.lives)
	state["parts"].append(id)
	# ノード突破を確定
	state["path"].append([tree.current_step(), col])
	state["pending"] = null
	if tree.is_goal():
		state["cleared"] = true
	_save(state, path)
	print("取得: id=%d '%s' → %s" % [id, part.title_key, _card_text(part)])
	_print_stats(state)
	if state["cleared"]:
		print("！！！全段突破・ラン完了！！！")
	else:
		var t2 := _tree_at(state)
		_print_reachable(t2)

func _giveup(state: Dictionary, path: String) -> void:
	state["dead"] = true
	_save(state, path)
	print("=== GIVE UP 段%d で終了 取得%d枚 残機%d ===" % [
		_tree_at(state).current_step(), state["parts"].size(), state["continues"]])


# ---- 計算ヘルパ ----

func _enemy_plans(enemies: Array, field: FieldData, bseed: int) -> Array:
	var rng := RandomNumberGenerator.new(); rng.seed = bseed
	var plans := []
	for e in enemies:
		plans.append(EnemySpawn.plan(field.center(), SPAWN_RING, LaunchSpeed.random(rng), SPAWN_SPREAD_DEG, rng, e.stats.radius, field.inradius()))
	return plans

func _ring_pos(field: FieldData, prad: float, from_deg: float) -> Vector2:
	var ring := field.inradius() - prad - 0.5
	var p := field.center() + Vector2.RIGHT.rotated(deg_to_rad(from_deg)) * ring
	if field.wall_shape == ArenaWall.WallShape.RECT:
		return ArenaWall.clamp_inside(field.arena_bounds, p, prad)
	return ArenaWall.clamp_inside_circle(field.center(), field.inradius(), p, prad)

func _target_point(field: FieldData, plans: Array, target: String) -> Vector2:
	if target == "center":
		return field.center()
	if target.begins_with("enemy"):
		var idx := int(target.substr(5)) - 1
		return plans[clampi(idx, 0, plans.size() - 1)].position
	var parts := target.split(",")
	if parts.size() == 2:
		return Vector2(float(parts[0]), float(parts[1]))
	return field.center()

func _ids(state: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for v in state["parts"]: out.append(int(v))
	return out


# ---- 表示ヘルパ ----

func _print_stats(state: Dictionary) -> void:
	var s = state["stats"]
	print("ステータス: mass=%.2f radius=%.2f friction=%.3f rest=%.2f rps=%.1f  (寿命目安rps/radius=%.1f 硬さmass*r^2=%.2f)" % [
		s["mass"], s["radius"], s["friction"], s["restitution"], s["rps"],
		float(s["rps"]) / float(s["radius"]), float(s["mass"]) * float(s["radius"]) * float(s["radius"])])

func _print_parts(state: Dictionary) -> void:
	if state["parts"].is_empty(): print("所持パーツ: なし"); return
	var names := []
	for id in state["parts"]:
		var p := CustomPartCatalog.by_id(int(id))
		names.append("%s" % (p.title_key if p else str(id)))
	print("所持パーツ: ", ", ".join(names))

func _print_tree(tree: MapTree) -> void:
	print("--- MAP (段:col=Lv[体数,土俵])  ゴールは段9のボス ---")
	for step in range(1, 10):
		var row := []
		for col in range(-4, 6):
			var c := Vector2i(step, col)
			if tree.nodes.has(c):
				var n: MapTree.MapNode = tree.nodes[c]
				row.append("col%+d=Lv%d[%d体,%s]" % [col, n.level(), n.enemy_count(), n.field.title_key.replace("FIELD_","")])
		if not row.is_empty():
			print("  段%d: %s" % [step, "  ".join(row)])

func _print_reachable(tree: MapTree) -> void:
	print("進める先(段%d→):" % (tree.current_step() + 1))
	for c in tree.next_coords():
		var n: MapTree.MapNode = tree.nodes[c]
		print("  col%+d : Lv%d %d体 %s" % [c.y, n.level(), n.enemy_count(), n.field.title_key])

## プレイヤーが実際に見る効果文(describe())をそのまま出す。独自に組み立てると
## MOMENTUM/RAGEのような非STAT効果がstat(既定MASS)で誤表示される(実際に盲プレイを
## 「質量×0.80」等の偽カード文で汚した)。改行は1行表示用に潰す。
func _card_text(c: CustomPart) -> String:
	return c.describe().replace("\n", " / ")

func _rarity(r: int) -> String:
	return "RARE" if r == CustomPart.Rarity.RARE else "COMMON"

func _wall_name(w: int) -> String:
	var names := ["RECT","CIRCLE","OCT"]
	return names[w] if w >= 0 and w < names.size() else str(w)

func _args() -> Dictionary:
	var out := {"cmd": ""}
	var argv := OS.get_cmdline_user_args()
	if argv.size() > 0 and not argv[0].begins_with("--"):
		out["cmd"] = argv[0]
	for arg in argv:
		if arg.begins_with("--") and arg.contains("="):
			var eq := arg.find("=")
			out[arg.substr(2, eq - 2)] = arg.substr(eq + 1)
	return out
