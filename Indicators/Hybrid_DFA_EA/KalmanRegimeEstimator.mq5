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

// レジーム定義（定数）
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
input bool   InpAllowDirectReversal = true;       // 急反転時の即時ドテンを許可 (Direct Reversal)
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // 適用価格

// 各バーの状態を保存する構造体（未確定足の更新による状態汚染を防止）
struct KalmanState
{
   double mu;             // 平滑化された価格水準
   double beta;           // 局所的な傾き
   double p00;            // 誤差共分散行列 P[0,0]
   double p01;            // 誤差共分散行列 P[0,1] = P[1,0]
   double p11;            // 誤差共分散行列 P[1,1]
   double regime;         // レジーム値 (1.0, -1.0, 0.0)
   bool   initialized;    // 初期化フラグ
};

// インジケーターバッファ
double BufferZScore[];    // Plot 1: Zスコアデータ
double BufferColor[];     // Plot 1: カラーインデックス (0: UP, 1: DOWN, 2: RANGE)
double BufferSlope[];     // EA取得用: 推定傾き (beta)
double BufferRegime[];    // EA取得用: レジーム (1.0, -1.0, 0.0)

// 全履歴バーのカルマン状態保持用配列
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
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // 入力バリデーション
   if(InpZExit < 0.0)
   {
      Print("[Error] z_exit は 0.0 以上である必要があります。");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpZEnter <= InpZExit)
   {
      Print("[Error] ヒステリシスを形成するため、z_enter は z_exit より大きい必要があります。");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpQMu <= 0.0 || InpQBeta <= 0.0 || InpR <= 0.0 || InpInitialP <= 0.0)
   {
      Print("[Error] ノイズパラメータおよび初期共分散は正の値である必要があります。");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // バッファのバインド
   SetIndexBuffer(0, BufferZScore, INDICATOR_DATA);
   SetIndexBuffer(1, BufferColor,  INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, BufferSlope,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, BufferRegime, INDICATOR_CALCULATIONS);

   // 小数点桁数設定
   IndicatorSetInteger(INDICATOR_DIGITS, 2);

   // インジケーター名の設定
   string short_name = StringFormat("KalmanRegime(%.1e, %.1e, Z:%.1f/%.1f)", 
                                    InpQMu, InpQBeta, InpZEnter, InpZExit);
   IndicatorSetString(INDICATOR_SHORTNAME, short_name);

   // サブウィンドウの水平レベル線設定
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
//| 1足分のカルマンフィルター更新とヒステリシスレジーム判定         |
//+------------------------------------------------------------------+
void UpdateKalmanStep(const KalmanState &prevState, 
                      const double price, 
                      KalmanState &outState, 
                      double &outSlope, 
                      double &outZScore, 
                      double &outRegime)
{
   // 初回足の初期化
   if(!prevState.initialized)
   {
      outState.mu = price;
      outState.beta = 0.0;
      outState.p00 = InpInitialP;
      outState.p01 = 0.0;
      outState.p11 = InpInitialP;
      outState.regime = REGIME_RANGE;
      outState.initialized = true;

      outSlope = 0.0;
      outZScore = 0.0;
      outRegime = REGIME_RANGE;
      return;
   }

   // -------------------------------------------------------------
   // 1. 予測ステップ (Time Update)
   // 状態遷移行列 F = [[1, 1], [0, 1]]
   // -------------------------------------------------------------
   double mu_pred   = prevState.mu + prevState.beta;
   double beta_pred = prevState.beta;

   // P_pred = F * P * F^T + Q
   double p00_pred = prevState.p00 + 2.0 * prevState.p01 + prevState.p11 + InpQMu;
   double p01_pred = prevState.p01 + prevState.p11;
   double p11_pred = prevState.p11 + InpQBeta;

   // -------------------------------------------------------------
   // 2. 更新ステップ (Measurement Update)
   // 観測行列 H = [1, 0] を利用したスカラー展開
   // -------------------------------------------------------------
   double residual = price - mu_pred;
   double s = p00_pred + InpR;

   // カルマンゲイン K = [K0, K1]^T
   double k0 = p00_pred / s;
   double k1 = p01_pred / s;

   // 状態ベクトルの更新
   outState.mu   = mu_pred + k0 * residual;
   outState.beta = beta_pred + k1 * residual;

   // 誤差共分散行列の更新: P = (I - K*H) * P_pred
   outState.p00 = p00_pred - k0 * p00_pred;
   outState.p01 = p01_pred - k0 * p01_pred;
   outState.p11 = p11_pred - k1 * p01_pred;
   outState.initialized = true;

   // -------------------------------------------------------------
   // 3. 統計量（傾きとZスコア）の算出
   // -------------------------------------------------------------
   outSlope = outState.beta;
   double slope_variance = (outState.p11 > 1e-12) ? outState.p11 : 1e-12;
   outZScore = outSlope / MathSqrt(slope_variance);

   // -------------------------------------------------------------
   // 4. ヒステリシス付きレジーム判定
   // -------------------------------------------------------------
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
//| Custom indicator iteration function                              |
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

   // 配列のインデックス方向を時系列順（0が最古、rates_total-1が最新足）に統一
   ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(BufferZScore, false);
   ArraySetAsSeries(BufferColor, false);
   ArraySetAsSeries(BufferSlope, false);
   ArraySetAsSeries(BufferRegime, false);

   // 状態保持用配列のサイズ調整
   if(ArraySize(StateHistory) != rates_total)
   {
      if(ArrayResize(StateHistory, rates_total) < 0)
      {
         Print("[Error] メモリ確保に失敗しました。");
         return(0);
      }
   }

   // 計算開始位置の決定
   int start = 0;
   if(prev_calculated > 0)
   {
      // 前回の確定足（prev_calculated - 1）から再計算することで、リアルタイム更新時の状態整合性を保証
      start = prev_calculated - 1;
   }

   for(int i = start; i < rates_total && !IsStopped(); i++)
   {
      // ユーザー設定の適用価格を反映
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
         // 1つ前のバー（確定状態）から状態を更新
         UpdateKalmanStep(StateHistory[i - 1], price, StateHistory[i], slope, zScore, regime);
      }

      // バッファへの格納
      BufferZScore[i] = zScore;
      BufferSlope[i]  = slope;
      BufferRegime[i] = regime;

      // カラーインデックスの設定
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