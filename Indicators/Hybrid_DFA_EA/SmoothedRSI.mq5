//+------------------------------------------------------------------+
//|                                                  SmoothedRSI.mq5 |
//|                                  Copyright 2026, Hybrid DFA System |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA System"
#property link "https://www.mql5.com"
#property version "1.00"
#property indicator_separate_window
#property indicator_buffers 4
#property indicator_plots 1

//--- プロット定義
#property indicator_label1 "Smoothed RSI"
#property indicator_type1 DRAW_LINE
#property indicator_color1 clrMediumSlateBlue
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

//--- レベル設定
#property indicator_level1 65.0
#property indicator_level2 35.0
#property indicator_level3 50.0
#property indicator_levelcolor clrDarkGray
#property indicator_levelstyle STYLE_DOT

//--- 入力パラメータ
input group
    "=== レンジ戦略 (Super Smoother + RSI) 設定 ===" input int InpSSPeriod =
        14;                           // Super Smoother 遮断周期
input int InpRsiPeriod = 7;           // RSI 計算期間
input double InpRsiOverbought = 65.0; // RSI 買われすぎ境界値
input double InpRsiOversold = 35.0;   // RSI 売られすぎ境界値
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // 適用価格

//--- バッファ
double SmoothedRsiBuffer[];
double SuperSmootherBuffer[];
double AvgGainBuffer[];
double AvgLossBuffer[];

//--- フィルター係数
double c1, c2, c3;

//+------------------------------------------------------------------+
//| カスタムインディケータ初期化関数                                 |
//+------------------------------------------------------------------+
int OnInit() {
  // バッファのバインディング
  SetIndexBuffer(0, SmoothedRsiBuffer, INDICATOR_DATA);
  SetIndexBuffer(1, SuperSmootherBuffer, INDICATOR_CALCULATIONS);
  SetIndexBuffer(2, AvgGainBuffer, INDICATOR_CALCULATIONS);
  SetIndexBuffer(3, AvgLossBuffer, INDICATOR_CALCULATIONS);

  // 全バッファを時系列 (0=最新) に設定
  ArraySetAsSeries(SmoothedRsiBuffer, true);
  ArraySetAsSeries(SuperSmootherBuffer, true);
  ArraySetAsSeries(AvgGainBuffer, true);
  ArraySetAsSeries(AvgLossBuffer, true);

  IndicatorSetString(
      INDICATOR_SHORTNAME,
      StringFormat("SmoothedRSI(SS=%d, RSI=%d)", InpSSPeriod, InpRsiPeriod));
  IndicatorSetInteger(INDICATOR_DIGITS, 2);

  // Super Smoother (2-Pole) 係数の事前計算
  if (InpSSPeriod < 2 || InpRsiPeriod < 1) {
    Print("[SmoothedRSI] エラー: 期間パラメータが不正です。");
    return INIT_PARAMETERS_INCORRECT;
  }

  double gamma = (M_SQRT2 * M_PI) / (double)InpSSPeriod;
  double a = MathExp(-gamma);
  c2 = 2.0 * a * MathCos(gamma);
  c3 = -a * a;
  c1 = 1.0 - c2 - c3;

  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 適用価格の取得ヘルパー                                           |
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
  if (rates_total < InpSSPeriod + InpRsiPeriod + 2) {
    return 0;
  }

  // 入力価格系列を時系列配列として作成
  double price[];
  ArraySetAsSeries(price, true);
  ArrayResize(price, rates_total);
  for (int i = 0; i < rates_total; i++) {
    int srcIdx = rates_total - 1 - i;
    price[i] = GetPrice(srcIdx, open, high, low, close);
  }

  int limit;
  if (prev_calculated == 0) {
    // 初回初期化
    limit = rates_total - 3;
    SuperSmootherBuffer[rates_total - 1] = price[rates_total - 1];
    SuperSmootherBuffer[rates_total - 2] = price[rates_total - 2];
    AvgGainBuffer[rates_total - 1] = 0.0;
    AvgLossBuffer[rates_total - 1] = 0.0;
    SmoothedRsiBuffer[rates_total - 1] = 50.0;
    SmoothedRsiBuffer[rates_total - 2] = 50.0;
  } else {
    limit = rates_total - prev_calculated + 1;
  }

  if (limit >= rates_total - 2)
    limit = rates_total - 3;

  // 過去から現在へ向かって Super Smoother と RSI を順次計算
  for (int i = limit; i >= 0; i--) {
    // 1. Super Smoother 2-Pole 漸化式
    // S_t = c1 * (P_t + P_{t-1}) / 2 + c2 * S_{t-1} + c3 * S_{t-2}
    SuperSmootherBuffer[i] = c1 * (price[i] + price[i + 1]) * 0.5 +
                             c2 * SuperSmootherBuffer[i + 1] +
                             c3 * SuperSmootherBuffer[i + 2];

    // 2. Smoothed RSI 計算
    double diff = SuperSmootherBuffer[i] - SuperSmootherBuffer[i + 1];
    double gain = (diff > 0.0) ? diff : 0.0;
    double loss = (diff < 0.0) ? -diff : 0.0;

    // 古いバーでの初期シード
    if (i >= rates_total - InpSSPeriod - InpRsiPeriod) {
      AvgGainBuffer[i] = gain;
      AvgLossBuffer[i] = loss;
      SmoothedRsiBuffer[i] = 50.0;
    } else {
      // Wilder's Exponential Smoothing
      AvgGainBuffer[i] = (AvgGainBuffer[i + 1] * (InpRsiPeriod - 1) + gain) /
                         (double)InpRsiPeriod;
      AvgLossBuffer[i] = (AvgLossBuffer[i + 1] * (InpRsiPeriod - 1) + loss) /
                         (double)InpRsiPeriod;

      double total = AvgGainBuffer[i] + AvgLossBuffer[i];
      if (total > 1e-12) {
        SmoothedRsiBuffer[i] = 100.0 * (AvgGainBuffer[i] / total);
      } else {
        SmoothedRsiBuffer[i] = 50.0;
      }
    }
  }

  return rates_total;
}
//+------------------------------------------------------------------+
