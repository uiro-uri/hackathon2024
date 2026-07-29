class_name StatOp
extends Resource

## 強化パーツが1つのステータスに加える1回の操作。
##
## 元は CustomPart が (stat, multiplier) を1組だけ持っていた。「1枚=1ステータスに
## 定数を掛ける」札しか無かったからだが、次の2つがその前提を壊した:
##  - オーバーウェイト: 倍率だと重ねがけで複利に増える(1.5→2.25→3.38→5.06)。
##    定数加算にして線形にしたい。掛け算しか無いと表現できない。
##  - ジャイアントグロース: 直径と質量の両方を上げる複合札。1組しか持てないと
##    表現できない。
## そこで操作を「掛けて足して上限で止める」1単位に切り出し、CustomPartは
## その配列を持つ形にした。MOMENTUM/RAGEのように SpinnerStats の外(spin_decay・
## wall_keep)まで触る効果はここでは表現しないので、CustomPart側の分岐に残る。
##
## Stat enum をこちら側に置いているのは、CustomPart が StatOp を配列で持つため。
## 逆向き(StatOpがCustomPart.Statを見る)にすると相互参照になる。
## CustomPart.Stat は互換のためこの enum を指す別名。

enum Stat { MASS, RADIUS, FRICTION, RESTITUTION, RPS }

## どのステータスを触るか。
@export var stat: Stat = Stat.MASS

## 掛ける倍率。1未満なら下げる効果。
@export var multiplier: float = 1.0

## 倍率を掛けたあとに足す定数。重ねがけを線形にしたい札で使う。
@export var addend: float = 0.0

## 上限。0以下なら上限なし。倍率でも加算でも同じように頭打ちにする。
@export var cap: float = 0.0


## 倍率の操作を作る。
static func mult(stat_: Stat, multiplier_: float, cap_: float = 0.0) -> StatOp:
	var op := StatOp.new()
	op.stat = stat_
	op.multiplier = multiplier_
	op.cap = cap_
	return op


## 定数加算の操作を作る。倍率は1.0のまま(素の値に足すだけ)。
static func add(stat_: Stat, addend_: float, cap_: float = 0.0) -> StatOp:
	var op := StatOp.new()
	op.stat = stat_
	op.addend = addend_
	op.cap = cap_
	return op


## ステータスを書き換える。value = 元の値 × multiplier + addend、capで頭打ち。
func apply(stats: SpinnerStats) -> void:
	var value := read(stats) * multiplier + addend
	if cap > 0.0:
		value = minf(value, cap)
	_write(stats, value)


## 強化の向き。説明文の注釈(〜が増える/減る)をどちらにするかに使う。
func raises() -> bool:
	return multiplier > 1.0 or addend > 0.0


## 効果があるか。倍率1.0かつ加算0なら何もしない操作。
func changes() -> bool:
	return not is_equal_approx(multiplier, 1.0) or not is_zero_approx(addend)


func read(stats: SpinnerStats) -> float:
	match stat:
		Stat.MASS:
			return stats.mass
		Stat.RADIUS:
			return stats.radius
		Stat.FRICTION:
			return stats.friction
		Stat.RESTITUTION:
			return stats.restitution
		_:
			return stats.rps


func _write(stats: SpinnerStats, value: float) -> void:
	match stat:
		Stat.MASS:
			stats.mass = value
		Stat.RADIUS:
			stats.radius = value
		Stat.FRICTION:
			stats.friction = value
		Stat.RESTITUTION:
			stats.restitution = value
		_:
			stats.rps = value
