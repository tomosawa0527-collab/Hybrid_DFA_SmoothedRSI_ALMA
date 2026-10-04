//+------------------------------------------------------------------+
//|                                                 MultiTrendMA.mq5 |
//|                                  Copyright 2026, Hybrid DFA Quant |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Hybrid DFA Quant"
#property link        "https://www.mql5.com"
#property version     "3.00"
#property description "3本対応マルチトレンド移動平均インジケーター (SMA/EMA/SMMA/LWMA/ALMA・個別タイプ/色分けプロット)"
#property indicator_chart_window
#property indicator_buffers 6
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

#include <Hybrid_DFA_EA\MultiTrendMA.mqh>

//--- 入力パラメータ
input group "=== 移動平均線 基本設定 ==="
input ENUM_TREND_MA_TYPE InpFastMaType     = TREND_MA_LWMA; // [Fast] 移動平均タイプ
input int                InpFastWindow     = 8;             // [Fast] 期間 (0で無効)
input ENUM_TREND_MA_TYPE InpMidMaType      = TREND_MA_EMA;  // [Mid] 移動平均タイプ
input int                InpMidWindow      = 21;            // [Mid] 期間 (0で無効)
input ENUM_TREND_MA_TYPE InpSlowMaType     = TREND_MA_SMA;  // [Slow] 移動平均タイプ
input int                InpSlowWindow     = 89;            // [Slow] 期間 (0で無効)
input ENUM_APPLIED_PRICE InpAppliedPrice   = PRICE_CLOSE;   // 適用価格

input group "=== ALMA 専用パラメータ ==="
input double InpAlmaFastOffset = 0.92;                      // [Fast ALMA] Offset (0.0〜1.0)
input double InpAlmaFastSigma  = 5.5;                       // [Fast ALMA] Sigma (1.0〜10.0)
input double InpAlmaMidOffset  = 0.91;                      // [Mid ALMA] Offset (0.0〜1.0)
input double InpAlmaMidSigma   = 5.5;                       // [Mid ALMA] Sigma (1.0〜10.0)
input double InpAlmaSlowOffset = 0.90;                      // [Slow ALMA] Offset (0.0〜1.0)
input double InpAlmaSlowSigma  = 5.5;                       // [Slow ALMA] Sigma (1.0〜10.0)

input group "=== 高度フィルター設定 (オプション) ==="
input bool   InpUseSuperSmoother   = false;                 // 2-Pole SuperSmoother有効化 (OFF推奨)
input int    InpSSCutoff           = 4;                     // 高周波カットオフ周期 (bars: 4推奨)
input bool   InpUseZeroLagLead     = false;                 // 先行モメンタム補正有効化
input double InpLeadFactor         = 0.40;                  // 先行モメンタム係数 (0.1〜1.0)
input bool   InpUseSchmittTrigger  = false;                 // ATR連動シュミットトリガー有効化 (Fast vs Slow)
input int    InpHysteresisAtrPeriod= 20;                    // ヒステリシス用ATR期間
input double InpHysteresisFactor   = 0.08;                  // 不感帯幅係数 (ATR比率)

//--- インジケータバッファ
double BufferFast[];
double BufferMid[];
double BufferSlow[];
double BufferPreFiltered[];
double BufferSignalState[]; // +1.0: Bullish, -1.0: Bearish, 0.0: Neutral
double BufferATR[];

//--- SuperSmoother 内部キャッシュ係数
double ss_c1, ss_c2, ss_c3;

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
   SetIndexBuffer(0, BufferFast,        INDICATOR_DATA);
   SetIndexBuffer(1, BufferMid,         INDICATOR_DATA);
   SetIndexBuffer(2, BufferSlow,        INDICATOR_DATA);
   SetIndexBuffer(3, BufferPreFiltered, INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, BufferSignalState, INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, BufferATR,         INDICATOR_CALCULATIONS);

   ArraySetAsSeries(BufferFast,        false);
   ArraySetAsSeries(BufferMid,         false);
   ArraySetAsSeries(BufferSlow,        false);
   ArraySetAsSeries(BufferPreFiltered, false);
   ArraySetAsSeries(BufferSignalState, false);
   ArraySetAsSeries(BufferATR,         false);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   // ラベル設定
   string labelFast = StringFormat("%s(%d)", GetMaTypeName(InpFastMaType), InpFastWindow);
   string labelMid  = StringFormat("%s(%d)", GetMaTypeName(InpMidMaType),  InpMidWindow);
   string labelSlow = StringFormat("%s(%d)", GetMaTypeName(InpSlowMaType), InpSlowWindow);

   PlotIndexSetString(0, PLOT_LABEL, labelFast);
   PlotIndexSetString(1, PLOT_LABEL, labelMid);
   PlotIndexSetString(2, PLOT_LABEL, labelSlow);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("MultiTrendMA(F:%s, M:%s, S:%s)", labelFast, labelMid, labelSlow));
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

   if(InpSSCutoff < 2 || InpHysteresisAtrPeriod < 1 || InpLeadFactor < 0.0)
   {
      PrintFormat("[MultiTrendMA] 初期化エラー: パラメータ設定が不正です (SSCutoff=%d, HysteresisAtrPeriod=%d, LeadFactor=%.2f)。",
                  InpSSCutoff, InpHysteresisAtrPeriod, InpLeadFactor);
      return(INIT_PARAMETERS_INCORRECT);
   }

   // SuperSmoother 係数初期化 (2-Pole Butterworth 低遅延設計)
   double ss_a1 = MathExp(-1.414213562 * M_PI / (double)InpSSCutoff);
   double ss_b1 = 2.0 * ss_a1 * MathCos(1.414213562 * M_PI / (double)InpSSCutoff);
   ss_c2 = ss_b1;
   ss_c3 = -ss_a1 * ss_a1;
   ss_c1 = 1.0 - ss_c2 - ss_c3;

   PrintFormat("[MultiTrendMA] 初期化成功: Fast=[%s %d] Mid=[%s %d] Slow=[%s %d] MaxWin=%d Price=%d",
               GetMaTypeName(InpFastMaType), InpFastWindow,
               GetMaTypeName(InpMidMaType), InpMidWindow,
               GetMaTypeName(InpSlowMaType), InpSlowWindow,
               m_maxWindow, (int)InpAppliedPrice);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 適用価格取得ヘルパー                                             |
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
//| 単一MAの逐次計算ヘルパー                                         |
//+------------------------------------------------------------------+
double CalculateMaBar(const SingleMaConfig &cfg,
                      const int i,
                      const double &prices[],
                      const double prev_ma)
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
   else
   {
      // FIR型 (SMA, LWMA, ALMA)
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
   if(rates_total < m_maxWindow)
      return 0;

   ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   int start = prev_calculated - 1;
   if(start < 0) start = 0;

   // 初回初期化: 未満バーは EMPTY_VALUE に設定
   if(start < m_maxWindow - 1)
   {
      for(int i = 0; i < m_maxWindow - 1; i++)
      {
         BufferFast[i]        = EMPTY_VALUE;
         BufferMid[i]         = EMPTY_VALUE;
         BufferSlow[i]        = EMPTY_VALUE;
         BufferPreFiltered[i] = GetAppliedPrice(i, open, high, low, close);
         BufferSignalState[i] = 0.0;
         BufferATR[i]         = high[i] - low[i];
      }
      start = m_maxWindow - 1;
   }

   for(int i = start; i < rates_total; i++)
   {
      double rawPrice = GetAppliedPrice(i, open, high, low, close);

      // 1. SuperSmoother による高周波ジッター遮断 (オプション)
      double clean = rawPrice;
      if(InpUseSuperSmoother)
      {
         if(i >= 2)
         {
            double prevRaw = GetAppliedPrice(i - 1, open, high, low, close);
            clean = ss_c1 * (rawPrice + prevRaw) * 0.5 +
                    ss_c2 * BufferPreFiltered[i - 1] +
                    ss_c3 * BufferPreFiltered[i - 2];
         }
         else if(i == 1)
         {
            clean = (rawPrice + GetAppliedPrice(0, open, high, low, close)) * 0.5;
         }
      }

      // 2. 先行モメンタム補正 (Zero-Lag Feedforward: オプション)
      if(InpUseZeroLagLead && i >= 1)
      {
         double prevP = GetAppliedPrice(i - 1, open, high, low, close);
         clean = clean + InpLeadFactor * (clean - prevP);
      }

      BufferPreFiltered[i] = clean;

      // 3. 移動平均計算 (Fast, Mid, Slow)
      double prevFast = (i > 0) ? BufferFast[i - 1] : EMPTY_VALUE;
      double prevMid  = (i > 0) ? BufferMid[i - 1]  : EMPTY_VALUE;
      double prevSlow = (i > 0) ? BufferSlow[i - 1] : EMPTY_VALUE;

      BufferFast[i] = CalculateMaBar(m_cfgFast, i, BufferPreFiltered, prevFast);
      BufferMid[i]  = CalculateMaBar(m_cfgMid,  i, BufferPreFiltered, prevMid);
      BufferSlow[i] = CalculateMaBar(m_cfgSlow, i, BufferPreFiltered, prevSlow);

      // 4. True Range & ATR 計算
      double tr = high[i] - low[i];
      if(i > 0)
      {
         double tr1 = MathAbs(high[i] - close[i - 1]);
         double tr2 = MathAbs(low[i] - close[i - 1]);
         if(tr1 > tr) tr = tr1;
         if(tr2 > tr) tr = tr2;
      }
      double prevAtr = (i > 0) ? BufferATR[i - 1] : tr;
      double curAtr  = tr;
      if(i >= InpHysteresisAtrPeriod)
      {
         curAtr = (prevAtr * (double)(InpHysteresisAtrPeriod - 1) + tr) / (double)InpHysteresisAtrPeriod;
      }
      BufferATR[i] = curAtr;

      // 5. シグナル状態判定 (Fast vs Slow: シュミットトリガーまたは直接クロス)
      if(BufferFast[i] != EMPTY_VALUE && BufferSlow[i] != EMPTY_VALUE)
      {
         double diff = BufferFast[i] - BufferSlow[i];
         if(InpUseSchmittTrigger)
         {
            double h_band = curAtr * InpHysteresisFactor;
            if(diff > h_band)
               BufferSignalState[i] = 1.0;
            else if(diff < -h_band)
               BufferSignalState[i] = -1.0;
            else
               BufferSignalState[i] = (i > 0) ? BufferSignalState[i - 1] : 0.0;
         }
         else
         {
            if(diff > 0.0)
               BufferSignalState[i] = 1.0;
            else if(diff < 0.0)
               BufferSignalState[i] = -1.0;
            else
               BufferSignalState[i] = (i > 0) ? BufferSignalState[i - 1] : 0.0;
         }
      }
      else
      {
         BufferSignalState[i] = 0.0;
      }
   }

   return rates_total;
}
//+------------------------------------------------------------------+
