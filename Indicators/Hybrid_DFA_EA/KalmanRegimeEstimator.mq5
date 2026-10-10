//+------------------------------------------------------------------+
//|                                     KalmanRegimeEstimator.mq5    |
//|                                  Copyright 2026, Quant Research  |
//| Smooth Trend Model (Rolling Rice Estimator & Polar Placement)   |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Quant Research"
#property link        "https://www.mql5.com"
#property version     "5.20"
#property description "平滑トレンドモデル・確定足ローリングRice推定量＆現在足リアルタイム追従完全版"
#property indicator_separate_window
#property indicator_buffers 4
#property indicator_plots   1

//--- プロット定義 (Zスコアカラーライン)
#property indicator_label1 "Kalman Z-Score"
#property indicator_type1  DRAW_COLOR_LINE
#property indicator_color1 clrDodgerBlue, clrCrimson, clrDarkGray
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

//--- レジーム定義定数
#define REGIME_UP     1.0  // 上昇トレンド
#define REGIME_DOWN  -1.0  // 下降トレンド
#define REGIME_RANGE  0.0  // レンジ相場

//--- カラーバッファ用インデックス
#define COLOR_UP    0  // clrDodgerBlue
#define COLOR_DOWN  1  // clrCrimson
#define COLOR_RANGE 2  // clrDarkGray

//--- 入力パラメータ
input group "=== マルチタイムフレーム (MTF) 設定 ==="
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_CURRENT; // 計算対象タイムフレーム (上位足を指定可能)
input bool            InpAutoTimeframeScale = true;           // 手動モード時の時間足スケーリング (Δt補正)

input group "=== 確定足動的キャリブレーション (完全因果的・先読みゼロ) ==="
input bool   InpAutoCalibration = true;  // 確定足ローリングによる動的ノイズ推定 (推奨)
input double InpTargetLagBars   = 10.0;  // 抽出したいトレンドの実効時定数 tau (目安: 8〜15本)
input int    InpRollingWindow   = 200;   // ローリング観測窓長 W (過去確定足のみ使用: 100〜250推奨)

input group "=== カルマンフィルター パラメータ (手動設定時または初期フォールバック) ==="
input double InpManualQMu      = 0.0;    // プロセスノイズ分散 (水準: q_mu, 平滑トレンドモデル時は0.0)
input double InpManualQBeta    = 1e-9;   // プロセスノイズ分散 (傾き: q_beta)
input double InpManualR        = 1e-5;   // 観測ノイズ分散 (R)
input double InpManualInitialP = 1.0;    // 初期誤差共分散スケール (P0)

input group "=== レジーム判定 (ヒステリシス) パラメータ ==="
input double             InpZEnter              = 2.0;         // トレンド突入閾値 (|z| >= z_enter)
input double             InpZExit               = 1.0;         // トレンド離脱閾値 (|z| <= z_exit)
input bool               InpAllowDirectReversal = true;        // 急反転時の即時ドテン許可 (UP <-> DOWN 直行)
input ENUM_APPLIED_PRICE InpAppliedPrice        = PRICE_CLOSE; // 適用価格

//--- 各バーの状態を隔離保持する構造体（未確定足の状態汚染防止）
struct KalmanState
{
   double mu;          // 平滑化対数価格水準 ln(P)
   double beta;        // 局所的な対数傾き (1足あたりの期待リターン速度)
   double p00;         // 共分散 P[0,0]
   double p01;         // 共分散 P[0,1]
   double p11;         // 共分散 P[1,1]
   double regime;      // 現在のレジーム状態
   bool   initialized; // 初期化フラグ
};

//--- インジケーターバッファ
double BufferZScore[]; // プロット用: Zスコア
double BufferColor[];  // プロット用: カラーインデックス
double BufferSlope[];  // 計算用/EA取得用: 局所的な傾き beta
double BufferRegime[]; // 計算用/EA取得用: レジーム (+1: UP, -1: DOWN, 0: RANGE)

//--- シングルタイムフレーム動的計算用配列
KalmanState StateHistory[];
double      LogPriceHistory[]; // 対数価格系列 y_t = ln(P_t)
double      PrefixD2Sq[];      // 二階差分二乗の累積和配列 (真の O(1) スライディング計算用)

// 確定足時点でのキャリブレーション結果キャッシュ (未確定足に固定適用する用: Path A)
double g_current_r         = 1e-5;
double g_current_q_beta    = 1e-9;
double g_current_initial_p = 1.0;

// MTF専用の確定足パラメータキャッシュ (Path B)
double g_tf_cached_r         = 1e-5;
double g_tf_cached_q_beta    = 1e-9;
double g_tf_cached_initial_p = 1.0;

//--- MTF専用グローバル配列 (O(1) 増分処理用)
KalmanState g_tf_state_history[];
double      g_tf_log_prices[];
double      g_tf_prefix_d2_sq[];
double      g_tf_zscore_cache[];
double      g_tf_slope_cache[];
double      g_tf_regime_cache[];
datetime    g_tf_time_cache[];
int         g_tf_prev_rates_total = 0;
int         g_last_mapped_tf_idx  = 0;
MqlRates    g_tf_rates[];

// 直前有効価格の永続保持
double g_last_valid_price    = 0.0;
double g_tf_last_valid_price = 0.0;

// 実効基本パラメータ
double          g_base_q_mu      = 0.0;
double          g_base_q_beta    = 1e-9;
double          g_base_r         = 1e-5;
double          g_base_initial_p = 1.0;
double          g_tau4           = 10000.0; // tau^4
ENUM_TIMEFRAMES g_calc_tf        = PERIOD_CURRENT;

//+------------------------------------------------------------------+
//| 適用価格取得オーバーロード（配列版: Path A）                    |
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
//| 適用価格取得オーバーロード（MqlRates構造体版: Path B）           |
//+------------------------------------------------------------------+
double GetAppliedPrice(const ENUM_APPLIED_PRICE price_type, const MqlRates &rate)
{
   switch(price_type)
   {
      case PRICE_CLOSE:    return rate.close;
      case PRICE_OPEN:     return rate.open;
      case PRICE_HIGH:     return rate.high;
      case PRICE_LOW:      return rate.low;
      case PRICE_MEDIAN:   return (rate.high + rate.low) * 0.5;
      case PRICE_TYPICAL:  return (rate.high + rate.low + rate.close) / 3.0;
      case PRICE_WEIGHTED: return (rate.high + rate.low + 2.0 * rate.close) * 0.25;
      default:             return rate.close;
   }
}

//+------------------------------------------------------------------+
//| 初期化関数                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpZExit < 0.0 || InpZEnter <= InpZExit)
   {
      Print("[Error] 入力パラメータのバリデーションに失敗しました (InpZEnter > InpZExit >= 0 が必須)。");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpTargetLagBars < 1.0)
   {
      Print("[Error] InpTargetLagBars は 1.0 以上を指定してください。");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpRollingWindow < 20)
   {
      Print("[Error] InpRollingWindow は 20 以上を指定してください。");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_calc_tf = (InpTimeframe == PERIOD_CURRENT) ? _Period : InpTimeframe;
   g_tau4 = MathPow(InpTargetLagBars, 4.0);

   g_base_q_mu      = InpManualQMu;
   g_base_q_beta    = InpManualQBeta;
   g_base_r         = InpManualR;
   g_base_initial_p = InpManualInitialP;

   // 手動モード時の時間足スケーリング（Δt補正: Q, R, P0 の比率を完全維持）
   if(!InpAutoCalibration && InpAutoTimeframeScale)
   {
      double scale = (double)PeriodSeconds(g_calc_tf) / 86400.0;
      if(scale < 1e-4) scale = 1e-4;

      g_base_q_mu      *= scale;
      g_base_q_beta    *= scale;
      g_base_r         *= scale;
      g_base_initial_p *= scale; // ★ P0 も同時にスケーリングしゲイン不変性を保証
   }

   // Path A 用キャッシュの初期化
   g_current_r         = g_base_r;
   g_current_q_beta    = g_base_q_beta;
   g_current_initial_p = g_base_initial_p;

   // Path B 用キャッシュの明示的初期化（対称性の確保）
   g_tf_cached_r         = g_base_r;
   g_tf_cached_q_beta    = g_base_q_beta;
   g_tf_cached_initial_p = g_base_initial_p;

   // バッファバインド
   SetIndexBuffer(0, BufferZScore, INDICATOR_DATA);
   SetIndexBuffer(1, BufferColor, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, BufferSlope, INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, BufferRegime, INDICATOR_CALCULATIONS);

   IndicatorSetInteger(INDICATOR_DIGITS, 2);

   string mode_str   = InpAutoCalibration ? StringFormat("RollingRice(W:%d,tau:%.1f)", InpRollingWindow, InpTargetLagBars) : "Manual";
   string short_name = StringFormat("KalmanRegime(%s,%s,Z:%.1f/%.1f)", EnumToString(g_calc_tf), mode_str, InpZEnter, InpZExit);
   IndicatorSetString(INDICATOR_SHORTNAME, short_name);

   // 水平ライン設定
   IndicatorSetInteger(INDICATOR_LEVELS, 5);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, InpZEnter);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 1, InpZExit);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 2, 0.0);
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

   g_tf_prev_rates_total = 0;
   g_last_mapped_tf_idx  = 0;
   g_last_valid_price    = 0.0;
   g_tf_last_valid_price = 0.0;
   ArrayFree(g_tf_rates);

   Print("");
   PrintFormat("[★ KalmanRegimeEstimator 起動完了 ★]");
   PrintFormat("  - 動作モード             : %s", InpAutoCalibration ? "確定足ローリングRice推定量＆現在足リアルタイム追従" : "手動固定モード");
   PrintFormat("  - 抽出ターゲット時定数   : %.1f 本 (極配置関係式: q_beta = R_t / tau^4)", InpTargetLagBars);
   if(InpAutoCalibration)
      PrintFormat("  - ローリング観測窓幅     : 過去確定 %d 本 (現在足の未確定ノイズによるパラメータ汚染を完全遮断)", InpRollingWindow);
   else if(InpAutoTimeframeScale)
      PrintFormat("  - 時間足スケーリング     : 有効 (scale=%.4f, Q, R, P0 を同率補正)", (double)PeriodSeconds(g_calc_tf) / 86400.0);
   Print("");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 1ステップのカルマン逐次更新（動的パラメータ対応スカラー展開）    |
//+------------------------------------------------------------------+
void UpdateKalmanStepDynamic(const KalmanState &prevState,
                             const double log_price,
                             const double current_q_mu,
                             const double current_q_beta,
                             const double current_r,
                             const double initial_p,
                             KalmanState &outState,
                             double &outSlope,
                             double &outZScore,
                             double &outRegime)
{
   if(!prevState.initialized)
   {
      outState.mu          = log_price;
      outState.beta        = 0.0;
      outState.p00         = initial_p; // ★ 正しくスケーリングされた初期共分散を使用
      outState.p01         = 0.0;
      outState.p11         = initial_p;
      outState.regime      = REGIME_RANGE;
      outState.initialized = true;

      outSlope  = 0.0;
      outZScore = 0.0;
      outRegime = REGIME_RANGE;
      return;
   }

   // 1. 予測ステップ (平滑トレンドモデル: current_q_mu = 0.0)
   double mu_pred   = prevState.mu + prevState.beta;
   double beta_pred = prevState.beta;

   double p00_pred = prevState.p00 + 2.0 * prevState.p01 + prevState.p11 + current_q_mu;
   double p01_pred = prevState.p01 + prevState.p11;
   double p11_pred = prevState.p11 + current_q_beta;

   // 2. 更新ステップ
   double residual = log_price - mu_pred;
   double s        = p00_pred + current_r;
   if(s <= 1e-15) s = 1e-15;

   double k0 = p00_pred / s;
   double k1 = p01_pred / s;

   outState.mu   = mu_pred + k0 * residual;
   outState.beta = beta_pred + k1 * residual;

   outState.p00 = p00_pred - k0 * p00_pred;
   outState.p01 = p01_pred - k0 * p01_pred;
   outState.p11 = p11_pred - k1 * p01_pred;
   outState.initialized = true;

   outSlope = outState.beta;
   double slope_variance = (outState.p11 > 1e-15) ? outState.p11 : 1e-15;
   outZScore = outSlope / MathSqrt(slope_variance);

   // 3. ヒステリシス状態遷移
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
   outRegime       = current_regime;
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
   if(rates_total < 2) return(0);

   ArraySetAsSeries(time, false);
   ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(BufferZScore, false);
   ArraySetAsSeries(BufferColor, false);
   ArraySetAsSeries(BufferSlope, false);
   ArraySetAsSeries(BufferRegime, false);

   // =================================================================
   // パス A: シングルタイムフレーム (PERIOD_CURRENT)
   // =================================================================
   if(g_calc_tf == _Period)
   {
      if(ArraySize(StateHistory) != rates_total)
      {
         if(ArrayResize(StateHistory, rates_total) < 0 ||
            ArrayResize(LogPriceHistory, rates_total) < 0 ||
            ArrayResize(PrefixD2Sq, rates_total) < 0)
            return(0);
      }

      int start = 0;
      if(prev_calculated > 0)
      {
         start = prev_calculated - 1;
      }
      else
      {
         double p0 = GetAppliedPrice(InpAppliedPrice, open, high, low, close, 0);
         g_last_valid_price = (p0 > 0.0) ? p0 : close[0];
      }

      int last_bar_idx = rates_total - 1;

      for(int i = start; i < rates_total && !IsStopped(); i++)
      {
         double raw_price = GetAppliedPrice(InpAppliedPrice, open, high, low, close, i);
         if(raw_price > 0.0)
            g_last_valid_price = raw_price;

         double log_price = MathLog(g_last_valid_price);
         LogPriceHistory[i] = log_price;

         double current_r      = g_base_r;
         double current_q_beta = g_base_q_beta;
         double current_q_mu   = 0.0;

         // --- [キャリブレーション層の確定足隔離] ---
         // 確定足（i < last_bar_idx）でのみ累積和 PrefixD2Sq を更新し、
         // 最新の確定ノイズ分散 R_t をキャッシュする
         if(i < last_bar_idx)
         {
            if(i >= 2)
            {
               double d2 = log_price - 2.0 * LogPriceHistory[i - 1] + LogPriceHistory[i - 2];
               PrefixD2Sq[i] = PrefixD2Sq[i - 1] + (d2 * d2);
            }
            else
            {
               PrefixD2Sq[i] = 0.0;
            }

            if(InpAutoCalibration && i >= 2)
            {
               int start_k = (i >= InpRollingWindow + 1) ? (i - InpRollingWindow + 1) : 2;
               int count   = i - start_k + 1;

               if(count >= 10)
               {
                  double sum_d2_sq   = PrefixD2Sq[i] - PrefixD2Sq[start_k - 1];
                  double estimated_r = sum_d2_sq / (6.0 * (double)count);

                  if(estimated_r < 1e-9) estimated_r = 1e-9;
                  if(estimated_r > 1.0)  estimated_r = 1.0;

                  current_r      = estimated_r;
                  current_q_beta = current_r / g_tau4;
               }
            }
            g_current_r      = current_r;
            g_current_q_beta = current_q_beta;
         }
         else
         {
            // 現在バー（未確定足: i == last_bar_idx）:
            // リアルタイムティックでキャリブレーション配列を汚染させず、
            // 直前確定足で得られた安定した最新パラメータをそのまま固定適用する
            current_r      = g_current_r;
            current_q_beta = g_current_q_beta;
         }

         // --- [カルマンフィルター状態更新層（リアルタイム）] ---
         // 現在バーの最新価格 log_price を用いて毎ティック即座に応答計算
         double slope = 0.0, zScore = 0.0, regime = REGIME_RANGE;

         if(i == 0)
         {
            KalmanState emptyState;
            emptyState.initialized = false;
            emptyState.regime      = REGIME_RANGE;
            UpdateKalmanStepDynamic(emptyState, log_price, current_q_mu, current_q_beta, current_r, g_current_initial_p, StateHistory[i], slope, zScore, regime);
         }
         else
         {
            UpdateKalmanStepDynamic(StateHistory[i - 1], log_price, current_q_mu, current_q_beta, current_r, g_current_initial_p, StateHistory[i], slope, zScore, regime);
         }

         BufferZScore[i] = zScore;
         BufferSlope[i]  = slope;
         BufferRegime[i] = regime;
         BufferColor[i]  = (regime == REGIME_UP) ? COLOR_UP : (regime == REGIME_DOWN ? COLOR_DOWN : COLOR_RANGE);
      }
      return(rates_total);
   }

   // =================================================================
   // パス B: マルチタイムフレーム (上位足キャッシュ & 確定足キャリブレーション)
   // =================================================================
   bool need_full_fetch = (g_tf_prev_rates_total == 0 || ArraySize(g_tf_rates) == 0);

   if(!need_full_fetch)
   {
      MqlRates temp_rates[];
      ArraySetAsSeries(temp_rates, false);
      int temp_copied = CopyRates(_Symbol, g_calc_tf, 0, 3, temp_rates);

      int last_idx = ArraySize(g_tf_rates) - 1;
      if(temp_copied >= 2 && last_idx >= 1)
      {
         datetime last_time = g_tf_rates[last_idx].time;
         int match_idx = -1;

         for(int m = 0; m < temp_copied; m++)
         {
            if(temp_rates[m].time == last_time)
            {
               match_idx = m;
               break;
            }
         }

         if(match_idx >= 0)
         {
            g_tf_rates[last_idx] = temp_rates[match_idx];

            for(int m = match_idx + 1; m < temp_copied; m++)
            {
               int new_size = ArraySize(g_tf_rates) + 1;
               if(ArrayResize(g_tf_rates, new_size) > 0)
               {
                  g_tf_rates[new_size - 1] = temp_rates[m];
               }
            }
         }
         else
         {
            need_full_fetch = true;
         }
      }
      else
      {
         need_full_fetch = true;
      }
   }

   if(need_full_fetch)
   {
      ArraySetAsSeries(g_tf_rates, false);
      int copied = CopyRates(_Symbol, g_calc_tf, time[0], TimeCurrent(), g_tf_rates);
      if(copied <= 1) return(prev_calculated);

      g_tf_prev_rates_total = 0;
      g_last_mapped_tf_idx  = 0;
      double p0 = GetAppliedPrice(InpAppliedPrice, g_tf_rates[0]);
      g_tf_last_valid_price = (p0 > 0.0) ? p0 : g_tf_rates[0].close;
   }

   int tf_rates_total = ArraySize(g_tf_rates);
   if(tf_rates_total < 2) return(prev_calculated);

   if(ArraySize(g_tf_state_history) != tf_rates_total)
   {
      ArrayResize(g_tf_state_history, tf_rates_total);
      ArrayResize(g_tf_log_prices, tf_rates_total);
      ArrayResize(g_tf_prefix_d2_sq, tf_rates_total);
      ArrayResize(g_tf_zscore_cache, tf_rates_total);
      ArrayResize(g_tf_slope_cache, tf_rates_total);
      ArrayResize(g_tf_regime_cache, tf_rates_total);
      ArrayResize(g_tf_time_cache, tf_rates_total);
   }

   int tf_start = 0;
   if(g_tf_prev_rates_total > 0 && tf_rates_total >= g_tf_prev_rates_total)
      tf_start = g_tf_prev_rates_total - 1;

   int last_tf_idx = tf_rates_total - 1;

   for(int k = tf_start; k < tf_rates_total && !IsStopped(); k++)
   {
      double raw_price = GetAppliedPrice(InpAppliedPrice, g_tf_rates[k]);
      if(raw_price > 0.0)
         g_tf_last_valid_price = raw_price;

      double log_price = MathLog(g_tf_last_valid_price);
      g_tf_log_prices[k] = log_price;

      double current_r      = g_base_r;
      double current_q_beta = g_base_q_beta;
      double current_q_mu   = 0.0;

      // 上位足確定バーのみでキャリブレーション累積和を更新
      if(k < last_tf_idx)
      {
         if(k >= 2)
         {
            double d2 = log_price - 2.0 * g_tf_log_prices[k - 1] + g_tf_log_prices[k - 2];
            g_tf_prefix_d2_sq[k] = g_tf_prefix_d2_sq[k - 1] + (d2 * d2);
         }
         else
         {
            g_tf_prefix_d2_sq[k] = 0.0;
         }

         if(InpAutoCalibration && k >= 2)
         {
            int start_k = (k >= InpRollingWindow + 1) ? (k - InpRollingWindow + 1) : 2;
            int count   = k - start_k + 1;

            if(count >= 10)
            {
               double sum_d2_sq   = g_tf_prefix_d2_sq[k] - g_tf_prefix_d2_sq[start_k - 1];
               double estimated_r = sum_d2_sq / (6.0 * (double)count);

               if(estimated_r < 1e-9) estimated_r = 1e-9;
               if(estimated_r > 1.0)  estimated_r = 1.0;

               current_r      = estimated_r;
               current_q_beta = current_r / g_tau4;
            }
         }
         g_tf_cached_r      = current_r;
         g_tf_cached_q_beta = current_q_beta;
      }
      else
      {
         // 上位足の未確定バーでは確定パラメータを固定適用
         current_r      = g_tf_cached_r;
         current_q_beta = g_tf_cached_q_beta;
      }

      double slope = 0.0, zScore = 0.0, regime = REGIME_RANGE;

      if(k == 0)
      {
         KalmanState emptyState;
         emptyState.initialized = false;
         emptyState.regime      = REGIME_RANGE;
         UpdateKalmanStepDynamic(emptyState, log_price, current_q_mu, current_q_beta, current_r, g_tf_cached_initial_p, g_tf_state_history[k], slope, zScore, regime);
      }
      else
      {
         UpdateKalmanStepDynamic(g_tf_state_history[k - 1], log_price, current_q_mu, current_q_beta, current_r, g_tf_cached_initial_p, g_tf_state_history[k], slope, zScore, regime);
      }

      g_tf_zscore_cache[k] = zScore;
      g_tf_slope_cache[k]  = slope;
      g_tf_regime_cache[k] = regime;
      g_tf_time_cache[k]   = g_tf_rates[k].time;
   }
   g_tf_prev_rates_total = tf_rates_total;

   // チャート足への増分マッピング (O(1))
   int chart_start = 0;
   if(prev_calculated > 0)
      chart_start = prev_calculated - 1;

   int tf_idx = g_last_mapped_tf_idx;
   if(tf_idx >= tf_rates_total)
      tf_idx = tf_rates_total - 1;

   for(int i = chart_start; i < rates_total && !IsStopped(); i++)
   {
      datetime t = time[i];

      while(tf_idx < tf_rates_total - 1 && g_tf_time_cache[tf_idx + 1] <= t)
      {
         tf_idx++;
      }
      while(tf_idx > 0 && g_tf_time_cache[tf_idx] > t)
      {
         tf_idx--;
      }

      if(i < rates_total - 1)
         g_last_mapped_tf_idx = tf_idx;

      double regime = g_tf_regime_cache[tf_idx];
      BufferZScore[i] = g_tf_zscore_cache[tf_idx];
      BufferSlope[i]  = g_tf_slope_cache[tf_idx];
      BufferRegime[i] = regime;
      BufferColor[i]  = (regime == REGIME_UP) ? COLOR_UP : (regime == REGIME_DOWN ? COLOR_DOWN : COLOR_RANGE);
   }

   return(rates_total);
}
//+------------------------------------------------------------------+