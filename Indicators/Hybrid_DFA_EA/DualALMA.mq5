//+------------------------------------------------------------------+
//|                                                     DualALMA.mq5 |
//|                                  Copyright 2026, Hybrid DFA Quant |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA Quant"
#property link "https://www.mql5.com"
#property version "2.10"
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots 2

//--- プロット定義
#property indicator_label1 "Robust ALMA Fast"
#property indicator_type1 DRAW_LINE
#property indicator_color1 clrOrangeRed
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

#property indicator_label2 "Robust ALMA Slow"
#property indicator_type2 DRAW_LINE
#property indicator_color2 clrDeepSkyBlue
#property indicator_style2 STYLE_SOLID
#property indicator_width2 2

//--- 入力パラメータ
//--- ALMA Core Settings
input int InpAlmaFastWindow = 9;                        // 短期窓幅 (Fast Window)
input int InpAlmaSlowWindow = 21;                       // 長期窓幅 (Slow Window)
input double InpAlmaOffset = 0.85;                      // 基準 Offset (0.0〜1.0)
input double InpAlmaSigma = 6.0;                        // 基準 Sigma (1.0〜10.0)
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // 適用価格

//--- DSP Pre-Filter (Noise Cut)
input bool InpUseSuperSmoother = true; // 2-Pole SuperSmoother有効化
input int InpSSCutoff = 8;             // 高周波カットオフ周期 (bars)

//--- Schmitt Trigger (Hysteresis)
input bool InpUseSchmittTrigger = true;  // ATR連動シュミットトリガー有効化
input int InpHysteresisAtrPeriod = 14;   // ヒステリシス用ATR期間
input double InpHysteresisFactor = 0.20; // 不感帯幅係数 (ATR比率: 0.20 = 20% of ATR)

//--- インジケータバッファ
double BufferFast[];
double BufferSlow[];
double BufferPreFiltered[];
double BufferSignalState[]; // +1.0: Bullish, -1.0: Bearish, 0.0: Neutral
double BufferATR[];

//--- 内部キャッシュ係数・固定重み
double ss_c1, ss_c2, ss_c3;
double wFast[];
double sumWFast;
double wSlow[];
double sumWSlow;

//+------------------------------------------------------------------+
//| ALMA 重み係数の事前計算 (k=0 が最新バー、k=window-1 が最古バー)   |
//+------------------------------------------------------------------+
bool CalculateWeights(const int window, const double offset, const double sigma,
                      double &weights[], double &sumWeight) {
    if (window < 1 || sigma <= 0.0)
        return false;

    ArrayResize(weights, window);
    sumWeight = 0.0;

    double clpOffset = MathMin(MathMax(offset, 0.0), 1.0);
    double m = (1.0 - clpOffset) * (double)(window - 1);
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
//| 初期化関数                                                       |
//+------------------------------------------------------------------+
int OnInit() {
    SetIndexBuffer(0, BufferFast, INDICATOR_DATA);
    SetIndexBuffer(1, BufferSlow, INDICATOR_DATA);
    SetIndexBuffer(2, BufferPreFiltered, INDICATOR_CALCULATIONS);
    SetIndexBuffer(3, BufferSignalState, INDICATOR_CALCULATIONS);
    SetIndexBuffer(4, BufferATR, INDICATOR_CALCULATIONS);

    ArraySetAsSeries(BufferFast, false);
    ArraySetAsSeries(BufferSlow, false);
    ArraySetAsSeries(BufferPreFiltered, false);
    ArraySetAsSeries(BufferSignalState, false);
    ArraySetAsSeries(BufferATR, false);

    PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
    PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

    IndicatorSetString(INDICATOR_SHORTNAME,
                       StringFormat("RobustDualALMA(Fast=%d, Slow=%d, SS=%s, ST=%s)",
                                    InpAlmaFastWindow, InpAlmaSlowWindow,
                                    InpUseSuperSmoother ? "ON" : "OFF",
                                    InpUseSchmittTrigger ? "ON" : "OFF"));
    IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

    PrintFormat("[RobustDualALMA] OnInit: Fast=%d, Slow=%d, Offset=%.4f, Sigma=%.4f, Price=%d, SS=%s(Cutoff=%d), ST=%s(ATRPeriod=%d, HFactor=%.4f)",
                InpAlmaFastWindow, InpAlmaSlowWindow, InpAlmaOffset, InpAlmaSigma, (int)InpAppliedPrice,
                InpUseSuperSmoother ? "ON" : "OFF", InpSSCutoff,
                InpUseSchmittTrigger ? "ON" : "OFF", InpHysteresisAtrPeriod, InpHysteresisFactor);

    if (InpAlmaFastWindow < 2 || InpAlmaSlowWindow <= InpAlmaFastWindow) {
        PrintFormat("[RobustDualALMA] 初期化エラー: 窓幅設定が不正です (Fast=%d, Slow=%d: Fast >= 2 かつ Slow > Fast である必要があります)。",
                    InpAlmaFastWindow, InpAlmaSlowWindow);
        return INIT_PARAMETERS_INCORRECT;
    }

    if (InpSSCutoff < 2 || InpHysteresisAtrPeriod < 1) {
        PrintFormat("[RobustDualALMA] 初期化エラー: 周期パラメータが不正です (SSCutoff=%d, HysteresisAtrPeriod=%d)。",
                    InpSSCutoff, InpHysteresisAtrPeriod);
        return INIT_PARAMETERS_INCORRECT;
    }

    // 1. SuperSmoother 係数初期化 (2-Pole Butterworth 低遅延設計)
    double ss_a1 = MathExp(-1.414213562 * M_PI / (double)InpSSCutoff);
    double ss_b1 = 2.0 * ss_a1 * MathCos(1.414213562 * M_PI / (double)InpSSCutoff);
    ss_c2 = ss_b1;
    ss_c3 = -ss_a1 * ss_a1;
    ss_c1 = 1.0 - ss_c2 - ss_c3;

    // 2. 固定 ALMA 重み係数事前計算
    if (!CalculateWeights(InpAlmaFastWindow, InpAlmaOffset, InpAlmaSigma, wFast, sumWFast) ||
        !CalculateWeights(InpAlmaSlowWindow, InpAlmaOffset, InpAlmaSigma, wSlow, sumWSlow)) {
        Print("[RobustDualALMA] 初期化エラー: 重み係数計算に失敗しました。");
        return INIT_PARAMETERS_INCORRECT;
    }

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 適用価格取得ヘルパー                                             |
//+------------------------------------------------------------------+
double GetAppliedPrice(const int idx, const double& open[], const double& high[],
                       const double& low[], const double& close[]) {
    switch (InpAppliedPrice) {
    case PRICE_OPEN:
        return open[idx];
    case PRICE_HIGH:
        return high[idx];
    case PRICE_LOW:
        return low[idx];
    case PRICE_MEDIAN:
        return (high[idx] + low[idx]) * 0.5;
    case PRICE_TYPICAL:
        return (high[idx] + low[idx] + close[idx]) / 3.0;
    case PRICE_WEIGHTED:
        return (high[idx] + low[idx] + 2.0 * close[idx]) * 0.25;
    case PRICE_CLOSE:
    default:
        return close[idx];
    }
}

//+------------------------------------------------------------------+
//| 計算メインルーチン                                               |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime& time[], const double& open[],
                const double& high[], const double& low[],
                const double& close[], const long& tick_volume[],
                const long& volume[], const int& spread[]) {
    if (rates_total < InpAlmaSlowWindow)
        return 0;

    ArraySetAsSeries(open, false);
    ArraySetAsSeries(high, false);
    ArraySetAsSeries(low, false);
    ArraySetAsSeries(close, false);

    int start = prev_calculated - 1;
    if (start < 0) {
        start = 0;
    }

    // 初回初期化: 未満バーは EMPTY_VALUE に設定
    if (start < InpAlmaSlowWindow - 1) {
        for (int i = 0; i < InpAlmaSlowWindow - 1; i++) {
            BufferFast[i] = EMPTY_VALUE;
            BufferSlow[i] = EMPTY_VALUE;
            BufferPreFiltered[i] = GetAppliedPrice(i, open, high, low, close);
            BufferSignalState[i] = 0.0;
            BufferATR[i] = high[i] - low[i];
        }
        start = InpAlmaSlowWindow - 1;
    }

    for (int i = start; i < rates_total; i++) {
        double rawPrice = GetAppliedPrice(i, open, high, low, close);

        // 1. SuperSmoother による高周波ジッター・ヒゲの低遅延遮断
        double clean = rawPrice;
        if (InpUseSuperSmoother) {
            if (i >= 2) {
                double prevRaw = GetAppliedPrice(i - 1, open, high, low, close);
                clean = ss_c1 * (rawPrice + prevRaw) * 0.5 +
                        ss_c2 * BufferPreFiltered[i - 1] +
                        ss_c3 * BufferPreFiltered[i - 2];
            } else if (i == 1) {
                clean = (rawPrice + GetAppliedPrice(0, open, high, low, close)) * 0.5;
            }
        }
        BufferPreFiltered[i] = clean;

        // 2. 固定重みによる Fast ALMA 畳み込み演算 (極めて滑らか・低遅延)
        double fastSum = 0.0;
        for (int k = 0; k < InpAlmaFastWindow; k++) {
            fastSum += BufferPreFiltered[i - k] * wFast[k];
        }
        BufferFast[i] = fastSum / sumWFast;

        // 3. 固定重みによる Slow ALMA 畳み込み演算 (極めて滑らか・低遅延)
        double slowSum = 0.0;
        for (int k = 0; k < InpAlmaSlowWindow; k++) {
            slowSum += BufferPreFiltered[i - k] * wSlow[k];
        }
        BufferSlow[i] = slowSum / sumWSlow;

        // 4. True Range & ATR 計算 (ヒステリシス不感帯用)
        double tr = high[i] - low[i];
        if (i > 0) {
            double tr1 = MathAbs(high[i] - close[i - 1]);
            double tr2 = MathAbs(low[i] - close[i - 1]);
            if (tr1 > tr)
                tr = tr1;
            if (tr2 > tr)
                tr = tr2;
        }
        double prevAtr = (i > 0) ? BufferATR[i - 1] : tr;
        double curAtr = tr;
        if (i >= InpHysteresisAtrPeriod) {
            curAtr = (prevAtr * (double)(InpHysteresisAtrPeriod - 1) + tr) / (double)InpHysteresisAtrPeriod;
        }
        BufferATR[i] = curAtr;

        // 5. シュミットトリガーによるヒステリシス状態ラッチ (ダマシ・チャタリング完全防止)
        double diff = BufferFast[i] - BufferSlow[i];
        double h_band = 0.0;
        if (InpUseSchmittTrigger) {
            h_band = curAtr * InpHysteresisFactor;
        }

        if (diff > h_band) {
            BufferSignalState[i] = 1.0; // Bullish (買い優勢)
        } else if (diff < -h_band) {
            BufferSignalState[i] = -1.0; // Bearish (売り優勢)
        } else {
            BufferSignalState[i] = (i > 0) ? BufferSignalState[i - 1] : 0.0; // 不感帯内は直前状態を維持
        }
    }

    return rates_total;
}
//+------------------------------------------------------------------+
