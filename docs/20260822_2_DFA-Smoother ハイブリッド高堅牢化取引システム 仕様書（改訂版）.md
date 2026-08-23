# **DFA-Smoother ハイブリッド高堅牢化取引システム 仕様書（改訂版）**

## **1\. システム概要と設計思想**

本システム「DFA-Smoother ハイブリッド」は、金融時系列のフラクタル統計解析に基づく市場レジーム判別層と、デジタル信号処理（DSP）による低遅延フィルタ層を統合した、MetaTrader 5 (MQL5) 向け自動売買システムである。  
相場が定常的な平均回帰（レンジ）特性を示す局面と、非定常なトレンド持続特性を示す局面を統計的に分離し、それぞれのレジームに特化した低遅延サブ戦略へ資金を最適配分する。  
`[System Layer Architecture Table]`

| 階層 | モジュール名 | 適用手法 | 主要機能 |
| :---- | :---- | :---- | :---- |
| **Layer 1** | 市場レジーム判別層 | DFA（非トレンド変動解析）+ ヒステリシス制御 | フラクタルスケーリング指数 \\alpha の推定と状態遷移の安定化 |
| **Layer 2** | デジタル信号処理層 | John Ehlers 2-Pole Super Smoother Filter | 2次Butterworth低域通過フィルタによる高周波ノイズ除去 |
| **Layer 3** | シグナル生成層 | レンジ逆張り（Smoothed RSI）/ トレンド順張り（Dual ALMA） | レジーム適合型エントリーシグナルの生成 |
| **Layer 4** | リスク・執行管理層 | ATRボラティリティ出口 \+ スプレッド/摩擦フィルター | 動的SL/TP管理およびレジーム反転時の保護決済 |

## **2\. 数理モデルおよびアルゴリズム定義**

### **2.1 DFA（Detrended Fluctuation Analysis）レジーム判別モジュール**

対数リターン時系列の局所トレンドを除去し、自己相関構造を表すスケーリング指数 \\alpha（ハースト指数 H に相当）を算出する。

> 1. **対数リターンの累積偏差系列の生成**: 価格系列 P\_t から対数リターン r\_i \= \\ln(P\_i / P\_{i-1}) を計算し、窓幅 N における平均 \\bar{r} を用いて累積偏差プロファイル Y\_k を構築する。 Y\_k \= \\sum\_{i=1}^{k} (r\_i \- \\bar{r}), \\quad k \= 1, 2, \\dots, N  
> 2. **サブ区間分割と局所トレンド除去**: プロファイル Y\_k を長さ s の N\_s \= \\lfloor N/s \\rfloor 個の非重複区間に分割する。区間 \\nu における1次最小二乗多項式近似トレンドを y\_{\\nu}(i) とし、残差二乗平均を算出する。 F^2(\\nu, s) \= \\frac{1}{s} \\sum\_{i=1}^{s} \\left\[ Y\_{(\\nu-1)s \+ i} \- y\_{\\nu}(i) \\right\]^2  
> 3. **変動関数 F(s) の算出**: 全サブ区間について平均化を行い、スケール s における変動関数を求める。 F(s) \= \\sqrt{\\frac{1}{N\_s} \\sum\_{\\nu=1}^{N\_s} F^2(\\nu, s)}  
> 4. **スケーリング指数 \\alpha の推定**: \\ln F(s) と \\ln s の線形回帰直線の傾きから指数 \\alpha を推定する。 F(s) \\propto s^\\alpha \\implies \\ln F(s) \= \\alpha \\ln s \+ C  
> 5. **有限サンプルバイアス補正と動的閾値**: 有限窓幅（N=300 等）における推定誤差に対応するため、サロゲートデータ検定または適応型信頼区間を採用する。  
   * \\alpha \< \\alpha\_{\\text{low}}: 反持続性・平均回帰相場（レンジレジーム）  
   * \\alpha \> \\alpha\_{\\text{high}}: 持続性・トレンド相場（トレンドレジーム）  
   * \\alpha\_{\\text{low}} \\le \\alpha \\le \\alpha\_{\\text{high}}: ランダムウォーク（不感帯・中立レジーム）

\#\#\# 2.2 レジーム遷移のヒステリシス（不感帯ループ）機構  
境界値近傍での \\alpha の微小振動に伴う不要な戦略切り替えや強制決済（チャーン）を抑止するため、2値判定ではなくヒステリシス状態遷移モデルを実装する。  
`[Regime State Transition Table]`

| 現在の状態 | 遷移先状態 | 判定条件 | 動作 |
| :---- | :---- | :---- | :---- |
| **Neutral（中立）** | Range（レンジ） | \\alpha \< \\text{InpDfaThresholdLow} | レンジ戦略を起動 |
| **Neutral（中立）** | Trend（トレンド） | \\alpha \> \\text{InpDfaThresholdHigh} | トレンド戦略を起動 |
| **Range（レンジ）** | Neutral / Trend | \\alpha \> (\\text{I\[span\_22\](start\_span)\[span\_22\](end\_span)npDfaThresholdLow} \+ \\Delta\_{\\text{hyst}}) | レンジ戦略を停止・待機 |
| **Trend（トレンド）** | Neutral / Range | \\alpha \< (\\text{InpDfaThresholdHigh} \- \\Delta\_{\\text{hyst}}) | トレンド戦略を停止・待機 |

※ デフォルト値: \\text{InpDfaThresholdLow} \= 0.45, \\text{InpDfaThresholdHigh} \= 0.55, ヒステリシス幅 \\Delta\_{\\text{hyst}} \= 0.03。

### **2.3 2-Pole Super Smoother Filter（John Ehlers）**

従来の単純移動平均（SMA）や指数移動平均（EMA）に見られる群遅延とリップル（高周波通過）を排除した2次IIR低域通過フィルタ。

> * **伝達漸化式**: S\_\[span\_24\](start\_span)\[span\_24\](end\_span)t \= c\_1 \\cdot \\frac{P\_t \+ P\_{t-1}}{2} \+ c\_2 \\cdot S\_{t-1} \+ c\_3 \\cdot S\_{t-2}  
> * **フィルタ係数導出**: \\gamma \= \\frac{\\sqrt{2} \\pi}{\\text{CutoffPeriod}}, \\qu\[span\_18\](start\_span)\[span\_18\](end\_span)\[span\_20\](start\_span)\[span\_20\](end\_span)ad a \= \\exp(-\\gamma) c\_2 \= 2 a \\cos(\\gamma), \\quad c\_3 \= \-a^2, \\quad c\_1 \= 1 \- c\_2 \- c\_3

### **2.4 Dual ALMA（Arnaud Legoux Moving Average）**

ガウス分布窓関数を用い、オフセットパラメータによって位相遅れを相殺した適応型移動平均線。

> * **計算式**: \\text{ALMA}\_t \= \\frac{\\sum\_{i=0}^{W-1} P\_{t-i} \\cdot w\_i}{\\sum\_{i=0}^{W-1} w\_i}  
> * **ガウス加重重み**: w\_i \= \\exp \\left( \-\\frac{(i \- m)^2}{2 s^2} \\right), \\quad m \= \\text{Offset} \\cdot (W \- 1), \\quad s \= \\frac{W}{\\text{Sigma}}

## **3\. 売買ルールおよびリスク管理ロジック**

本システムの判定処理は、計算負荷の低減と再現性確保のため、原則として\*\*バー確定時（New Bar Event）\*\*にのみ実行される。

### **3.1 レンジ戦略（Super Smoother \+ RSI）**

> * **対象系列**: 原生価格系列 P\_t を 2-Pole Super Smoother Filter に通した平滑化系列 S\_t。  
> * **オシレータ**: S\_t に基づく7期間RSI（Smoothed RSI）。  
> * **買いエントリー条件**:  
  1. DFA状態が「レンジレジーム」であること。  
  2. Smoothed RSI が過売り水準（35以下）から上向き反転（\\text{RSI}\_{t-1} \\le 35 かつ \\tex\[span\_25\](start\_span)\[span\_25\](end\_span)t{RSI}\_t \> \\text{RSI}\_{t-1}）。  
> * \**売りエントリー条件*\*:  
  1. DFA状態が「レンジレジーム」であること。  
  2. Smoothed RSI が過買い水準（65以上）から下向き反転（\\text{RSI}\_{t-1} \\ge 65 かつ \\text{RSI}\_t \< \\text{RSI}\_{t-1}）。

### **3.2 トレンド戦略（Dual ALMA Cross）**

> * **オシレータ**: 短期ALMA（期間9）および長期ALMA（期間21）。  
> * **買いエントリー条件**:  
  1. DFA状態が「トレンドレジーム」であること。  
  2. 短期ALMAが長期ALMAをゴールデンクロス（\\text{ALMA}^\[span\_30\](start\_span)\[span\_30\](end\_span){\\text{Fast}}\_{t-1} \\le \\text{ALMA}^{\\text{Slow}}\_{t-1} かつ \\text{ALMA}^{\\te\[span\_31\](start\_span)\[span\_31\](end\_span)xt{Fast}}\_t \> \\text{ALMA}^{\\text{Slow}}\_t）。  
> * *売りエントリー条件*:  
  1. DFA状態が「トレンドレジーム」であること。  
  2. 短期ALMAが長期ALMAをデッドクロス（\\text{ALMA}^{\\text{Fast}}\_{t-1} \\ge \\text{ALMA}^{\\text{Slow}}\_{t-1} かつ \\text{ALMA}^{\\text\[span\_33\](start\_span)\[span\_33\](end\_span){Fast}}\_t \< \\text{ALMA}^{\\text{Slow}}\_t）。

### **3.3 リスク管理と決済ロジック**

> * **動的ATRエグジット**:  
  * 買いポジション: \\text{StopLoss} \= \\text{EntryPrice} \- (\\text{ATR} \\times \\text{InpAtrSlFactor}) \\text{TakeProfit}\[span\_35\](start\_span)\[span\_35\](end\_span) \= \\text{EntryPrice} \+ (\\text{ATR} \\times \\text{InpAtrTpFactor})  
  * 売りポジション: \\text{StopLoss} \= \\text{EntryPrice} \+ (\\text{ATR} \\times \\text{InpAtrSlFactor}) \\text{TakeProfit} \= \\text{EntryPrice} \- (\\text{ATR} \\times \\text{InpAtrTpFactor})  
> * **レジーム反転決済（フェイルセーフ）**:  
  * レンジ保有中に \\alpha \> \\text{InpDfaThresholdHigh} へ急変した場合、即時成行決済。  
  * トレンド保有中に \\alpha \< \\text{InpDfaThresholdLow} へ急変した場合、即時成行決済。  
> * **執行保護フィルター（スプレッド・摩擦制御）**:  
  * スプレッドが過去20期間平均スプレッドの2.0倍を超過している場合、新規発注およびレジーム反転決済を一時凍結し、不要なスリッページ損失を防ぐ。 \* エントリー後、最低3バーはレジーム判定による強制決済を猶予する「最小保有期間（Minimum Hold Lockout）」を設定し、ノイズによる往復売買を防止する。

## **4\. システムパラメータ一覧（Input Variables）**

| カテゴリ | 変数名 | データ型 | デフォルト値 | 設定範囲 / 説明 |
| :---- | :---- | :---- | :---- | :---- |
| **全般・資金管理** | InpMagicNumber | ulong | 20260822 | EA識別用マジックナンバー |
|  | InpRis\[span\_101\](start\_span)\[span\_101\](end\_span)\[span\_105\](start\_span)\[span\_105\](end\_span)kPercent | double | 1.0 | 1トレードあたりの許容リスク（口座残高%） |
|  | InpFixedLot | double | 0.0 | 固定ロット（0.0でリスク%計算を優先） |
|  | InpMaxSpreadPip | double | 2.5 | 許容最大スプレッド（pips） |
| **DFAレジーム** | InpUseDf\[span\_96\](start\_span)\[span\_96\](end\_span)a | bool | true | DFAレジーム判別の有効化フラグ |
|  | InpDfaWindowSize | int\[span\_38\](start\_span)\[span\_38\](end\_span) | 300 | DFA計算ローリング窓幅（バー本数） |
|  | InpDfaThresholdLow | d\[span\_39\](start\_span)\[span\_39\](end\_span)ouble | 0.45 | レンジ判定上限閾値（\\alpha\_{\\text{low}}） |
|  | InpDfaThresholdHigh | double | 0.55 | トレンド判定下限閾値（\\alpha\_{\\text{high}}） |
|  |  | InpDfaHysteresis | double | 0.03 |
| **レンジ戦略** | InpUseRangeStrategy | bool | true | レンジ戦略モジュールの有効化 |
|  | InpSSPeriod | int | 14 | Super Smoother カットオフ周期 |
|  | InpRs\[span\_43\](start\_span)\[span\_43\](end\_span)iPeriod | int | 7 | 平滑化系列に対するRSI計算期間 |
|  | InpRsiOverbought | double | 65.0 | レンジ逆張り売り閾値 |
|  | InpRsiOversold | double | 35.0 | レンジ逆張り買い閾値 |
| **トレンド戦略** | InpUseTrendStrategy | bool | true | トレンド戦略モジュールの有効化 |
|  | InpAlmaFastWindow | int | 9 | 短期ALMA窓幅 |
|  | InpAlmaSlowWindow | int | 21 | 長期ALMA窓幅 |
|  | InpAlmaOffset | double | 0.85 | ALMAガウス中心オフセット |
|  | InpAlmaSigma | double | 6.0 | ALMAガウス分布スケール（シグマ） |
| **リスク・決済** | InpUseAtrExit | bool | tr\[span\_92\](start\_span)\[span\_92\](end\_span)\[span\_94\](start\_span)\[span\_94\](end\_span)ue | ATR動的出口の有効化 |
|  | InpAtrPeriod | int | 14 | ATR計算期間 |
|  | InpAtrSlFactor | double | 1.5 | ATR損切り乗数 |
|  | InpAtrTpFactor | double | 3.0 | ATR利確乗数 |
|  | InpMinHoldBars | int | 3 | エントリー後最小保有バー数（ノイズ保護） |

## **5\. MQL5 実装アーキテクチャ仕様**

\#\#\# 5.1 イベント駆動構造と状態管理  
MQL5プログラムの OnTick()\[span\_87\](start\_span)\[span\_87\](end\_span)\[span\_90\](start\_span)\[span\_90\](end\_span) 内で毎回重いDFAループを処理することを防ぎ、CPU負荷とレイテンシを抑制する構造とする。

> * **バー確定検知（New Bar Detection）**: 静的変数 static datetime \[span\_56\](start\_span)\[span\_56\](end\_span)last\_bar\_time を保持し、iTime(\_Symbol, \_Period, 0\) の更新時のみ指標計算とシグナル判定を実行する。  
> * **配列インデックスの統一**: 時系列配列にはすべて ArraySetAsSeries(buffer, true) を宣言し、最新バーをインデックス0として統一的に扱う。  
> * **状態管理構造体**: システムの内部状態は SSystem\[span\_102\](start\_span)\[span\_102\](end\_span)\[span\_106\](start\_span)\[span\_106\](end\_span)State 構造体を通じて一元的に追跡する。

`enum ENUM_REGIME_STATE`  
`{`  
   `REGIME_NEUTRAL = 0,`  
   `REGIME_RANGE   = 1,`  
   `REGIME_TREND   = 2`  
`};`

`struct SSystemState`  
`{`  
   `ENUM_REGIME_STATE current_regime;`  
   `double            alpha_value;`  
   `double            ss_rsi_current;`  
   `double            ss_rsi_prev;`  
   `double            alma_fast[span_57](start_span)[span_57](end_span)_current;`  
   `double            alma_fast_prev;`  
   `double            alma_slow_current;`  
   `double            alma_slow_prev;`  
   `double            atr_value;`  
   `datetime          last_evaluation_time;`  
   `int               bars_in_position;`  
`};`

### **5.2 トレード執行クラスの適用**

> * 標準ライブラリ \#include \<Trade\\Trade.mqh\> の CTrade クラスインスタンスを使用する。  
> * 初期化関数 OnInit() において、trade.SetExpe\[span\_103\](start\_span)\[span\_103\](end\_span)\[span\_107\](start\_span)\[span\_107\](end\_span)rtMagicNumber(InpMagicNumber) およびスリッページ許容幅を設定する。  
> * ポジションクエリには \#include \<Trade\\Position\[span\_104\](start\_span)\[span\_104\](end\_span)\[span\_108\](start\_span)\[span\_108\](end\_span)Info.mqh\> の CPositionInfo を使用し、不要なループ処理を排除する。

## **6\. 過剰適合抑止プロトコルとバックテスト検証基準**

Bailey et al. (2014) の「*The Probability of Backtest Overfitting (PBO)*」およびLópez de Pradoの検証理論に基づき、本システムの最適化と堅牢性評価は以下の4段階の手順に従って実施する。  
`[Valida[span_115](start_span)[span_115](end_span)[span_116](start_span)[span_116](end_span)[span_117](start_span)[span_117](end_span)tion Protocol Flow Table]`

| ステップ | 検証種別 | 目的と評価基準 | 合否判定閾値 |
| :---- | :---- | :---- | :---- |
| **Step 1** | 単体モジュール検証 | レンジ戦略・トレンド戦略を単体で動かし、Alpha（固有優位性）の存在を確認する。 | 各戦略単体でプロフィットファクター \> 1.10 |
| **Step 2** | ウォークフォワード分析 (WFA) | 最適化期間（IS: 12ヶ月）と検証期間（OOS: 3ヶ月）をローリングさせ、パラメータの持続性を検証する。 | Walk-Forward Efficiency (WFE) \> 60% |
| **Step 3** | PBO検定（過剰適合確率） | グリッド最適化結果を分割クロスバリデーション（CPCV）にかけ、PBOを定量化する。 | PBO \< 0.20（過剰適合確率20%未満） |
| *Step 4* | 執行ストレステスト | 想定スプレッドを2倍、スリッページを20ms付与した環境での耐性を評価する。 | 最大ドローダウン \< 15%、シャープレシオ \> 1.20 |

> * **推奨対象通貨ペア・時間枠**: EURUSD, USDJPY / 5分足（M5）, 15分足（M15）  
> * **履歴データ要件**: ティッククオリティ 99.9% の高品質ヒストリカルデータを使用すること。

#### **引用文献**

1\. , https://drive.google.com/open?id=1ec8Un6YsVi2ybonCyIkWEpchu5fkg2XTicvEB2Q8UkM 2\. README.md \- lutfi-zain/quant-lttd-ichimoku \- GitHub, https://github.com/lutfi-zain/quant-lttd-ichimoku/blob/main/README.md 3\. Classical and modified rescaled range analysis: Sampling properties under heavy tails \- EconStor, https://www.econstor.eu/bitstream/10419/83365/1/618415785.pdf 4\. MF-toolkit: A High-Performance Python Library for Multifractal Analysis with Automated Crossover Detection, Source Identification and Application to Gravitational Waves Data. \- arXiv, https://arxiv.org/html/2604.16257v1 5\. Long-range Auto-correlations in Limit Order Book Markets: Inter- and Cross-event Analysis \- arXiv, https://arxiv.org/pdf/1711.03534 6\. (PDF) Revisiting detrended fluctuation analysis \- ResearchGate, https://www.researchgate.net/publication/221704088\_Revisiting\_detrended\_fluctuation\_analysis 7\. Detrended Fluctuation Analysis and Adaptive Fractal Analysis of Stride Time Data in Parkinson's Disease: Stitching Together Short Gait Trials \- PMC, https://pmc.ncbi.nlm.nih.gov/articles/PMC3900445/ 8\. Rescaled Range Analysis and Detrended Fluctuation Analysis: Finite Sample Properties and Confidence Intervals \- ResearchGate, https://www.researchgate.net/publication/227360892\_Rescaled\_Range\_Analysis\_and\_Detrended\_Fluctuation\_Analysis\_Finite\_Sample\_Properties\_and\_Confidence\_Intervals 9\. Detecting Long-range Correlations with Detrended Fluctuation Analysis \- ResearchGate, https://www.researchgate.net/publication/222572588\_Detecting\_Long-range\_Correlations\_with\_Detrended\_Fluctuation\_Analysis 10\. Forex Trading Bot Development: MT4/MT5 Expert Advisor Guide \- Nadcab Labs, https://www.nadcab.com/blog/forex-trading-bot-development-mt4-mt5-guide 11\. Smooth — indsl 8.9.0 documentation \- Cognite's Industrial Data Science Library, https://indsl.docs.cognite.com/smooth.html 12\. MetaTrader 5 Machine Learning Blueprint (Part 5): Sequential Bootstrapping—Debiasing Labels, Improving Returns \- MQL5 Articles, https://www.mql5.com/en/articles/20059