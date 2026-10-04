# FX売買戦略仕様書（実運用完全版）
## Dual-Directional Trend Follow + Normalized Kalman Regime + Dual-Layer Hard Stop + ATR Band + Multi-Horizon Ensemble

---

### 改定履歴
* **バージョン**: 2.3.1（通貨ペア分類・取引摩擦表記整合版）
* **改定日**: 2026-09-17
* **改定概要**:
  1. **取引摩擦モデル（第10.2章）のペア分類整合**: クロス円・マイナーペアの例示にあった `AUDUSD` を `AUDJPY` へ修正し、第2.2章の通貨ペア分類（ドルストレート／クロス円）と完全に整合。
  2. **ハードSL 2段階約定・更新プロトコルの策定（v2.3.0継続）**: 成行注文送信時（確定足ベースの事前SL）と約定後（実約定価格 $OpenPrice$ に基づく $0.5 \times \text{ATR}$ フロア保証の即時 `OrderModify`）の2段階執行プロトコルを明文化。
  3. **バックテスト控除コスト設定の復元（v2.3.0継続）**: スプレッド、スリッページ、スワップの厳密なモデル数値を第10.2章に復元し、第13章の合否判定基準との整合性を担保。
  4. **価格スケール正規化（v2.2.0継続）**: カルマンフィルターへの入力価格を対数パーセント価格（$100 \times \ln(\text{Close})$）に正規化し、USDJPYとEURUSDのスケール不整合を解決。
  5. **RSI上限緩和およびブレイクアウト適正化（v2.2.0継続）**: RSI上限を $80$ へ緩和、ATRバンド倍率を $1.2$ に適正化し初動取り逃しを防止。
  6. **2通貨分解型クラスタリスク管理（v2.2.0継続）**: 1ポジションの保有通貨双方のリスク枠消費を厳格に独立計算。

---

## 1. 目的および基本方針

### 1.1 システムの目的
本仕様書は、主要外国為替（FX）市場における中長期的な価格トレンドを体系的・定量的に捉え、実運用時の取引コスト（スプレッド、スリッページ、スワップ）、証拠金規制、テールリスク（週末窓開け・平日突発ショック・サーバーダウン）を耐え抜く自動売買システム（Python、MQL5等）の完全な設計・実装仕様を定義する。

### 1.2 基本方針
1. **完全双方向性**: ロング（買い）およびショート（売り）の完全対称トレンドフォロー。
2. **対数正規化カルマンフィルター・レジーム判定**: 局所線形トレンドモデルの観測入力に対数価格変換を適用。通貨ペア固有の価格水準スケール（USDJPYの150 vs EURUSDの1.05）を排除し、統一されたパラメータセットで低遅延かつ高精度なトレンド・レンジ弁別を実現。
3. **低遅延トレンド検知**: 線形加重移動平均（LWMA: Linearly Weighted Moving Average）を採用し、単純移動平均（SMA）比で追従遅延を大幅短縮。
4. **ダマシ抑制と強トレンド捕捉の両立**: $\text{ATR}(14)$ ブレイクアウトバンドによるレンジ内ノイズ排除と、過度なRSI上限制約の排除。
5. **マルチホライズン・アンサンブル**: 3組の異なる期間ペアによる合致度（Ensemble Ratio）を算出し、確信度に応じた連続的なロットサイジングを実行。
6. **二重防護ストップ構造（Dual-Layer Stop Architecture）**:
   * **第1防護壁（ハードストップ）**: ブローカーサーバー上に常時配置される物理的な逆指値注文（SL）。成行約定と同時に2段階プロトコルで確実にフロア価格を固定し、平日の突発ショックや通信障害時の想定最大損失（$0.5\%$）を物理的に保証。
   * **第2防護壁（ソフトトレイリング）**: ニューヨーククローズ確定足に基づく日次ロジック判定。トレンド崩壊や反転時に翌朝成行で有利にエグジットし、ハードストップ価格を日次で有利な方向へ引き上げ。
7. **2通貨分解型クラスタリスク管理**: 通貨ペアを構成する2通貨それぞれのリスク消費を厳格に独立計算し、特定通貨への隠れ過剰集中を数学的に遮断。
8. **未来参照バイアス（Look-ahead Bias）の完全排除**: ニューヨーククローズ確定足（日足終値 / シフト1）基準で計算し、翌日早朝スプレッド正常化後の始値にて執行。

---

## 2. 対象市場および通貨ペア仕様

### 2.1 対象市場および時間軸
* **対象市場**: 主要外国為替（FX）市場
* **基準時間軸**: 日足（Daily / D1）
* **日足区切り**: ニューヨーク市場クローズ（夏時間: 日本時間 06:00 / 冬時間: 日本時間 07:00）

### 2.2 通貨ペアごとの PipSize および PipValue 定義
プログラム実装時の計算誤差および誤発注を防止するため、Pip単位を以下のように厳密に二分する。

#### A. クロス円ペア（JPYペア）
* **対象ペア例**: USDJPY, EURJPY, GBPJPY, AUDJPY, CADJPY, CHFJPY, NZDJPY
* **$\text{PipSize}$**: $0.01$（価格の小数第2位）
* **$1 \text{ Pip}$ の価値（$1.0 \text{ Lot} = 100,000 \text{ 通貨}$ あたり）**:
  $$1 \text{ PipValue}_{\text{JPY}} = 100,000 \times 0.01 = 1,000 \text{ JPY}$$
  （※口座通貨がJPYの場合、為替レートによらず常に $1,000 \text{ JPY}$）

#### B. 非クロス円ペア（Non-JPYペア）
* **対象ペア例**: EURUSD, GBPUSD, AUDUSD, NZDUSD, USDCAD, USDCHF
* **$\text{PipSize}$**: $0.0001$（価格の小数第4位）
* **$1 \text{ Pip}$ の価値（$1.0 \text{ Lot} = 100,000 \text{ 通貨}$ あたり）**:
  $$1 \text{ PipValue}_{\text{USD}} = 100,000 \times 0.0001 = 10.0 \text{ USD}$$
  * 口座通貨がJPYの場合の $1 \text{ Pip}$ 価値:
    $$1 \text{ PipValue}_{\text{JPY}} = 10.0 \times \text{USDJPYレート}$$

### 2.3 発注ロット制約
* **最小ロット単位**: $0.01 \text{ Lot}$（$1,000 \text{ 通貨}$）
* **ロット刻み幅**: $0.01 \text{ Lot}$
* **端数処理**: ロット計算時の端数はすべて切り捨て（$\text{FLOOR}$ 処理）

---

## 3. 使用インジケータ仕様

すべての指標は、バー $t$ の日足終値確定時点（クローズ確定足＝シフト1）の値を用いて計算する。

### 3.1 対数正規化カルマンフィルター・レジーム推定量（`KalmanRegimeEstimator`）

#### A. 価格スケール問題の解決（対数パーセント変換）
生の価格 $\text{Close}$ をそのまま入力した場合、USDJPY（$\approx 150$）とEURUSD（$\approx 1.05$）では観測ノイズ分散 $R=1.0$ の持つ統計的重みが約 $20,000$ 倍乖離し、EURUSDにおいて過剰平滑化（シグナル不発）が発生する。
これを完全に排除するため、インジケーターへの入力観測系列 $y_t$ を**対数パーセント価格**に統一変換する。

$$y_t = 100.0 \times \ln(\text{Close}[t])$$

これにより、$y_t$ の1足あたりの変動量は通貨ペアの絶対価格水準に依存せず**「日次リターン（$\%$）」**と同一スケール（通常 $0.3 \sim 1.5$ 程度）に標準化され、全通貨ペアで同一パラメータ群が数学的に正当化される。

#### B. 局所線形トレンドモデルの定式化
* **状態ベクトル**: $x_t = [\mu_t, \; \beta_t]^T$（$\mu_t$: 平滑化対数価格水準, $\beta_t$: 局所的な日次傾き・変化率）
* **状態方程式**:
  $$\begin{bmatrix} \mu_t \\ \beta_t \end{bmatrix} = \begin{bmatrix} 1 & 1 \\ 0 & 1 \end{bmatrix} \begin{bmatrix} \mu_{t-1} \\ \beta_{t-1} \end{bmatrix} + \begin{bmatrix} w_{\mu, t} \\ w_{\beta, t} \end{bmatrix}, \quad Q = \begin{bmatrix} q_\mu & 0 \\ 0 & q_\beta \end{bmatrix}$$
* **観測方程式**:
  $$y_t = \begin{bmatrix} 1 & 0 \end{bmatrix} \begin{bmatrix} \mu_t \\ \beta_t \end{bmatrix} + v_t, \quad v_t \sim \mathcal{N}(0, R)$$

#### C. 標準設定パラメータ（対数パーセントスケール基準）
* $q_\mu$（水準プロセスノイズ）: $1.0 \times 10^{-4}$
* $q_\beta$（傾きプロセスノイズ）: $1.0 \times 10^{-4}$
* $R$（観測ノイズ）: $1.0$
* $P_0$（初期共分散スケール）: $100.0$
* $z_{\text{enter}}$（トレンド突入閾値）: $2.0$
* $z_{\text{exit}}$（トレンド離脱閾値）: $1.0$
* $\text{AllowDirectReversal}$（即時ドテン許可）: `true`

#### D. インジケーターバッファ仕様
* **Buffer 3 (`Regime`)**:
  * `+1.0`: 上昇トレンドレジーム（$\text{REGIME\_UP}$）
  * `-1.0`: 下降トレンドレジーム（$\text{REGIME\_DOWN}$）
  * `0.0`: レンジ相場レジーム（$\text{REGIME\_RANGE}$）
* **Buffer 0 (`Z-Score`)**: 標準化モメンタム強度スコア $z_t = \frac{\hat{\beta}_t}{\sqrt{\max(P_{11}, 10^{-12})}}$
* **Buffer 2 (`Slope`)**: 推定された傾き実数値 $\hat{\beta}_t$

### 3.2 LWMA（Linearly Weighted Moving Average）アンサンブルセット
* **LWMA計算式**:
  $$\text{LWMA}(P)[t] = \frac{\sum_{i=0}^{P-1} (P - i) \cdot \text{Close}[t - i]}{\frac{P(P+1)}{2}}$$
* **設定ペア**:
  1. 短期ペア: $\text{Fast} = \text{LWMA}(10)$ , $\text{Slow} = \text{LWMA}(30)$
  2. 中期ペア: $\text{Fast} = \text{LWMA}(20)$ , $\text{Slow} = \text{LWMA}(60)$（※ブレイクアウトおよび決済基準線）
  3. 長期ペア: $\text{Fast} = \text{LWMA}(40)$ , $\text{Slow} = \text{LWMA}(120)$

### 3.3 ATR（Average True Range）
* **期間**: $14$（Wilder平滑化）
* **用途**: ブレイクアウトバンド閾値、ハードストップ価格、初期リスク距離の動的算出

### 3.4 RSI（Relative Strength Index）
* **期間**: $14$
* **用途**: トレンド方向のモメンタム確認。ブレイクアウト初動の強トレンドを取りこぼさないよう、上限を $80$（従来 $75$ より緩和）に設定。
* **許容レンジ**:
  * 買い（Long）: $50 < \text{RSI}(14)[t] \le 80$
  * 売り（Short）: $20 \le \text{RSI}(14)[t] < 50$

### 3.5 Swing Low / Swing High（自己参照バグ排除定義）
当日バー $t$ の価格を含めることによる論理的デッドロックを防ぐため、**参照期間は当日を含まない過去 $N$ 本**に厳格固定する。
* **参照期間**: $N = 20$
* **算出式**:
  $$\text{SwingLow}[t] = \min(\text{Low}[t-1], \text{Low}[t-2], \dots, \text{Low}[t-N])$$
  $$\text{SwingHigh}[t] = \max(\text{High}[t-1], \text{High}[t-2], \dots, \text{High}[t-N])$$

---

## 4. エントリーロジック

日足バー $t$ の終値確定時に以下の全条件を評価し、すべて合致した場合、翌バー $(t+1)$ の早朝スプレッド正常化確認後、成行買い/売りを発注する。

### 4.1 買いエントリー（Long）
以下の条件 `[L-ENTRY-01]` 〜 `[L-ENTRY-06]` がすべて真（True）であること。

* `[L-ENTRY-01]` **カルマンレジーム条件**: $\text{KalmanRegime}[t] == 1.0$（対数正規化カルマン上昇レジーム確定中）
* `[L-ENTRY-02]` **ブレイクアウト条件**: $\text{Close}[t] \ge \text{LWMA}(60)[t] + 1.2 \times \text{ATR}(14)[t]$
* `[L-ENTRY-03]` **アンサンブルトレンド条件**: $\text{LongEnsembleRatio}[t] \ge 0.67$（3組中2組以上合致）
* `[L-ENTRY-04]` **モメンタム条件**: $50 < \text{RSI}(14)[t] \le 80$
* `[L-ENTRY-05]` **経済指標安全条件**: 重要経済指標の禁止時間帯に該当しないこと
* `[L-ENTRY-06]` **リスク・証拠金・クラスタ条件**: 第7章〜第8章の制限を満たすこと

### 4.2 売りエントリー（Short）
以下の条件 `[S-ENTRY-01]` 〜 `[S-ENTRY-06]` がすべて真（True）であること。

* `[S-ENTRY-01]` **カルマンレジーム条件**: $\text{KalmanRegime}[t] == -1.0$（対数正規化カルマン下降レジーム確定中）
* `[S-ENTRY-02]` **ブレイクアウト条件**: $\text{Close}[t] \le \text{LWMA}(60)[t] - 1.2 \times \text{ATR}(14)[t]$
* `[S-ENTRY-03]` **アンサンブルトレンド条件**: $\text{ShortEnsembleRatio}[t] \ge 0.67$（3組中2組以上合致）
* `[S-ENTRY-04]` **モメンタム条件**: $20 \le \text{RSI}(14)[t] < 50$
* `[S-ENTRY-05]` **経済指標安全条件**: 重要経済指標の禁止時間帯に該当しないこと
* `[S-ENTRY-06]` **リスク・証拠金・クラスタ条件**: 第7章〜第8章の制限を満たすこと

### 4.3 アンサンブル合致度（Ensemble Ratio）の算出
各時間軸ペアの方向フラグを算出し、平均スコア化する。
$$\text{Flag\_L1} = (\text{LWMA}(10)[t] > \text{LWMA}(30)[t]) ? 1 : 0$$
$$\text{Flag\_L2} = (\text{LWMA}(20)[t] > \text{LWMA}(60)[t]) ? 1 : 0$$
$$\text{Flag\_L3} = (\text{LWMA}(40)[t] > \text{LWMA}(120)[t]) ? 1 : 0$$
$$\text{LongEnsembleRatio}[t] = \frac{\text{Flag\_L1} + \text{Flag\_L2} + \text{Flag\_L3}}{3.0}$$

（※ショート判定は不等号をすべて逆転させて算出）

---

## 5. エグジット（決済）ロジックおよび二重防護ストップ構造

平日のフラッシュクラッシュ、要人発言ショック、VPS/通信障害による破滅的損失を防ぐため、**「ブローカー配置ハードSL」**と**「日足確定時ソフト決済」**を併用する二重防御構造を義務付ける。

### 5.1 第1防護壁: ブローカー側ハードストップ（Hard Stop-Loss Order）

#### A. ハードSL価格の算定式
新規成行注文の発注時点では約定価格（$\text{OpenPrice}$）が未確定であるため、以下の2段階計算を行う。

1. **発注前基準ストップ価格（$\text{StopPrice}_{\text{init}}$）**:
   * ロング: $\text{StopPrice}_{\text{init}} = \min\left( \text{LWMA}(60)[t] - 1.0 \times \text{ATR}(14)[t], \; \text{SwingLow}[t] \right)$
   * ショート: $\text{StopPrice}_{\text{init}} = \max\left( \text{LWMA}(60)[t] + 1.0 \times \text{ATR}(14)[t], \; \text{SwingHigh}[t] \right)$

2. **約定直後の確定ハードSL価格（実約定価格フロア反映）**:
   約定スリッページや極小ストップによるノイズ狩りを防止するため、実約定価格 $\text{OpenPrice}$ からの最低距離（$0.5 \times \text{ATR}$）を担保する。
   * ロング確定SL:
     $$\text{HardSL}_{\text{Long}} = \min\left( \text{StopPrice}_{\text{init}}, \; \text{OpenPrice} - 0.5 \times \text{ATR}(14)[t] \right)$$
   * ショート確定SL:
     $$\text{HardSL}_{\text{Short}} = \max\left( \text{StopPrice}_{\text{init}}, \; \text{OpenPrice} + 0.5 \times \text{ATR}(14)[t] \right)$$

#### B. 2段階執行プロトコル（Two-Step Order Protocol）
1. **ステップ1（成行発注時）**:
   成行注文（`OrderSend`）の SL 引数には、確定足ベースで算出した $\text{StopPrice}_{\text{init}}$ を指定して送信する。これにより、発注直後の無防備な空白時間を物理的に排除する。
2. **ステップ2（約定確認およびSL即時更新）**:
   注文約定イベントを受信した直後、ブローカーから返却された実約定価格 $\text{OpenPrice}$ を取得し、上記式に基づき $\text{HardSL}$ を算出する。$\text{HardSL} \neq \text{StopPrice}_{\text{init}}$ である場合、即座に注文変更（MQL5: `trade.PositionModify`）を発行してハードSLを確定価格に同期させる。

#### C. ハードSLの有利方向トレイリング更新（日次更新規程）
毎バー $t$ の日足終値確定時、算出し直したストップ水準が現在設定されているハードSLよりも「有利な方向（ロングなら上方、ショートなら下方）」へ移動した場合に限り、ブローカー注文変更関数を発行してハードSL価格を切り上げる/切り下げる。逆方向への緩和（SLの拡大）はプログラムレベルで厳格に禁止する。

### 5.2 第2防護壁: 日足終値確定時ソフト決済（Soft Exit）
ハードストップにヒットしていない状態であっても、毎バー $t$ の日足終値確定時に以下を評価し、満たされた場合は翌バー始値で成行決済する。
**全決済条件と部分決済条件が同一バーで同時に成立した場合、常に全決済を優先する。**

#### A. ロングポジションのソフトエグジット
1. **全決済（Full Exit）**: 以下のいずれか1つでも成立した場合、全ロットを成行決済。
   * カルマン急反転: $\text{KalmanRegime}[t] == -1.0$（下降レジーム転換即時脱出）
   * ATRバンド割れ: $\text{Close}[t] < \text{LWMA}(60)[t] - 1.0 \times \text{ATR}(14)[t]$
   * Swing Low割れ: $\text{Close}[t] < \text{SwingLow}[t]$
2. **部分利確（Partial Take Profit）**: 全決済不成立、未利確、かつ保有ロットが $0.02 \text{ Lot}$ 以上の場合のみ。
   * 発動条件: $\text{Close}[t] < \text{LWMA}(20)[t]$
   * 執行内容: 保有ロットの $50\%$（端数切り捨て）を翌バー始値で決済。

#### B. ショートポジションのソフトエグジット
1. **全決済（Full Exit）**: 以下のいずれか1つでも成立した場合、全ロットを成行決済。
   * カルマン急反転: $\text{KalmanRegime}[t] == 1.0$（上昇レジーム転換即時脱出）
   * ATRバンド超え: $\text{Close}[t] > \text{LWMA}(60)[t] + 1.0 \times \text{ATR}(14)[t]$
   * Swing High超え: $\text{Close}[t] > \text{SwingHigh}[t]$
2. **部分利確（Partial Take Profit）**: 全決済不成立、未利確、かつ保有ロットが $0.02 \text{ Lot}$ 以上の場合のみ。
   * 発動条件: $\text{Close}[t] > \text{LWMA}(20)[t]$
   * 執行内容: 保有ロットの $50\%$（端数切り捨て）を翌バー始値で決済。

---

## 6. 資金管理およびロットサイジング仕様

### 6.1 トレード許容リスク金額
口座有効証拠金（$\text{AccountEquity}$）の $0.5\%$ を1トレードあたりの許容リスク金額とする。
$$\text{MaxRiskAmount} = \text{AccountEquity} \times 0.005$$

### 6.2 リスク距離の算出
$$\text{RiskDistance}_{\text{raw}} = |\text{Close}[t] - \text{StopPrice}_{\text{init}}|$$
$$\text{RiskDistance} = \max\left( \text{RiskDistance}_{\text{raw}}, \; 0.5 \times \text{ATR}(14)[t] \right)$$

### 6.3 ロット数の算出
$$\text{RiskInPips} = \frac{\text{RiskDistance}}{\text{PipSize}}$$
$$\text{BaseLots} = \frac{\text{MaxRiskAmount}}{\text{RiskInPips} \times \text{PipValuePerLot}}$$
$$\text{FinalLots} = \left\lfloor \frac{\text{BaseLots} \times \text{EnsembleRatio}}{0.01} \right\rfloor \times 0.01$$
* $\text{FinalLots} < 0.01$ の場合はエントリーを見送る。

---

## 7. レバレッジおよび証拠金維持率管理仕様

### 7.1 実効レバレッジ上限規制
$$\text{EffectiveLeverage} = \frac{\sum (\text{全保有ポジションの想定元本合計})}{\text{AccountEquity}} \le 5.0$$
新規発注によって実効レバレッジが $5.0$ 倍を超える場合、発注を完全に拒絶する。

### 7.2 証拠金維持率（Margin Level）ゲート
$$\text{MarginLevel} = \left( \frac{\text{AccountEquity}}{\text{UsedMargin}} \right) \times 100\%$$
* **新規発注停止ゲート（$\text{MarginLevel} < 300\%$）**: すべての新規エントリーシグナルを遮断。
* **緊急リスクオフゲート（$\text{MarginLevel} < 150\%$）**: 含み損の大きいポジションから順に $50\%$ を強制成行決済し、強制ロスカット水準への接近を未然に防止。

---

## 8. 通貨クラスタ分解リスク管理（2通貨エクスポージャー消費モデル）

### 8.1 2通貨分解アロケーションの基本原則
1つの通貨ペア $A/B$ のポジションは、**「通貨 $A$ の買い（売り）」と「通貨 $B$ の売り（買い）」の2つの独立したリスクエクスポージャーを同時に生成する**。
したがって、1つのポジションが保有するリスク金額 $R_{\text{pos}}$（$= \text{AccountEquity} \times 0.005$）は、通貨 $A$ のクラスタおよび通貨 $B$ のクラスタの**双方の枠を同時に同額消費する**。

### 8.2 通貨クラスタの定義
通貨ペアではなく「通貨そのもの」を以下の4つのクラスタに分類する。

| クラスタ名 | 構成通貨 | 同方向リスク許容上限（対口座総資産比） |
| :--- | :--- | :--- |
| **USDクラスタ** | USD | 最大 $1.0\%$（ロング/ショート各方向） |
| **EUR/GBP/CHFクラスタ（欧州）** | EUR, GBP, CHF | 最大 $1.0\%$（ロング/ショート各方向） |
| **資源国クラスタ** | AUD, NZD, CAD | 最大 $1.0\%$（ロング/ショート各方向） |
| **JPYクラスタ** | JPY | 最大 $1.0\%$（ロング/ショート各方向） |

### 8.3 クラスタ消費判定アルゴリズム
新規ポジション $P_{\text{new}}$（ペア $A/B$、売買方向 $D \in \{\text{BUY}, \text{SELL}\}$、リスク額 $R_{\text{pos}}$）を発注する際、以下の判定を行う。

1. **通貨 $A$ の方向**: $\text{BUY}$ なら $A$ をロング、$\text{SELL}$ なら $A$ をショート。
2. **通貨 $B$ の方向**: $\text{BUY}$ なら $B$ をショート、$\text{SELL}$ なら $B$ をロング。
3. **判定式**:
   既存ポジションによる当該クラスタ・同方向のリスク合計を $\text{CurrentRisk}(\text{Cluster}, \text{Direction})$ とする。
   $$\text{CurrentRisk}(\text{Cluster}_A, \text{Direction}_A) + R_{\text{pos}} \le \text{AccountEquity} \times 0.010$$
   かつ
   $$\text{CurrentRisk}(\text{Cluster}_B, \text{Direction}_B) + R_{\text{pos}} \le \text{AccountEquity} \times 0.010$$
   双方が満たされない場合、新規発注は完全に拒絶される。

* **具体例**:
  * ポジション1: USDJPY 買い（リスク $0.5\%$）保有中
    $\rightarrow$ USDロング: $0.5\%$ 消費 / JPYショート: $0.5\%$ 消費
  * ポジション2: EURJPY 買い（リスク $0.5\%$）シグナル発生
    $\rightarrow$ EURロング: $0.5\% \le 1.0\%$（OK） / JPYショート: $0.5\% + 0.5\% = 1.0\% \le 1.0\%$（OK） $\rightarrow$ 発注承認。
  * ポジション3: AUDJPY 買い（リスク $0.5\%$）シグナル発生
    $\rightarrow$ JPYショート: 既存 $1.0\% + 0.5\% = 1.5\% > 1.0\%$ となり**発注拒絶**（JPY売り過剰集中を阻止）。

### 8.4 ポートフォリオ総オープンリスク上限
口座全体の全保有ポジションのリスク総和は、口座総資産の $2.0\%$ を超えてはならない。
$$\sum_{k} R_{\text{pos}, k} \le \text{AccountEquity} \times 0.02$$

### 8.5 ローリング相関係数フィルター
* **計算期間**: 直近 $60$ 日間の日足終値リターン
* **ルール**: 新規候補ペアと既存保有ペアの相関係数 $|r| > 0.70$ の場合、新規発注をスキップする。

---

## 9. ギャップリスクおよび経済イベント防護仕様

### 9.1 週末持ち越し（Weekend Carry）リスク管理
* **判定時刻**: 毎週金曜日のニューヨーク市場クローズ1時間前（夏時間: 日本時間 土曜 05:00 / 冬時間: 06:00）
* **強制決済条件**: ポジションが含み損状態であり、かつ現在値からハードSLまでの距離が $0.5 \times \text{ATR}(14)$ 未満に接近している場合、週明けの窓開け被弾を避けるため市場クローズ前に成行全決済する。

### 9.2 重要経済指標・中央銀行イベントフィルター
* **対象イベント**: 米雇用統計（NFP）、米FOMC、主要中央銀行（ECB, BOJ, BOE）政策金利発表、米CPI
* **制御ルール**: イベント発表前 $30$ 分〜発表後 $15$ 分は新規発注を禁止。スプレッドが平常値の $1.5$ 倍以上に拡大している間は待機する。

---

## 10. 執行仕様およびルックアヘッドバイアス排除規定

### 10.1 約定タイムライン
1. **日足クローズ確定**: バー $t$ の日足終値（NYクローズ確定＝シフト1）を受信。
2. **対数価格正規化および指標計算**:
   * 入力系列 $y_t = 100.0 \times \ln(\text{Close}[t])$ を算出し、`KalmanRegimeEstimator` の確定足バッファからレジームを取得。
   * LWMA、ATR、RSI、Ensemble Ratio を算出。
3. **早朝流動性スキャン**: 日本時間 05:55 〜 06:25（冬時間: 06:55 〜 07:25）の早朝スプレッド拡大が収束したことを確認（USDJPY $\le 1.5 \text{ pips}$, EURUSD $\le 1.5 \text{ pips}$）。
4. **ステップ1発注**: 早朝スプレッド正常化後、バー $(t+1)$ の市場に対して成行注文を送信。この際、$\text{StopPrice}_{\text{init}}$ を初期SLとして付与。
5. **ステップ2同期**: 約定通知から実約定価格 $\text{OpenPrice}$ を取得し、$\text{HardSL}$（$0.5 \times \text{ATR}$ フロア反映後）を確定。必要に応じて直ちに注文変更（`Modify`）を発行。
6. **バイアス排除規程**: バックテスト時にバー $t$ の終値で約定したとみなすバックテスト実装は厳格に禁止する。

### 10.2 バックテスト控除コスト設定（取引摩擦モデル）
バックテスト検証時は、実運用環境の摩擦を過小評価しないよう、第2.2章の通貨ペア分類に整合させた以下の取引コストを必ずモデルに織り込むこと。
* **固定片道スプレッド**:
  * ドルストレート（EURUSD, GBPUSD, AUDUSD 等）および USDJPY: $1.5 \text{ pips}$
  * クロス円・マイナーペア（EURJPY, GBPJPY, AUDJPY 等）: $2.0 \sim 2.5 \text{ pips}$
* **執行スリッページ**:
  * 全取引一律 片道 $0.5 \text{ pips}$（指標発表前後等の突発時は追加ペナルティを考慮）
* **キャリーコスト（スワップポイント）**:
  * ブローカー提供のヒストリカル・スワップポイントを日次ロールオーバー（NYクローズ持ち越し時）ごとに正確に加減算（水曜日の3倍スワップを含む）。

---

## 11. 再エントリーおよびクールダウン

* **ルール**: ハードSLまたはソフト全決済となった通貨ペアは、決済バーを含めて以降 $2$ 本（$48$ 時間）の間、新規エントリーを禁止する。

---

## 12. アルゴリズム擬似コードおよびMQL5連携仕様

### 12.1 MQL5での対数正規化インジケーター呼び出しインターフェース
```cpp
//--- インジケーターハンドルの初期化（EA OnInit内）
int h_kalman = iCustom(_Symbol, PERIOD_D1, "KalmanRegimeEstimator_Normalized",
                       1e-4,       // InpQMu (対数%スケール)
                       1e-4,       // InpQBeta (対数%スケール)
                       1.0,        // InpR
                       100.0,      // InpInitialP
                       2.0,        // InpZEnter
                       1.0,        // InpZExit
                       true        // InpAllowDirectReversal
                      );

//--- 日足確定時（シフト1）のデータ取得
double regime_val[1];
CopyBuffer(h_kalman, 3, 1, 1, regime_val); // Buffer 3: Regime (1.0, -1.0, 0.0)
double kalman_regime = regime_val[0];
```

### 12.2 日足確定メインループ擬似コード
```python
def on_daily_close(t):
    # -------------------------------------------------------------
    # 1. 保有中ポジションの監視、ソフト決済、およびハードSL更新
    # -------------------------------------------------------------
    for pos in get_open_positions():
        symbol = pos.symbol
        close_t = get_close(symbol, t)
        atr_14 = get_atr(symbol, 14, t)
        lwma_20 = get_lwma(symbol, 20, t)
        lwma_60 = get_lwma(symbol, 60, t)
        swing_l = get_swing_low(symbol, 20, t)
        swing_h = get_swing_high(symbol, 20, t)
        kalman_regime = get_kalman_regime_normalized(symbol, t)
        
        if pos.type == POSITION_TYPE_LONG:
            # [ソフト全決済判定]
            if kalman_regime == -1.0 or close_t < (lwma_60 - 1.0 * atr_14) or close_t < swing_l:
                close_position(pos, reason="Soft Exit Long Full")
                set_cooldown(symbol, bars=2)
                continue
            
            # [ソフト部分利確判定]
            elif close_t < lwma_20 and not pos.partial_closed:
                if pos.lots >= 0.02:
                    partial_lots = math.floor((pos.lots * 0.5) / 0.01) * 0.01
                    close_partial_position(pos, partial_lots, reason="Soft Exit Long Partial")
                    pos.partial_closed = True

            # [ハードSLトレイリング更新（有利方向のみ）]
            new_sl = min(lwma_60 - 1.0 * atr_14, swing_l)
            if new_sl > pos.current_hard_sl:
                modify_order_hard_sl(pos, new_sl)

        elif pos.type == POSITION_TYPE_SHORT:
            # [ソフト全決済判定]
            if kalman_regime == 1.0 or close_t > (lwma_60 + 1.0 * atr_14) or close_t > swing_h:
                close_position(pos, reason="Soft Exit Short Full")
                set_cooldown(symbol, bars=2)
                continue
            
            # [ソフト部分利確判定]
            elif close_t > lwma_20 and not pos.partial_closed:
                if pos.lots >= 0.02:
                    partial_lots = math.floor((pos.lots * 0.5) / 0.01) * 0.01
                    close_partial_position(pos, partial_lots, reason="Soft Exit Short Partial")
                    pos.partial_closed = True

            # [ハードSLトレイリング更新（有利方向のみ）]
            new_sl = max(lwma_60 + 1.0 * atr_14, swing_h)
            if new_sl < pos.current_hard_sl:
                modify_order_hard_sl(pos, new_sl)

    # -------------------------------------------------------------
    # 2. 口座全体のレバレッジ・証拠金ゲートチェック
    # -------------------------------------------------------------
    if get_margin_level() < 150.0:
        trigger_emergency_risk_off()
        return
        
    if get_margin_level() < 300.0 or get_effective_leverage() >= 5.0:
        log("新規発注停止: 証拠金維持率不足または実効レバレッジ超過")
        return

    # -------------------------------------------------------------
    # 3. 新規シグナル判定および発注（2段階ハードSL設定プロトコル）
    # -------------------------------------------------------------
    for symbol in WATCH_LIST:
        if has_position(symbol) or get_cooldown(symbol) > 0:
            continue
        if is_economic_event_near(symbol, pre_min=30, post_min=15):
            continue
            
        close_t = get_close(symbol, t)
        kalman_regime = get_kalman_regime_normalized(symbol, t)
        lwma_60 = get_lwma(symbol, 60, t)
        atr_14 = get_atr(symbol, 14, t)
        rsi_14 = get_rsi(symbol, 14, t)
        
        # --- 買い（Long）シグナル判定 ---
        if kalman_regime == 1.0:
            if close_t >= (lwma_60 + 1.2 * atr_14):
                if 50.0 < rsi_14 <= 80.0:
                    ratio = calc_long_ensemble_ratio(symbol, t)
                    if ratio >= 0.67:
                        swing_l = get_swing_low(symbol, 20, t)
                        stop_price_init = min(lwma_60 - 1.0 * atr_14, swing_l)
                        risk_dist = max(close_t - stop_price_init, 0.5 * atr_14)
                        
                        lots = calculate_lots(symbol, risk_dist, ratio)
                        # 2通貨分解クラスタリスクチェック
                        if lots >= 0.01 and validate_dual_currency_cluster_limits(symbol, lots, ORDER_BUY):
                            # ステップ1: 成行発注（確定足ベースの暫定ハードSLを常時配置）
                            pos_ticket = open_market_order(symbol, ORDER_BUY, lots, stop_loss=stop_price_init)
                            
                            # ステップ2: 実約定価格（OpenPrice）に基づくフロア確定・即時更新
                            open_price = get_position_open_price(pos_ticket)
                            hard_sl = min(stop_price_init, open_price - 0.5 * atr_14)
                            if hard_sl != stop_price_init:
                                modify_order_hard_sl(pos_ticket, hard_sl)

        # --- 売り（Short）シグナル判定 ---
        elif kalman_regime == -1.0:
            if close_t <= (lwma_60 - 1.2 * atr_14):
                if 20.0 <= rsi_14 < 50.0:
                    ratio = calc_short_ensemble_ratio(symbol, t)
                    if ratio >= 0.67:
                        swing_h = get_swing_high(symbol, 20, t)
                        stop_price_init = max(lwma_60 + 1.0 * atr_14, swing_h)
                        risk_dist = max(stop_price_init - close_t, 0.5 * atr_14)
                        
                        lots = calculate_lots(symbol, risk_dist, ratio)
                        # 2通貨分解クラスタリスクチェック
                        if lots >= 0.01 and validate_dual_currency_cluster_limits(symbol, lots, ORDER_SELL):
                            # ステップ1: 成行発注（確定足ベースの暫定ハードSLを常時配置）
                            pos_ticket = open_market_order(symbol, ORDER_SELL, lots, stop_loss=stop_price_init)
                            
                            # ステップ2: 実約定価格（OpenPrice）に基づくフロア確定・即時更新
                            open_price = get_position_open_price(pos_ticket)
                            hard_sl = max(stop_price_init, open_price + 0.5 * atr_14)
                            if hard_sl != stop_price_init:
                                modify_order_hard_sl(pos_ticket, hard_sl)
```

---

## 13. バックテスト評価指標およびロバストネス合否判定基準

### 13.1 サンプルサイズとバックテスト期間規程
日足トレンドフォロー戦略の年間シグナル発生頻度は $1$ 通貨ペアあたり約 $10 \sim 25$ 回である。統計的自由度および標本分散の偏りを排除するため、以下の検証期間を必須とする。
* **バックテスト対象期間**: **最低15年間**（2011年〜2026年等、複数の利上げ・利下げサイクルおよび円高・円安相場を網羅）
* **検証対象ペア**: 主要 8〜10 通貨ペア（EURUSD, GBPUSD, AUDUSD, USDJPY, EURJPY, GBPJPY, AUDJPY, USDCAD, USDCHF 等）

### 13.2 パラメータ高原（Plateau）検証グリッド
* **対数カルマン・プロセスノイズ $q_\beta$**: $5.0 \times 10^{-5} \;/\; 1.0 \times 10^{-4} \;/\; 2.0 \times 10^{-4}$
* **対数カルマン・ヒステリシス閾値ペア $(z_{\text{enter}}, z_{\text{exit}})$**: $(1.8, 0.8) \;/\; (2.0, 1.0) \;/\; (2.5, 1.2)$
* **$\text{LWMA}$ 中期ペア**: $(15, 50) \;/\; (20, 60) \;/\; (25, 75)$
* **$\text{ATR}$ エントリーバンド倍率**: $1.0 \;/\; 1.2 \;/\; 1.5$
* **$\text{RSI}$ 許容範囲（Long）**: $[50\text{--}75] \;/\; [50\text{--}80] \;/\; [50\text{--}85] \;/\; [50\text{--}100]$（上限なし）
* **Swing期間 $N$**: $15 \;/\; 20 \;/\; 25$
* **$\text{CooldownBars}$**: $0 \;/\; 2 \;/\; 5$

### 13.3 2段階シャープレシオ設計と合否クライテリア
単一通貨ペアの日足トレンドフォローは低勝率（$35\% \sim 45\%$）・高損益比（Profit Factor重視）の統計的特性を持ち、単一ペア単体でのシャープレシオは年率 $0.6 \sim 0.8$ が適正水準である。複数通貨ペア運用による相関分散効果を通じてシステム全体の年率 Sharpe $> 1.0$ を達成する2段階合否構造を採用する。

| 評価項目 | 個別通貨ペア単体基準 | ポートフォリオ統合後基準 |
| :--- | :--- | :--- |
| **最低トレード数** | **各ペア $80$ 回以上**（15年検証） | **全体で $500$ 回以上**（統計的有意性確保） |
| **Profit Factor (PF)** | In-Sample $> 1.30$ / Out-of-Sample $> 1.15$ | In-Sample $> 1.40$ / Out-of-Sample $> 1.25$ |
| **最大ドローダウン (MaxDD)** | $\text{MaxDD} < 20\%$ | $\text{MaxDD} < 15\%$ |
| **シャープレシオ (年率)** | **$\text{Sharpe} > 0.70$**（第10.2章コスト全控除後） | **$\text{Sharpe} > 1.00$**（相関分散による底上げ） |
| **ウォークフォワード分析** | — | 過去5年学習 / 将来1年テストのローリング検証において、OOS期間の $70\%$ 以上でプラスリターンを維持 |

---