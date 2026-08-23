# **MQL5 システム仕様書: DFA-Smoother ハイブリッドトレーディングシステム**

## **1\. システム概要**

本システムは、金融時系列の自己相関特性（ロングメモリー / レジーム）を\*\*DFA (Detrended Fluctuation Analysis: 非トレンド変動解析)\*\*を用いてリアルタイムに評価し、市場環境（トレンド / レンジ / 遷移状態）に応じた最適なシグナル生成エンジンへ動的に切り替えるMetaTrader 5 (MQL5) 用の自動売買エキスパートアドバイザー（EA）である。

### **主な特徴**

> * **モジュール別 ON/OFF スイッチ**: DFA判定、レンジ戦略、トレンド戦略、ATRリスク管理のそれぞれを各パラメータグループの先頭（bool）で個別に有効化/無効化可能。バックテストでの各単体効果の検証や、特定相場環境専用EAとしての稼働に対応。  
> * **レジーム認識エンジン (DFA)**: 終値系列のリターンに対してDFAを適用し、スケーリング指数 \\alpha \\approx H（ハースト指数）を算出。ヒステリシス（不感帯）を導入して頻繁なレジーム切り替えを抑制（※ON/OFF選択可）。  
> * **レンジ適応エンジン (Super Smoother \+ RSI)**: ノイズ除去性能に優れ遅延の小さい 2-Pole Super Smoother Filter で平滑化した価格に対し短期RSIを計算し、平均回帰の逆張りトレードを行う（※ON/OFF選択可）。  
> * **トレンド適応エンジン (Dual ALMA Cross)**: 位相遅れを相殺した ALMA (Arnaud Legoux Moving Average) の短期・長期ラインのゴールデンクロス / デッドクロスによる追従型順張りトレードを行う（※ON/OFF選択可）。  
> * **堅牢なリスク管理**: ATR (Average True Range) をベースとしたハードストップ/テイクプロフィット（※ON/OFF選択可）およびレジーム変化時の即時クローズロジックを搭載。

## **2\. システムアーキテクチャ**

                          `[ 確定バー入力 (OnTick / Bar Close) ]`  
                                            `│`  
                                            `▼`  
                             `[ DFA有効判定 (InpUseDfa) ]`  
                               `┌────────────┴────────────┐`  
                         `(有効)│                         │(無効)`  
                               `▼                         ▼`  
                 `[ DFA レジーム判定モジュール ]      [ レジーム制限なし (ALL) ]`  
                               `│                         │`  
      `┌────────────────────────┼────────────────────────┐│`  
      `│ (H < H_low)            │ (H_low <= H <= H_high) │ (H > H_high)`  
      `▼                        ▼                        ▼│`  
`[レンジ戦略モジュール]    [遷移状態 (静観)]     [トレンド戦略モジュール]│`  
`(InpUseRangeStrategy)    - 新規エントリー停止   (InpUseTrendStrategy)   │`  
  `- Super Smoother       - 既存ポジは管理       - 短期 ALMA (Fast)     │`  
  `- Smoothed RSI                                - 長期 ALMA (Slow)     │`  
      `│                                             │                  │`  
      `└────────────────────────┬────────────────────┴──────────────────┘`  
                               `│`  
                               `▼`  
                   `[ エントリーシグナル判定 ]`  
                               `│`  
                               `▼`  
                 `[ ATRリスク管理 (InpUseAtrExit) ]`  
                 `- 有効: SL/TPをATR倍率で自動計算`  
                 `- 無効: SL/TP設定なし (手動/他指標決済)`  
                               `│`  
                               `▼`  
                   `[ 発注・ポジション実行 ]`

## **3\. アルゴリズム詳細仕様**

### **3.1. DFA (Detrended Fluctuation Analysis) モジュール**

（InpUseDfa \= true の場合に実行）  
DFAは非定常時系列における長期的自己相関（ハースト指数 H に相当）を正確に評価するアルゴリズムである。

> 1. **対数リターンの累積和算出**: 価格系列 P\_t から対数リターン r\_t \= \\ln(P\_t / P\_{t-1}) を計算し、その平均 \\bar{r} を差し引いた累積和 Y\_k を作成する。 Y\_k \= \\sum\_{i=1}^{k} (r\_i \- \\bar{r})  
> 2. **ウィンドウ分割と局所トレンド除去**: 全体データ長 N を長さ s の重複しないブロック（N\_s \= \\lfloor N/s \\rfloor）に分割する。各ブロック内で最小二乗法により1次多項式（直線） y\_{\\text{fit}}(k) をフィッティングし、トレンドを除去する。  
> 3. **変動関数 F(s) の算出**: F(s) \= \\sqrt{ \\frac{1}{N} \\sum\_{k=1}^{N} \\left( Y\_k \- y\_{\\text{fit}}(k) \\right)^2 }  
> 4. **スケーリング指数 \\alpha の回帰**: 複数のボックスサイズ s \\in \[s\_{\\min}, s\_{\\max}\] に対して \\ln F(s) と \\ln s をプロットし、その傾き \\alpha を最小二乗法で求める。  
   * \\alpha \< \\text{InpDfaThresholdLow}: レンジ（反発性・平均回帰特性）  
   * \\text{InpDfaThresholdLow} \\le \\alpha \\le \\text{InpDfaThresholdHigh}: ランダムウォーク（不感帯）  
   * \\alpha \> \\text{InpDfaThresholdHigh}: トレンド（持続性）

### **3.2. Super Smoother Filter モジュール (John Ehlers 2-Pole)**

（InpUseRangeStrategy \= true の場合に実行）  
高周波ノイズ（ホワイトノイズ）を急峻に減衰させつつ、群遅延を最小化するIIR（無限インパルス応答）フィルタ。

#### **漸化式:**

S\_t \= c\_1 \\cdot \\frac{P\_t \+ P\_{t-1}}{2} \+ c\_2 \\cdot S\_{t-1} \+ c\_3 \\cdot S\_{t-2}

#### **係数計算式:**

\\gamma \= \\frac{\\sqrt{2} \\cdot \\pi}{\\text{CutoffPeriod}} a \= \\exp(-\\gamma) c\_2 \= 2 \\cdot a \\cdot \\cos(\\gamma) c\_3 \= \-a^2 c\_1 \= 1.0 \- c\_2 \- c\_3

### **3.3. Smoothed RSI モジュール**

（InpUseRangeStrategy \= true の場合に実行）  
Super Smoother によって処理された平滑化価格 S\_t を用いてRSI（相対力指数）を計算する。高周波ノイズが除去されているため、通常の価格を用いるよりも過剰な振幅が抑えられ、ダマシが劇的に減少する。

#### **パラメータ標準値:**

> * **RSI Period**: 7 〜 9（平滑化済みのため短周期化）  
> * **Overbought (買われすぎ)**: 65 (通常の70より低く設定)  
> * **Oversold (売られすぎ)**: 35 (通常の30より高く設定)

### **3.4. ALMA (Arnaud Legoux Moving Average) モジュール**

（InpUseTrendStrategy \= true の場合に実行）  
ガウス分布に基づく加重平均を用い、重心パラメータ Offset により位相遅れを物理的に相殺するFIRフィルタ。

#### **計算式:**

\\text{ALMA}\_t \= \\frac{\\sum\_{i=0}^{W-1} P\_{t-i} \\cdot w\_i}{\\sum\_{i=0}^{W-1} w\_i} w\_i \= \\exp \\left( \-\\frac{(i \- m)^2}{2 \\cdot s^2} \\right)  
ここで、

> * W: Window Size (窓幅)  
> * m \= \\text{Offset} \\cdot (W \- 1\) (重心のシフト比率, 0.85推奨)  
> * s \= \\frac{W}{\\text{Sigma}} (ガウス分布の広がり, 6.0推奨)

## **4\. トレードロジック仕様**

### **4.1. モジュール制御とエントリー判定条件**

新規エントリー判定は、原則として\*\*バー確定時（1番バー: iClose(Symbol(), Period(), 1)）\*\*にのみ実行する。

#### **A. レンジ相場シグナル (Super Smoother \+ RSI)**

InpUseRangeStrategy \= true であり、かつ **( InpUseDfa \= false または \\alpha \< \\text{InpDfaThresholdLow} )** の場合に評価する。

> * **BUY エントリー**: Smoothed\_RSI\[1\] \< InpRsiOversold かつ Smoothed\_RSI\[1\] \> Smoothed\_RSI\[2\] (反転上昇を確認)  
> * **SELL エントリー**: Smoothed\_RSI\[1\] \> InpRsiOverbought かつ Smoothed\_RSI\[1\] \< Smoothed\_RSI\[2\] (反転下落を確認)

#### **B. トレンド相場シグナル (Dual ALMA Cross)**

InpUseTrendStrategy \= true であり、かつ **( InpUseDfa \= false または \\alpha \> \\text{InpDfaThresholdHigh} )** の場合に評価する。

> * **BUY エントリー (ゴールデンクロス)**: ALMA\_Fast\[2\] \<= ALMA\_Slow\[2\] かつ ALMA\_Fast\[1\] \> ALMA\_Slow\[1\]  
> * **SELL エントリー (デッドクロス)**: ALMA\_Fast\[2\] \>= ALMA\_Slow\[2\] かつ ALMA\_Fast\[1\] \< ALMA\_Slow\[1\]

#### **C. フィルタリング / 不感帯動作**

> * **DFA有効時**: \\text{InpDfaThresholdLow} \\le \\alpha \\le \\text{InpDfaThresholdHigh} の不感帯では新規エントリーを行わない（静観）。  
> * **各戦略無効時**: InpUseRangeStrategy \= false の場合はレンジシグナルを無視。InpUseTrendStrategy \= false の場合はトレンドシグナルを無視。

### **4.2. エグジット条件**

> 1. **ATR に基づくハードストップ / テイクプロフィット (InpUseAtrExit \= true)**:  
   * StopLoss \= エントリー価格 \\pm (\\text{ATR}\[1\] \\times \\text{InpAtrSlFactor})  
   * TakeProfit \= エントリー価格 \\mp (\\text{ATR}\[1\] \\times \\text{InpAtrTpFactor})  
   * ※ InpUseAtrExit \= false の場合、発注時のSL/TPは 0 (設定なし) とし、逆シグナルや手動/他管理による決済に依存する。  
> 2. **レジーム逆行時の強制決済 (InpUseDfa \= true 時のみ有効)**:  
   * レンジ戦略によるBUY/SELLポジションを保有中、\\alpha \> \\text{InpDfaThresholdHigh}（トレンド発生）に切り替わった場合は**即時全決済**。  
   * トレンド戦略によるBUY/SELLポジションを保有中、\\alpha \< \\text{InpDfaThresholdLow}（レンジ移行）または逆交差シグナルが発生した場合は**即時全決済**。

## **5\. MQL5 入力パラメータ定義 (input 変数)**

`//+------------------------------------------------------------------+`  
`//| Input Parameters                                                 |`  
`//+------------------------------------------------------------------+`  
`//--- 資金管理`  
`input group "=== 資金管理パラメータ ==="`  
`input double   InpRiskPercent       = 1.0;       // 1トレードあたりの許容リスク (%)`  
`input double   InpFixedLot          = 0.1;       // 固定ロット数 (InpRiskPercent=0の時に使用)`

`//--- DFA レジーム判定設定`  
`input group "=== DFA (レジーム判定) 設定 ==="`  
`input bool     InpUseDfa            = true;      // DFA レジーム判定を有効化`  
`input int      InpDfaWindowSize     = 300;       // DFAの計算対象バー数`  
`input double   InpDfaThresholdLow   = 0.45;      // レンジ判定閾値 (これ未満でレンジ)`  
`input double   InpDfaThresholdHigh  = 0.55;      // トレンド判定閾値 (これ超過でトレンド)`

`//--- レンジ戦略 (Super Smoother + RSI) 設定`  
`input group "=== レンジ戦略 (Super Smoother + RSI) ==="`  
`input bool     InpUseRangeStrategy  = true;      // レンジ戦略 (Super Smoother + RSI) を有効化`  
`input int      InpSSPeriod          = 14;        // Super Smoother 遮断周期`  
`input int      InpRsiPeriod         = 7;         // RSI 計算期間`  
`input double   InpRsiOverbought     = 65.0;      // RSI 買われすぎ境界値`  
`input double   InpRsiOversold       = 35.0;      // RSI 売られすぎ境界値`

`//--- トレンド戦略 (Dual ALMA Cross) 設定`  
`input group "=== トレンド戦略 (Dual ALMA) ==="`  
`input bool     InpUseTrendStrategy  = true;      // トレンド戦略 (Dual ALMA Cross) を有効化`  
`input int      InpAlmaFastWindow    = 9;         // 短期 ALMA 窓幅`  
`input int      InpAlmaSlowWindow    = 21;        // 長期 ALMA 窓幅`  
`input double   InpAlmaOffset        = 0.85;      // ALMA Offset (共通)`  
`input double   InpAlmaSigma         = 6.0;       // ALMA Sigma (共通)`

`//--- 出口戦略 (ATR Risk Management)`  
`input group "=== 出口戦略 (ATR) ==="`  
`input bool     InpUseAtrExit        = true;      // ATR 出口戦略 (SL/TP) を有効化`  
`input int      InpAtrPeriod         = 14;        // ATR 期間`  
`input double   InpAtrSlFactor       = 1.5;       // ストップロス (ATR倍率)`  
`input double   InpAtrTpFactor       = 3.0;       // テイクプロフィット (ATR倍率)`

## **6\. MQL5 実装における技術的要件**

### **6.1. 配列管理とインデックス設定**

MQL5 では、カスタムインディケータおよびEA内部の計算バッファにおいて時系列インデックス（0 番目が最新バー）を揃えるため、使用する全動的配列に対して明示的に ArraySetAsSeries(array, true) を呼び出すこと。

### **6.2. スイッチによる計算最適化**

無駄なCPU演算を減らすため、ON/OFFフラグに応じて非アクティブなモジュールの計算をスキップすること。

> * InpUseDfa \= false の場合、重いDFA演算ループ全体をスキップ。  
> * InpUseRangeStrategy \= false の場合、Super SmootherおよびSmoothed RSIの計算をスキップ。  
> * InpUseTrendStrategy \= false の場合、ALMA配列の計算をスキップ。  
> * InpUseAtrExit \= false の場合、ATR値の計算をスキップ。

### **6.3. 発注・ポジション管理クラス**

MQL5 標準ライブラリの \<Trade\\Trade.mqh\> (CTrade クラス) を使用し、マジックナンバー (SetExpertMagicNumber) および許容スリッページを設定して発注をカプセル化すること。

### **6.4. 内部データ計算構造体の例**

`struct SSystemState`  
  `{`  
   `double            alpha;          // 最新DFA指数`  
   `double            super_smoother; // 最新Super Smoother値`  
   `double            smoothed_rsi;   // 最新Smoothed RSI値`  
   `double            alma_fast;      // 最新短期ALMA`  
   `double            alma_slow;      // 最新長期ALMA`  
   `double            atr;            // 最新ATR値`  
   `ENUM_REGIME_TYPE  regime;         // REGIME_RANGE, REGIME_TREND, REGIME_TRANSITION, REGIME_ALL`  
  `};`

## **7\. バックテストおよび検証手順**

> 1. **各モジュール単体バックテスト (アビリティ検証)**:  
   * InpUseDfa \= false, InpUseTrendStrategy \= false に設定し、レンジ戦略単体のパフォーマンス（純粋なSuper Smoother \+ RSI効果）を検証する。  
   * InpUseDfa \= false, InpUseRangeStrategy \= false に設定し、トレンド戦略単体のパフォーマンス（純粋なDual ALMA Cross効果）を検証する。  
> 2. **DFAフィルター併用バックテスト (ハイブリッド検証)**:  
   * 全モジュールを true にし、DFAによる環境認識フィルタが各単体戦略のドローダウンをどれだけ削減できているかを比較評価する。  
> 3. **パラメータ最適化 (Optimization)**:  
   * 対象通貨ペア: EURUSD, USDJPY (5分足 / 15分足)  
   * 最適化対象: InpDfaWindowSize (200〜400), InpSSPeriod (10〜18), InpAlmaFastWindow (7〜12)  
   * 評価基準: シャープレシオの最大化、最大ドローダウンの抑制（\< 15%）