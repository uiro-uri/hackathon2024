extends Node

## 画面切り替えのルート。Flask版のルーティング（/, /map, /simulation, /reward）に相当する。
## 各画面はScreenHolderの子として差し替える。
##
## 各画面は「何が起きたか」だけをsignalで知らせ、次にどこへ行くかはここが決める。

const TITLE_SCENE: PackedScene = preload("res://scenes/title/Title.tscn")
const MAP_SCENE: PackedScene = preload("res://scenes/map/MapScreen.tscn")
const BATTLE_SCENE: PackedScene = preload("res://scenes/battle/Battle.tscn")
const REWARD_SCENE: PackedScene = preload("res://scenes/reward/RewardScreen.tscn")
const GAMEOVER_SCENE: PackedScene = preload("res://scenes/gameover/GameOver.tscn")
const GAMECLEAR_SCENE: PackedScene = preload("res://scenes/gameclear/GameClear.tscn")
const SOUNDTEST_SCENE: PackedScene = preload("res://scenes/soundtest/SoundTest.tscn")

@onready var _screen_holder: Node = $ScreenHolder

## 勝った戦闘で倒した頭数ぶん、報酬選択を繰り返す残り回数。
var _rewards_remaining: int = 0

## ランを通して出しっぱなしにするビルド表示HUD。ScreenHolderの外(Main直下)に置いて
## 画面差し替えで消えないようにし、_swap_screenのたびに現在のGameStateへ追従させる。
var _stat_panel: StatPanel

## 全画面が共有する文字サイズのテーマ。実体は1つだけ持ち回し、画面の向きが変わったら
## 中身を書き換える(Themeは書き換えるとchangedを出すので、使っている側は自動で組み直る)。
## 貼り付けはFontScale.applyがやる。ScreenHolderがNode、BattleのルートがNode2D、
## StatPanelがCanvasLayerで、テーマ継承がそこで切れるため、ウィンドウに貼るだけでは届かない。
var _ui_theme := Theme.new()

## 直前に判定した画面の向き。向きが変わったときだけテーマを書き換える
## (size_changedはウィンドウのドラッグ中に毎フレーム級で飛ぶ)。
var _portrait := false


func _ready() -> void:
	_portrait = ScreenLayout.is_portrait(get_viewport().get_visible_rect().size)
	FontScale.fill_theme(_ui_theme, _portrait)
	get_viewport().size_changed.connect(_on_viewport_resized)

	_stat_panel = StatPanel.new()
	add_child(_stat_panel)
	FontScale.apply(_stat_panel, _ui_theme)

	goto_title()


## 画面の向きが変わったときだけ文字サイズを組み替える。
func _on_viewport_resized() -> void:
	var portrait := ScreenLayout.is_portrait(get_viewport().get_visible_rect().size)
	if portrait == _portrait:
		return
	_portrait = portrait
	FontScale.fill_theme(_ui_theme, portrait)


func goto_title() -> void:
	# タイトルはランの外なのでビルド表示は出さない。
	var title := _swap_screen(TITLE_SCENE, false)
	title.start_requested.connect(_on_start_requested)
	title.sound_test_requested.connect(goto_sound_test)


## タイトルから開くサウンドテスト。戻るでタイトルへ返す。
func goto_sound_test() -> void:
	# サウンドテストもランの外なのでビルド表示は出さない。
	var sound_test := _swap_screen(SOUNDTEST_SCENE, false)
	sound_test.back_requested.connect(goto_title)


func _on_start_requested() -> void:
	AudioManager.play("ui_confirm")
	GameState.reset_run()
	goto_map()


func goto_map() -> void:
	var map := _swap_screen(MAP_SCENE)
	map.node_chosen.connect(_on_map_node_chosen)
	map.setup(GameState.map_tree)


## 進む先を選んだら、そのノードに確定済みの敵グループ(1〜3体)と土俵を戦闘へ渡す。
## ここでは再抽選しない（マップ生成時に決めた遭遇をそのまま使う＝表示と実戦が一致）。
func _on_map_node_chosen(coord: Vector2i) -> void:
	if not GameState.map_tree.advance_to(coord):
		push_error("Main: 進めないノードが選ばれた: %s" % coord)
		return
	AudioManager.play("ui_select")
	var node: MapTree.MapNode = GameState.map_tree.nodes[GameState.map_tree.current_coord]
	GameState.pending_enemies = node.enemies
	GameState.pending_field = node.field
	goto_battle()


func goto_battle() -> void:
	var battle := _swap_screen(BATTLE_SCENE)
	battle.finished.connect(_on_battle_finished)


## 負けたらゲームオーバー画面へ。勝てば報酬を選んでマップへ戻る。
func _on_battle_finished(player_won: bool) -> void:
	if not player_won:
		goto_gameover()
		return
	if GameState.map_tree.is_goal():
		# ボスに勝ったらラン終了。クリア画面で締める。
		goto_gameclear()
		return
	# 倒した頭数だけ報酬を選ぶ。乱戦はrps据え置きで手強いぶん、見返りも頭数ぶん。
	_rewards_remaining = maxi(GameState.pending_enemies.size(), 1)
	goto_reward()


func goto_gameclear() -> void:
	# 勝ち切ったので連続クリア記録を伸ばす。setupの前に加算し、加算後の値を画面へ渡す。
	GameState.record_clear()
	var gameclear := _swap_screen(GAMECLEAR_SCENE)
	gameclear.to_title_requested.connect(_on_gameclear_to_title)
	gameclear.setup(GameState.acquired_part_ids, GameState.continues_left, GameState.clear_streak)
	# クリアの締めにファンファーレ。戦闘の勝利ジングルは決着後の余韻中に鳴り終えており、
	# クリア画面は決着から finish_delay 秒ほど後に出るので重ならない。
	AudioManager.play_clear_fanfare()


func _on_gameclear_to_title() -> void:
	AudioManager.play("ui_click")
	goto_title()


func goto_gameover() -> void:
	var gameover := _swap_screen(GAMEOVER_SCENE)
	gameover.continue_requested.connect(_on_continue_requested)
	gameover.give_up_requested.connect(_on_give_up_requested)
	gameover.setup(GameState.continues_left)


## コンティニュー: 回数を1消費し、同じ相手・同じマップ位置で戦闘へ戻る。
## pending_enemiesもcurrent_coordも触らないので、同じグループでそのまま再挑戦になる。
func _on_continue_requested() -> void:
	AudioManager.play("ui_confirm")
	if not GameState.use_continue():
		# 残0で来たら念のためタイトルへ（通常はボタンが隠れて起きない）。
		goto_title()
		return
	goto_battle()


func _on_give_up_requested() -> void:
	# ランを勝ち切れずに終えたので連続クリア記録は途切れる。
	GameState.break_streak()
	AudioManager.play("ui_back")
	goto_title()


func goto_reward() -> void:
	var reward := _swap_screen(REWARD_SCENE)
	reward.part_chosen.connect(_on_part_chosen)
	# 今倒した段のレベルほどレアが出やすい。current_step()は段選択時と同じ値。
	var level := EnemyRoster.level_for_step(GameState.map_tree.current_step())
	reward.setup(CustomPartCatalog.pick_choices(CustomPartCatalog.REWARD_CHOICES, null, level))


func _on_part_chosen(part: CustomPart) -> void:
	AudioManager.play("ui_confirm")
	GameState.apply_part(part)
	# まだ倒した頭数ぶんの報酬が残っていれば、次の報酬選択へ。無ければマップへ戻る。
	_rewards_remaining -= 1
	if _rewards_remaining > 0:
		goto_reward()
		return
	goto_map()


## 画面を差し替える。show_stats=true(既定)のときはビルド表示HUDを今のGameStateへ
## 更新して見せ、ランの外の画面(タイトル/サウンドテスト)はfalseで隠す。
func _swap_screen(scene: PackedScene, show_stats: bool = true) -> Node:
	for child in _screen_holder.get_children():
		_screen_holder.remove_child(child)
		child.queue_free()
	var screen := scene.instantiate()
	# ツリーへ入れる前に貼る(入れてから貼ると最小サイズの計算が2度走る)。
	FontScale.apply(screen, _ui_theme)
	_screen_holder.add_child(screen)
	if show_stats:
		_stat_panel.refresh()
	else:
		_stat_panel.hide_panel()
	return screen
