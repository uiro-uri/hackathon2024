class_name CustomPart
extends Resource

## 戦闘に勝つと選べる強化パーツ。archive/flask-prototype/custom_part.py の移植。
##
## プロトタイプは効果ごとにupdate_massのようなメソッドを用意し、
## kwargsで生やした属性(mass_value/mass_calculation)の有無でディスパッチして
## いたが、実際の7個はすべて「あるステータスに定数を掛ける」だけなので、
## 対象ステータスと倍率のデータに畳んだ。
## その後「質量に定数を足す」札と「直径と質量を両方上げる」札が要ったので、
## 1組の(stat, multiplier)から StatOp(掛ける・足す・上限)の配列へ広げた。
##
## 説明文は数値から自動生成する。プロトタイプでは説明文が手書きで、
## 実際の値と2回食い違っていた:
##  - Spin Engineは「10%上昇」と書いて実際は1.2倍(=20%)。しかも直前のコミットが
##    「パーツ説明が嘘だったので修正」で、修正したそばから再発している。
##  - 以前は「50%上昇 (最大20)」で、上限も実際の40と違っていた。
## 生成にすれば嘘のつきようがない。

enum Rarity { COMMON, RARE }

## ステータスの種類。実体は StatOp 側にある(CustomPartがStatOpの配列を持つので、
## 逆向きに参照すると相互参照になる)。CustomPart.Stat.MASS の書き方を残すための別名。
const Stat := StatOp.Stat

## 効果の種類。既存の札はほとんどSTATS（ステータスをStatOpの並びで書き換える）。
## STATS以外は非ステータス効果で、SpinnerStatsのどの値にも乗らない:
##  - SET_LIVES: コマの性能ではなくランの残機(GameState.continues_left)を触る。
##    適用はGameState.apply_partが担う（CustomPartは純ResourceのままGameStateを参照しない）。
##  - GHOST: 最初の衝突の直後から一定時間だけ敵との衝突を無効化する時間効果
##    (ヒット&ラン: 初撃は通り、直後の報復をすり抜けて離脱する)。すり抜け時間は
##    BattleがCustomPartCatalog.total_ghost_secondsで戦闘へ渡す。
## MOMENTUM: 摩擦(速度減衰)と回転減衰率の両方を multiplier 倍にする「勢い維持」効果。
## 単一ステータス倍率では摩擦しか触れず戦績がほぼ0だったので、回転減衰にも効かせる。
## cap は spin_decay の下限(これ以上は減らさない=青天井/無限HP化を防ぐ)。
##
## RAGE: 反発(restitution)を multiplier 倍(cap上限)にしつつ、壁でのrps喪失を
## 減らす(wall_keepを wall_keep_step ぶん加算、上限1.0)複合効果。反発upは相手を
## 壁へ押し込む攻撃用途として残しつつ、wall_keepで自分の壁ダメージを減らす。
enum Effect { STATS, SET_LIVES, GHOST, MOMENTUM, RAGE }

## レアカードの見た目。報酬選択とマップの取得済み一覧で同じ強調を使うため、
## パーツ側に置いて共有する。地が明るい金色なので文字は暗くしないと読めない。
const RARE_TEXT_COLOR := Palette.TEXT_ON_LIGHT

## 効果の説明に使う翻訳キー。倍率と上限を埋め込む。
const _STAT_KEYS := {
	Stat.MASS: "PART_EFFECT_MASS",
	Stat.RADIUS: "PART_EFFECT_RADIUS",
	Stat.FRICTION: "PART_EFFECT_FRICTION",
	Stat.RESTITUTION: "PART_EFFECT_RESTITUTION",
	Stat.RPS: "PART_EFFECT_RPS",
}

## 倍率だけでは何が起きるか読み取れないので、実際の挙動を一言添える。
## キーは PART_NOTE_<ステータス>_<UP|DOWN> の形。上げ下げで効果が逆になる
## ステータス（特に半径は衝突減衰と自然減衰が逆に動く）ので方向で分ける。
## 未使用の方向でも、後でデバフ札を足したとき訳抜けが素で見えるよう両方置く。
const _STAT_NAMES := {
	Stat.MASS: "MASS",
	Stat.RADIUS: "RADIUS",
	Stat.FRICTION: "FRICTION",
	Stat.RESTITUTION: "RESTITUTION",
	Stat.RPS: "RPS",
}

@export var id: int = 0

## パーツ名の翻訳キー。
@export var title_key: String = ""

@export var rarity: Rarity = Rarity.COMMON

## 効果の種類。デフォルトはステータス書き換え。
@export var effect: Effect = Effect.STATS

## ステータスへの操作の並び。effectがSTATSのときだけ意味を持つ。
## 1枚で複数のステータスを触る札(ジャイアントグロース)は複数個入る。
@export var ops: Array[StatOp] = []

## 効果注記を差し替える翻訳キー。空なら操作ごとの注記(PART_NOTE_<ステータス>_<向き>)を
## 並べる。複数ステータスを触る札は注記も複数行になり、しかも似た文が重なって読みにくい
## (直径と質量はどちらも「衝突で削られる回転が減る」)。そういう札だけ1行にまとめる。
## 差し替えるのは注記だけで、数値は変わらず生成されたものが出る(説明が嘘にならない)。
@export var note_key: String = ""

## 掛ける倍率。MOMENTUM(摩擦と回転減衰)とRAGE(反発)が自分の倍率として使う。
## STATSの札は使わない(倍率はopsが持つ)。
@export var multiplier: float = 1.0

## MOMENTUMではspin_decayの下限、RAGEでは反発の上限。
## STATSの札は使わない(上限はopsが持つ)。
@export var cap: float = 0.0

## SET_LIVESで引き上げる残機。他の札では0（GameState.apply_partのmaxiが無害になる）。
@export var lives: int = 0

## ゴースト1枚あたりのすり抜け秒数(最初の衝突後に効く)。effectがGHOSTのときだけ意味を持つ。
## 合計時間(=枚数×これ)はCustomPartCatalog.total_ghost_secondsが出す。
@export var ghost_seconds: float = 0.0

## RAGE札が1枚あたり加算する壁rps保持量(wall_keepへ加算)。
@export var wall_keep_step: float = 0.0

## RAGE札のwall_keep上限。壁を完全無損失(1.0)にすると無敵化するので1未満で頭打ち。
@export var wall_keep_max: float = 1.0


## 1つのステータスに倍率を掛けるだけの札を作る。大半の札はこれ。
static func make(
	id_: int, title_key_: String, rarity_: Rarity, stat_: StatOp.Stat,
	multiplier_: float, cap_: float = 0.0
) -> CustomPart:
	return make_stats(id_, title_key_, rarity_, [StatOp.mult(stat_, multiplier_, cap_)])


## ステータス操作を並べて札を作る。加算や、複数ステータスを触る複合札用。
static func make_stats(
	id_: int, title_key_: String, rarity_: Rarity, ops_: Array[StatOp],
	note_key_: String = ""
) -> CustomPart:
	var part := CustomPart.new()
	part.id = id_
	part.title_key = title_key_
	part.rarity = rarity_
	part.ops = ops_
	part.note_key = note_key_
	return part


## 残機を引き上げる札を作る。ステータスには触らないので ops は空のまま。
static func make_set_lives(
	id_: int, title_key_: String, rarity_: Rarity, lives_: int
) -> CustomPart:
	var part := CustomPart.new()
	part.id = id_
	part.title_key = title_key_
	part.rarity = rarity_
	part.effect = Effect.SET_LIVES
	part.lives = lives_
	return part


## ゴースト札を作る。ステータスは変えず、最初の衝突の直後からseconds_秒だけ
## 敵との衝突を消す(ヒット&ラン)。
static func make_ghost(
	id_: int, title_key_: String, rarity_: Rarity, seconds_: float
) -> CustomPart:
	var part := CustomPart.new()
	part.id = id_
	part.title_key = title_key_
	part.rarity = rarity_
	part.effect = Effect.GHOST
	part.ghost_seconds = seconds_
	return part


## 勢い維持札を作る。摩擦とspin_decayの両方を multiplier 倍にする。
## spin_decay_floor_ は spin_decay の下限（重ねても回転減衰をこれ以下にはしない）。
static func make_momentum(
	id_: int, title_key_: String, rarity_: Rarity,
	multiplier_: float, spin_decay_floor_: float = 0.0
) -> CustomPart:
	var part := CustomPart.new()
	part.id = id_
	part.title_key = title_key_
	part.rarity = rarity_
	part.effect = Effect.MOMENTUM
	part.multiplier = multiplier_
	part.cap = spin_decay_floor_
	return part


## 怒りの反射札を作る。反発を restitution_mult 倍(restitution_cap上限)にしつつ、
## 壁rps保持を wall_keep_step_ ぶん上げる複合札。
static func make_rage(
	id_: int, title_key_: String, rarity_: Rarity,
	restitution_mult_: float, restitution_cap_: float,
	wall_keep_step_: float, wall_keep_max_: float
) -> CustomPart:
	var part := CustomPart.new()
	part.id = id_
	part.title_key = title_key_
	part.rarity = rarity_
	part.effect = Effect.RAGE
	part.multiplier = restitution_mult_
	part.cap = restitution_cap_
	part.wall_keep_step = wall_keep_step_
	part.wall_keep_max = wall_keep_max_
	return part


func apply_to(stats: SpinnerStats) -> void:
	# 勢い維持(MOMENTUM): 摩擦と回転減衰の両方を下げる。spin_decayはcapを下限に
	# クランプして、重ねても回転減衰がゼロ(=無限に回る)にならないようにする。
	if effect == Effect.MOMENTUM:
		stats.friction *= multiplier
		var decayed := stats.spin_decay * multiplier
		if cap > 0.0:
			decayed = maxf(decayed, cap)
		stats.spin_decay = decayed
		return
	# 怒りの反射(RAGE): 反発を上げつつ(cap上限)、壁rps喪失を減らす(wall_keep加算)。
	if effect == Effect.RAGE:
		var rest := stats.restitution * multiplier
		if cap > 0.0:
			rest = minf(rest, cap)
		stats.restitution = rest
		# 壁rps保持はwall_keep_maxで頭打ち。1.0(完全無損失)まで許すと重ねがけで
		# 壁ダメージ皆無＝ほぼ無敵になり、ラン単位で壊れる(計測で+59pt)ため。
		stats.wall_keep = minf(stats.wall_keep + wall_keep_step, wall_keep_max)
		return
	# 非ステータスの札(残機・ゴースト)はコマの性能を一切いじらない。残機はGameState.
	# apply_partが、ゴーストのすり抜け時間はBattleが処理する。
	if effect != Effect.STATS:
		return
	for op in ops:
		op.apply(stats)


## レアカードの金色スタイルボックス。報酬選択とマップ一覧で共有する。
static func rare_stylebox() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.GOLD_CARD
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	return style


## 実際の値から説明文を組み立てる。手書きしないので数値と食い違わない。
## 1行目は「質量 ×1.6（上限 8）」の生の倍率、2行目に実際の挙動を一言。
func describe() -> String:
	if effect == Effect.SET_LIVES:
		return tr("PART_EFFECT_SET_LIVES").format([lives])
	# ゴーストは倍率を持たないので、すり抜け秒数を埋めた専用の説明を返す。
	if effect == Effect.GHOST:
		return tr("PART_EFFECT_GHOST").format([_trim(ghost_seconds)])
	# 勢い維持は摩擦と回転減衰の両方に効く。倍率を埋めた専用の説明を返す。
	if effect == Effect.MOMENTUM:
		return tr("PART_EFFECT_MOMENTUM").format([_trim(multiplier)])
	# 怒りの反射は反発倍率と壁rps保持の複合。両方を埋めた専用の説明を返す。
	if effect == Effect.RAGE:
		return tr("PART_EFFECT_RAGE").format([_trim(multiplier), _trim(cap)])
	# 複数ステータスを触る札は「直径 ×1.1 / 質量 ×1.2」のように並べる。
	var parts := PackedStringArray()
	for op in ops:
		parts.append(_describe_op(op))
	var text := " / ".join(parts)
	# 注釈は操作ごとに1行。同じ文面(同じステータスを2回触る等)は重ねない。
	# note_keyがある札は、その1行でまとめて置き換える。
	var notes := PackedStringArray()
	if note_key != "":
		notes.append(tr(note_key))
	else:
		for op in ops:
			var note := _effect_note(op)
			if note != "" and not notes.has(note):
				notes.append(note)
	for note in notes:
		text += "\n" + note
	return text


## 操作1つぶんの表記。「質量 ×1.5（上限 8）」「質量 +0.75（上限 8）」。
func _describe_op(op: StatOp) -> String:
	var key: String = _STAT_KEYS[op.stat]
	var text: String
	# 加算の札は倍率を持たない(掛けて足す形だが、実際は片方しか使わない)。
	# 「×1」と出しても意味がないので、加算があればそちらを表記する。
	if not is_zero_approx(op.addend):
		text = tr(key + "_ADD").format([_trim(op.addend)])
	else:
		text = tr(key).format([_trim(op.multiplier)])
	if op.cap > 0.0:
		text += tr("PART_EFFECT_CAP").format([_trim(op.cap)])
	return text


## 操作の向きから実際の挙動の説明を引く。何も変えない操作なら空。
func _effect_note(op: StatOp) -> String:
	if not op.changes():
		return ""
	var direction := "UP" if op.raises() else "DOWN"
	return tr("PART_NOTE_%s_%s" % [_STAT_NAMES[op.stat], direction])


## 1.20 -> "1.2", 2.00 -> "2" のように余分な0を落とす。
static func _trim(value: float) -> String:
	var text := "%.2f" % value
	while text.ends_with("0"):
		text = text.substr(0, text.length() - 1)
	if text.ends_with("."):
		text = text.substr(0, text.length() - 1)
	return text
