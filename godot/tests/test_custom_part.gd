extends RefCounted

## custom_part.gd / custom_part_catalog.gd のテスト。

const TRIALS := 300

const EPS := 1e-4


func run(check: Callable) -> void:
	_test_apply(check)
	_test_caps(check)
	_test_description_matches_effect(check)
	_test_selection(check)
	_test_rarity_weighting(check)
	_test_rarity_by_level(check)
	_test_titles_translated(check)
	_test_no_debuffs(check)
	_test_set_lives(check)
	_test_ghost(check)
	_test_rage(check)


func _stats() -> SpinnerStats:
	var s := SpinnerStats.new()
	s.mass = 1.5
	s.radius = 0.5
	s.friction = 0.98
	s.restitution = 1.0
	s.rps = 15.0
	return s


func _test_apply(check: Callable) -> void:
	var s := _stats()
	CustomPart.make(0, "T", CustomPart.Rarity.COMMON, CustomPart.Stat.MASS, 0.5).apply_to(s)
	check.call(is_equal_approx(s.mass, 0.75), "パーツ: 質量が半分になる (%.3f)" % s.mass)

	s = _stats()
	CustomPart.make(0, "T", CustomPart.Rarity.COMMON, CustomPart.Stat.RADIUS, 2.0).apply_to(s)
	check.call(is_equal_approx(s.radius, 1.0), "パーツ: 直径が倍になる (%.3f)" % s.radius)

	# 名前どおり「勢いを保つ」＝摩擦(速度減衰)と回転減衰の両方が減ること。
	# 摩擦だけ下げていた頃は戦績ほぼ0の死に札だったので、回転減衰にも効かせた。
	var before_friction := _stats().friction
	var before_decay := _stats().spin_decay
	s = _stats()
	CustomPartCatalog.by_id(5).apply_to(s)
	check.call(
		s.friction < before_friction,
		"パーツ: Full Steam Aheadで摩擦が減る (%.3f -> %.3f)" % [before_friction, s.friction]
	)
	check.call(
		s.spin_decay < before_decay,
		"パーツ: Full Steam Aheadで回転減衰も減る (%.3f -> %.3f)" % [before_decay, s.spin_decay]
	)
	# spin_decayは下限FULL_STEAM_FLOORでクランプ(重ねても無限には回らない)。
	s = _stats()
	for i in 12:
		CustomPartCatalog.by_id(5).apply_to(s)
	check.call(
		s.spin_decay >= CustomPartCatalog.FULL_STEAM_FLOOR - EPS,
		"パーツ: Full Steamのspin_decayが下限%.2fで止まる (%.3f)" % [
			CustomPartCatalog.FULL_STEAM_FLOOR, s.spin_decay
		]
	)

	# 掛け算なので繰り返し取ると積み上がる
	s = _stats()
	var part := CustomPart.make(0, "T", CustomPart.Rarity.COMMON, CustomPart.Stat.MASS, 2.0)
	part.apply_to(s)
	part.apply_to(s)
	check.call(is_equal_approx(s.mass, 6.0), "パーツ: 重ねがけで積み上がる (%.3f)" % s.mass)

	# 定数加算の札は重ねても線形(倍率のような複利にならない)。オーバーウェイトを
	# 定数化した狙いそのものなので、掛け算との差が出る形でピンする。
	s = _stats()
	var adder := CustomPart.make_stats(0, "T", CustomPart.Rarity.COMMON, [
		StatOp.add(CustomPart.Stat.MASS, 0.75),
	] as Array[StatOp])
	adder.apply_to(s)
	check.call(is_equal_approx(s.mass, 2.25), "パーツ: 加算1枚で+0.75 (%.3f)" % s.mass)
	adder.apply_to(s)
	adder.apply_to(s)
	check.call(is_equal_approx(s.mass, 3.75), "パーツ: 加算は重ねても線形 (%.3f)" % s.mass)

	# 1枚で複数のステータスを触る複合札。片方だけ効いて終わっていないこと。
	s = _stats()
	CustomPart.make_stats(0, "T", CustomPart.Rarity.COMMON, [
		StatOp.mult(CustomPart.Stat.RADIUS, 1.1),
		StatOp.mult(CustomPart.Stat.MASS, 1.2),
	] as Array[StatOp]).apply_to(s)
	check.call(is_equal_approx(s.radius, 0.55), "パーツ: 複合札で直径が上がる (%.3f)" % s.radius)
	check.call(is_equal_approx(s.mass, 1.8), "パーツ: 複合札で質量も上がる (%.3f)" % s.mass)

	# カタログの実データでも両方動くこと(定義側の取り違えを拾う)。
	s = _stats()
	CustomPartCatalog.by_id(2).apply_to(s)
	check.call(
		s.radius > 0.5 and s.mass > 1.5,
		"パーツ: ジャイアントグロースは直径と質量の両方を上げる (r=%.3f m=%.3f)" % [
			s.radius, s.mass
		]
	)
	s = _stats()
	CustomPartCatalog.by_id(3).apply_to(s)
	check.call(
		is_equal_approx(s.mass, 2.25),
		"パーツ: オーバーウェイトは質量に定数を足す (%.3f)" % s.mass
	)


func _test_caps(check: Callable) -> void:
	# 上限を超えない
	var s := _stats()
	s.rps = 39.0
	CustomPartCatalog.by_id(7).apply_to(s)
	check.call(
		is_equal_approx(s.rps, CustomPartCatalog.RPS_CAP),
		"パーツ: 回転数が上限%.0fで止まる (%.2f)" % [CustomPartCatalog.RPS_CAP, s.rps]
	)

	s = _stats()
	s.restitution = 1.95
	CustomPartCatalog.by_id(6).apply_to(s)
	check.call(
		is_equal_approx(s.restitution, CustomPartCatalog.RESTITUTION_CAP),
		"パーツ: 反発が上限%.1fで止まる (%.2f)" % [CustomPartCatalog.RESTITUTION_CAP, s.restitution]
	)

	# 上限に届かないうちは普通に掛かる
	s = _stats()
	s.rps = 10.0
	var spin: CustomPart = CustomPartCatalog.by_id(7)
	spin.apply_to(s)
	check.call(
		is_equal_approx(s.rps, 10.0 * spin.ops[0].multiplier),
		"パーツ: 上限未満なら倍率どおり (%.2f)" % s.rps
	)

	# 上限は加算にも効く。倍率だけクランプして加算を素通しにすると、定数札を
	# 重ねただけで上限を突き抜ける。
	s = _stats()
	for i in 20:
		CustomPartCatalog.by_id(3).apply_to(s)
	check.call(
		is_equal_approx(s.mass, CustomPartCatalog.MASS_CAP),
		"パーツ: 定数加算も上限%.0fで止まる (%.2f)" % [CustomPartCatalog.MASS_CAP, s.mass]
	)

	# 報酬は全部プラスなので、取るほど強くなる一方。上限がないと
	# アリーナをコマが埋め尽くすので、伸びるステータスには全部上限がある。
	# 倍率でも加算でも上げるなら上限が要る。
	for part in CustomPartCatalog.all():
		for op in part.ops:
			if op.raises():
				check.call(
					op.cap > 0.0,
					"パーツ%d(%s): 強化札には上限がある" % [part.id, part.title_key]
				)


## 説明文が実際の効果と食い違わないこと。
##
## プロトタイプは説明文が手書きで、2回嘘になっていた(「50%上昇(最大20)」で
## 実際は上限40、その後「10%上昇」と書いて実際は1.2倍=20%)。しかも直前の
## コミットが「パーツ説明が嘘だったので修正」。生成にした狙いはここなので、
## 実際に数値を適用した結果と説明文の数字が一致することまで確かめる。
func _test_description_matches_effect(check: Callable) -> void:
	TranslationServer.set_locale("en")
	for part in CustomPartCatalog.all():
		var text := part.describe()

		# 説明にキーがそのまま出ていない＝訳がある
		if text.contains("PART_EFFECT"):
			check.call(false, "パーツ%d: 効果の訳がない (%s)" % [part.id, text])
			continue

		# 残機札は倍率でも注記でもなく、引き上げ先の残機を出す単行の説明。
		# 倍率・上限・注記・改行の検査はステータス札向けなので飛ばす。
		if part.effect == CustomPart.Effect.SET_LIVES:
			check.call(
				text.contains(str(part.lives)),
				"パーツ%d(%s): 残機の説明に数値が出ている (%s に %d)" % [
					part.id, part.title_key, text, part.lives
				]
			)
			continue

		# ゴーストは倍率を持たない。説明に無敵秒数が出ていることだけ確かめる。
		if part.effect == CustomPart.Effect.GHOST:
			check.call(
				text.contains(CustomPart._trim(part.ghost_seconds)),
				"パーツ%d(%s): 説明に無敵秒数が出ている (%s)" % [part.id, part.title_key, text]
			)
			continue

		# 勢い維持は摩擦と回転減衰の両方に効く単行の説明。倍率が出ていること
		# だけ確かめる(capはspin_decayの下限であって表示する上限ではない)。
		if part.effect == CustomPart.Effect.MOMENTUM:
			check.call(
				text.contains(CustomPart._trim(part.multiplier)),
				"パーツ%d(%s): 勢い維持の説明に倍率が出ている (%s)" % [part.id, part.title_key, text]
			)
			continue

		# 怒りの反射は反発倍率と壁rps保持の複合。反発倍率が出ていることを確かめる。
		if part.effect == CustomPart.Effect.RAGE:
			check.call(
				text.contains(CustomPart._trim(part.multiplier)),
				"パーツ%d(%s): 怒りの反射の説明に反発倍率が出ている (%s)" % [part.id, part.title_key, text]
			)
			continue

		# 説明に書かれた数値が、実際に適用される値と一致すること。
		# 複合札は操作ごとに1つずつ、全部出ていること(片方だけ書いて残りを
		# 黙っていると説明が嘘になる)。
		for op in part.ops:
			var shown := CustomPart._trim(op.addend if not is_zero_approx(op.addend) else op.multiplier)
			check.call(
				text.contains(shown),
				"パーツ%d(%s): 説明の数値が実際と一致 (%s に %s)" % [
					part.id, part.title_key, text, shown
				]
			)
			# 加算の札は「×」ではなく「+」で見せる(×1と出ると意味不明になる)。
			if not is_zero_approx(op.addend):
				check.call(
					text.contains("+" + shown),
					"パーツ%d(%s): 加算は+表記で出る (%s)" % [part.id, part.title_key, text]
				)
			# 上限があるなら説明にも出ていること
			if op.cap > 0.0:
				check.call(
					text.contains(CustomPart._trim(op.cap)),
					"パーツ%d: 説明に上限が出ている (%s)" % [part.id, text]
				)

		# 倍率だけでは挙動が読めないので、実際の効果を一言添えている。
		# キーが素のまま残っている＝訳がない、を弾く。現行パーツは全部
		# 倍率≠1なので必ず注記が付く。
		check.call(
			not text.contains("PART_NOTE"),
			"パーツ%d(%s): 効果注記の訳がある (%s)" % [part.id, part.title_key, text]
		)
		check.call(
			text.contains("\n"),
			"パーツ%d(%s): 倍率行に続けて効果注記が付く (%s)" % [part.id, part.title_key, text]
		)

	# 半径は上げると衝突被害が減る一方で自然減衰が上がる二面性がある。
	# 倍率だけでは伝わらないので、その挙動が注記に出ていることをピンする。
	var radius_part := CustomPart.make(
		0, "T", CustomPart.Rarity.COMMON, CustomPart.Stat.RADIUS, 1.35
	)
	var radius_note := radius_part.describe().to_lower()
	check.call(
		radius_note.contains("decay"),
		"パーツ: 半径UPの注記が自然減衰に触れる (%s)" % radius_note
	)
	TranslationServer.set_locale("ja")
	check.call(
		radius_part.describe().contains("減衰"),
		"パーツ: 半径UPの注記(ja)が減衰に触れる (%s)" % radius_part.describe()
	)


func _test_selection(check: Callable) -> void:
	var rng := RandomNumberGenerator.new()
	var dup_seen := false
	var wrong_count := false
	for trial in TRIALS:
		rng.seed = trial
		var picks := CustomPartCatalog.pick_choices(3, rng)
		if picks.size() != 3:
			wrong_count = true
		var ids := {}
		for p in picks:
			if ids.has(p.id):
				dup_seen = true
			ids[p.id] = true

	check.call(not wrong_count, "パーツ抽選: 常に指定した枚数を返す")
	check.call(not dup_seen, "パーツ抽選: %d回引いて重複が出ない" % TRIALS)

	# プロトタイプは引数nを無視して常に3個だった。ここは指定どおりになる。
	rng.seed = 1
	check.call(CustomPartCatalog.pick_choices(2, rng).size() == 2, "パーツ抽選: 2枚を頼めば2枚返る")
	rng.seed = 1
	check.call(CustomPartCatalog.pick_choices(1, rng).size() == 1, "パーツ抽選: 1枚を頼めば1枚返る")
	# 母集団より多く頼まれても壊れない
	rng.seed = 1
	var everything := CustomPartCatalog.pick_choices(99, rng)
	check.call(
		everything.size() == CustomPartCatalog.all().size(),
		"パーツ抽選: 母集団より多く頼まれても全部返して止まる (%d枚)" % everything.size()
	)


func _test_rarity_weighting(check: Callable) -> void:
	# レアはcommonより出にくいこと。厳密な比率ではなく向きだけ見る。
	var rng := RandomNumberGenerator.new()
	var rare_hits := 0
	var common_hits := 0
	for trial in TRIALS:
		rng.seed = trial + 5000
		for part in CustomPartCatalog.pick_choices(1, rng):
			if part.rarity == CustomPart.Rarity.RARE:
				rare_hits += 1
			else:
				common_hits += 1

	check.call(
		rare_hits < common_hits,
		"パーツ抽選: レアはcommonより出にくい (rare=%d common=%d)" % [rare_hits, common_hits]
	)
	check.call(rare_hits > 0, "パーツ抽選: レアもちゃんと出る (%d回)" % rare_hits)


## 倒した敵のレベルが高いほどレアが出やすいこと。厳密な比率ではなく向きだけ見る。
func _test_rarity_by_level(check: Callable) -> void:
	var low_rares := _count_rares(1)
	var high_rares := _count_rares(5)
	check.call(
		high_rares > low_rares,
		"パーツ抽選: 高レベルほどレアが出やすい (lv1=%d lv5=%d)" % [low_rares, high_rares]
	)
	check.call(
		CustomPartCatalog.rare_weight_for_level(1) < CustomPartCatalog.rare_weight_for_level(5),
		"パーツ抽選: RAREの重みは高レベルで増える (%d < %d)" % [
			CustomPartCatalog.rare_weight_for_level(1), CustomPartCatalog.rare_weight_for_level(5)
		]
	)


## そのレベルで1枚引きをTRIALS回して、レアを引いた回数を返す。
func _count_rares(level: int) -> int:
	var rng := RandomNumberGenerator.new()
	var rares := 0
	for trial in TRIALS:
		rng.seed = trial + 9000
		for part in CustomPartCatalog.pick_choices(1, rng, level):
			if part.rarity == CustomPart.Rarity.RARE:
				rares += 1
	return rares


func _test_titles_translated(check: Callable) -> void:
	TranslationServer.set_locale("ja")
	var untranslated: Array[String] = []
	for part in CustomPartCatalog.all():
		if tr(part.title_key) == part.title_key:
			untranslated.append(part.title_key)
	check.call(untranslated.is_empty(), "パーツ: 名前に訳がある (未訳: %s)" % [untranslated])


## 報酬にマイナスの札が混じっていないこと。
##
## プロトタイプには Gravity Negator(質量×0.5) と Shrink(直径×0.5) があり、
## どちらも純粋なデバフだった。特に半径は削られるRPSに2乗で効くので、
## Shrinkは耐えられる衝突回数を1/4にする。勝った報酬の3枚に自分を弱くする
## 札が混じっているのは罠でしかない。
##
## 「マイナス」は名前ではなく実際の効果で判定する。硬さ(rps×質量×半径²)が
## 下がる札は、何と名乗っていてもデバフ。
func _test_no_debuffs(check: Callable) -> void:
	for part in CustomPartCatalog.all():
		var before := _stats()
		var after := _stats()
		part.apply_to(after)

		var tough_before := before.rps * before.mass * before.radius * before.radius
		var tough_after := after.rps * after.mass * after.radius * after.radius
		check.call(
			tough_after >= tough_before - EPS,
			"パーツ%d(%s): 硬さを下げない (%.2f -> %.2f)" % [
				part.id, part.title_key, tough_before, tough_after
			]
		)

		# 硬さに関わらないステータス(摩擦・反発)も、悪い方へ動かさない
		check.call(
			after.friction <= before.friction + EPS,
			"パーツ%d(%s): 摩擦を増やさない (%.3f -> %.3f)" % [
				part.id, part.title_key, before.friction, after.friction
			]
		)
		check.call(
			after.restitution >= before.restitution - EPS,
			"パーツ%d(%s): 反発を減らさない (%.3f -> %.3f)" % [
				part.id, part.title_key, before.restitution, after.restitution
			]
		)

	# 反発の上限は1.0を超えてよい(Rage Reflectionの攻撃的な壁押し込み)が、
	# 際限なくは上げない。反発>1は壁反射のたびに加速するので、BattleRequestの
	# 速度上限(max_speed>0)で発散を抑える前提でのみ許容する。両者が揃うことを見る。
	check.call(
		CustomPartCatalog.RESTITUTION_CAP <= 2.0,
		"反発の上限が過大でない(<=2.0, %.2f)" % CustomPartCatalog.RESTITUTION_CAP
	)
	check.call(
		BattleRequest.new().max_speed > 0.0,
		"反発>1の発散を抑える速度上限がある (max_speed=%.1f)" % BattleRequest.new().max_speed
	)


## ゴースト札。ステータスは変えず、無敵時間だけを枚数に比例して伸ばす。
func _test_ghost(check: Callable) -> void:
	var ghost := CustomPartCatalog.by_id(9)
	check.call(ghost != null, "ゴースト: カタログにID9がある")
	check.call(
		ghost.effect == CustomPart.Effect.GHOST,
		"ゴースト: 効果種別がGHOST"
	)

	# apply_toはステータスを一切変えない。
	var before := _stats()
	var after := _stats()
	ghost.apply_to(after)
	check.call(
		is_equal_approx(after.mass, before.mass)
		and is_equal_approx(after.radius, before.radius)
		and is_equal_approx(after.friction, before.friction)
		and is_equal_approx(after.restitution, before.restitution)
		and is_equal_approx(after.rps, before.rps),
		"ゴースト: apply_toはステータスを変えない"
	)

	# 説明が訳されていること(キーが素で出ていない)。
	TranslationServer.set_locale("ja")
	check.call(
		ghost.describe() != "PART_EFFECT_GHOST" and not ghost.describe().contains("PART_EFFECT"),
		"ゴースト: 説明に訳がある (%s)" % ghost.describe()
	)

	# 合計無敵時間は枚数×1枚あたり秒数。ゴースト以外のIDは無視する。
	var per := CustomPartCatalog.GHOST_SECONDS_PER_STACK
	check.call(
		is_equal_approx(CustomPartCatalog.total_ghost_seconds([] as Array[int]), 0.0),
		"ゴースト: 未取得なら0秒"
	)
	check.call(
		is_equal_approx(CustomPartCatalog.total_ghost_seconds([9] as Array[int]), per),
		"ゴースト: 1枚で%.1f秒 (%.2f)" % [per, CustomPartCatalog.total_ghost_seconds([9] as Array[int])]
	)
	check.call(
		is_equal_approx(CustomPartCatalog.total_ghost_seconds([9, 9] as Array[int]), per * 2.0),
		"ゴースト: 2枚で%.1f秒 (線形延長)" % [per * 2.0]
	)
	# ステータス札(ID2)も残機札(ID8)もゴーストではないので無敵時間に数えない。
	check.call(
		is_equal_approx(CustomPartCatalog.total_ghost_seconds([2, 8, 9] as Array[int]), per),
		"ゴースト: 非ゴースト札(ID2/ID8)は無敵時間に数えない"
	)


## 残機を引き上げる札(スペアコア)の検証。コマの性能には触らず、GameState.apply_partで
## コンティニュー回数を底上げする。上書きではなくmaxiなので既に多ければ下げない。
##
## GameStateはオートロードだが、--scriptランナーではツリーに載らず参照できないので、
## ここではスクリプトを直接new()した独立インスタンスで検証する（グローバルも汚さない）。
const GameStateScript := preload("res://autoloads/GameState.gd")


## 怒りの反射(RAGE)札。反発を上げつつ(cap上限)、壁rps保持(wall_keep)も上げる複合。
func _test_rage(check: Callable) -> void:
	var rage := CustomPartCatalog.by_id(6)
	check.call(rage.effect == CustomPart.Effect.RAGE, "怒りの反射: 効果種別がRAGE")

	# 1枚で反発が上がり、壁rps保持も上がる（複合）。
	# 実プレイの初期反発は0.75なので、そこから上がることを見る。
	var s := _stats()
	s.restitution = 0.75
	var before_rest := s.restitution
	var before_keep := s.wall_keep
	rage.apply_to(s)
	check.call(s.restitution > before_rest, "怒りの反射: 反発が上がる (%.3f -> %.3f)" % [before_rest, s.restitution])
	check.call(s.wall_keep > before_keep, "怒りの反射: 壁rps保持が上がる (%.3f -> %.3f)" % [before_keep, s.wall_keep])

	# 反発はRESTITUTION_CAP(1.5)を超えない。壁rps保持はRAGE_WALL_KEEP_MAXで頭打ち
	# (1.0=完全無損失まで許すと無敵化するため低く抑える)。
	s = _stats()
	for i in 10:
		rage.apply_to(s)
	check.call(
		s.restitution <= CustomPartCatalog.RESTITUTION_CAP + EPS,
		"怒りの反射: 反発が上限%.1fで止まる (%.3f)" % [CustomPartCatalog.RESTITUTION_CAP, s.restitution]
	)
	check.call(
		s.wall_keep <= CustomPartCatalog.RAGE_WALL_KEEP_MAX + EPS,
		"怒りの反射: 壁rps保持が上限%.2fで止まる (%.3f)" % [CustomPartCatalog.RAGE_WALL_KEEP_MAX, s.wall_keep]
	)
	check.call(
		s.wall_keep >= CustomPartCatalog.RAGE_WALL_KEEP_MAX - EPS,
		"怒りの反射: 重ねがけで壁rps保持が上限へ届く (%.3f)" % s.wall_keep
	)
	check.call(
		CustomPartCatalog.RAGE_WALL_KEEP_MAX < 1.0,
		"怒りの反射: 壁rps保持の上限は1.0未満(完全無損失=無敵化を防ぐ) (%.2f)" % CustomPartCatalog.RAGE_WALL_KEEP_MAX
	)


func _test_set_lives(check: Callable) -> void:
	var part := CustomPart.make_set_lives(8, "PART_SPARE_CORE", CustomPart.Rarity.RARE, 5)
	check.call(part.effect == CustomPart.Effect.SET_LIVES, "残機札: 効果種別がSET_LIVES")
	check.call(part.lives == 5, "残機札: 引き上げ先が5 (%d)" % part.lives)

	# コマの性能には一切触らない。ステータス操作を無理やり生やしてもSET_LIVESなら
	# 書き込まない＝apply_toのガードが効いていることの検証（opsが空だと何もしないのが
	# 当たり前になってしまい、ガードの有無を判別できない）。
	var tampered := CustomPart.make_set_lives(8, "PART_SPARE_CORE", CustomPart.Rarity.RARE, 5)
	tampered.ops = [
		StatOp.mult(CustomPart.Stat.MASS, 2.0),
		StatOp.add(CustomPart.Stat.RADIUS, 1.0),
	] as Array[StatOp]
	var s := _stats()
	var base := _stats()
	tampered.apply_to(s)
	check.call(
		is_equal_approx(s.mass, base.mass) and is_equal_approx(s.radius, base.radius)
		and is_equal_approx(s.friction, base.friction)
		and is_equal_approx(s.restitution, base.restitution)
		and is_equal_approx(s.rps, base.rps),
		"残機札: ステータスを一切変えない (mass=%.3f radius=%.3f rps=%.3f)" % [s.mass, s.radius, s.rps]
	)

	# 説明に引き上げ先の数値が出る（en/jaとも）。
	TranslationServer.set_locale("en")
	check.call(part.describe().contains("5"), "残機札: 説明(en)に5が出る (%s)" % part.describe())
	TranslationServer.set_locale("ja")
	check.call(part.describe().contains("5"), "残機札: 説明(ja)に5が出る (%s)" % part.describe())

	var gs: Node = GameStateScript.new()

	# apply_partで残機が引き上がり、取得IDに残る。
	gs.reset_run()
	check.call(
		gs.continues_left == GameStateScript.MAX_CONTINUES,
		"残機札: 適用前は初期コンティニュー数 (%d)" % gs.continues_left
	)
	gs.apply_part(part)
	check.call(gs.continues_left == 5, "残機札: 適用後は残機5 (%d)" % gs.continues_left)
	check.call(gs.acquired_part_ids.has(8), "残機札: 取得IDに8が残る")

	# 底上げのみ。既に5超なら下げない（上書き実装なら5へ下がって落ちる）。
	gs.continues_left = 7
	gs.apply_part(part)
	check.call(gs.continues_left == 7, "残機札: 既に多ければ下げない (%d)" % gs.continues_left)

	# ステータス札はapply_partでも残機を動かさない（lives=0）が、性能は上がる。
	gs.reset_run()
	var before_rps: float = gs.player_stats.rps
	var stat_part: CustomPart = CustomPartCatalog.by_id(7)  # Spin Engine (rps×1.25)
	gs.apply_part(stat_part)
	check.call(
		gs.continues_left == GameStateScript.MAX_CONTINUES,
		"残機札: ステータス札は残機を変えない (%d)" % gs.continues_left
	)
	check.call(
		gs.player_stats.rps > before_rps,
		"残機札: ステータス札はちゃんと性能を上げる (%.2f -> %.2f)" % [before_rps, gs.player_stats.rps]
	)

	gs.free()
	TranslationServer.set_locale("ja")
