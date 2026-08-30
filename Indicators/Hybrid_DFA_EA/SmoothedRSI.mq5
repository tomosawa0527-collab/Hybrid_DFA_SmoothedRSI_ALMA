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
#property indicator_minimum 0.0
#property indicator_maximum 100.0

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
//--- レンジ戦略 (Super Smoother + RSI) 設定
input int InpSSPeriod = 14;                             // Super Smoother 遮断周期
input int InpRsiPeriod = 7;                             // RSI 計算期間
input double InpRsiOverbought = 65.0;                   // RSI 買われすぎ境界値
input double InpRsiOversold = 35.0;                     // RSI 売られすぎ境界値
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // 適用価格

//--- バッファ
double SmoothedRsiBuffer[];
double RawRsiBuffer[];
double AvgGainBuffer[];
double AvgLossBuffer[];

//--- フィルター係数
double c1, c2, c3;

//+------------------------------------------------------------------+
//| カスタムインディケータ初期化関数                                 |
//+------------------------------------------------------------------+
int OnInit() {
    // バッファのバインディング (0=最古, rates_total-1=最新)
    SetIndexBuffer(0, SmoothedRsiBuffer, INDICATOR_DATA);
    SetIndexBuffer(1, RawRsiBuffer, INDICATOR_CALCULATIONS);
    SetIndexBuffer(2, AvgGainBuffer, INDICATOR_CALCULATIONS);
    SetIndexBuffer(3, AvgLossBuffer, INDICATOR_CALCULATIONS);

    ArraySetAsSeries(SmoothedRsiBuffer, false);
    ArraySetAsSeries(RawRsiBuffer, false);
    ArraySetAsSeries(AvgGainBuffer, false);
    ArraySetAsSeries(AvgLossBuffer, false);

    PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
    PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, InpSSPeriod + InpRsiPeriod);

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
double GetPrice(const int index, const double& open[], const double& high[],
                const double& low[], const double& close[]) {
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
                const datetime& time[], const double& open[],
                const double& high[], const double& low[],
                const double& close[], const long& tick_volume[],
                const long& volume[], const int& spread[]) {
    if (rates_total < InpSSPeriod + InpRsiPeriod + 2) {
        return 0;
    }

    ArraySetAsSeries(open, false);
    ArraySetAsSeries(high, false);
    ArraySetAsSeries(low, false);
    ArraySetAsSeries(close, false);

    int start = prev_calculated - 1;
    if (start < InpRsiPeriod) {
        start = InpRsiPeriod;
        // 初期化
        for (int i = 0; i < start; i++) {
            RawRsiBuffer[i] = 50.0;
            SmoothedRsiBuffer[i] = 50.0;
            AvgGainBuffer[i] = 0.0;
            AvgLossBuffer[i] = 0.0;
        }
        // 初回シード
        double sumGain = 0.0, sumLoss = 0.0;
        for (int i = 1; i <= InpRsiPeriod; i++) {
            double diff = GetPrice(i, open, high, low, close) - GetPrice(i - 1, open, high, low, close);
            if (diff > 0.0) sumGain += diff;
            else sumLoss += -diff;
        }
        AvgGainBuffer[InpRsiPeriod] = sumGain / (double)InpRsiPeriod;
        AvgLossBuffer[InpRsiPeriod] = sumLoss / (double)InpRsiPeriod;
        double total = AvgGainBuffer[InpRsiPeriod] + AvgLossBuffer[InpRsiPeriod];
        RawRsiBuffer[InpRsiPeriod] = (total > 1e-12) ? (100.0 * AvgGainBuffer[InpRsiPeriod] / total) : 50.0;
        SmoothedRsiBuffer[InpRsiPeriod] = RawRsiBuffer[InpRsiPeriod];
        start = InpRsiPeriod + 1;
    }

    // 1. 生の RSI 計算 (i は 0=最古 から rates_total-1=最新 へ進む)
    for (int i = start; i < rates_total; i++) {
        double diff = GetPrice(i, open, high, low, close) - GetPrice(i - 1, open, high, low, close);
        double gain = (diff > 0.0) ? diff : 0.0;
        double loss = (diff < 0.0) ? -diff : 0.0;

        AvgGainBuffer[i] = (AvgGainBuffer[i - 1] * (InpRsiPeriod - 1) + gain) / (double)InpRsiPeriod;
        AvgLossBuffer[i] = (AvgLossBuffer[i - 1] * (InpRsiPeriod - 1) + loss) / (double)InpRsiPeriod;

        double total = AvgGainBuffer[i] + AvgLossBuffer[i];
        if (total > 1e-12) {
            RawRsiBuffer[i] = 100.0 * (AvgGainBuffer[i] / total);
        } else {
            RawRsiBuffer[i] = 50.0;
        }
    }

    // 2. Super Smoother 平滑化の適用 (RSI に対して平滑化フィルターを通す)
    int ssStart = start;
    if (ssStart < InpRsiPeriod + 2) {
        ssStart = InpRsiPeriod + 2;
        SmoothedRsiBuffer[InpRsiPeriod + 1] = RawRsiBuffer[InpRsiPeriod + 1];
    }

    for (int i = ssStart; i < rates_total; i++) {
        SmoothedRsiBuffer[i] = c1 * (RawRsiBuffer[i] + RawRsiBuffer[i - 1]) * 0.5 +
                               c2 * SmoothedRsiBuffer[i - 1] +
                               c3 * SmoothedRsiBuffer[i - 2];
    }

    return rates_total;
}
//+------------------------------------------------------------------+
