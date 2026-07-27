extends Control

## サウンドテスト画面。配置済みの効果音素材(候補含む)を1つずつ鳴らして確かめる。
## 併せて全体音量スライダーを置く。
##
## 遷移先はMainが決める。SoundTestは「戻るが押された」ことだけ知らせる(既存画面と同じ流儀)。
##
## SEのカタログは SoundCatalog(純粋データ)から引き、再生は AudioManager 経由。
## AudioManager が実ゲームで鳴らすキー(impact等はランダムに1素材選択)と違い、ここでは
## 素材ファイルを1つずつ鳴らしたいので play_path() を使う。
signal back_requested

@onready var _volume_slider: HSlider = $Margin/VBox/VolumeRow/VolumeSlider
@onready var _list: VBoxContainer = $Margin/VBox/Scroll/List
@onready var _back_button: Button = $Margin/VBox/BackButton


func _ready() -> void:
	_back_button.pressed.connect(_on_back_pressed)
	_volume_slider.value = AudioManager.get_master_volume_linear()
	_volume_slider.value_changed.connect(_on_volume_changed)
	_build_list()


## SoundCatalog をカテゴリごとに回して見出し+素材ごとのボタンを積み、
## 最後に合成音(複数素材の旋律=クリアファンファーレ)のセクションを足す。
func _build_list() -> void:
	var grouped := SoundCatalog.by_category()
	for category in grouped:
		_add_heading(_category_key(category))
		for entry in grouped[category]:
			var button := Button.new()
			# 素材ファイル名をそのまま出す(訳キーは作らない)。自動翻訳で拾われないよう固定。
			button.auto_translate = false
			button.text = entry["key"]
			var path: String = entry["path"]
			button.pressed.connect(func() -> void: AudioManager.play_path(path))
			_list.add_child(button)

	# 素材1ファイルではなく旋律を鳴らすもの。ゲーム中の演出をそのまま試聴できる。
	_add_heading("SOUNDTEST_CAT_FANFARE")
	var fanfare := Button.new()
	fanfare.text = "SOUNDTEST_CLEAR_FANFARE"
	fanfare.pressed.connect(func() -> void: AudioManager.play_clear_fanfare())
	_list.add_child(fanfare)


## カテゴリ見出しの Label を1つ積む。
func _add_heading(text_key: String) -> void:
	var heading := Label.new()
	heading.text = text_key
	heading.theme_type_variation = FontScale.HEADING
	_list.add_child(heading)


## カテゴリ名(サブフォルダ名)を翻訳キーに変換する。SOUNDTEST_CAT_LAUNCH など。
static func _category_key(category: String) -> String:
	return "SOUNDTEST_CAT_%s" % category.to_upper()


func _on_volume_changed(value: float) -> void:
	AudioManager.set_master_volume_linear(value)


func _on_back_pressed() -> void:
	back_requested.emit()
