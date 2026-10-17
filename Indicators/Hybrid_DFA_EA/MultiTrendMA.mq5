//+------------------------------------------------------------------+
//|                                                 MultiTrendMA.mq5 |
//|                                  Copyright 2026, Hybrid DFA Quant |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Hybrid DFA Quant"
#property link        "https://www.mql5.com"
#property version     "3.11"
#property description "3本対応マルチトレンド移動平均インジケーター (SMA/EMA/SMMA/LWMA/ALMA・SuperSmoother/ZeroLag補正対応)"
#property indicator_chart_window
#property indicator_buffers 7
#property indicator_plots   3

//--- プロット定義 (Fast: オレンジ赤, Mid: スカイブルー, Slow: マゼンタ)
#property indicator_label1 "Trend MA Fast"
#property indicator_type1  DRAW_LINE
#property indicator_color1 clrOrangeRed
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

#property indicator_label2 "Trend MA Mid"
#property indicator_type2  DRAW_LINE
#property indicator_color2 clrDeepSkyBlue
#property indicator_style2 STYLE_SOLID
#property indicator_width2 2

#property indicator_label3 "Trend MA Slow"
#property indicator_type3  DRAW_LINE
#property indicator_color3 clrMagenta
#property indicator_style3 STYLE_SOLID
#property indicator_width3 2
#property tester_everytick_calculate

#include <Hybrid_DFA_EA\MultiTrendMA.mqh>

//--- 入力パラメータ
input group "=== マルチタイムフレーム (MTF) 設定 ==="
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_CURRENT; // 計算対象タイムフレーム (上位足を指定可能)

input group "=== 移動平均線 基本設定 ==="
input ENUM_TREND_MA_TYPE InpFastMaType     = TREND_MA_LWMA; // [Fast] 移動平均タイプ
input ENUM_MA_PERIOD     InpFastWindow     = MA_PERIOD_8;   // [Fast] 期間 (0で無効)
input ENUM_TREND_MA_TYPE InpMidMaType      = TREND_MA_EMA;  // [Mid] 移動平均タイプ
input ENUM_MA_PERIOD     InpMidWindow      = MA_PERIOD_21;  // [Mid] 期間 (0で無効)
input ENUM_TREND_MA_TYPE InpSlowMaType     = TREND_MA_SMA;  // [Slow] 移動平均タイプ
input ENUM_MA_PERIOD     InpSlowWindow     = MA_PERIOD_89;  // [Slow] 期間 (0で無効)
input ENUM_APPLIED_PRICE InpAppliedPrice   = PRICE_CLOSE;   // 適用価格

input group "=== ALMA 専用パラメータ ==="
input bool   InpAlmaAutoAdaptive    = true;            // ALMAパラメータ自動適応化 (動的推定)
input int    InpAlmaRollingWindow   = 100;             // ローリング観測窓長 W (確定足 30〜250推奨)
input double InpAlmaOffsetMin       = 0.70;            // [自動時] 最小 Offset (レンジ相場用)
input double InpAlmaOffsetMax       = 0.95;            // [自動時] 最大 Offset (トレンド相場用)
input double InpAlmaSigmaMin        = 4.5;             // [自動時] 最小 Sigma (広帯域・強力平滑化)
input double InpAlmaSigmaMax        = 7.5;             // [自動時] 最大 Sigma (狭帯域・鋭敏追従)
input double InpAlmaFastOffset      = 0.92;            // [手動時] Fast ALMA Offset (0.0〜1.0)
input double InpAlmaFastSigma       = 5.5;             // [手動時] Fast ALMA Sigma (1.0〜10.0)
input double InpAlmaMidOffset       = 0.91;            // [手動時] Mid ALMA Offset (0.0〜1.0)
input double InpAlmaMidSigma        = 5.5;             // [手動時] Mid ALMA Sigma (1.0〜10.0)
input double InpAlmaSlowOffset      = 0.90;            // [手動時] Slow ALMA Offset (0.0〜1.0)
input double InpAlmaSlowSigma       = 5.5;             // [手動時] Slow ALMA Sigma (1.0〜10.0)

//--- インジケータバッファ配列
double BufferFast[];
double BufferMid[];
double BufferSlow[];
double BufferPreFiltered[];
double BufferSignalState[]; // +1.0: Bullish, -1.0: Bearish, 0.0: Neutral
double BufferATR[];
double BufferSS[];          // 内部バッファ

//--- 計算対象タイムフレーム
ENUM_TIMEFRAMES g_calc_tf = PERIOD_CURRENT;

//--- MTF キャッシュ用配列 (上位足タイムフレーム用)
MqlRates g_tf_rates[];
int      g_tf_prev_rates_total = 0;
int      g_last_mapped_tf_idx  = 0;

double   g_tf_fast_cache[];
double   g_tf_mid_cache[];
double   g_tf_slow_cache[];
double   g_tf_ss_cache[];
double   g_tf_prefiltered_cache[];
double   g_tf_atr_cache[];
double   g_tf_signal_cache[];
datetime g_tf_time_cache[];

//--- 各移動平均線の構成構造体
struct SingleMaConfig {
  ENUM_TREND_MA_TYPE type;
  int                window;
  double             offset;
  double             sigma;
  double             alpha;       // EMA平滑化係数
  double             weights[];   // FIR重み配列 (SMA, LWMA, ALMA)
  double             sumWeight;
  bool               enabled;
};

SingleMaConfig m_cfgFast;
SingleMaConfig m_cfgMid;
SingleMaConfig m_cfgSlow;
int            m_maxWindow = 1;
int            m_atrPeriod = 20; // ゼロ除算防止用にクランプされた内部ATR期間

//+------------------------------------------------------------------+
//| MAタイプ名取得ヘルパー                                           |
//+------------------------------------------------------------------+
string GetMaTypeName(const ENUM_TREND_MA_TYPE type)
{
  switch(type)
  {
     case TREND_MA_SMA:  return "SMA";
     case TREND_MA_EMA:  return "EMA";
     case TREND_MA_SMMA: return "SMMA";
     case TREND_MA_LWMA: return "LWMA";
     case TREND_MA_ALMA: return "ALMA";
     default:            return "MA";
  }
}

//+------------------------------------------------------------------+
//| 単一MAの設定初期化と重み係数計算                                 |
//+------------------------------------------------------------------+
bool InitMaConfig(SingleMaConfig &cfg,
                 const ENUM_TREND_MA_TYPE type,
                 const int window,
                 const double offset,
                 const double sigma)
{
  cfg.type      = type;
  cfg.window    = window;
  cfg.offset    = offset;
  cfg.sigma     = sigma;
  cfg.alpha     = 0.0;
  cfg.sumWeight = 0.0;
  cfg.enabled   = (window >= 1);
  ArrayFree(cfg.weights);

  if(!cfg.enabled) return true;

  if(type == TREND_MA_EMA)
  {
     cfg.alpha = 2.0 / (double)(window + 1);
     return true;
  }
  else if(type == TREND_MA_SMMA)
  {
     return true;
  }

  // FIR型 (SMA, LWMA, ALMA)
  ArrayResize(cfg.weights, window);
  cfg.sumWeight = 0.0;

  switch(type)
  {
     case TREND_MA_SMA:
        for(int k = 0; k < window; k++)
        {
           cfg.weights[k] = 1.0;
           cfg.sumWeight += 1.0;
        }
        break;

     case TREND_MA_LWMA:
        for(int k = 0; k < window; k++)
        {
           cfg.weights[k] = (double)(window - k);
           cfg.sumWeight += cfg.weights[k];
        }
        break;

     case TREND_MA_ALMA:
     default:
     {
        if(sigma <= 0.0) return false;
        double clpOffset = MathMin(MathMax(offset, 0.0), 1.0);
        double m = (1.0 - clpOffset) * (double)(window - 1);
        double s = (double)window / sigma;
        double two_s_sq = 2.0 * s * s;
        for(int k = 0; k < window; k++)
        {
           double diff = (double)k - m;
           cfg.weights[k] = MathExp(-(diff * diff) / two_s_sq);
           cfg.sumWeight += cfg.weights[k];
        }
        break;
     }
  }

  return (cfg.sumWeight > 0.0);
}

//+------------------------------------------------------------------+
//| 初期化関数                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
  // mqh の定数マクロを使用してバッファをバインド
  SetIndexBuffer(MULTI_TREND_MA_BUFFER_FAST,      BufferFast,        INDICATOR_DATA);
  SetIndexBuffer(MULTI_TREND_MA_BUFFER_MID,       BufferMid,         INDICATOR_DATA);
  SetIndexBuffer(MULTI_TREND_MA_BUFFER_SLOW,      BufferSlow,        INDICATOR_DATA);
  SetIndexBuffer(MULTI_TREND_MA_BUFFER_PREFILTER, BufferPreFiltered, INDICATOR_CALCULATIONS);
  SetIndexBuffer(MULTI_TREND_MA_BUFFER_SIGNAL,    BufferSignalState, INDICATOR_CALCULATIONS);
  SetIndexBuffer(MULTI_TREND_MA_BUFFER_ATR,       BufferATR,         INDICATOR_CALCULATIONS);
  SetIndexBuffer(MULTI_TREND_MA_BUFFER_SS,        BufferSS,          INDICATOR_CALCULATIONS);

  ArraySetAsSeries(BufferFast,        false);
  ArraySetAsSeries(BufferMid,         false);
  ArraySetAsSeries(BufferSlow,        false);
  ArraySetAsSeries(BufferPreFiltered, false);
  ArraySetAsSeries(BufferSignalState, false);
  ArraySetAsSeries(BufferATR,         false);
  ArraySetAsSeries(BufferSS,          false);

  PlotIndexSetDouble(MULTI_TREND_MA_BUFFER_FAST, PLOT_EMPTY_VALUE, EMPTY_VALUE);
  PlotIndexSetDouble(MULTI_TREND_MA_BUFFER_MID,  PLOT_EMPTY_VALUE, EMPTY_VALUE);
  PlotIndexSetDouble(MULTI_TREND_MA_BUFFER_SLOW, PLOT_EMPTY_VALUE, EMPTY_VALUE);

  // ラベル設定
  string labelFast = StringFormat("%s(%d)", GetMaTypeName(InpFastMaType), InpFastWindow);
  string labelMid  = StringFormat("%s(%d)", GetMaTypeName(InpMidMaType),  InpMidWindow);
  string labelSlow = StringFormat("%s(%d)", GetMaTypeName(InpSlowMaType), InpSlowWindow);

  PlotIndexSetString(MULTI_TREND_MA_BUFFER_FAST, PLOT_LABEL, labelFast);
  PlotIndexSetString(MULTI_TREND_MA_BUFFER_MID,  PLOT_LABEL, labelMid);
  PlotIndexSetString(MULTI_TREND_MA_BUFFER_SLOW, PLOT_LABEL, labelSlow);

  g_calc_tf = (InpTimeframe == PERIOD_CURRENT) ? _Period : InpTimeframe;

  string tfStr = (g_calc_tf == _Period) ? "" : StringFormat("[%s] ", EnumToString(g_calc_tf));
  IndicatorSetString(INDICATOR_SHORTNAME,
                     StringFormat("%sMultiTrendMA(F:%s, M:%s, S:%s)", tfStr, labelFast, labelMid, labelSlow));
  IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

  // MA設定の初期化
  if(!InitMaConfig(m_cfgFast, InpFastMaType, InpFastWindow, InpAlmaFastOffset, InpAlmaFastSigma) ||
     !InitMaConfig(m_cfgMid,  InpMidMaType,  InpMidWindow,  InpAlmaMidOffset,  InpAlmaMidSigma)  ||
     !InitMaConfig(m_cfgSlow, InpSlowMaType, InpSlowWindow, InpAlmaSlowOffset, InpAlmaSlowSigma))
  {
     Print("[MultiTrendMA] 初期化エラー: 重み係数の計算に失敗しました。");
     return(INIT_PARAMETERS_INCORRECT);
  }

  m_maxWindow = 1;
  if(m_cfgFast.enabled) m_maxWindow = MathMax(m_maxWindow, m_cfgFast.window);
  if(m_cfgMid.enabled)  m_maxWindow = MathMax(m_maxWindow, m_cfgMid.window);
  if(m_cfgSlow.enabled) m_maxWindow = MathMax(m_maxWindow, m_cfgSlow.window);

  // パラメータ検証: 基本設定
  if(InpFastWindow < 0 || InpMidWindow < 0 || InpSlowWindow < 0)
  {
     Print("[MultiTrendMA] 初期化エラー: 期間には0以上の整数を指定してください。");
     return(INIT_PARAMETERS_INCORRECT);
  }

  // パラメータ検証: ALMA自動適応設定
  if(InpAlmaAutoAdaptive)
  {
     if(InpAlmaRollingWindow < 5)
     {
        PrintFormat("[MultiTrendMA] 初期化エラー: InpAlmaRollingWindow は 5 以上を指定してください (現在値: %d)。", InpAlmaRollingWindow);
        return(INIT_PARAMETERS_INCORRECT);
     }
     if(InpAlmaOffsetMin < 0.0 || InpAlmaOffsetMax > 1.0 || InpAlmaOffsetMin > InpAlmaOffsetMax)
     {
        PrintFormat("[MultiTrendMA] 初期化エラー: InpAlmaOffsetMin/Max は 0.0〜1.0 かつ Min <= Max である必要があります (Min=%.2f, Max=%.2f)。",
                    InpAlmaOffsetMin, InpAlmaOffsetMax);
        return(INIT_PARAMETERS_INCORRECT);
     }
     if(InpAlmaSigmaMin <= 0.0 || InpAlmaSigmaMax <= 0.0 || InpAlmaSigmaMin > InpAlmaSigmaMax)
     {
        PrintFormat("[MultiTrendMA] 初期化エラー: インジケーター Sigma は正の値かつ Min <= Max である必要があります (Min=%.2f, Max=%.2f)。",
                    InpAlmaSigmaMin, InpAlmaSigmaMax);
        return(INIT_PARAMETERS_INCORRECT);
     }
  }

  // ATR計算用期間の初期化（標準14）
  m_atrPeriod = 14;

  PrintFormat("[MultiTrendMA] 初期化成功: TF=%s Fast=[%s %d] Mid=[%s %d] Slow=[%s %d] MaxWin=%d ALMA_Adaptive=%s(W=%d, Offset=%.2f-%.2f, Sigma=%.1f-%.1f)",
              EnumToString(g_calc_tf),
              GetMaTypeName(InpFastMaType), InpFastWindow,
              GetMaTypeName(InpMidMaType), InpMidWindow,
              GetMaTypeName(InpSlowMaType), InpSlowWindow,
              m_maxWindow,
              InpAlmaAutoAdaptive ? "ON" : "OFF", InpAlmaRollingWindow,
              InpAlmaOffsetMin, InpAlmaOffsetMax, InpAlmaSigmaMin, InpAlmaSigmaMax);

  return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 適用価格取得ヘルパー (カレント足用)                              |
//+------------------------------------------------------------------+
double GetAppliedPrice(const int idx, const double &open[], const double &high[],
                      const double &low[], const double &close[])
{
  switch(InpAppliedPrice)
  {
     case PRICE_OPEN:     return open[idx];
     case PRICE_HIGH:     return high[idx];
     case PRICE_LOW:      return low[idx];
     case PRICE_MEDIAN:   return (high[idx] + low[idx]) * 0.5;
     case PRICE_TYPICAL:  return (high[idx] + low[idx] + close[idx]) / 3.0;
     case PRICE_WEIGHTED: return (high[idx] + low[idx] + 2.0 * close[idx]) * 0.25;
     case PRICE_CLOSE:
     default:             return close[idx];
  }
}

//+------------------------------------------------------------------+
//| 適用価格取得ヘルパー (MqlRates構造体用: MTF上位足)               |
//+------------------------------------------------------------------+
double GetAppliedPriceFromRate(const MqlRates &rate, const ENUM_APPLIED_PRICE price_type)
{
  switch(price_type)
  {
     case PRICE_OPEN:     return rate.open;
     case PRICE_HIGH:     return rate.high;
     case PRICE_LOW:      return rate.low;
     case PRICE_MEDIAN:   return (rate.high + rate.low) * 0.5;
     case PRICE_TYPICAL:  return (rate.high + rate.low + rate.close) / 3.0;
     case PRICE_WEIGHTED: return (rate.high + rate.low + 2.0 * rate.close) * 0.25;
     case PRICE_CLOSE:
     default:             return rate.close;
  }
}

//+------------------------------------------------------------------+
//| カウフマン効率比 (KER) に基づく動的ALMAパラメータ推定関数       |
//+------------------------------------------------------------------+
void EstimateAdaptiveAlmaParams(const int eval_idx,
                                const double &prices[],
                                const int rolling_window,
                                const double offset_min,
                                const double offset_max,
                                const double sigma_min,
                                const double sigma_max,
                                double &out_offset,
                                double &out_sigma)
{
   if(eval_idx < rolling_window)
   {
      // 窓幅に満たない初期期間は中央値でフォールバック
      out_offset = (offset_min + offset_max) * 0.5;
      out_sigma  = (sigma_min + sigma_max) * 0.5;
      return;
   }

   // 1. 純移動量 (Net Change)
   double net_change = MathAbs(prices[eval_idx] - prices[eval_idx - rolling_window]);

   // 2. 総経路長 (Total Path Length)
   double total_path = 0.0;
   for(int j = 0; j < rolling_window; j++)
   {
      total_path += MathAbs(prices[eval_idx - j] - prices[eval_idx - j - 1]);
   }

   // 3. 効率比 ER (0.0: 完全ランダム/レンジ 〜 1.0: 完全トレンド)
   double er = 0.0;
   if(total_path > 1e-12)
      er = net_change / total_path;
   if(er > 1.0) er = 1.0;

   // 4. 動的スケーリング (線形マッピング)
   out_offset = offset_min + er * (offset_max - offset_min);
   out_sigma  = sigma_min  + er * (sigma_max - sigma_min);
}

//+------------------------------------------------------------------+
//| 単一MAの逐次計算ヘルパー (動的適応型ALMA対応)                    |
//+------------------------------------------------------------------+
double CalculateMaBar(const SingleMaConfig &cfg,
                     const int i,
                     const double &prices[],
                     const double prev_ma,
                     const double dyn_offset = -1.0,
                     const double dyn_sigma = -1.0)
{
  if(!cfg.enabled || i < cfg.window - 1)
     return EMPTY_VALUE;

  if(cfg.type == TREND_MA_EMA)
  {
     if(i == cfg.window - 1 || prev_ma == EMPTY_VALUE)
     {
        double sum = 0.0;
        for(int k = 0; k < cfg.window; k++) sum += prices[i - k];
        return (sum / (double)cfg.window);
     }
     return (cfg.alpha * prices[i] + (1.0 - cfg.alpha) * prev_ma);
  }
  else if(cfg.type == TREND_MA_SMMA)
  {
     if(i == cfg.window - 1 || prev_ma == EMPTY_VALUE)
     {
        double sum = 0.0;
        for(int k = 0; k < cfg.window; k++) sum += prices[i - k];
        return (sum / (double)cfg.window);
     }
     return ((prev_ma * (cfg.window - 1) + prices[i]) / (double)cfg.window);
  }
  else if(cfg.type == TREND_MA_ALMA && dyn_offset >= 0.0 && dyn_sigma > 0.0)
  {
     // 動的適応型 ALMA 計算 (バー毎にガウス重みを動的生成)
     double clpOffset = MathMin(MathMax(dyn_offset, 0.0), 1.0);
     double m = (1.0 - clpOffset) * (double)(cfg.window - 1);
     double s = (double)cfg.window / dyn_sigma;
     double two_s_sq = 2.0 * s * s;

     double sum = 0.0;
     double sumW = 0.0;
     for(int k = 0; k < cfg.window; k++)
     {
        double diff = (double)k - m;
        double w = MathExp(-(diff * diff) / two_s_sq);
        sum += prices[i - k] * w;
        sumW += w;
     }
     return (sumW > 0.0) ? (sum / sumW) : prices[i];
  }
  else
  {
     // 固定 FIR型 (SMA, LWMA, 手動ALMA)
     double sum = 0.0;
     for(int k = 0; k < cfg.window; k++)
     {
        sum += prices[i - k] * cfg.weights[k];
     }
     return (sum / cfg.sumWeight);
  }
}

//+------------------------------------------------------------------+
//| 計算メインルーチン                                               |
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
     return 0;

  // =================================================================
  // パス A: カレント足計算 (InpTimeframe == PERIOD_CURRENT または _Period)
  // =================================================================
  if(g_calc_tf == _Period)
  {
     ArraySetAsSeries(open,  false);
     ArraySetAsSeries(high,  false);
     ArraySetAsSeries(low,   false);
     ArraySetAsSeries(close, false);

     int start = prev_calculated - 1;
     if(start < 0) start = 0;

     for(int i = start; i < rates_total; i++)
     {
        double rawPrice = GetAppliedPrice(i, open, high, low, close);
        BufferSS[i] = rawPrice;
        BufferPreFiltered[i] = rawPrice;

        // ALMA動的推定 (InpAlmaAutoAdaptive 有効時)
        double dyn_offset = -1.0;
        double dyn_sigma  = -1.0;
        if(InpAlmaAutoAdaptive && (InpFastMaType == TREND_MA_ALMA || InpMidMaType == TREND_MA_ALMA || InpSlowMaType == TREND_MA_ALMA))
        {
           int eval_idx = (i == rates_total - 1 && i > 0) ? (i - 1) : i;
           EstimateAdaptiveAlmaParams(eval_idx, BufferPreFiltered, InpAlmaRollingWindow,
                                      InpAlmaOffsetMin, InpAlmaOffsetMax,
                                      InpAlmaSigmaMin, InpAlmaSigmaMax,
                                      dyn_offset, dyn_sigma);
        }

        // 1. 移動平均計算 (Fast, Mid, Slow)
        double prevFast = (i > 0) ? BufferFast[i - 1] : EMPTY_VALUE;
        double prevMid  = (i > 0) ? BufferMid[i - 1]  : EMPTY_VALUE;
        double prevSlow = (i > 0) ? BufferSlow[i - 1] : EMPTY_VALUE;

        BufferFast[i] = CalculateMaBar(m_cfgFast, i, BufferPreFiltered, prevFast, dyn_offset, dyn_sigma);
        BufferMid[i]  = CalculateMaBar(m_cfgMid,  i, BufferPreFiltered, prevMid,  dyn_offset, dyn_sigma);
        BufferSlow[i] = CalculateMaBar(m_cfgSlow, i, BufferPreFiltered, prevSlow, dyn_offset, dyn_sigma);

        // 2. True Range & ATR 計算
        double tr = high[i] - low[i];
        if(i > 0)
        {
           double tr1 = MathAbs(high[i] - close[i - 1]);
           double tr2 = MathAbs(low[i] - close[i - 1]);
           if(tr1 > tr) tr = tr1;
           if(tr2 > tr) tr = tr2;
        }

        double curAtr = tr;
        if(i > 0)
        {
           double prevAtr = BufferATR[i - 1];
           if(i >= m_atrPeriod)
           {
              curAtr = (prevAtr * (double)(m_atrPeriod - 1) + tr) / (double)m_atrPeriod;
           }
           else
           {
              curAtr = (prevAtr * (double)i + tr) / (double)(i + 1);
           }
        }
        BufferATR[i] = curAtr;

        // 3. シグナル状態判定 (Fast vs Slow: 直接クロス)
        if(BufferFast[i] != EMPTY_VALUE && BufferSlow[i] != EMPTY_VALUE)
        {
           double diff = BufferFast[i] - BufferSlow[i];
           if(diff > 0.0)
              BufferSignalState[i] = MULTI_TREND_MA_SIGNAL_BULLISH;
           else if(diff < 0.0)
              BufferSignalState[i] = MULTI_TREND_MA_SIGNAL_BEARISH;
           else
              BufferSignalState[i] = (i > 0) ? BufferSignalState[i - 1] : MULTI_TREND_MA_SIGNAL_NEUTRAL;
        }
        else
        {
           BufferSignalState[i] = MULTI_TREND_MA_SIGNAL_NEUTRAL;
        }
     }

     return rates_total;
  }

  // =================================================================
  // パス B: マルチタイムフレーム (上位足キャッシュ & チャート足マッピング)
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
  }

  int tf_rates_total = ArraySize(g_tf_rates);
  if(tf_rates_total < 2) return(prev_calculated);

  if(ArraySize(g_tf_fast_cache) != tf_rates_total)
  {
     ArrayResize(g_tf_fast_cache,        tf_rates_total);
     ArrayResize(g_tf_mid_cache,         tf_rates_total);
     ArrayResize(g_tf_slow_cache,        tf_rates_total);
     ArrayResize(g_tf_ss_cache,          tf_rates_total);
     ArrayResize(g_tf_prefiltered_cache, tf_rates_total);
     ArrayResize(g_tf_atr_cache,         tf_rates_total);
     ArrayResize(g_tf_signal_cache,      tf_rates_total);
     ArrayResize(g_tf_time_cache,        tf_rates_total);
  }

  int tf_start = 0;
  if(g_tf_prev_rates_total > 0 && tf_rates_total >= g_tf_prev_rates_total)
     tf_start = g_tf_prev_rates_total - 1;

  for(int k = tf_start; k < tf_rates_total && !IsStopped(); k++)
  {
     double rawPrice = GetAppliedPriceFromRate(g_tf_rates[k], InpAppliedPrice);
     g_tf_ss_cache[k] = rawPrice;
     g_tf_prefiltered_cache[k] = rawPrice;

     // ALMA動的推定 (InpAlmaAutoAdaptive 有効時)
     double dyn_offset = -1.0;
     double dyn_sigma  = -1.0;
     if(InpAlmaAutoAdaptive && (InpFastMaType == TREND_MA_ALMA || InpMidMaType == TREND_MA_ALMA || InpSlowMaType == TREND_MA_ALMA))
     {
        int eval_idx = (k == tf_rates_total - 1 && k > 0) ? (k - 1) : k;
        EstimateAdaptiveAlmaParams(eval_idx, g_tf_prefiltered_cache, InpAlmaRollingWindow,
                                   InpAlmaOffsetMin, InpAlmaOffsetMax,
                                   InpAlmaSigmaMin, InpAlmaSigmaMax,
                                   dyn_offset, dyn_sigma);
     }

     // 1. 移動平均計算 (Fast, Mid, Slow)
     double prevFast = (k > 0) ? g_tf_fast_cache[k - 1] : EMPTY_VALUE;
     double prevMid  = (k > 0) ? g_tf_mid_cache[k - 1]  : EMPTY_VALUE;
     double prevSlow = (k > 0) ? g_tf_slow_cache[k - 1] : EMPTY_VALUE;

     g_tf_fast_cache[k] = CalculateMaBar(m_cfgFast, k, g_tf_prefiltered_cache, prevFast, dyn_offset, dyn_sigma);
     g_tf_mid_cache[k]  = CalculateMaBar(m_cfgMid,  k, g_tf_prefiltered_cache, prevMid,  dyn_offset, dyn_sigma);
     g_tf_slow_cache[k] = CalculateMaBar(m_cfgSlow, k, g_tf_prefiltered_cache, prevSlow, dyn_offset, dyn_sigma);

     // 2. True Range & ATR 計算
     double tr = g_tf_rates[k].high - g_tf_rates[k].low;
     if(k > 0)
     {
        double tr1 = MathAbs(g_tf_rates[k].high - g_tf_rates[k - 1].close);
        double tr2 = MathAbs(g_tf_rates[k].low  - g_tf_rates[k - 1].close);
        if(tr1 > tr) tr = tr1;
        if(tr2 > tr) tr = tr2;
     }

     double curAtr = tr;
     if(k > 0)
     {
        double prevAtr = g_tf_atr_cache[k - 1];
        if(k >= m_atrPeriod)
        {
           curAtr = (prevAtr * (double)(m_atrPeriod - 1) + tr) / (double)m_atrPeriod;
        }
        else
        {
           curAtr = (prevAtr * (double)k + tr) / (double)(k + 1);
        }
     }
     g_tf_atr_cache[k] = curAtr;

     // 3. シグナル状態判定 (直接クロス)
     if(g_tf_fast_cache[k] != EMPTY_VALUE && g_tf_slow_cache[k] != EMPTY_VALUE)
     {
        double diff = g_tf_fast_cache[k] - g_tf_slow_cache[k];
        if(diff > 0.0)
           g_tf_signal_cache[k] = MULTI_TREND_MA_SIGNAL_BULLISH;
        else if(diff < 0.0)
           g_tf_signal_cache[k] = MULTI_TREND_MA_SIGNAL_BEARISH;
        else
           g_tf_signal_cache[k] = (k > 0) ? g_tf_signal_cache[k - 1] : MULTI_TREND_MA_SIGNAL_NEUTRAL;
     }
     else
     {
        g_tf_signal_cache[k] = MULTI_TREND_MA_SIGNAL_NEUTRAL;
     }

     g_tf_time_cache[k] = g_tf_rates[k].time;
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

     BufferFast[i]        = g_tf_fast_cache[tf_idx];
     BufferMid[i]         = g_tf_mid_cache[tf_idx];
     BufferSlow[i]        = g_tf_slow_cache[tf_idx];
     BufferSS[i]          = g_tf_ss_cache[tf_idx];
     BufferPreFiltered[i] = g_tf_prefiltered_cache[tf_idx];
     BufferATR[i]         = g_tf_atr_cache[tf_idx];
     BufferSignalState[i] = g_tf_signal_cache[tf_idx];
  }

  return rates_total;
}
//+------------------------------------------------------------------+