class_name StatReadout
extends RefCounted

## 対戦画面に出すプレイヤーのコマのステータス表示。
##
## 「どのステータスを・どの翻訳キーで・どれだけ埋まったバーで出すか」を、UIノード
## 生成から切り離してここ一箇所の純粋関数に集める(headlessでテストできるように
## する。cf. scripts/core/screen_layout.gd)。実際のバー生成は Battle.gd が行う。
##
## 数値の生表示は無粋なので、各ステータスは 0〜1 の割合(fraction)で返してバーで見せる。
## あくまで見た目用で、勝敗計算とは無関係。
##
## rps は「初期回転数」として出す。ライブに減っていく回転数は画面下のHPバーで
## 既に見えているので、こちらはビルドの基準値(＝開始時rps)を見せる。

## バーが満タンになる値(下端は0)。パーツはすべてバフ(デバフなし)なので、各
## ステータスが到達できる上限はカタログのCAPそのもの。表示上限をCAPに一致させ、
## 「MAXまで強化したらバーが満タン」になるようにする。CAPと別に表示レンジを持つと
## ずれる(以前は反発の表示上限1.5>CAP1.0でMAX強化でもバーが67%止まりだった)ので、
## 単一の情報源であるCustomPartCatalogのCAPを参照する。
const MASS_MAX := CustomPartCatalog.MASS_CAP
const RADIUS_MAX := CustomPartCatalog.RADIUS_CAP
const RESTITUTION_MAX := CustomPartCatalog.RESTITUTION_CAP
const RPS_MAX := CustomPartCatalog.RPS_CAP
## すり抜け時間の上端。ゴーストにはCAPが無い(重ねるほど線形に伸びる)ので、表示用に
## ゴースト2枚(合計4秒)で満タンとしておく。
const GHOST_MAX := 4.0


## 表示する行(上から順)。ラベルの翻訳キーと、バーの埋まり具合(0〜1)。
##
## ghost_seconds はゴースト札で得たすり抜け時間の合計(枚数×1枚あたり秒)。取得して
## いる(0より大きい)ときだけ末尾にすり抜け時間の行を足す。未取得なら出さない。値は
## CustomPartCatalog.total_ghost_seconds が出したものを Battle が渡す。
static func rows(stats: SpinnerStats, ghost_seconds: float = 0.0) -> Array[Dictionary]:
	var r: Array[Dictionary] = [
		{"label_key": "STAT_MASS", "fraction": _fraction(stats.mass, MASS_MAX)},
		{"label_key": "STAT_RADIUS", "fraction": _fraction(stats.radius, RADIUS_MAX)},
		{"label_key": "STAT_RESTITUTION", "fraction": _fraction(stats.restitution, RESTITUTION_MAX)},
		{"label_key": "STAT_RPS_INITIAL", "fraction": _fraction(stats.rps, RPS_MAX)},
	]
	if ghost_seconds > 0.0:
		r.append({"label_key": "STAT_GHOST", "fraction": _fraction(ghost_seconds, GHOST_MAX)})
	return r


## 値を 0〜max で 0〜1 に正規化する。範囲外は端で頭打ち(バーが溢れない/負にならない)。
static func _fraction(value: float, max_value: float) -> float:
	if max_value <= 0.0:
		return 0.0
	return clampf(value / max_value, 0.0, 1.0)
