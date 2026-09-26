//+------------------------------------------------------------------+
//|                                                  MultiDualMA.mq5 |
//|                                  Copyright 2026, Hybrid DFA Quant |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA Quant"
#property link "https://www.mql5.com"
#property version "2.30"
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots 2

//--- プロット定義 (Fast: オレンジ赤, Slow: 水色 で全MAタイプ統一描画)
#property indicator_label1 "Dual MA Fast"
#property indicator_type1 DRAW_LINE
#property indicator_color1 clrOrangeRed
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

#property indicator_label2 "Dual MA Slow"
#property indicator_type2 DRAW_LINE
#property indicator_color2 clrDeepSkyBlue
#property indicator_style2 STYLE_SOLID
#property indicator_width2 2

//--- 移動平均種別定義
enum ENUM_TREND_MA_TYPE {
  TREND_MA_SMA  = 0, // SMA (単純移動平均)
  TREND_MA_EMA  = 1, // EMA (指数平滑移動平均)
  TREND_MA_SMMA = 2, // SMMA (平滑移動平均)
  TREND_MA_LWMA = 3, // LWMA (線形加重移動平均)
  TREND_MA_ALMA = 4  // ALMA (Arnaud Legoux 移動平均)
};

//--- 入力パラメータ
input ENUM_TREND_MA_TYPE InpTrendMaType = TREND_MA_LWMA; // 移動平均タイプ (SMA/EMA/SMMA/LWMA/ALMA)
input int InpAlmaFastWindow = 20;                        // 短期期間 / 窓幅 (Fast Window)
input int InpAlmaSlowWindow = 40;                        // 長期期間 / 窓幅 (Slow Window)
input double InpAlmaFastOffset = 0.92;                   // [ALMA専用] 短期 Offset (0.0〜1.0)
input double InpAlmaSlowOffset = 0.90;                   // [ALMA専用] 長期 Offset (0.0〜1.0)
input double InpAlmaFastSigma = 5.5;                     // [ALMA専用] 短期 Sigma (1.0〜10.0)
input double InpAlmaSlowSigma = 5.5;                     // [ALMA専用] 長期 Sigma (1.0〜10.0)
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE;  // 適用価格

//--- DSP Optional Pre-Filter (Noise Cut: 低遅延重視時はOFF推奨)
input bool InpUseSuperSmoother = false;                  // 2-Pole SuperSmoother有効化 (OFF推奨)
input int InpSSCutoff = 4;                               // 高周波カットオフ周期 (bars: 4推奨)

//--- Zero-Lag Momentum Feedforward (先行価格補正: スパイクゼロの低遅延化)
input bool InpUseZeroLagLead = false;                    // 先行モメンタム補正有効化
input double InpLeadFactor = 0.40;                       // 先行モメンタム係数 (0.1〜1.0)

//--- Schmitt Trigger (Hysteresis)
input bool InpUseSchmittTrigger = false;                 // ATR連動シュミットトリガー有効化
input int InpHysteresisAtrPeriod = 20;                   // ヒステリシス用ATR期間
input double InpHysteresisFactor = 0.08;                 // 不感帯幅係数 (ATR比率: 0.08 = 8% of ATR)

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
//| 移動平均 重み係数の事前計算 (SMA / LWMA / ALMA 対応)             |
//+------------------------------------------------------------------+
bool CalculateMaWeights(const ENUM_TREND_MA_TYPE type, const int window,
                        const double offset, const double sigma,
                        double &weights[], double &sumWeight) {
    if (window < 1)
        return false;

    ArrayResize(weights, window);
    sumWeight = 0.0;

    switch (type) {
    case TREND_MA_SMA:
        for (int k = 0; k < window; k++) {
            weights[k] = 1.0;
            sumWeight += 1.0;
        }
        break;

    case TREND_MA_LWMA:
        for (int k = 0; k < window; k++) {
            weights[k] = (double)(window - k);
            sumWeight += weights[k];
        }
        break;

    case TREND_MA_ALMA:
    default: {
        if (sigma <= 0.0) return false;
        double clpOffset = MathMin(MathMax(offset, 0.0), 1.0);
        double m = (1.0 - clpOffset) * (double)(window - 1);
        double s = (double)window / sigma;
        double two_s_sq = 2.0 * s * s;
        for (int k = 0; k < window; k++) {
            double diff = (double)k - m;
            weights[k] = MathExp(-(diff * diff) / two_s_sq);
            sumWeight += weights[k];
        }
        break;
    }
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

    string maTypeName = "LWMA";
    switch (InpTrendMaType) {
    case TREND_MA_SMA:  maTypeName = "SMA";  break;
    case TREND_MA_EMA:  maTypeName = "EMA";  break;
    case TREND_MA_SMMA: maTypeName = "SMMA"; break;
    case TREND_MA_LWMA: maTypeName = "LWMA"; break;
    case TREND_MA_ALMA: maTypeName = "ALMA"; break;
    }

    IndicatorSetString(INDICATOR_SHORTNAME,
                       StringFormat("MultiDualMA(%s, Fast=%d, Slow=%d, ST=%s)",
                                    maTypeName, InpAlmaFastWindow, InpAlmaSlowWindow,
                                    InpUseSchmittTrigger ? "ON" : "OFF"));
    IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

    PlotIndexSetString(0, PLOT_LABEL, StringFormat("MultiDual %s Fast(%d)", maTypeName, InpAlmaFastWindow));
    PlotIndexSetString(1, PLOT_LABEL, StringFormat("MultiDual %s Slow(%d)", maTypeName, InpAlmaSlowWindow));

    PrintFormat("[MultiDualMA] OnInit: Type=%s, Fast=%d, Slow=%d, Price=%d, SS=%s, ZL=%s, ST=%s(HFactor=%.4f)",
                maTypeName, InpAlmaFastWindow, InpAlmaSlowWindow, (int)InpAppliedPrice,
                InpUseSuperSmoother ? "ON" : "OFF",
                InpUseZeroLagLead ? "ON" : "OFF",
                InpUseSchmittTrigger ? "ON" : "OFF", InpHysteresisFactor);

    if (InpAlmaFastWindow < 2 || InpAlmaSlowWindow <= InpAlmaFastWindow) {
        PrintFormat("[MultiDualMA] 初期化エラー: 窓幅設定が不正です (Fast=%d, Slow=%d: Fast >= 2 かつ Slow > Fast である必要があります)。",
                    InpAlmaFastWindow, InpAlmaSlowWindow);
        return INIT_PARAMETERS_INCORRECT;
    }

    if (InpSSCutoff < 2 || InpHysteresisAtrPeriod < 1 || InpLeadFactor < 0.0) {
        PrintFormat("[MultiDualMA] 初期化エラー: パラメータ設定が不正です (SSCutoff=%d, HysteresisAtrPeriod=%d, LeadFactor=%.2f)。",
                    InpSSCutoff, InpHysteresisAtrPeriod, InpLeadFactor);
        return INIT_PARAMETERS_INCORRECT;
    }

    // 1. SuperSmoother 係数初期化 (2-Pole Butterworth 低遅延設計)
    double ss_a1 = MathExp(-1.414213562 * M_PI / (double)InpSSCutoff);
    double ss_b1 = 2.0 * ss_a1 * MathCos(1.414213562 * M_PI / (double)InpSSCutoff);
    ss_c2 = ss_b1;
    ss_c3 = -ss_a1 * ss_a1;
    ss_c1 = 1.0 - ss_c2 - ss_c3;

    // 2. 移動平均重み係数事前計算 (SMA, LWMA, ALMA)
    if (InpTrendMaType == TREND_MA_SMA || InpTrendMaType == TREND_MA_LWMA || InpTrendMaType == TREND_MA_ALMA) {
        if (!CalculateMaWeights(InpTrendMaType, InpAlmaFastWindow, InpAlmaFastOffset, InpAlmaFastSigma, wFast, sumWFast) ||
            !CalculateMaWeights(InpTrendMaType, InpAlmaSlowWindow, InpAlmaSlowOffset, InpAlmaSlowSigma, wSlow, sumWSlow)) {
            Print("[MultiDualMA] 初期化エラー: 重み係数計算に失敗しました。");
            return INIT_PARAMETERS_INCORRECT;
        }
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

    // EMA用平滑化係数
    double aFast = 2.0 / (double)(InpAlmaFastWindow + 1);
    double aSlow = 2.0 / (double)(InpAlmaSlowWindow + 1);

    for (int i = start; i < rates_total; i++) {
        double rawPrice = GetAppliedPrice(i, open, high, low, close);

        // 1. SuperSmoother による高周波ジッター遮断 (オプション)
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

        // 2. 先行モメンタム補正 (Zero-Lag Feedforward: オプション)
        if (InpUseZeroLagLead && i >= 1) {
            double prevP = GetAppliedPrice(i - 1, open, high, low, close);
            clean = clean + InpLeadFactor * (clean - prevP);
        }

        BufferPreFiltered[i] = clean;

        // 3. 移動平均計算 (SMA / EMA / SMMA / LWMA / ALMA)
        // 常に Fast=BufferFast (clrOrangeRed), Slow=BufferSlow (clrDeepSkyBlue) で描画
        if (InpTrendMaType == TREND_MA_EMA) {
            if (i == InpAlmaSlowWindow - 1) {
                double fSum = 0, sSum = 0;
                for (int k = 0; k < InpAlmaFastWindow; k++) fSum += BufferPreFiltered[i - k];
                for (int k = 0; k < InpAlmaSlowWindow; k++) sSum += BufferPreFiltered[i - k];
                BufferFast[i] = fSum / (double)InpAlmaFastWindow;
                BufferSlow[i] = sSum / (double)InpAlmaSlowWindow;
            } else {
                BufferFast[i] = aFast * BufferPreFiltered[i] + (1.0 - aFast) * BufferFast[i - 1];
                BufferSlow[i] = aSlow * BufferPreFiltered[i] + (1.0 - aSlow) * BufferSlow[i - 1];
            }
        } else if (InpTrendMaType == TREND_MA_SMMA) {
            if (i == InpAlmaSlowWindow - 1) {
                double fSum = 0, sSum = 0;
                for (int k = 0; k < InpAlmaFastWindow; k++) fSum += BufferPreFiltered[i - k];
                for (int k = 0; k < InpAlmaSlowWindow; k++) sSum += BufferPreFiltered[i - k];
                BufferFast[i] = fSum / (double)InpAlmaFastWindow;
                BufferSlow[i] = sSum / (double)InpAlmaSlowWindow;
            } else {
                BufferFast[i] = (BufferFast[i - 1] * (InpAlmaFastWindow - 1) + BufferPreFiltered[i]) / (double)InpAlmaFastWindow;
                BufferSlow[i] = (BufferSlow[i - 1] * (InpAlmaSlowWindow - 1) + BufferPreFiltered[i]) / (double)InpAlmaSlowWindow;
            }
        } else {
            // FIR型 (SMA, LWMA, ALMA): 事前計算された重み配列で畳み込み
            double fastSum = 0.0;
            for (int k = 0; k < InpAlmaFastWindow; k++) {
                fastSum += BufferPreFiltered[i - k] * wFast[k];
            }
            BufferFast[i] = fastSum / sumWFast;

            double slowSum = 0.0;
            for (int k = 0; k < InpAlmaSlowWindow; k++) {
                slowSum += BufferPreFiltered[i - k] * wSlow[k];
            }
            BufferSlow[i] = slowSum / sumWSlow;
        }

        // 4. True Range & ATR 計算
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

        // 5. シグナル状態判定 (シュミットトリガーまたは直接クロス)
        double diff = BufferFast[i] - BufferSlow[i];
        if (InpUseSchmittTrigger) {
            double h_band = curAtr * InpHysteresisFactor;
            if (diff > h_band) {
                BufferSignalState[i] = 1.0;
            } else if (diff < -h_band) {
                BufferSignalState[i] = -1.0;
            } else {
                BufferSignalState[i] = (i > 0) ? BufferSignalState[i - 1] : 0.0;
            }
        } else {
            if (diff > 0.0) {
                BufferSignalState[i] = 1.0;
            } else if (diff < 0.0) {
                BufferSignalState[i] = -1.0;
            } else {
                BufferSignalState[i] = (i > 0) ? BufferSignalState[i - 1] : 0.0;
            }
        }
    }

    return rates_total;
}
//+------------------------------------------------------------------+
