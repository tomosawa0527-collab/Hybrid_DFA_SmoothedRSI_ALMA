//+------------------------------------------------------------------+
//|                                                     DualALMA.mq5 |
//|                                  Copyright 2026, Hybrid DFA Quant |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA Quant"
#property link "https://www.mql5.com"
#property version "2.00"
#property indicator_chart_window
#property indicator_buffers 9
#property indicator_plots 2

//--- プロット定義
#property indicator_label1 "Adaptive ALMA Fast"
#property indicator_type1 DRAW_LINE
#property indicator_color1 clrOrangeRed
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

#property indicator_label2 "Adaptive ALMA Slow"
#property indicator_type2 DRAW_LINE
#property indicator_color2 clrDeepSkyBlue
#property indicator_style2 STYLE_SOLID
#property indicator_width2 2

//--- 入力パラメータ
//--- ALMA Core Settings
input int InpAlmaFastWindow = 9;                        // 短期窓幅 (Fast Window)
input int InpAlmaSlowWindow = 21;                       // 長期窓幅 (Slow Window)
input double InpAlmaOffset = 0.85;                      // 基準 Offset (0.5〜0.95)
input double InpAlmaSigma = 6.0;                        // 基準 Sigma (1.0〜10.0)
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // 適用価格

//--- DSP Pre-Filter (Noise & Wave Cut)
input bool InpUseSuperSmoother = true; // 2-Pole SuperSmoother有効化
input int InpSSCutoff = 8;             // 高周波カットオフ周期 (bars)
input bool InpUseDecycler = true;      // 不要サイクル除去 (Decycler) 有効化
input int InpDecyclerPeriod = 60;      // 低中周波うねり遮断周期 (bars)

//--- Dynamic Adaptation & Zero-Lag
input bool InpUseAdaptive = true; // Kaufman ER による動的適応
input int InpERPeriod = 10;       // 効率比 (ER) 計算周期
input bool InpUseZeroLag = true;  // 前方予測 Zero-Lag 補正

//--- Schmitt Trigger (Hysteresis)
input bool InpUseSchmittTrigger = true;  // ATR連動シュミットトリガー有効化
input int InpHysteresisAtrPeriod = 14;   // ヒステリシス用ATR期間
input double InpHysteresisFactor = 0.20; // 不感帯幅係数 (ATR比率: 0.20 = 20% of ATR)

//--- インジケータバッファ
double BufferFast[];
double BufferSlow[];
double BufferPreFiltered[];
double BufferSignalState[]; // +1.0: Bullish, -1.0: Bearish, 0.0: Neutral
double BufferSS[];
double BufferHP[];
double BufferRawFast[];
double BufferRawSlow[];
double BufferATR[];

//--- 内部キャッシュ係数
double ss_c1, ss_c2, ss_c3;
double hp_alpha1;

//+------------------------------------------------------------------+
//| 初期化関数                                                       |
//+------------------------------------------------------------------+
int OnInit() {
    SetIndexBuffer(0, BufferFast, INDICATOR_DATA);
    SetIndexBuffer(1, BufferSlow, INDICATOR_DATA);
    SetIndexBuffer(2, BufferPreFiltered, INDICATOR_CALCULATIONS);
    SetIndexBuffer(3, BufferSignalState, INDICATOR_CALCULATIONS);
    SetIndexBuffer(4, BufferSS, INDICATOR_CALCULATIONS);
    SetIndexBuffer(5, BufferHP, INDICATOR_CALCULATIONS);
    SetIndexBuffer(6, BufferRawFast, INDICATOR_CALCULATIONS);
    SetIndexBuffer(7, BufferRawSlow, INDICATOR_CALCULATIONS);
    SetIndexBuffer(8, BufferATR, INDICATOR_CALCULATIONS);

    ArraySetAsSeries(BufferFast, false);
    ArraySetAsSeries(BufferSlow, false);
    ArraySetAsSeries(BufferPreFiltered, false);
    ArraySetAsSeries(BufferSignalState, false);
    ArraySetAsSeries(BufferSS, false);
    ArraySetAsSeries(BufferHP, false);
    ArraySetAsSeries(BufferRawFast, false);
    ArraySetAsSeries(BufferRawSlow, false);
    ArraySetAsSeries(BufferATR, false);

    PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
    PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

    IndicatorSetString(INDICATOR_SHORTNAME,
                       StringFormat("RobustDualALMA(Fast=%d, Slow=%d, SS=%s, Decycle=%s, Adapt=%s, ZL=%s, ST=%s)",
                                    InpAlmaFastWindow, InpAlmaSlowWindow,
                                    InpUseSuperSmoother ? "ON" : "OFF",
                                    InpUseDecycler ? "ON" : "OFF",
                                    InpUseAdaptive ? "ON" : "OFF",
                                    InpUseZeroLag ? "ON" : "OFF",
                                    InpUseSchmittTrigger ? "ON" : "OFF"));
    IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

    PrintFormat("[RobustDualALMA] OnInit受信パラメータ: Fast=%d, Slow=%d, Offset=%.4f, Sigma=%.4f, Price=%d, SS=%s(Cutoff=%d), Decycle=%s(Period=%d), Adapt=%s(ERPeriod=%d), ZL=%s, ST=%s(ATRPeriod=%d, HFactor=%.4f)",
                InpAlmaFastWindow, InpAlmaSlowWindow, InpAlmaOffset, InpAlmaSigma, (int)InpAppliedPrice,
                InpUseSuperSmoother ? "ON" : "OFF", InpSSCutoff,
                InpUseDecycler ? "ON" : "OFF", InpDecyclerPeriod,
                InpUseAdaptive ? "ON" : "OFF", InpERPeriod,
                InpUseZeroLag ? "ON" : "OFF",
                InpUseSchmittTrigger ? "ON" : "OFF", InpHysteresisAtrPeriod, InpHysteresisFactor);

    if (InpAlmaFastWindow < 2 || InpAlmaSlowWindow <= InpAlmaFastWindow) {
        PrintFormat("[RobustDualALMA] 初期化エラー: 窓幅設定が不正です (Fast=%d, Slow=%d: Fast >= 2 かつ Slow > Fast である必要があります)。",
                    InpAlmaFastWindow, InpAlmaSlowWindow);
        return INIT_PARAMETERS_INCORRECT;
    }

    if (InpSSCutoff < 2 || InpDecyclerPeriod < 2 || InpERPeriod < 1 || InpHysteresisAtrPeriod < 1) {
        PrintFormat("[RobustDualALMA] 初期化エラー: 周期パラメータが不正です (SSCutoff=%d, DecyclerPeriod=%d, ERPeriod=%d, HysteresisAtrPeriod=%d)。",
                    InpSSCutoff, InpDecyclerPeriod, InpERPeriod, InpHysteresisAtrPeriod);
        return INIT_PARAMETERS_INCORRECT;
    }

    // 1. SuperSmoother 係数初期化 (2-Pole Butterworth 低遅延設計)
    double ss_a1 = MathExp(-1.414213562 * M_PI / (double)InpSSCutoff);
    double ss_b1 = 2.0 * ss_a1 * MathCos(1.414213562 * M_PI / (double)InpSSCutoff);
    ss_c2 = ss_b1;
    ss_c3 = -ss_a1 * ss_a1;
    ss_c1 = 1.0 - ss_c2 - ss_c3;

    // 2. Decycler 係数初期化 (2-Pole HighPass フィルタ)
    double angle = 0.70710678 * 2.0 * M_PI / (double)InpDecyclerPeriod;
    hp_alpha1 = (MathCos(angle) + MathSin(angle) - 1.0) / MathCos(angle);

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
//| 動的 ALMA 単一バー畳み込み演算                                   |
//+------------------------------------------------------------------+
double CalculateSingleALMA(const int curr_idx, const int window,
                           const double offset, const double sigma,
                           const double& src[]) {
    if (curr_idx < window - 1)
        return src[curr_idx];

    double clpOffset = MathMin(MathMax(offset, 0.05), 0.99);
    double clpSigma = MathMax(sigma, 0.1);

    double m = (1.0 - clpOffset) * (double)(window - 1);
    double s = (double)window / clpSigma;
    double two_s_sq = 2.0 * s * s;

    double sumW = 0.0;
    double sumV = 0.0;

    for (int k = 0; k < window; k++) {
        double diff = (double)k - m;
        double w = MathExp(-(diff * diff) / two_s_sq);
        sumW += w;
        sumV += src[curr_idx - k] * w;
    }

    return (sumW > 0.0) ? (sumV / sumW) : src[curr_idx];
}

//+------------------------------------------------------------------+
//| 計算メインルーチン                                               |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime& time[], const double& open[],
                const double& high[], const double& low[],
                const double& close[], const long& tick_volume[],
                const long& volume[], const int& spread[]) {
    int warmup = MathMax(InpAlmaSlowWindow, MathMax(InpDecyclerPeriod, InpSSCutoff)) +
                 InpERPeriod + InpHysteresisAtrPeriod + 10;
    if (rates_total < warmup)
        return 0;

    ArraySetAsSeries(open, false);
    ArraySetAsSeries(high, false);
    ArraySetAsSeries(low, false);
    ArraySetAsSeries(close, false);

    int start = prev_calculated - 1;
    if (start < 2) {
        start = 2;
        for (int i = 0; i < start; i++) {
            double p = GetAppliedPrice(i, open, high, low, close);
            BufferSS[i] = p;
            BufferHP[i] = 0.0;
            BufferPreFiltered[i] = p;
            BufferRawFast[i] = p;
            BufferRawSlow[i] = p;
            BufferFast[i] = EMPTY_VALUE;
            BufferSlow[i] = EMPTY_VALUE;
            BufferSignalState[i] = 0.0;
            BufferATR[i] = high[i] - low[i];
        }
    }

    for (int i = start; i < rates_total; i++) {
        double rawPrice = GetAppliedPrice(i, open, high, low, close);

        // 1. SuperSmoother による高周波ジッター遮断
        double ss = rawPrice;
        if (InpUseSuperSmoother) {
            double prevRaw = GetAppliedPrice(i - 1, open, high, low, close);
            ss = ss_c1 * (rawPrice + prevRaw) * 0.5 +
                 ss_c2 * BufferSS[i - 1] +
                 ss_c3 * BufferSS[i - 2];
        }
        BufferSS[i] = ss;

        // 2. Decycler による不要低中周波サイクルの相殺除去
        double clean = ss;
        if (InpUseDecycler && i >= 2) {
            double p0 = ss;
            double p1 = BufferSS[i - 1];
            double p2 = BufferSS[i - 2];

            double hp = MathPow(1.0 - hp_alpha1 * 0.5, 2.0) * (p0 - 2.0 * p1 + p2) +
                        2.0 * (1.0 - hp_alpha1) * BufferHP[i - 1] -
                        MathPow(1.0 - hp_alpha1, 2.0) * BufferHP[i - 2];

            BufferHP[i] = hp;
            clean = p0 - hp; // サイクル振動を除去し純粋トレンド成分を抽出
        } else {
            BufferHP[i] = 0.0;
        }
        BufferPreFiltered[i] = clean;

        // 3. Kaufman ER によるパラメータ動的適応
        double dynOffset = InpAlmaOffset;
        double dynSigma = InpAlmaSigma;

        if (InpUseAdaptive && i >= InpERPeriod) {
            double netChange = MathAbs(BufferPreFiltered[i] - BufferPreFiltered[i - InpERPeriod]);
            double totalPath = 0.0;
            for (int j = 0; j < InpERPeriod; j++) {
                totalPath += MathAbs(BufferPreFiltered[i - j] - BufferPreFiltered[i - j - 1]);
            }
            double er = (totalPath > 0.0) ? (netChange / totalPath) : 0.0;

            // トレンド時は Offset を上げ、Sigma を引き締める
            dynOffset = InpAlmaOffset + 0.10 * (er - 0.5);
            dynOffset = MathMin(MathMax(dynOffset, 0.60), 0.96);

            dynSigma = InpAlmaSigma + 3.0 * (er - 0.5);
            dynSigma = MathMin(MathMax(dynSigma, 3.0), 9.5);
        }

        // 4. 動的 ALMA コア演算
        double rawAlmaFast = CalculateSingleALMA(i, InpAlmaFastWindow, dynOffset, dynSigma, BufferPreFiltered);
        double rawAlmaSlow = CalculateSingleALMA(i, InpAlmaSlowWindow, dynOffset, dynSigma, BufferPreFiltered);
        BufferRawFast[i] = rawAlmaFast;
        BufferRawSlow[i] = rawAlmaSlow;

        // 5. 前方外挿 Zero-Lag 補正
        double almaFast = rawAlmaFast;
        double almaSlow = rawAlmaSlow;

        if (InpUseZeroLag && i >= 2) {
            double tauFast = (double)InpAlmaFastWindow * 0.25;
            double tauSlow = (double)InpAlmaSlowWindow * 0.25;

            double velFast = rawAlmaFast - BufferRawFast[i - 1];
            double velSlow = rawAlmaSlow - BufferRawSlow[i - 1];

            almaFast = rawAlmaFast + tauFast * velFast;
            almaSlow = rawAlmaSlow + tauSlow * velSlow;
        }

        BufferFast[i] = almaFast;
        BufferSlow[i] = almaSlow;

        // 6. True Range & ATR 計算 (ヒステリシス不感帯用)
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

        // 7. シュミットトリガーによるヒステリシス状態ラッチ
        double diff = almaFast - almaSlow;
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
