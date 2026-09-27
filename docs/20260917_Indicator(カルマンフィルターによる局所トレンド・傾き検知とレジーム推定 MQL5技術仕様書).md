# カルマンフィルターによる局所トレンド・傾き検知とレジーム推定 MQL5技術仕様書

## 1. 概要とMetaTrader 5におけるアプローチ

MetaTrader 5（MQL5）における従来のトレンド検知手法（ADX、移動平均の傾き、MACDなど）は、過去バーの平滑化計算に伴う**位相遅延（ラグ）**が不可避であり、相場の急変・転換初動の遅れやレンジ相場での往復ビンタ（Whipsaw）が最大の課題でした。

本手法では、時系列計量経済学における**局所線形トレンドモデル（Local Linear Trend Model）**を採用し、価格を「真の平滑価格水準（$\mu$）」と「局所的な変化率・速度（傾き $\beta$）」に分解します。カルマンフィルターの逐次ベイズ更新により、ラグを極小に抑えつつノイズを除去し、同時に得られる**傾きの推定誤差共分散（不確実性）**を用いて統計的にトレンド相場とレンジ相場を判定します。

本ドキュメントは、MQL5環境でノンリペイントかつ超高速（計算量 $O(1)$）に動作するカスタムインジケーターの数理設計、完全なソースコード、およびEA（エキスパートアドバイザー）連携仕様を網羅した完全版仕様書です。

---

## 2. 状態空間モデルの定式化

観測値 $y_t$（市場の足の適用価格）の背後に、直接観測できない2次元の状態ベクトル $x_t$ を仮定します。

$$
x_t = \begin{bmatrix} \mu_t \\ \beta_t \end{bmatrix}
$$

* $\mu_t$: 時点 $t$ における真の平滑化価格水準
* $\beta_t$: 時点 $t$ における局所的な傾き（1足あたりのモメンタム・速度成分）

### (1) 状態方程式（システムモデル）

価格水準 $\mu_t$ は前回の水準に前回の傾き $\beta_{t-1}$ を加算したものとして遷移し、傾き $\beta_t$ はランダムウォークとしてモデル化します。

$$
\begin{bmatrix} \mu_t \\ \beta_t \end{bmatrix}
= \begin{bmatrix} 1 & 1 \\ 0 & 1 \end{bmatrix} \begin{bmatrix} \mu_{t-1} \\ \beta_{t-1} \end{bmatrix} + \begin{bmatrix} w_{\mu, t} \\ w_{\beta, t} \end{bmatrix}
$$

* 状態遷移行列: $F = \begin{bmatrix} 1 & 1 \\ 0 & 1 \end{bmatrix}$
* プロセスノイズ共分散行列: $Q = \begin{bmatrix} q_\mu & 0 \\ 0 & q_\beta \end{bmatrix}$

### (2) 観測方程式

市場価格 $y_t$ は、真の水準 $\mu_t$ にヒゲやマイクロストラクチャノイズ等の観測ノイズ $v_t$ が加算されて観測されます。

$$
y_t = \begin{bmatrix} 1 & 0 \end{bmatrix} \begin{bmatrix} \mu_t \\ \beta_t \end{bmatrix} + v_t
$$

* 観測行列: $H = \begin{bmatrix} 1 & 0 \end{bmatrix}$
* 観測ノイズ分散: $R = \sigma_v^2$

---

## 3. 逐次更新アルゴリズム（MQL5向けスカラー展開）

観測行列が $H = \begin{bmatrix} 1 & 0 \end{bmatrix}$ であるため、逆行列演算を含むカルマンフィルタの行列計算はすべて初等代数（スカラー四則演算）に陽に展開可能です。外部線形代数ライブラリを一切介さず、1足あたり数ナノ秒で処理されます。

### ステップ 1: 予測ステップ (Time Update)

状態ベクトルの事前予測:
$$
\mu_{t|t-1} = \mu_{t-1|t-1} + \beta_{t-1|t-1}
$$
$$
\beta_{t|t-1} = \beta_{t-1|t-1}
$$

誤差共分散行列 $P$ の事前予測 ($P_{t|t-1} = F P_{t-1|t-1} F^T + Q$):
$$
P_{00, \text{pred}} = P_{00} + 2 P_{01} + P_{11} + q_\mu
$$
$$
P_{01, \text{pred}} = P_{01} + P_{11}
$$
$$
P_{11, \text{pred}} = P_{11} + q_\beta
$$

### ステップ 2: 更新ステップ (Measurement Update)

観測残差 $e_t$ と残差分散 $S_t$:
$$
e_t = y_t - \mu_{t|t-1}
$$
$$
S_t = P_{00, \text{pred}} + R
$$

カルマンゲイン $K_t = \begin{bmatrix} K_0 \\ K_1 \end{bmatrix}$:
$$
K_0 = \frac{P_{00, \text{pred}}}{S_t}, \quad K_1 = \frac{P_{01, \text{pred}}}{S_t}
$$

状態ベクトルの事後推定:
$$
\mu_{t|t} = \mu_{t|t-1} + K_0 e_t
$$
$$
\beta_{t|t} = \beta_{t|t-1} + K_1 e_t
$$

誤差共分散行列の事後更新 ($P_{t|t} = (I - K_t H) P_{t|t-1}$):
$$
P_{00} = P_{00, \text{pred}} - K_0 P_{00, \text{pred}}
$$
$$
P_{01} = P_{01, \text{pred}} - K_0 P_{01, \text{pred}}
$$
$$
P_{11} = P_{11, \text{pred}} - K_1 P_{01, \text{pred}}
$$

ここで得られる $\hat{\beta}_t = \beta_{t|t}$ が「推定された局所的な傾き」、$P_{11}$ が「傾きの推定誤差分散 $\text{Var}(\hat{\beta}_t)$」となります。

---

## 4. レジーム判定ロジックとヒステリシス設計

### (1) 標準化モメンタム強度スコア（$z$ スコア）

傾きをその推定誤差で除算し、無次元の標準化スコアを算出します。

$$
z_t = \frac{\hat{\beta}_t}{\sqrt{\text{Var}(\hat{\beta}_t)}} = \frac{\beta_{t|t}}{\sqrt{\max(P_{11}, 10^{-12})}}
$$

* **実務上の留意点**: 理論上は正規分布の検定統計量ですが、金融時系列は非定常かつファットテールであるため、「統計的有意性」というより**「不確実性を考慮したモメンタム強度指標」**として扱います。

### (2) ヒステリシス状態遷移マシン（チャタリング防止）

単一閾値での判定は、閾値境界での微小な価格変動によって毎足レジームが入れ替わるチャタリングを引き起こします。突入閾値（`InpZEnter`）と離脱閾値（`InpZExit`）を分けたヒステリシス構造を採用します（$z_{\text{enter}} > z_{\text{exit}} \ge 0$）。

```
                ┌─────────────────────────────────┐
                │          z >= z_enter           │
                ▼                                 │
         ┌─────────────┐                          │
         │             │       z <= z_exit        │
         │  UP_TREND   │─────────────────────┐    │
         │             │                     ▼    │
         └─────────────┘               ┌───────────┐
             ▲     │                   │           │
             │     │ Direct Reversal   │   RANGE   │
             │     │ (z <= -z_enter)   │           │
             │     ▼                   └───────────┘
             │  ┌─────────────┐              ▲    │
             │  │             │              │    │
             │  │ DOWN_TREND  │──────────────┘    │
             │  │             │  z >= -z_exit     │
             │  └─────────────┘                   │
             │         │                          │
             └─────────┴──────────────────────────┘
              Direct Reversal        z <= -z_enter
              (z >= z_enter)
```

#### 急反転時のドテン制御（`InpAllowDirectReversal`）
* **`true`（即時ドテン）**: 上昇トレンド中に急落して $z \le -z_{\text{enter}}$ に達した場合、RANGEを経由せず1足で下降トレンドに切り替えます。トレンドフォロー型EAに適しています。
* **`false`（フラット化優先）**: 急反転時でも一旦 `RANGE`（手仕舞い・ノーポジション）を経由させます。急変時の安全性を重視する運用に適しています。

---

## 5. MQL5 完全実装ソースコード

MetaTrader 5のインジケーターフォルダ（`MQL5/Indicators/`）に配置してコンパイル可能な完全なコードです。入力パラメータ `InpAppliedPrice` に応じた適切な価格抽出ロジックを含みます。

```cpp
//+------------------------------------------------------------------+
//|                                        KalmanRegimeEstimator.mq5 |
//|                                  Copyright 2026, Quant Research  |
//|                        Local Linear Trend Model Regime Indicator |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Quant Research"
#property link        "https://www.mql5.com"
#property version     "1.01"
#property description "カルマンフィルター（局所線形トレンドモデル）によるレジーム判定インジケーター"

#property indicator_separate_window
#property indicator_buffers 4
#property indicator_plots   1

// プロット1: Zスコアのカラーライン表示
#property indicator_label1  "Kalman Z-Score"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrDodgerBlue, clrCrimson, clrDarkGray
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

// レジーム定義定数
#define REGIME_UP     1.0   // 上昇トレンド
#define REGIME_DOWN  -1.0   // 下降トレンド
#define REGIME_RANGE  0.0   // レンジ相場

// カラーインデックス定義
#define COLOR_UP      0     // clrDodgerBlue
#define COLOR_DOWN    1     // clrCrimson
#define COLOR_RANGE   2     // clrDarkGray

//--- 入力パラメータ
input group "=== カルマンフィルター パラメータ ==="
input double InpQMu                 = 1e-5;       // プロセスノイズ (水準: q_mu)
input double InpQBeta               = 1e-5;       // プロセスノイズ (傾き: q_beta)
input double InpR                   = 1.0;        // 観測ノイズ (R)
input double InpInitialP            = 1000.0;     // 初期誤差共分散スケール (P0)

input group "=== レジーム判定 パラメータ ==="
input double InpZEnter              = 2.0;        // トレンド突入閾値 (z_enter)
input double InpZExit               = 1.0;        // トレンド離脱閾値 (z_exit)
input bool   InpAllowDirectReversal = true;       // 急反転時の即時ドテン許可
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // 適用価格

// 各バーの状態を完全に隔離保持する構造体（状態汚染の防止）
struct KalmanState
{
   double mu;             // 平滑化価格水準
   double beta;           // 推定傾き
   double p00;            // 共分散 P[0,0]
   double p01;            // 共分散 P[0,1]
   double p11;            // 共分散 P[1,1]
   double regime;         // レジーム値 (1.0, -1.0, 0.0)
   bool   initialized;    // 初期化完了フラグ
};

// インジケーターバッファ
double BufferZScore[];    // Plot 0: Zスコア値
double BufferColor[];     // Plot 0 Color: 描画色インデックス (0:UP, 1:DOWN, 2:RANGE)
double BufferSlope[];     // Calculation 2: 傾き実数値 (EA取得用)
double BufferRegime[];    // Calculation 3: レジーム値 (EA取得用)

// 全バーの確定状態履歴バッファ
KalmanState StateHistory[];

//+------------------------------------------------------------------+
//| 適用価格取得ヘルパー関数                                         |
//+------------------------------------------------------------------+
double GetAppliedPrice(const ENUM_APPLIED_PRICE price_type,
                       const double &open[],
                       const double &high[],
                       const double &low[],
                       const double &close[],
                       const int index)
{
   switch(price_type)
   {
      case PRICE_CLOSE:    return close[index];
      case PRICE_OPEN:     return open[index];
      case PRICE_HIGH:     return high[index];
      case PRICE_LOW:      return low[index];
      case PRICE_MEDIAN:   return (high[index] + low[index]) * 0.5;
      case PRICE_TYPICAL:  return (high[index] + low[index] + close[index]) / 3.0;
      case PRICE_WEIGHTED: return (high[index] + low[index] + 2.0 * close[index]) * 0.25;
      default:             return close[index];
   }
}

//+------------------------------------------------------------------+
//| 初期化関数                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   // 入力バリデーション
   if(InpZExit < 0.0)
   {
      Print("[Error] InpZExit は 0.0 以上である必要があります。");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpZEnter <= InpZExit)
   {
      Print("[Error] ヒステリシス形成のため InpZEnter > InpZExit である必要があります。");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpQMu <= 0.0 || InpQBeta <= 0.0 || InpR <= 0.0 || InpInitialP <= 0.0)
   {
      Print("[Error] ノイズパラメータおよび初期共分散は正の値である必要があります。");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // バッファバインド
   SetIndexBuffer(0, BufferZScore, INDICATOR_DATA);
   SetIndexBuffer(1, BufferColor,  INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, BufferSlope,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, BufferRegime, INDICATOR_CALCULATIONS);

   IndicatorSetInteger(INDICATOR_DIGITS, 2);

   string short_name = StringFormat("KalmanRegime(%.1e, %.1e, Z:%.1f/%.1f)", 
                                    InpQMu, InpQBeta, InpZEnter, InpZExit);
   IndicatorSetString(INDICATOR_SHORTNAME, short_name);

   // 水平ライン設定（突入・離脱レベル）
   IndicatorSetInteger(INDICATOR_LEVELS, 5);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 0,  InpZEnter);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 1,  InpZExit);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 2,  0.0);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 3, -InpZExit);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 4, -InpZEnter);

   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 0, STYLE_DASH);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 1, STYLE_DOT);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 2, STYLE_SOLID);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 3, STYLE_DOT);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 4, STYLE_DASH);

   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 0, clrDimGray);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 1, clrDarkGray);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 2, clrSilver);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 3, clrDarkGray);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 4, clrDimGray);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 1足分のカルマン更新ステップ関数                                  |
//+------------------------------------------------------------------+
void UpdateKalmanStep(const KalmanState &prevState, 
                      const double price, 
                      KalmanState &outState, 
                      double &outSlope, 
                      double &outZScore, 
                      double &outRegime)
{
   if(!prevState.initialized)
   {
      outState.mu   = price;
      outState.beta = 0.0;
      outState.p00  = InpInitialP;
      outState.p01  = 0.0;
      outState.p11  = InpInitialP;
      outState.regime = REGIME_RANGE;
      outState.initialized = true;

      outSlope  = 0.0;
      outZScore = 0.0;
      outRegime = REGIME_RANGE;
      return;
   }

   // 1. 予測ステップ
   double mu_pred   = prevState.mu + prevState.beta;
   double beta_pred = prevState.beta;

   double p00_pred = prevState.p00 + 2.0 * prevState.p01 + prevState.p11 + InpQMu;
   double p01_pred = prevState.p01 + prevState.p11;
   double p11_pred = prevState.p11 + InpQBeta;

   // 2. 更新ステップ
   double residual = price - mu_pred;
   double s = p00_pred + InpR;

   double k0 = p00_pred / s;
   double k1 = p01_pred / s;

   outState.mu   = mu_pred + k0 * residual;
   outState.beta = beta_pred + k1 * residual;

   outState.p00 = p00_pred - k0 * p00_pred;
   outState.p01 = p01_pred - k0 * p01_pred;
   outState.p11 = p11_pred - k1 * p01_pred;
   outState.initialized = true;

   // 3. 統計量算出
   outSlope = outState.beta;
   double slope_variance = (outState.p11 > 1e-12) ? outState.p11 : 1e-12;
   outZScore = outSlope / MathSqrt(slope_variance);

   // 4. ヒステリシス状態遷移
   double current_regime = prevState.regime;

   if(current_regime == REGIME_RANGE)
   {
      if(outZScore >= InpZEnter)
         current_regime = REGIME_UP;
      else if(outZScore <= -InpZEnter)
         current_regime = REGIME_DOWN;
   }
   else if(current_regime == REGIME_UP)
   {
      if(InpAllowDirectReversal && (outZScore <= -InpZEnter))
         current_regime = REGIME_DOWN;
      else if(outZScore <= InpZExit)
         current_regime = REGIME_RANGE;
   }
   else if(current_regime == REGIME_DOWN)
   {
      if(InpAllowDirectReversal && (outZScore >= InpZEnter))
         current_regime = REGIME_UP;
      else if(outZScore >= -InpZExit)
         current_regime = REGIME_RANGE;
   }

   outState.regime = current_regime;
   outRegime = current_regime;
}

//+------------------------------------------------------------------+
//| 計算イベント関数                                                 |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < 2)
      return(0);

   // インデックス方向を時系列昇順（0: 最古, rates_total-1: 最新未確定足）に統一
   ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(BufferZScore, false);
   ArraySetAsSeries(BufferColor, false);
   ArraySetAsSeries(BufferSlope, false);
   ArraySetAsSeries(BufferRegime, false);

   // 履歴配列の動的確保
   if(ArraySize(StateHistory) != rates_total)
   {
      if(ArrayResize(StateHistory, rates_total) < 0)
      {
         Print("[Error] StateHistoryのメモリ確保に失敗しました。");
         return(0);
      }
   }

   // 状態汚染防止: 未確定バー（rates_total-1）のティック更新時は直前の確定バーから再計算
   int start = 0;
   if(prev_calculated > 0)
   {
      start = prev_calculated - 1;
   }

   for(int i = start; i < rates_total && !IsStopped(); i++)
   {
      // 選択された適用価格を取得
      double price = GetAppliedPrice(InpAppliedPrice, open, high, low, close, i);
      double slope = 0.0;
      double zScore = 0.0;
      double regime = REGIME_RANGE;

      if(i == 0)
      {
         KalmanState emptyState;
         emptyState.initialized = false;
         emptyState.regime = REGIME_RANGE;
         UpdateKalmanStep(emptyState, price, StateHistory[i], slope, zScore, regime);
      }
      else
      {
         // 確定している直前バーの状態から逐次更新
         UpdateKalmanStep(StateHistory[i - 1], price, StateHistory[i], slope, zScore, regime);
      }

      BufferZScore[i] = zScore;
      BufferSlope[i]  = slope;
      BufferRegime[i] = regime;

      if(regime == REGIME_UP)
         BufferColor[i] = COLOR_UP;
      else if(regime == REGIME_DOWN)
         BufferColor[i] = COLOR_DOWN;
      else
         BufferColor[i] = COLOR_RANGE;
   }

   return(rates_total);
}
//+------------------------------------------------------------------+
```

---

## 6. MQL5アーキテクチャとEA連携インターフェース

### (1) 未確定足（Bar 0）の状態汚染（State Corruption）防止メカニズム

MetaTrader 5のインジケーターは、未確定バー（Bar 0）のティック変動ごとに `OnCalculate` が呼ばれます。
カルマンフィルターのような逐次モデルで単一のグローバル状態変数（$\mu, \beta, P$）を毎ティック更新してしまうと、未確定足の途中の値動きが永久に状態を歪める「状態汚染」が発生し、バックテスト結果とリアルタイム運用で描画が乖離（リペイント）します。

本実装では以下の設計でこれを完全に防ぎます。
1. **確定足履歴配列 `StateHistory[]`**: 各バー確定時の最終状態のみをバーインデックスごとに保存。
2. **再計算基点の固定**: ティック更新時は常に確定バー `StateHistory[rates_total - 2]` から未確定バー `StateHistory[rates_total - 1]` を一時的に更新。足が確定した瞬間にのみ状態が次足への引き継ぎデータとして固定化されます。

### (2) インジケーターバッファ仕様

| バッファ番号 | タイプ | プロット名 | 格納データ / 役割 | EA利用 |
| :---: | :---: | :---: | :--- | :---: |
| **0** | `INDICATOR_DATA` | Kalman Z-Score | 標準化モメンタムスコア $z_t$（描画用） | 可 |
| **1** | `INDICATOR_COLOR_INDEX` | Color Index | 描画色（0: 青 / UP, 1: 赤 / DOWN, 2: 灰 / RANGE） | 可 |
| **2** | `INDICATOR_CALCULATIONS` | Slope ($\beta$) | 推定された傾き実数値（1足あたりのモメンタム量） | **推奨** |
| **3** | `INDICATOR_CALCULATIONS` | Regime | レジーム値（`1.0`: UP, `-1.0`: DOWN, `0.0`: RANGE） | **推奨** |

### (3) エキスパートアドバイザー（EA）からの呼び出し実装例

EAの `OnInit`、`OnDeinit`、および `OnTick` でのリソース管理を含めた安全なデータ取得コードです。

```cpp
//--- グローバル変数
int g_kalman_handle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // KalmanRegimeEstimator インジケーターハンドルの作成
   g_kalman_handle = iCustom(_Symbol, _Period, "KalmanRegimeEstimator",
                             1e-5,       // InpQMu
                             1e-5,       // InpQBeta
                             1.0,        // InpR
                             1000.0,     // InpInitialP
                             2.0,        // InpZEnter
                             1.0,        // InpZExit
                             true,       // InpAllowDirectReversal
                             PRICE_CLOSE);

   if(g_kalman_handle == INVALID_HANDLE)
   {
      Print("[Error] インジケーターハンドルの取得に失敗しました。");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // インジケーターハンドルの明示的解放
   if(g_kalman_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_kalman_handle);
      g_kalman_handle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 直前の確定足（シフト 1）のレジーム、Zスコア、傾きを取得
   double regime_arr[1];
   double z_score_arr[1];
   double slope_arr[1];

   if(CopyBuffer(g_kalman_handle, 3, 1, 1, regime_arr) <= 0 ||
      CopyBuffer(g_kalman_handle, 0, 1, 1, z_score_arr) <= 0 ||
      CopyBuffer(g_kalman_handle, 2, 1, 1, slope_arr) <= 0)
   {
      return; // データ未準備
   }

   double current_regime = regime_arr[0];
   double current_z      = z_score_arr[0];
   double current_slope  = slope_arr[0];

   // レジームに応じた戦略分岐
   if(current_regime == 1.0)
   {
      // 【上昇トレンドレジーム】
      // 例: 押し目買いエントリー / ショートポジションの手仕舞い / 買トレール発動
   }
   else if(current_regime == -1.0)
   {
      // 【下降トレンドレジーム】
      // 例: 戻り売りエントリー / ロングポジションの手仕舞い / 売トレール発動
   }
   else
   {
      // 【レンジ相場レジーム (0.0)】
      // 例: トレンドフォローの新規発注を一時停止 / ボリンジャーバンド等の平均回帰逆張り発動
   }
}
```

---

## 7. バックテストと運用の推奨事項

1. **ADXとの遅延比較（イベントスタディ）**:
   * 急反転（V字/逆V字）のバーにおいて、ADXのピークアウトおよびDIクロス判定と比較して、カルマンフィルターの $z$ スコアが何足早く `RANGE` または逆トレンドを検知するかを検証してください。
2. **プロセスノイズ $q_\beta$ の最適化**:
   * 通貨ペアや時間足（1分足〜日足）のボラティリティスケールに応じて $q_\beta$ を調整します。
   * $q_\beta$ が大きすぎる場合：ヒゲや突発的なノイズに反応しやすくなります。
   * $q_\beta$ が小さすぎる場合：平滑性は高まりますが、移動平均と同等の遅延が生じます。
3. **即時ドテン（`InpAllowDirectReversal`）の損益分岐検証**:
   * 急激なトレンド転換局面において、ドテン有効（即座に逆ポジション）とドテン無効（一旦レンジで決済してフラット）での最大ドローダウンの違いを検証してください。