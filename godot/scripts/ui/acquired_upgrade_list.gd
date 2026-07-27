class_name AcquiredUpgradeList
extends RefCounted

## このランで取得済みのアップグレード(カスタムパーツ)の一覧UIを組み立てる共有ヘルパー。
##
## マップ画面(サイドの「取得済み」パネル)とゲームクリア画面(締めのリザルト)で同じ行を
## 使いたいので、行ビルダーをここに集約する。もとは MapScreen が抱えていたが、
## クリア画面にも出すにあたり二重持ちを避けて切り出した。
##
## 集約(重複の畳み込み)は CustomPartCatalog.aggregate_acquired に任せ、ここは見た目だけを担う。


## listの中身を取得済みパーツの行で組み直す。既存の子は消してから積む。
## 集約後のエントリ数(＝行数。空なら0)を返す。呼び手が列数などを決めるのに使える
## (クリア画面はこれでGridの列数を合わせ、スクロール無しで全部見せる)。
## 器はVBox/Gridどちらでもよいので型は Container で受ける。
## show_description=false で効果説明を省き、名前だけの詰まった行にする
## (クリア画面はサマリなので名前だけで足りる。マップは戦略に効くので既定で出す)。
static func populate(list: Container, ids: Array[int], show_description := true) -> int:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()

	var entries := CustomPartCatalog.aggregate_acquired(ids)
	if entries.is_empty():
		var empty := Label.new()
		empty.text = "MAP_NO_UPGRADES"  # キー＝自動翻訳
		list.add_child(empty)
		return 0

	for entry in entries:
		list.add_child(build_row(entry["part"], entry["count"], show_description))
	return entries.size()


## 取得済みパーツ1件分の行。報酬カード(RewardScreen._build_card)の縮約版。
## 選択ボタンや明滅はなく、名前(＋任意で効果)を静的に見せるだけ。
static func build_row(part: CustomPart, count: int, show_description := true) -> Control:
	var is_rare := part.rarity == CustomPart.Rarity.RARE

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if is_rare:
		panel.add_theme_stylebox_override("panel", CustomPart.rare_stylebox())

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)

	# レア強調(暗色文字)を掛けるラベルを集めておく。説明を省くと名前だけ。
	var labels: Array[Label] = []

	var title := Label.new()
	# 個数がある時だけ「×2」を付ける。1個ならキーのまま渡して自動翻訳に任せる。
	# 静的関数からは tr() を呼べないので、TranslationServer で現在ロケールを引く
	# (GameClear.format_* と同じ流儀。数個の連結には文脈がないので等価)。
	if count > 1:
		title.text = (
			TranslationServer.translate(part.title_key)
			+ TranslationServer.translate("PART_COUNT_SUFFIX").format([count])
		)
	else:
		title.text = part.title_key
	title.theme_type_variation = FontScale.CAPTION
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)
	labels.append(title)

	if show_description:
		# 説明文はパーツの実データから生成される（custom_part.gd:describe）ので嘘にならない。
		var text := Label.new()
		text.text = part.describe()
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(text)
		labels.append(text)

	if is_rare:
		# 金色の地は明るいので文字を暗くしないと読めない。報酬カードと同じ扱い。
		for label in labels:
			label.add_theme_color_override("font_color", CustomPart.RARE_TEXT_COLOR)

	return panel
