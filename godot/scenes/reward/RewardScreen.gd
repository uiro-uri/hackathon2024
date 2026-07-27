extends Control

## 戦闘に勝った後の報酬選択。3枚から1枚選ぶ。
##
## プロトタイプはBootstrapのカードで、レアだけ金色に光らせていた。
## その演出は踏襲する。

## 選ばれた。適用と遷移はMainがやる。
signal part_chosen(part: CustomPart)

const CHOICE_COUNT := 3

## カード1枚の最小の大きさ(横画面)。縦画面では FontScale.chrome_scale 倍にして
## 大きくなった文字に器を合わせる。
const CARD_SIZE := Vector2(220, 260)

@onready var _cards: GridContainer = $CenterContainer/VBoxContainer/Cards

var _shine := 0.0


func _ready() -> void:
	# 縦画面では文字が最大2倍になり、3枚を横に並べると1280の幅に収まらない。
	# 縦に積み替える。横画面(設計比16:9)では3列のまま何も変えない。
	get_viewport().size_changed.connect(_recompute_layout)
	_recompute_layout()


func setup(parts: Array[CustomPart]) -> void:
	for child in _cards.get_children():
		_cards.remove_child(child)
		child.queue_free()

	for part in parts:
		_cards.add_child(_build_card(part))


## 画面比に応じて列数とカードの大きさを決める。横画面はシーン既定(3列)のまま。
func _recompute_layout() -> void:
	var portrait := ScreenLayout.is_portrait(get_viewport().get_visible_rect().size)
	_cards.columns = 1 if portrait else CHOICE_COUNT
	var size := CARD_SIZE * FontScale.chrome_scale(portrait)
	for card in _cards.get_children():
		(card as Control).custom_minimum_size = size


func _build_card(part: CustomPart) -> Control:
	var is_rare := part.rarity == CustomPart.Rarity.RARE

	var panel := PanelContainer.new()
	var portrait := ScreenLayout.is_portrait(get_viewport().get_visible_rect().size)
	panel.custom_minimum_size = CARD_SIZE * FontScale.chrome_scale(portrait)
	if is_rare:
		panel.add_theme_stylebox_override("panel", CustomPart.rare_stylebox())

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	var title := Label.new()
	title.text = part.title_key
	title.theme_type_variation = FontScale.BODY
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)

	# 説明文はパーツの実データから組み立てる。手書きしないので嘘にならない。
	var text := Label.new()
	text.text = part.describe()
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(text)

	if is_rare:
		var tag := Label.new()
		tag.text = "PART_RARITY_RARE"
		tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(tag)
		# 金の地は明るいまま残る唯一の面なので、暗色文字＋明色縁取りで読ませる
		# (戦闘メッセージの明色文字＋暗色縁取りと対の関係)。文字色はCustomPartが出所。
		for label in [title, text, tag]:
			label.add_theme_color_override("font_color", CustomPart.RARE_TEXT_COLOR)
			label.add_theme_color_override("font_outline_color", Palette.TEXT_PRIMARY)
			label.add_theme_constant_override("outline_size", 3)

	var button := Button.new()
	button.text = "REWARD_SELECT"
	button.pressed.connect(func() -> void: part_chosen.emit(part))
	box.add_child(button)

	return panel


func _process(delta: float) -> void:
	# レアのカードを控えめに明滅させる。プロトタイプの光る演出に相当。
	_shine += delta * 2.0
	var pulse := 1.0 + sin(_shine) * 0.06
	for card in _cards.get_children():
		if card.has_theme_stylebox_override("panel"):
			card.modulate = Color(pulse, pulse, pulse)
