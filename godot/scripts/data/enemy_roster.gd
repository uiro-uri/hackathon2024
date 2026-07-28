class_name EnemyRoster
extends RefCounted

## 敵の一覧と、どの段でどのレベルが出るか。
## archive/flask-prototype/enemy.py の ENEMY_LIST と get_random_enemy に相当する。
##
## 数値はプロトタイプを出発点にしているだけで、手触りで調整する前提。


## 敵の見た目・当たり判定の大きさ(半径)を一律で縮める倍率。盤面を見やすくする
## ためのバランス調整で、表の設計値はそのまま残し、生成時にこれを掛ける。
## 半径は物理にも効く(硬さ=質量×半径²、寿命=rps÷半径)ので、いじったら
## scripts/playtest.sh で勝率を測り直すこと。
const SIZE_SCALE := 0.75


## 敵の初期rpsを一律で上げ下げする倍率。SIZE_SCALEと同じく、表の設計値(同レベル内で
## 硬さが揃うよう形から逆算した値)はそのまま残し、生成時にこれを掛ける。
## 難度の主つまみ。rpsは**硬さ(=rps×質量×半径²)と寿命(=rps÷半径)の両方**に効くので、
## 上げると「倒すのに要する打撃数」と「放っておいても力尽きるまでの時間」が同時に伸びる。
## いじったら scripts/playtest.sh で勝率を測り直すこと。
const RPS_SCALE := 3.5


## 段(1..9)に対する敵レベル(1..5)。ゴール(段9)がレベル5のボスになる。
## プロトタイプに「エネミーが強くなる周期が変だったので修正（ボスがレベル5に
## なるようにしたい）」というコミットがあり、この式に落ち着いている。
static func level_for_step(step: int) -> int:
	return clampi((step + 1) / 2, 1, 5)


## 数値はテストプレイ(scripts/playtest.sh)で当てたもの。プロトタイプの表は
## 使っていない。あちらは段9のボスが 質量5.0/半径3.0/rps60 で、パーツを8枚
## 積んだプレイヤーでも勝率0%だった(25,000戦で勝利ゼロ)。
##
## この2つが勝敗をほぼ決めるので、そこを見て決めている:
##  - **寿命 = rps ÷ 半径**。自然減衰が半径に比例するため。殴られなくても
##    ここで力尽きる。プロトタイプの敵は寿命20〜30秒で、プレイヤー(強化後で
##    9秒前後)が待つだけで負けていた。
##  - **硬さ = 質量 × 半径²**。1衝突で削られるRPSがこれに反比例する。
##    プロトタイプのボスは45、プレイヤーは0.4しかなく、接触即死だった。
##
## 質量と半径は見た目の個性(小さくて素早い/大きくて重い)として先に決める。
## 同レベルの2体はほぼ同じ強さで、形だけ違う(rpsは形に合わせて僅かに違えてよい)。
##
## **強さはレベルと共に緩やかに上げる**。強さは1つのつまみではなく、硬さ・質量・
## 初期rpsの複合で決まる:
##  - **硬さ = rps × 質量 × 半径²**。倒すのに要する打撃数はこれにほぼ比例する
##    (1衝突のrps減少が 質量×半径² に反比例するため)。レベルと共に上げる主軸。
##  - **寿命 = rps ÷ 半径**。自然減衰が半径比例。殴られなくてもここで力尽きる。
##    プレイヤー(強化後〜9秒)を大きく超える寿命は「待ち負け」を生む。
##  - **rps** は回転ゲージそのもの。**レベルと共に単調増加**させる(低レベルほど
##    ゲージが大きいと直感と食い違う)。かつては勝率つまみとしてrpsを高レベルほど
##    下げており(Lv1=32→Lv4=10.5)、rpsも寿命もレベルと逆転、実プレイでも高レベル段
##    ほど楽という逆転が起きていた(段別勝率が横ばい〜後半で上昇)。それを解消した。
##
## 三者は掛かり合う(硬さ=rps×質量×半径²)ので、全部を急に上げると硬さが跳ねて
## 難易度に崖ができる。レベル間の上昇が緩やかになるよう複合で当てる。
## 同レベル2体はほぼ同強度に揃える。
##
## **以下の表の値は設計値で、実際に出る敵は半径にSIZE_SCALE・rpsにRPS_SCALEが掛かる。**
## レベル間の相対関係を読むための表なので、絶対値は係数込みで見ること。
##
## 調整の判定は段別勝率を固定ターゲットにせず(全段の目標勝率を決めているわけではない)、
## 「レベルと共に難易度が緩やかに上がるか・即死化していないか・待ち負けが支配的で
## ないか・ボスが据え置き挙動か」の signal で見る。数値をいじったら scripts/playtest.sh で
## 測り直すこと。
static func all() -> Array[EnemyData]:
	return [
		# 各レベル5種。同レベルは硬さ(=強さ)をほぼ揃え、形(質量・半径)で個性を出す。
		# rpsは硬さ一定になるよう形から逆算しているので同レベル内で少し違う。
		# 小さくて素早い。ほぼ負けない導入。
		_enemy(1, "ENEMY_1_1", 0.8, 0.5, 0.97, 1.0, 15.6),
		_enemy(1, "ENEMY_1_2", 0.7, 0.55, 0.98, 1.0, 16.2),
		_enemy(1, "ENEMY_1_3", 1.0, 0.46, 0.97, 1.0, 15.5),
		_enemy(1, "ENEMY_1_4", 0.6, 0.6, 0.98, 1.0, 15.2),
		_enemy(1, "ENEMY_1_5", 0.85, 0.52, 0.975, 1.0, 14.3),
		_enemy(2, "ENEMY_2_1", 1.2, 0.8, 0.97, 1.0, 19.5),
		_enemy(2, "ENEMY_2_2", 1.1, 0.85, 0.98, 1.0, 20.2),
		_enemy(2, "ENEMY_2_3", 1.5, 0.74, 0.97, 1.0, 18.9),
		_enemy(2, "ENEMY_2_4", 0.95, 0.92, 0.985, 1.0, 19.2),
		_enemy(2, "ENEMY_2_5", 1.3, 0.82, 0.98, 1.0, 17.7),
		_enemy(3, "ENEMY_3_1", 2.0, 1.2, 0.98, 1.0, 21.4),
		_enemy(3, "ENEMY_3_2", 1.8, 1.25, 0.985, 1.0, 22.1),
		_enemy(3, "ENEMY_3_3", 2.5, 1.12, 0.98, 1.0, 19.8),
		_enemy(3, "ENEMY_3_4", 1.55, 1.32, 0.985, 1.0, 22.9),
		_enemy(3, "ENEMY_3_5", 2.1, 1.22, 0.982, 1.0, 19.9),
		_enemy(4, "ENEMY_4_1", 3.0, 1.6, 0.98, 1.0, 26.0),
		_enemy(4, "ENEMY_4_2", 2.8, 1.7, 0.985, 1.0, 26.7),
		_enemy(4, "ENEMY_4_3", 3.6, 1.5, 0.98, 1.0, 25.6),
		_enemy(4, "ENEMY_4_4", 2.4, 1.78, 0.985, 1.0, 27.3),
		_enemy(4, "ENEMY_4_5", 3.1, 1.62, 0.982, 1.0, 25.5),
		# ボス。大きく重く、寿命も硬さもプレイヤーを上回る。5種あり、ランごとに1体が単体で出る。
		# 発射速度はEnemyDataから外し、自機と共通のレンジ(LaunchSpeed。上限12)から出現ごとに
		# 抽選する。かつてボスは全種8.5固定だった(元は11.0)。速いとボスが壁に突撃し、無敵中に
		# rpsの6割超を壁で失って勝手に死ぬ(=GHOSTで待つだけで倒せた)ため落としていた。共通レンジの
		# 上限を12に抑えることで、その暴発を新しい物理法則を足さず既存の発射軌道の範囲で抑える。
		# 追加種も硬さを揃え形だけ違う。
		_enemy(5, "ENEMY_5_1", 4.5, 2.4, 0.98, 1.0, 33.8),
		_enemy(5, "ENEMY_5_2", 5.2, 2.25, 0.98, 1.0, 33.3),
		_enemy(5, "ENEMY_5_3", 3.9, 2.55, 0.98, 1.0, 34.6),
		_enemy(5, "ENEMY_5_4", 4.6, 2.4, 0.98, 1.0, 33.0),
		_enemy(5, "ENEMY_5_5", 4.9, 2.32, 0.98, 1.0, 33.3),
	]


static func of_level(level: int) -> Array[EnemyData]:
	var result: Array[EnemyData] = []
	for enemy in all():
		if enemy.level == level:
			result.append(enemy)
	return result


## その段にふさわしい敵を1体選ぶ。
static func pick_for_step(step: int, rng: RandomNumberGenerator = null) -> EnemyData:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	var candidates := of_level(level_for_step(step))
	if candidates.is_empty():
		push_error("EnemyRoster: 段%dに出せる敵がいない" % step)
		return null
	return candidates[rng.randi_range(0, candidates.size() - 1)]


## その段の出現グループ(1〜3体)を選ぶ。乱戦パターンの入り口。
##
## ほとんどは1体。たまに2〜3体の乱戦になる。複数体でも**単体と同じ、その段の
## レベル**から選ぶ(各体は据え置きで、頭数でrpsを弱めない)。
## ボス(レベル5)は演出上つねに単体。
##
## かつては複数体を1段下のレベルから選び、さらに総回転量を一定に保つため各体の
## rpsを頭数で割っていた。だが割ると「衝突1回で終わる」コマになり一撃死が多発
## (3体Lv1で12.7%)、下限を張って凌ぐ始末だった。頭数割りも1段下げも撤廃し、
## 乱戦は頭数ぶん純粋に手強くなるが、その見返りに**倒した頭数だけ報酬を選べる**
## (Main.gdが pending_enemies.size()回だけ報酬画面を回す)。rpsを触らないので
## 抽選した敵をそのまま返す(pick_for_stepと同じく all()が毎回新しい実体を作るので
## 共有Resourceを壊す心配もない)。
static func pick_group_for_step(step: int, rng: RandomNumberGenerator = null) -> Array[EnemyData]:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()

	# ボスは単体固定。
	if level_for_step(step) >= 5:
		return [pick_for_step(step, rng)]

	# 頭数を重み付きで決める。大半は1体、たまに2〜3体。
	var roll := rng.randf()
	var count := 1
	if roll > 0.9:
		count = 3
	elif roll > 0.6:
		count = 2

	if count == 1:
		return [pick_for_step(step, rng)]

	# 複数体も単体と同じ、その段のレベルから選ぶ。各体は据え置き(頭数で弱めない)。
	var candidates := of_level(level_for_step(step))
	if candidates.is_empty():
		return [pick_for_step(step, rng)]
	var group: Array[EnemyData] = []
	for _i in count:
		group.append(candidates[rng.randi_range(0, candidates.size() - 1)])
	return group


static func _enemy(
	level: int, name_: String,
	mass: float, radius: float, friction: float, restitution: float, rps: float,
	spin_decay: float = 1.0
) -> EnemyData:
	var stats := SpinnerStats.new()
	stats.mass = mass
	stats.radius = radius * SIZE_SCALE
	stats.friction = friction
	stats.restitution = restitution
	stats.rps = rps * RPS_SCALE
	# 敵は全種1.0(=素の自然減衰)。表の誰もこの引数を渡していない。
	# spin_decayはFull Steam Aheadの札の効果として入れたもので、**敵には援用しない**と
	# 決めている(ボスの自滅は発射速度=既存の軌道で抑えた。`187caab`)。
	stats.spin_decay = spin_decay
	return EnemyData.make(level, name_, stats)
