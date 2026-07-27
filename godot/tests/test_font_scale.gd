extends RefCounted

## font_scale.gd のテスト。役割別サイズ表と、そこから作る Theme を数値で確かめる。
##
## 見た目そのものは静止画では確かめられない(CLAUDE.mdの方針)。ここでは
## 「横画面の寸法は今までどおり」「縦画面では必ず大きくなる」「小さい役割ほど強く上がる」
## という不変条件と、Theme の組み立て・貼り付けの機構を固定する。実描画の当否は
## verify.sh のSPスクショで人が見る。
##
## Control 側の解決(get_theme_font_size)はここでは見ない。run_tests.gd は
## SceneTree の _init から走るため root が普通のシーンとして立っておらず、
## ツリーに入れても既定の16しか返らないことを実測で確認している。Theme リソースの
## 中身と apply() の貼り先までをここで固定し、実際に効いているかは
## verify.sh の段階6/7(SPスクショ)が担保する。
##
## サボタージュ検証 (CLAUDE.md「壊した実装を落とせて初めて完成」):
##   1. SIZES の縦の値を横と同じにする → 「縦は横より大きい」が赤くなる。
##   2. 倍率を一律(全役割2.0倍)にする → 「小さい役割ほど強く上がる」が赤くなる。
##   3. fill_theme から set_type_variation を落とす → 「土台がLabel」が赤くなる。
##   4. apply() で Control を見つけても再帰を止めない → 「貼るのは一番上だけ」が赤くなる。
##   5. Title.tscn に theme_override_font_sizes を書き戻す → 走査ガードが赤くなる。
##   いずれも確認済み。

## .tscn を走査するときの起点。
const SCENES_DIR := "res://scenes"
## 走査が空振り(パス誤りで0件)していないことを確かめる下限。画面は7つある。
const MIN_SCANNED_SCENES := 7


func run(check: Callable) -> void:
	_test_hierarchy(check)
	_test_portrait_is_bigger(check)
	_test_small_roles_grow_more(check)
	_test_landscape_matches_existing_values(check)
	_test_theme_contents(check)
	_test_apply_targets_topmost_control(check)
	_test_no_font_sizes_left_in_scenes(check)


## 役割は小さい順に並び、同じ大きさの段は作らない(段が被ると役割を分ける意味がない)。
func _test_hierarchy(check: Callable) -> void:
	for orientation in [false, true]:
		var label := "縦" if orientation else "横"
		for i in range(1, FontScale.ROLES.size()):
			var smaller := FontScale.size_for(FontScale.ROLES[i - 1], orientation)
			var bigger := FontScale.size_for(FontScale.ROLES[i], orientation)
			check.call(
				bigger > smaller,
				"%s: %s(%d) は %s(%d) より大きい" % [
					label, FontScale.ROLES[i], bigger, FontScale.ROLES[i - 1], smaller
				]
			)


## 一番大事な不変条件: 縦画面では必ず大きくなる。ここが崩れるとSPで読めないまま。
func _test_portrait_is_bigger(check: Callable) -> void:
	for role in FontScale.ROLES:
		var land := FontScale.size_for(role, false)
		var port := FontScale.size_for(role, true)
		check.call(port > land, "%s: 縦(%d) は横(%d) より大きい" % [role, port, land])


## 小さい役割ほど倍率が強い。大見出しまで一律に上げると1280の幅を超えるので、
## 「読めない下の段を強く、元から読める上の段は控えめに」を設計として固定する。
func _test_small_roles_grow_more(check: Callable) -> void:
	for i in range(1, FontScale.ROLES.size()):
		var small_ratio := (
			float(FontScale.size_for(FontScale.ROLES[i - 1], true))
			/ float(FontScale.size_for(FontScale.ROLES[i - 1], false))
		)
		var big_ratio := (
			float(FontScale.size_for(FontScale.ROLES[i], true))
			/ float(FontScale.size_for(FontScale.ROLES[i], false))
		)
		check.call(
			small_ratio > big_ratio,
			"%s(%.2f倍) は %s(%.2f倍) より強く上がる" % [
				FontScale.ROLES[i - 1], small_ratio, FontScale.ROLES[i], big_ratio
			]
		)


## 横画面の見た目を変えないための固定。既存の .tscn にあった値の集合と一致させる。
## (36 だけは意図的に落として SUBTITLE の 32 へ丸めた。font_scale.gd のコメント参照)
func _test_landscape_matches_existing_values(check: Callable) -> void:
	var expected := [16, 20, 24, 32, 40, 48]
	var actual: Array[int] = []
	for role in FontScale.ROLES:
		actual.append(FontScale.size_for(role, false))
	check.call(actual == expected, "横画面の寸法は既存のまま %s (期待 %s)" % [actual, expected])
	# 役割なしノードの既定は Godot 既定の16のままであること。
	check.call(
		FontScale.size_for(FontScale.DEFAULT_ROLE, false) == 16,
		"横画面の既定サイズは16 (%d)" % FontScale.size_for(FontScale.DEFAULT_ROLE, false)
	)


## Theme の中身。default_font_size と、各役割の variation の寸法・土台。
##
## 注意: default_font_size を入れた Theme は has_font_size() が常に true を返すので、
## 存在確認には使えない。型の一覧で確かめる。
func _test_theme_contents(check: Callable) -> void:
	for orientation in [false, true]:
		var label := "縦" if orientation else "横"
		var theme := FontScale.build_theme(orientation)
		check.call(
			theme.default_font_size == FontScale.size_for(FontScale.DEFAULT_ROLE, orientation),
			"%s: 既定サイズが %s と一致 (%d)" % [
				label, FontScale.DEFAULT_ROLE, theme.default_font_size
			]
		)
		var variations := theme.get_type_variation_list(FontScale.VARIATION_BASE)
		for role in FontScale.ROLES:
			check.call(
				variations.has(String(role)),
				"%s: %s が Label の variation として登録されている" % [label, role]
			)
			check.call(
				theme.get_type_variation_base(role) == FontScale.VARIATION_BASE,
				"%s: %s の土台は Label (%s)" % [
					label, role, theme.get_type_variation_base(role)
				]
			)
			check.call(
				theme.get_font_size(&"font_size", role) == FontScale.size_for(role, orientation),
				"%s: %s の寸法は %d (%d)" % [
					label, role, FontScale.size_for(role, orientation),
					theme.get_font_size(&"font_size", role)
				]
			)
		# フォント本体は触らない。ここに Font を入れると日本語が豆腐になる。
		check.call(theme.default_font == null, "%s: フォント本体は差し替えない" % label)


## apply() は Node/Node2D/CanvasLayer を降りて、一番上の Control にだけ貼る。
##
## Godot のテーマ継承は Control/Window しか辿らないので、ここが壊れると
## 「Themeは作られたが誰も見ていない」状態になる。しかもエラーは出ない。
func _test_apply_targets_topmost_control(check: Callable) -> void:
	var theme := FontScale.build_theme(true)

	# Battle と同じ形: Node2D > CanvasLayer > Label、隣に Control ではない枝もある。
	var root := Node2D.new()
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var message := Label.new()
	layer.add_child(message)
	var inner := Label.new()
	message.add_child(inner)
	var bare := Node2D.new()
	root.add_child(bare)

	var applied := FontScale.apply(root, theme)
	check.call(applied == 1, "非Controlを降りて Control 1つに貼る (%d)" % applied)
	check.call(message.theme == theme, "CanvasLayer越しの Label に貼られている")
	check.call(inner.theme == null, "貼るのは一番上だけ(子には貼らない)")
	root.free()

	# 画面ルートが Control のとき(Title など)はそこで止まる。
	var screen := Control.new()
	var child := Label.new()
	screen.add_child(child)
	check.call(FontScale.apply(screen, theme) == 1, "Controlルートには1回だけ貼る")
	check.call(screen.theme == theme and child.theme == null, "ルートにだけ貼られている")
	screen.free()

	# Control が1つも無ければ0。呼び出し側が「届かなかった」に気付けること。
	var empty := Node.new()
	empty.add_child(Node2D.new())
	check.call(FontScale.apply(empty, theme) == 0, "Controlが無ければ0を返す")
	empty.free()


## 回帰ガード: サイズの出所が .tscn へ逆戻りしていないこと。
##
## Palette の色は .tscn へ手写しされて二重持ちになっている。同じことがサイズで
## 起きると、横画面と縦画面で別の値が効く事故になるので機械的に止める。
func _test_no_font_sizes_left_in_scenes(check: Callable) -> void:
	var offenders: Array[String] = []
	var scanned := _scan_scenes(SCENES_DIR, offenders)
	check.call(
		scanned >= MIN_SCANNED_SCENES,
		".tscn を %d 件走査した (空振りしていない、下限 %d)" % [scanned, MIN_SCANNED_SCENES]
	)
	check.call(
		offenders.is_empty(),
		"どの .tscn にも theme_override_font_sizes が無い (%s)" % ", ".join(offenders)
	)


## dir 以下の .tscn を数え、theme_override_font_sizes を含むものを offenders へ足す。
func _scan_scenes(dir_path: String, offenders: Array[String]) -> int:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	var count := 0
	for sub in dir.get_directories():
		count += _scan_scenes(dir_path.path_join(sub), offenders)
	for file_name in dir.get_files():
		if not file_name.ends_with(".tscn"):
			continue
		count += 1
		var path := dir_path.path_join(file_name)
		var text := FileAccess.get_file_as_string(path)
		if text.contains("theme_override_font_sizes"):
			offenders.append(path)
	return count
