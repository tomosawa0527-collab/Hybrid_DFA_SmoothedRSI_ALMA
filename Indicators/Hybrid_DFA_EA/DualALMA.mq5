//+------------------------------------------------------------------+
//|                                                     DualALMA.mq5 |
//|                                  Copyright 2026, Hybrid DFA System |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA System"
#property link "https://www.mql5.com"
#property version "1.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots 2

//--- プロット定義
#property indicator_label1 "ALMA Fast"
#property indicator_type1 DRAW_LINE
#property indicator_color1 clrOrangeRed
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

#property indicator_label2 "ALMA Slow"
#property indicator_type2 DRAW_LINE
#property indicator_color2 clrDeepSkyBlue
#property indicator_style2 STYLE_SOLID
#property indicator_width2 2

//--- 入力パラメータ
//--- トレンド戦略 (Dual ALMA) 設定
input int InpAlmaFastWindow = 9;                         // 短期 ALMA 窓幅 (Fast Window)
input int InpAlmaSlowWindow = 21;  // 長期 ALMA 窓幅 (Slow Window)
input double InpAlmaOffset = 0.85; // ALMA Offset (重心シフト 0.0〜1.0)
input double InpAlmaSigma = 6.0;   // ALMA Sigma (ガウス幅)
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // 適用価格

//--- バッファ
double AlmaFastBuffer[];
double AlmaSlowBuffer[];

//--- 加重ウェイト事前計算用
double wFast[];
double sumWFast;
double wSlow[];
double sumWSlow;

//+------------------------------------------------------------------+
//| ALMA の加重係数を事前計算 (k=0 が最新バー、k=window-1 が最古バー) |
//+------------------------------------------------------------------+
bool CalculateWeights(const int window, const double offset, const double sigma,
                      double &weights[], double &sumWeight) {
  if (window < 1 || sigma <= 0.0)
    return false;

  ArrayResize(weights, window);
  sumWeight = 0.0;

  // 重心位置 m (0=最新バー, window-1=最古バー)
  // offset=0.85 の場合、最新バー寄りの (1.0 - 0.85) * (window - 1) に重心を配置
  double m = (1.0 - offset) * (double)(window - 1);
  double s = (double)window / sigma;
  double two_s_sq = 2.0 * s * s;

  for (int k = 0; k < window; k++) {
    double diff = (double)k - m;
    weights[k] = MathExp(-(diff * diff) / two_s_sq);
    sumWeight += weights[k];
  }

  return (sumWeight > 0.0);
}

//+------------------------------------------------------------------+
//| カスタムインディケータ初期化関数                                 |
//+------------------------------------------------------------------+
int OnInit() {
  // 標準インジケータバッファ (0=最古, rates_total-1=最新)
  SetIndexBuffer(0, AlmaFastBuffer, INDICATOR_DATA);
  SetIndexBuffer(1, AlmaSlowBuffer, INDICATOR_DATA);

  ArraySetAsSeries(AlmaFastBuffer, false);
  ArraySetAsSeries(AlmaSlowBuffer, false);

  PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
  PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

  IndicatorSetString(INDICATOR_SHORTNAME,
                     StringFormat("DualALMA(Fast=%d, Slow=%d)",
                                  InpAlmaFastWindow, InpAlmaSlowWindow));
  IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

  if (InpAlmaFastWindow < 1 || InpAlmaSlowWindow < 1 ||
      InpAlmaFastWindow >= InpAlmaSlowWindow) {
    Print("[DualALMA] エラー: 窓幅パラメータが不正です (Fast < Slow "
          "である必要があります)。");
    return INIT_PARAMETERS_INCORRECT;
  }

  if (!CalculateWeights(InpAlmaFastWindow, InpAlmaOffset, InpAlmaSigma, wFast,
                        sumWFast) ||
      !CalculateWeights(InpAlmaSlowWindow, InpAlmaOffset, InpAlmaSigma, wSlow,
                        sumWSlow)) {
    Print("[DualALMA] エラー: ウェイト計算に失敗しました。");
    return INIT_PARAMETERS_INCORRECT;
  }

  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 適用価格の取得ヘルパー (index は 0=最古, rates_total-1=最新)     |
//+------------------------------------------------------------------+
double GetPrice(const int index, const double &open[], const double &high[],
                const double &low[], const double &close[]) {
  switch (InpAppliedPrice) {
  case PRICE_OPEN:
    return open[index];
  case PRICE_HIGH:
    return high[index];
  case PRICE_LOW:
    return low[index];
  case PRICE_MEDIAN:
    return (high[index] + low[index]) * 0.5;
  case PRICE_TYPICAL:
    return (high[index] + low[index] + close[index]) / 3.0;
  case PRICE_WEIGHTED:
    return (high[index] + low[index] + 2.0 * close[index]) * 0.25;
  case PRICE_CLOSE:
  default:
    return close[index];
  }
}

//+------------------------------------------------------------------+
//| カスタムインディケータ計算関数                                   |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[]) {
  if (rates_total < InpAlmaSlowWindow) {
    return 0;
  }

  // 入力配列を標準順序 (0=最古, rates_total-1=最新) に統一
  ArraySetAsSeries(open, false);
  ArraySetAsSeries(high, false);
  ArraySetAsSeries(low, false);
  ArraySetAsSeries(close, false);

  int start = prev_calculated - 1;
  if (start < InpAlmaSlowWindow - 1) {
    start = InpAlmaSlowWindow - 1;
    for (int i = 0; i < start; i++) {
      AlmaFastBuffer[i] = EMPTY_VALUE;
      AlmaSlowBuffer[i] = EMPTY_VALUE;
    }
  }

  // ALMA 計算 (i は 0=最古 から rates_total-1=最新 へ進む)
  for (int i = start; i < rates_total; i++) {
    // Fast ALMA
    double fastSum = 0.0;
    for (int k = 0; k < InpAlmaFastWindow; k++) {
      fastSum += GetPrice(i - k, open, high, low, close) * wFast[k];
    }
    AlmaFastBuffer[i] = fastSum / sumWFast;

    // Slow ALMA
    double slowSum = 0.0;
    for (int k = 0; k < InpAlmaSlowWindow; k++) {
      slowSum += GetPrice(i - k, open, high, low, close) * wSlow[k];
    }
    AlmaSlowBuffer[i] = slowSum / sumWSlow;
  }

  return rates_total;
}
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
