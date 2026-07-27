extends SceneTree

## ヘッドレスで実行する簡易テストランナー。
##   godot --headless --path godot --script res://tests/run_tests.gd
## 失敗すると終了コード1で終わるのでCIやコミット前チェックに使える。
##
## 注意: GDScriptの実行時エラー（型不一致など）は例外として捕捉できず、
## その関数だけが中断される。取りこぼして「成功」と誤報告しないよう、
## 各テストは最後に_done()を呼び、全部が完走したかを最後に照合する。

var _failures: Array[String] = []
var _completed: Array[String] = []

const EXPECTED_TESTS: Array[String] = [
	"translations", "gamestate", "font", "physics", "map", "mapglow", "enemies", "parts", "acquired", "acquiredlist", "spawn", "battle", "fields", "disc", "discgradient", "spinaura", "wobble", "finishfocus", "contrast", "playtest", "screenlayout", "fontscale", "game_clear", "fadeout", "rainbow", "ghostvisual", "audio", "soundtest", "statreadout", "launchspeed", "gameversion"
]


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   - %s" % message)
	else:
		_failures.append(message)
		printerr("  FAIL - %s" % message)


func _done(test_name: String) -> void:
	_completed.append(test_name)


func _init() -> void:
	print("== translations ==")
	_test_translations()

	print("== gamestate ==")
	_test_gamestate_autoload()

	print("== font ==")
	_test_font_covers_japanese()

	print("== physics ==")
	_test_physics()

	print("== map ==")
	_test_map()

	print("== mapglow ==")
	_test_map_glow()

	print("== enemies ==")
	_test_enemies()

	print("== roster ==")
	_test_roster()

	print("== parts ==")
	_test_parts()

	print("== acquired ==")
	_test_acquired()

	print("== acquiredlist ==")
	_test_acquired_list()

	print("== spawn ==")
	_test_spawn()

	print("== battle ==")
	_test_battle()

	print("== fields ==")
	_test_fields()

	print("== disc ==")
	_test_disc()

	print("== discgradient ==")
	_test_disc_gradient()

	print("== spinaura ==")
	_test_spin_aura()

	print("== wobble ==")
	_test_wobble()

	print("== finishfocus ==")
	_test_finish_focus()

	print("== fadeout ==")
	_test_enemy_fadeout()

	print("== contrast ==")
	_test_contrast()

	print("== playtest ==")
	_test_playtest()

	print("== screenlayout ==")
	_test_screen_layout()

	print("== fontscale ==")
	_test_font_scale()

	print("== game_clear ==")
	_test_game_clear()

	print("== rainbow ==")
	_test_rainbow_background()

	print("== ghostvisual ==")
	_test_ghost_visual()

	print("== audio ==")
	_test_audio_levels()

	print("== soundtest ==")
	_test_sound_test()

	print("== statreadout ==")
	_test_stat_readout()

	print("== launchspeed ==")
	_test_launch_speed()

	print("== gameversion ==")
	_test_game_version()

	for test_name in EXPECTED_TESTS:
		if not test_name in _completed:
			_failures.append("%s が完走しなかった（実行時エラーの可能性）" % test_name)
			printerr("  FAIL - %s が完走しなかった（実行時エラーの可能性）" % test_name)

	print("")
	if _failures.is_empty():
		print("すべて成功 (%d/%d テスト完走)" % [_completed.size(), EXPECTED_TESTS.size()])
		quit(0)
	else:
		printerr("%d 件失敗" % _failures.size())
		quit(1)


func _test_translations() -> void:
	var locales := TranslationServer.get_loaded_locales()
	_check("en" in locales, "enの翻訳が読み込まれている (loaded: %s)" % [locales])
	_check("ja" in locales, "jaの翻訳が読み込まれている (loaded: %s)" % [locales])

	TranslationServer.set_locale("en")
	_check(tr("TITLE_START") == "Game Start", "en: TITLE_START -> '%s'" % tr("TITLE_START"))

	TranslationServer.set_locale("ja")
	_check(tr("TITLE_START") == "ゲームスタート", "ja: TITLE_START -> '%s'" % tr("TITLE_START"))
	_check(
		tr("GAMEOVER_CONTINUE") == "コンティニュー",
		"ja: GAMEOVER_CONTINUE -> '%s'" % tr("GAMEOVER_CONTINUE")
	)

	# 対戦画面のステータス表示キー(初期回転数など)
	_check(tr("STAT_RPS_INITIAL") == "初期回転数", "ja: STAT_RPS_INITIAL -> '%s'" % tr("STAT_RPS_INITIAL"))
	_check(tr("STAT_MASS") == "重さ", "ja: STAT_MASS -> '%s'" % tr("STAT_MASS"))
	_check(tr("STAT_GHOST") == "すり抜け時間", "ja: STAT_GHOST -> '%s'" % tr("STAT_GHOST"))
	_check(tr("STAT_LIVES") == "残機", "ja: STAT_LIVES -> '%s'" % tr("STAT_LIVES"))

	# 未定義キーはキー自身が返る＝訳抜けを検出できる
	_check(tr("NO_SUCH_KEY") == "NO_SUCH_KEY", "未定義キーはそのまま返る")

	_done("translations")


func _test_gamestate_autoload() -> void:
	# autoloadはメインシーン実行時にツリーへ入るので、--script実行のこの時点では
	# まだ存在しない。ここでは「project.godotに登録されているか」と
	# 「スクリプト自体の挙動」を分けて確認する。
	_check(
		ProjectSettings.get_setting("autoload/GameState", "") == "*res://autoloads/GameState.gd",
		"GameStateがproject.godotにautoload登録されている"
	)

	var game_state: Node = load("res://autoloads/GameState.gd").new()
	var part_ids: Array[int] = [1, 2]
	game_state.acquired_part_ids = part_ids
	var pending: Array[EnemyData] = [EnemyRoster.all()[0]]
	game_state.pending_enemies = pending
	game_state.pending_field = FieldRoster.all()[0]
	game_state.reset_run()

	_check(game_state.acquired_part_ids.is_empty(), "reset_run()でacquired_part_idsが空になる")
	_check(game_state.pending_enemies.is_empty(), "reset_run()でpending_enemiesが空になる")
	_check(game_state.pending_field == null, "reset_run()でpending_fieldが消える")
	_check(game_state.player_stats != null, "reset_run()でプレイヤーの性能が用意される")
	_check(game_state.map_tree != null, "reset_run()でマップが生成される")
	if game_state.map_tree != null:
		_check(
			game_state.map_tree.current_coord == MapTree.START_COORD,
			"reset_run()でマップがスタート地点から始まる"
		)

	# コンティニュー回数。定数はautoload名ではなくロード済みインスタンス経由で参照する
	# （--script実行時はGameStateがツリーに入っていないため）。
	_check(
		game_state.continues_left == game_state.MAX_CONTINUES,
		"reset_run()でコンティニュー回数が満タンになる"
	)
	var before: int = game_state.continues_left
	_check(game_state.use_continue() == true, "use_continue()は残ありならtrueを返す")
	_check(game_state.continues_left == before - 1, "use_continue()で残り回数が1減る")
	while game_state.continues_left > 0:
		game_state.use_continue()
	_check(game_state.use_continue() == false, "残0のuse_continue()はfalse")
	_check(game_state.continues_left == 0, "残0を下回らない")

	# 連続クリア記録。クリアで増え、あきらめで0に戻り、reset_run()をまたいでも消えない。
	_check(game_state.clear_streak == 0, "clear_streakの初期値は0")
	game_state.record_clear()
	game_state.record_clear()
	_check(game_state.clear_streak == 2, "record_clear()で連続クリア記録が増える")
	game_state.reset_run()
	_check(game_state.clear_streak == 2, "reset_run()をまたいでも連続クリア記録は保持される")
	game_state.break_streak()
	_check(game_state.clear_streak == 0, "break_streak()で連続クリア記録が0に戻る")

	game_state.free()

	_done("gamestate")


func _test_font_covers_japanese() -> void:
	# Godot標準フォントはCJKグリフを持たず、日本語が豆腐(□)になる。
	# 実ブラウザで見るまで気付けなかったので、ここで機械的に検出する。
	# pckサイズでは捕まらない: フォントファイルはall_resourcesで同梱される
	# ため、custom_fontの指定を外しても容量は変わらない。
	var font_path: String = ProjectSettings.get_setting("gui/theme/custom_font", "")
	_check(font_path != "", "既定フォントがproject.godotに設定されている")
	if font_path == "":
		_done("font")
		return

	var font := load(font_path) as Font
	_check(font != null, "既定フォントを読み込める (%s)" % font_path)
	if font == null:
		_done("font")
		return

	for sample in ["あ", "日", "ア", "A"]:
		_check(
			font.has_char(sample.unicode_at(0)),
			"既定フォントが '%s' のグリフを持つ" % sample
		)

	_done("font")


func _test_physics() -> void:
	var suite = load("res://tests/test_spinner_physics.gd").new()
	suite.run(_check)
	_done("physics")


func _test_map() -> void:
	var suite = load("res://tests/test_map_tree.gd").new()
	suite.run(_check)
	_done("map")


func _test_map_glow() -> void:
	var suite = load("res://tests/test_map_glow.gd").new()
	suite.run(_check)
	_done("mapglow")


func _test_roster() -> void:
	var suite = load("res://tests/test_enemy_roster.gd").new()
	suite.run(_check)
	_done("roster")


func _test_parts() -> void:
	var suite = load("res://tests/test_custom_part.gd").new()
	suite.run(_check)
	_done("parts")


func _test_acquired() -> void:
	var suite = load("res://tests/test_acquired_upgrades.gd").new()
	suite.run(_check)
	_done("acquired")


func _test_acquired_list() -> void:
	var suite = load("res://tests/test_acquired_upgrade_list.gd").new()
	suite.run(_check)
	_done("acquiredlist")


func _test_spawn() -> void:
	var suite = load("res://tests/test_enemy_spawn.gd").new()
	suite.run(_check)
	_done("spawn")


func _test_battle() -> void:
	var suite = load("res://tests/test_battle_resolver.gd").new()
	suite.run(_check)
	_done("battle")


func _test_fields() -> void:
	var suite = load("res://tests/test_field_variations.gd").new()
	suite.run(_check)
	_done("fields")


func _test_disc() -> void:
	var suite = load("res://tests/test_disc_visual.gd").new()
	suite.run(_check)
	_done("disc")


func _test_disc_gradient() -> void:
	var suite = load("res://tests/test_disc_gradient.gd").new()
	suite.run(_check)
	_done("discgradient")


func _test_spin_aura() -> void:
	var suite = load("res://tests/test_spin_aura.gd").new()
	suite.run(_check)
	_done("spinaura")


func _test_wobble() -> void:
	var suite = load("res://tests/test_telegraph_wobble.gd").new()
	suite.run(_check)
	_done("wobble")


func _test_finish_focus() -> void:
	var suite = load("res://tests/test_finish_focus.gd").new()
	suite.run(_check)
	_done("finishfocus")


func _test_enemy_fadeout() -> void:
	var suite = load("res://tests/test_enemy_fadeout.gd").new()
	suite.run(_check)
	_done("fadeout")


func _test_contrast() -> void:
	var suite = load("res://tests/test_contrast.gd").new()
	suite.run(_check)
	_done("contrast")


func _test_playtest() -> void:
	var suite = load("res://tests/test_playtest.gd").new()
	suite.run(_check)
	_done("playtest")


func _test_game_clear() -> void:
	var suite = load("res://tests/test_game_clear.gd").new()
	suite.run(_check)
	_done("game_clear")


func _test_audio_levels() -> void:
	var suite = load("res://tests/test_audio_levels.gd").new()
	suite.run(_check)
	_done("audio")


func _test_sound_test() -> void:
	var suite = load("res://tests/test_sound_test.gd").new()
	suite.run(_check)
	_done("soundtest")


func _test_stat_readout() -> void:
	var suite = load("res://tests/test_stat_readout.gd").new()
	suite.run(_check)
	_done("statreadout")


func _test_launch_speed() -> void:
	var suite = load("res://tests/test_launch_speed.gd").new()
	suite.run(_check)
	_done("launchspeed")


func _test_game_version() -> void:
	var suite = load("res://tests/test_game_version.gd").new()
	suite.run(_check)
	_done("gameversion")


func _test_ghost_visual() -> void:
	var suite = load("res://tests/test_ghost_visual.gd").new()
	suite.run(_check)
	_done("ghostvisual")


func _test_rainbow_background() -> void:
	var suite = load("res://tests/test_rainbow_background.gd").new()
	suite.run(_check)
	_done("rainbow")


func _test_screen_layout() -> void:
	var suite = load("res://tests/test_screen_layout.gd").new()
	suite.run(_check)
	_done("screenlayout")


func _test_font_scale() -> void:
	var suite = load("res://tests/test_font_scale.gd").new()
	suite.run(_check)
	_done("fontscale")


func _test_enemies() -> void:
	# どの段にも出せる敵がいること。1体でも欠けるとその段で進行不能になる。
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for step in range(1, MapTree.STEP_GOAL + 1):
		var enemy: EnemyData = EnemyRoster.pick_for_step(step, rng)
		_check(
			enemy != null and enemy.stats != null,
			"段%d に出せる敵がいる (レベル%d)" % [step, EnemyRoster.level_for_step(step)]
		)

	# ゴールがボス(レベル5)になること。プロトタイプが修正コミットで狙った挙動。
	_check(
		EnemyRoster.level_for_step(MapTree.STEP_GOAL) == 5,
		"ゴール(段%d)がレベル5のボスになる" % MapTree.STEP_GOAL
	)
	# 段が進むほど強くなること(下がらない)
	var monotonic := true
	for step in range(1, MapTree.STEP_GOAL):
		if EnemyRoster.level_for_step(step + 1) < EnemyRoster.level_for_step(step):
			monotonic = false
	_check(monotonic, "段が進んでも敵レベルが下がらない")

	# 名前が翻訳されること(訳抜けはキーがそのまま出るので分かる)
	TranslationServer.set_locale("ja")
	var untranslated: Array[String] = []
	for enemy in EnemyRoster.all():
		if tr(enemy.display_name) == enemy.display_name:
			untranslated.append(enemy.display_name)
	_check(untranslated.is_empty(), "敵の名前に訳がある (未訳: %s)" % [untranslated])

	# 複数敵グループ。どの段でも1〜3体の非空グループが返り、各体の性能が正常なこと。
	var group_rng := RandomNumberGenerator.new()
	group_rng.seed = 3
	var all_valid := true
	var count_in_range := true
	for _iter in range(200):
		for step in range(1, MapTree.STEP_GOAL + 1):
			var group := EnemyRoster.pick_group_for_step(step, group_rng)
			if group.is_empty() or group.size() > 3:
				count_in_range = false
			for member in group:
				if member == null or member.stats == null or member.stats.rps <= 0.0:
					all_valid = false
	_check(count_in_range, "グループ: どの段でも1〜3体が返る")
	_check(all_valid, "グループ: 各体の性能が正常(stats非null・rps>0)")

	# ボス段は常に単体。
	var boss_rng := RandomNumberGenerator.new()
	boss_rng.seed = 5
	var boss_always_single := true
	for _iter in range(200):
		if EnemyRoster.pick_group_for_step(MapTree.STEP_GOAL, boss_rng).size() != 1:
			boss_always_single = false
	_check(boss_always_single, "グループ: ボス段(段%d)は常に単体" % MapTree.STEP_GOAL)

	# グループ抽選が共有Resourceを壊さないこと。乱戦メンバーは弱めず据え置きだが、
	# 何度取り出しても元のall()のrpsは変わらない(all()が毎回新しい実体を作る)。
	var lvl1_rps_before: float = EnemyRoster.of_level(1)[0].stats.rps
	var scale_rng := RandomNumberGenerator.new()
	scale_rng.seed = 9
	for _iter in range(200):
		EnemyRoster.pick_group_for_step(3, scale_rng)
	var lvl1_rps_after: float = EnemyRoster.of_level(1)[0].stats.rps
	_check(
		is_equal_approx(lvl1_rps_before, lvl1_rps_after),
		"グループ: 抽選が共有Resourceを壊さない (%.2f -> %.2f)" % [lvl1_rps_before, lvl1_rps_after]
	)

	_done("enemies")
