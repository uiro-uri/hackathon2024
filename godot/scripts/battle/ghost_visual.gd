class_name GhostVisual
extends RefCounted

## ゴースト(すり抜け)中のコマの見た目の数式。純粋関数。
##
## spin_aura.gd / telegraph_wobble.gd / map_glow.gd と同じ設計で、時刻を渡せば
## 同じ値が返る。_processに数式を埋めるとヘッドレスでテストできないため、
## 明滅(シマー)の式だけをここへ切り出す。
##
## **半透明の保証**: alphaは常に(0,1)の内側。完全不透明だとすり抜け中に
## 見えず、完全透明だとコマが消えてしまう。どちらも困るので上下に余白を残す。
## tests/test_ghost_visual.gd がこれを固定する。

## 明滅の速さ(1秒あたりの周期数)。速すぎると点滅、遅すぎると気づかない。
const SHIMMER_HZ := 2.5

## 明滅の中心alpha。すり抜け中の平均的な透け具合。
const ALPHA_BASE := 0.5

## 明滅の振れ幅。ALPHA_BASE±これの範囲で脈打つ。
const ALPHA_AMP := 0.18

## ゴースト中にコマ全体へ掛ける色合い。modulateは乗算なので、本体色を少し
## 青白い霊的な寒色へ倒す。下のalphaと合わせて「すり抜けている」を伝える。
const TINT := Color(0.75, 0.9, 1.0)


## 時刻tでのalpha。中心ALPHA_BASE、振幅ALPHA_AMPで正弦波に明滅する。
static func alpha(time: float) -> float:
	return ALPHA_BASE + ALPHA_AMP * sin(time * SHIMMER_HZ * TAU)


## ゴースト中にコマへ掛けるmodulate(色×透明度)。
static func modulate(time: float) -> Color:
	return Color(TINT, alpha(time))
