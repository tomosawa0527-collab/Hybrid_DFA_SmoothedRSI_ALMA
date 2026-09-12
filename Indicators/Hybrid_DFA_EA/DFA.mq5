//+------------------------------------------------------------------+
//|                                                          DFA.mq5 |
//|                                  Copyright 2026, Hybrid DFA System |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA System"
#property link "https://www.mql5.com"
#property version "1.40"
#property indicator_separate_window
#property indicator_buffers 3
#property indicator_plots 1

//--- プロット定義 (カラーライン: 0=レンジ(赤), 1=中立(グレー), 2=トレンド(青))
#property indicator_label1 "DFA Alpha"
#property indicator_type1 DRAW_COLOR_LINE
#property indicator_color1 clrCrimson, clrGray, clrDodgerBlue
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

//--- 入力パラメータ
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT;  // 計算対象時間軸 (PERIOD_CURRENT: チャート時間軸)
input int InpDfaWindowSize = 300;                     // DFA 計算対象バー数 (N)
input int InpMinBoxSize = 10;                         // 最小ボックスサイズ (s_min: 学術推奨10以上)
input int InpMaxBoxSize = 0;                          // 最大ボックスサイズ (0: N/4 自動設定)
input int InpMaxBarsToCalc = 1500;                    // 初回計算最大バー数 (0: 全バー計算, 推奨: 1000〜2000)
input int InpSmoothPeriod = 5;                        // 平滑化期間 (1: 平滑化なし, 2以上: 低遅延平滑化)
input double InpDfaThresholdLow = 0.45;               // レンジ判定閾値 (これ未満でレンジ)
input double InpDfaThresholdHigh = 0.55;              // トレンド判定閾値 (これ超過でトレンド)
input double InpScaleMargin = 0.25;                   // 縮尺マージン (Low-Margin 〜 High+Margin)
input bool InpUseDriftFilter = true;                  // ドリフト結合フィルタ (効率比ERによるトレンド補正)
input double InpDriftThreshold = 0.20;                // トレンド認定効率比(ER)閾値 (推奨: 0.15〜0.25)

//--- インディケータバッファ
double AlphaBuffer[];
double AlphaColors[];
double RawAlphaBuffer[];

//--- MTF 上位足用内部ハンドル
int h_htfDfa = INVALID_HANDLE;

//--- Super Smoother 平滑化係数
double ssC1, ssC2, ssC3;

//--- スケール定数の事前計算構造体
struct DfaScaleInfo {
  int s;            // ボックスサイズ s
  int numBlocks;    // 順方向ブロック数 N_s
  int totalBlocks;  // 双方向合計ブロック数 (2 * N_s)
  int totalPoints;  // 双方向合計データ点数 (2 * N_s * s)
  double logS;      // ln(s)
  double sumX;      // sum_{j=0}^{s-1} j = s*(s-1)/2
  double invDelta;  // 1 / (s * sumX2 - sumX^2)
  double invS;      // 1.0 / s
};

#define NUM_SCALES_FIXED 16
DfaScaleInfo g_scaleList[NUM_SCALES_FIXED];
int g_validScaleCount = 0;

//--- ln(s) 回帰用の事前計算定数
double g_sumLogS = 0.0;
double g_sumLogS2 = 0.0;
double g_regDenomS = 0.0;

//--- 計算用静的ワーク配列
double g_returns[];               // 対数リターン配列 (サイズ N-1)
double g_Y[];                     // 累積プロファイル配列 (サイズ N-1)
double g_logF[NUM_SCALES_FIXED];  // 各スケールのゆらぎ対数値

//+------------------------------------------------------------------+
//| スケール定数の事前計算 (OnInit で一度だけ実行)                   |
//+------------------------------------------------------------------+
void PrecomputeScales(const int N) {
  int returnCount = N - 1;
  int sMin = (InpMinBoxSize >= 6) ? InpMinBoxSize : 6;
  int sMax = (InpMaxBoxSize > sMin) ? InpMaxBoxSize : (returnCount / 4);
  if (sMax <= sMin) sMax = sMin + 4;

  double logMin = MathLog((double)sMin);
  double logMax = MathLog((double)sMax);
  double step = (logMax - logMin) / (double)(NUM_SCALES_FIXED - 1);

  g_validScaleCount = 0;
  int lastS = -1;

  for (int k = 0; k < NUM_SCALES_FIXED; k++) {
    int s = (int)MathRound(MathExp(logMin + k * step));
    if (s == lastS || s < sMin || s > sMax) continue;

    int nBlocks = returnCount / s;
    if (nBlocks < 1) continue;

    lastS = s;
    DfaScaleInfo info;
    info.s = s;
    info.numBlocks = nBlocks;
    info.totalBlocks = 2 * nBlocks;
    info.totalPoints = info.totalBlocks * s;
    info.logS = MathLog((double)s);

    double dS = (double)s;
    double sumX = dS * (dS - 1.0) * 0.5;
    double sumX2 = (dS - 1.0) * dS * (2.0 * dS - 1.0) / 6.0;
    double delta = dS * sumX2 - sumX * sumX;

    info.sumX = sumX;
    info.invDelta = (MathAbs(delta) > 1e-12) ? (1.0 / delta) : 0.0;
    info.invS = 1.0 / dS;

    g_scaleList[g_validScaleCount] = info;
    g_validScaleCount++;
  }

  // ln(s) に関する回帰定数の事前計算
  g_sumLogS = 0.0;
  g_sumLogS2 = 0.0;
  for (int k = 0; k < g_validScaleCount; k++) {
    g_sumLogS += g_scaleList[k].logS;
    g_sumLogS2 += g_scaleList[k].logS * g_scaleList[k].logS;
  }
  g_regDenomS = g_validScaleCount * g_sumLogS2 - g_sumLogS * g_sumLogS;
}

//+------------------------------------------------------------------+
//| カスタムインディケータ初期化関数                                 |
//+------------------------------------------------------------------+
int OnInit() {
  SetIndexBuffer(0, AlphaBuffer, INDICATOR_DATA);
  SetIndexBuffer(1, AlphaColors, INDICATOR_COLOR_INDEX);
  SetIndexBuffer(2, RawAlphaBuffer, INDICATOR_CALCULATIONS);

  ArraySetAsSeries(AlphaBuffer, false);
  ArraySetAsSeries(AlphaColors, false);
  ArraySetAsSeries(RawAlphaBuffer, false);

  PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
  PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, InpDfaWindowSize);

  double scaleMin = InpDfaThresholdLow - InpScaleMargin;
  double scaleMax = InpDfaThresholdHigh + InpScaleMargin;
  if (scaleMin < 0.0) scaleMin = 0.0;
  if (scaleMax > 1.0) scaleMax = 1.0;

  IndicatorSetDouble(INDICATOR_MINIMUM, scaleMin);
  IndicatorSetDouble(INDICATOR_MAXIMUM, scaleMax);

  IndicatorSetInteger(INDICATOR_LEVELS, 3);
  IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, InpDfaThresholdLow);
  IndicatorSetDouble(INDICATOR_LEVELVALUE, 1, 0.50);
  IndicatorSetDouble(INDICATOR_LEVELVALUE, 2, InpDfaThresholdHigh);

  IndicatorSetInteger(INDICATOR_LEVELSTYLE, 0, STYLE_DOT);
  IndicatorSetInteger(INDICATOR_LEVELSTYLE, 1, STYLE_DASHDOT);
  IndicatorSetInteger(INDICATOR_LEVELSTYLE, 2, STYLE_DOT);

  IndicatorSetInteger(INDICATOR_LEVELCOLOR, 0, clrSilver);
  IndicatorSetInteger(INDICATOR_LEVELCOLOR, 1, clrGray);
  IndicatorSetInteger(INDICATOR_LEVELCOLOR, 2, clrSilver);

  string tfName = (InpTimeframe == PERIOD_CURRENT) ? EnumToString(_Period) : EnumToString(InpTimeframe);
  IndicatorSetString(INDICATOR_SHORTNAME,
                     StringFormat("FastDFA(%s, N=%d, Smooth=%d, Drift=%s)",
                                  tfName, InpDfaWindowSize, InpSmoothPeriod, (InpUseDriftFilter ? "ON" : "OFF")));
  IndicatorSetInteger(INDICATOR_DIGITS, 4);

  if (InpDfaWindowSize < 30) {
    Print("[DFA] エラー: ウィンドウサイズは30以上に設定してください。");
    return INIT_PARAMETERS_INCORRECT;
  }

  // MTF モードのハンドル取得
  if (InpTimeframe != PERIOD_CURRENT && InpTimeframe != _Period) {
    h_htfDfa = iCustom(_Symbol, InpTimeframe, "Hybrid_DFA_EA\\DFA", PERIOD_CURRENT,
                       InpDfaWindowSize, InpMinBoxSize, InpMaxBoxSize, InpMaxBarsToCalc,
                       InpSmoothPeriod, InpDfaThresholdLow, InpDfaThresholdHigh, InpScaleMargin,
                       InpUseDriftFilter, InpDriftThreshold);
    if (h_htfDfa == INVALID_HANDLE) {
      h_htfDfa = iCustom(_Symbol, InpTimeframe, "Indicators\\Hybrid_DFA_EA\\DFA", PERIOD_CURRENT,
                         InpDfaWindowSize, InpMinBoxSize, InpMaxBoxSize, InpMaxBarsToCalc,
                         InpSmoothPeriod, InpDfaThresholdLow, InpDfaThresholdHigh, InpScaleMargin,
                         InpUseDriftFilter, InpDriftThreshold);
    }
    if (h_htfDfa == INVALID_HANDLE) {
      PrintFormat("[DFA] 上位足 %s の内部DFAハンドル取得に失敗しました。", EnumToString(InpTimeframe));
      return INIT_FAILED;
    }
  } else {
    // Super Smoother 係数の計算
    if (InpSmoothPeriod > 1) {
      double a = MathExp(-1.41421356 * M_PI / (double)InpSmoothPeriod);
      double b = 2.0 * a * MathCos(1.41421356 * M_PI / (double)InpSmoothPeriod);
      ssC2 = b;
      ssC3 = -a * a;
      ssC1 = 1.0 - ssC2 - ssC3;
    }
  }

  // ワーク配列の確保とスケール事前計算
  int returnCount = InpDfaWindowSize - 1;
  ArrayResize(g_returns, returnCount);
  ArrayResize(g_Y, returnCount);
  PrecomputeScales(InpDfaWindowSize);

  PrintFormat("[DFA] OnInit 実行完了: Timeframe=%s, N=%d, sMin=%d, sMax=%d, MaxBars=%d, Scales=%d, DriftFilter=%s",
              tfName, InpDfaWindowSize, InpMinBoxSize, InpMaxBoxSize, InpMaxBarsToCalc, g_validScaleCount,
              (InpUseDriftFilter ? "ON" : "OFF"));

  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| カスタムインディケータ終了処理関数                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  if (h_htfDfa != INVALID_HANDLE) {
    IndicatorRelease(h_htfDfa);
    h_htfDfa = INVALID_HANDLE;
  }
}

//+------------------------------------------------------------------+
//| 高速化された1バー地点での DFA Alpha 算出ルーチン (1パスSSR+ドリフト結合) |
//+------------------------------------------------------------------+
double FastCalculateDfaAlphaAtBar(const double &close[], const int barIdx) {
  int N = InpDfaWindowSize;
  if (barIdx < N) return 0.5;

  int returnCount = N - 1;
  int startPos = barIdx - N + 1;

  // 1. 対数リターンの計算、プロファイル系列の生成、および効率比(ER)の集計
  double sumReturn = 0.0;
  double sumAbsReturn = 0.0;
  for (int i = 0; i < returnCount; i++) {
    int prevPos = startPos + i;
    int currPos = startPos + i + 1;
    if (close[prevPos] <= 0.0 || close[currPos] <= 0.0) {
      g_returns[i] = 0.0;
    } else {
      g_returns[i] = MathLog(close[currPos] / close[prevPos]);
    }

    sumReturn += g_returns[i];
    sumAbsReturn += MathAbs(g_returns[i]);
  }
  double meanReturn = sumReturn / (double)returnCount;

  // カウフマン効率比 (ER)
  double er = (sumAbsReturn > 1e-12) ? (MathAbs(sumReturn) / sumAbsReturn) : 0.0;

  double cumSum = 0.0;
  for (int i = 0; i < returnCount; i++) {
    cumSum += (g_returns[i] - meanReturn);
    g_Y[i] = cumSum;
  }

  if (g_validScaleCount < 3 || MathAbs(g_regDenomS) < 1e-12)
    return 0.5;

  // 2. 各スケールにおけるゆらぎ関数 F(s) の算出 (1パスSSR)
  int validScalesFound = 0;

  for (int k = 0; k < g_validScaleCount; k++) {
    int s = g_scaleList[k].s;
    int numBlocks = g_scaleList[k].numBlocks;
    int totalBlocks = g_scaleList[k].totalBlocks;
    int totalPoints = g_scaleList[k].totalPoints;
    double sumX = g_scaleList[k].sumX;
    double invDelta = g_scaleList[k].invDelta;
    double invS = g_scaleList[k].invS;

    double totalSSR = 0.0;

    for (int b = 0; b < totalBlocks; b++) {
      int blockStart = (b < numBlocks) ? (b * s) : (returnCount - (b - numBlocks + 1) * s);

      // 単一ループでの統計量積算 (中間コピーを完全排除)
      double sumY = 0.0;
      double sumY2 = 0.0;
      double sumXY = 0.0;

      for (int j = 0; j < s; j++) {
        double yVal = g_Y[blockStart + j];
        sumY += yVal;
        sumY2 += yVal * yVal;
        sumXY += (double)j * yVal;
      }

      // 解析的残差平方和の算出
      double slope = (s * sumXY - sumX * sumY) * invDelta;
      double Syy = sumY2 - (sumY * sumY) * invS;
      double Sxy = sumXY - (sumX * sumY) * invS;
      double ssr = Syy - slope * Sxy;

      if (ssr > 0.0)
        totalSSR += ssr;
    }

    double F_s = MathSqrt(totalSSR / (double)totalPoints);
    if (F_s > 1e-12) {
      g_logF[k] = MathLog(F_s);
      validScalesFound++;
    } else {
      g_logF[k] = -27.63; // 極小値フォールバック (ln(1e-12))
    }
  }

  if (validScalesFound < 3)
    return 0.5;

  // 3. ln(s) 対 ln(F(s)) の最小二乗回帰による Alpha の導出
  double sumLogF = 0.0;
  double sumLogSF = 0.0;
  for (int k = 0; k < g_validScaleCount; k++) {
    sumLogF += g_logF[k];
    sumLogSF += g_scaleList[k].logS * g_logF[k];
  }

  double alpha = (g_validScaleCount * sumLogSF - g_sumLogS * sumLogF) / g_regDenomS;

  if (!MathIsValidNumber(alpha))
    return 0.5;

  // 4. ドリフト結合型ハイブリッド補正 (Drift-Coupled Hybrid DFA)
  if (InpUseDriftFilter) {
    if (er >= InpDriftThreshold) {
      // 強い方向性トレンド: ERに応じてalphaを上方へ (最大1.0)
      double w = (1.0 - InpDriftThreshold > 1e-6) ? ((er - InpDriftThreshold) / (1.0 - InpDriftThreshold)) : 1.0;
      if (w > 1.0) w = 1.0;
      double baseAlpha = (alpha > 0.50) ? alpha : 0.50;
      alpha = baseAlpha + w * (1.0 - baseAlpha);
    } else {
      if (alpha < 0.50) {
        // 純粋なレンジ・平均回帰: 生のalphaをそのまま採用 (0.45未満のレンジ領域を維持)
      } else {
        // 方向感のない乱高下・大きなうねり (ER低 & DFA高):
        // 偽トレンドを抑制し、ERの比率に応じて中立(0.50)へ減衰
        double ratio = (InpDriftThreshold > 1e-6) ? (er / InpDriftThreshold) : 0.0;
        if (ratio > 1.0) ratio = 1.0;
        alpha = 0.50 + ratio * (alpha - 0.50);
      }
    }
  }

  return alpha;
}

//+------------------------------------------------------------------+
//| カスタムインディケータ反復計算関数                               |
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
                const int &spread[]) {
  if (rates_total <= InpDfaWindowSize)
    return 0;

  ArraySetAsSeries(time, false);
  ArraySetAsSeries(close, false);

  // 1. MTF モード (確定足同期による安全なバッファ参照)
  if (h_htfDfa != INVALID_HANDLE) {
    int start = prev_calculated - 1;
    if (start < 0) start = 0;

    for (int i = start; i < rates_total; i++) {
      double buf[1];
      // ルックアヘッド・バイアス回避: 確定済みのバー時刻と同期
      if (CopyBuffer(h_htfDfa, 0, time[i], 1, buf) > 0) {
        AlphaBuffer[i] = buf[0];
        RawAlphaBuffer[i] = buf[0];

        if (AlphaBuffer[i] < InpDfaThresholdLow)
          AlphaColors[i] = 0.0; // レンジ (赤)
        else if (AlphaBuffer[i] > InpDfaThresholdHigh)
          AlphaColors[i] = 2.0; // トレンド (青)
        else
          AlphaColors[i] = 1.0; // 中立 (グレー)
      } else {
        AlphaBuffer[i] = (i > 0) ? AlphaBuffer[i - 1] : EMPTY_VALUE;
        RawAlphaBuffer[i] = (i > 0) ? RawAlphaBuffer[i - 1] : EMPTY_VALUE;
        AlphaColors[i] = (i > 0) ? AlphaColors[i - 1] : 1.0;
      }
    }
    return rates_total;
  }

  // 2. 通常モード: 初回計算範囲のクリッピング制御
  int start = prev_calculated - 1;
  if (start < InpDfaWindowSize) {
    start = InpDfaWindowSize;

    // 初回起動時の走査バー数制限 (起動遅延解消の主要素)
    if (InpMaxBarsToCalc > 0 && (rates_total - start) > InpMaxBarsToCalc) {
      start = rates_total - InpMaxBarsToCalc;
    }

    for (int i = 0; i < start; i++) {
      RawAlphaBuffer[i] = EMPTY_VALUE;
      AlphaBuffer[i] = EMPTY_VALUE;
      AlphaColors[i] = 1.0;
    }
  }

  // DFA Alpha 値の高速計算ループ
  for (int i = start; i < rates_total; i++) {
    RawAlphaBuffer[i] = FastCalculateDfaAlphaAtBar(close, i);
  }

  // 3. Super Smoother フィルタによる低遅延平滑化
  if (InpSmoothPeriod > 1) {
    int ssStart = start;
    if (ssStart < InpDfaWindowSize + 2) {
      ssStart = InpDfaWindowSize + 2;
      AlphaBuffer[InpDfaWindowSize] = RawAlphaBuffer[InpDfaWindowSize];
      AlphaBuffer[InpDfaWindowSize + 1] = RawAlphaBuffer[InpDfaWindowSize + 1];
    }

    for (int i = ssStart; i < rates_total; i++) {
      if (RawAlphaBuffer[i] == EMPTY_VALUE) {
        AlphaBuffer[i] = EMPTY_VALUE;
        continue;
      }

      double p0 = RawAlphaBuffer[i];
      double p1 = (RawAlphaBuffer[i - 1] != EMPTY_VALUE) ? RawAlphaBuffer[i - 1] : p0;
      double y1 = (AlphaBuffer[i - 1] != EMPTY_VALUE) ? AlphaBuffer[i - 1] : p0;
      double y2 = (AlphaBuffer[i - 2] != EMPTY_VALUE) ? AlphaBuffer[i - 2] : y1;

      AlphaBuffer[i] = ssC1 * (p0 + p1) * 0.5 + ssC2 * y1 + ssC3 * y2;
    }
  } else {
    for (int i = start; i < rates_total; i++) {
      AlphaBuffer[i] = RawAlphaBuffer[i];
    }
  }

  // 4. 市場レジーム色分け判定
  for (int i = start; i < rates_total; i++) {
    if (AlphaBuffer[i] == EMPTY_VALUE) {
      AlphaColors[i] = 1.0;
    } else if (AlphaBuffer[i] < InpDfaThresholdLow) {
      AlphaColors[i] = 0.0; // レンジ (赤)
    } else if (AlphaBuffer[i] > InpDfaThresholdHigh) {
      AlphaColors[i] = 2.0; // トレンド (青)
    } else {
      AlphaColors[i] = 1.0; // 中立 (グレー)
    }
  }

  return rates_total;
}
//+------------------------------------------------------------------+
