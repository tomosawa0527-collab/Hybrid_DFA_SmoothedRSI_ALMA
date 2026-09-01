//+------------------------------------------------------------------+
//|                                                          DFA.mq5 |
//|                                  Copyright 2026, Hybrid DFA System |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA System"
#property link "https://www.mql5.com"
#property version "1.00"
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
//--- DFA 設定
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT;  // 計算対象時間軸 (PERIOD_CURRENT: チャート時間軸)
input int InpDfaWindowSize = 300;                     // DFA 計算対象バー数 (N)
input int InpMinBoxSize = 8;                          // 最小ボックスサイズ (s_min)
input int InpMaxBoxSize = 0;                          // 最大ボックスサイズ (0: N/4 自動設定)
input int InpSmoothPeriod = 5;                        // 平滑化期間 (1: 平滑化なし, 2以上: 低遅延平滑化)
input double InpDfaThresholdLow = 0.45;               // レンジ判定閾値 (これ未満でレンジ)
input double InpDfaThresholdHigh = 0.55;              // トレンド判定閾値 (これ超過でトレンド)
input double InpScaleMargin = 0.05;                   // 縮尺マージン (Low-Margin 〜 High+Margin)

//--- バッファ
double AlphaBuffer[];
double AlphaColors[];
double RawAlphaBuffer[];

//--- MTF 上位足用内部ハンドル
int h_htfDfa = INVALID_HANDLE;

//--- 平滑化係数
double ssC1, ssC2, ssC3;

//--- DFA 計算用静的ワーク配列 (毎バーの ArrayResize を排除しヒープ断片化を防止)
double g_returns[];    // 対数リターン配列 (最大 N-1 要素)
double g_Y[];          // 累積偏差プロファイル系列 (最大 N-1 要素)
double g_logS[];       // スケール対数配列 (最大 numScales=16 要素)
double g_logF[];       // ゆらぎ対数配列 (最大 numScales=16 要素)
double g_blockX[];     // 局所回帰用 X 配列 (最大 sMax 要素, 静的整数列)
double g_blockY[];     // 局所回帰用 Y 配列 (最大 sMax 要素)
int    g_sMax = 0;     // 事前計算された最大ボックスサイズ

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

  // 縮尺を (InpDfaThresholdLow - InpScaleMargin) 〜 (InpDfaThresholdHigh + InpScaleMargin) で固定
  double scaleMin = InpDfaThresholdLow - InpScaleMargin;
  double scaleMax = InpDfaThresholdHigh + InpScaleMargin;
  if (scaleMin < 0.0) scaleMin = 0.0;
  if (scaleMax > 1.0) scaleMax = 1.0;

  IndicatorSetDouble(INDICATOR_MINIMUM, scaleMin);
  IndicatorSetDouble(INDICATOR_MAXIMUM, scaleMax);

  // 動的レベルラインの設定 (Low, 0.5基準線, High)
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
                     StringFormat("DFA(%s, N=%d, Smooth=%d, Low=%.2f, High=%.2f)",
                                  tfName, InpDfaWindowSize, InpSmoothPeriod, InpDfaThresholdLow, InpDfaThresholdHigh));
  IndicatorSetInteger(INDICATOR_DIGITS, 4);

  // MTF モード (上位足指定時) の場合、上位足の DFA ハンドルを取得
  if (InpTimeframe != PERIOD_CURRENT && InpTimeframe != _Period) {
    h_htfDfa = iCustom(_Symbol, InpTimeframe, "Hybrid_DFA_EA\\DFA", PERIOD_CURRENT,
                       InpDfaWindowSize, InpMinBoxSize, InpMaxBoxSize, InpSmoothPeriod,
                       InpDfaThresholdLow, InpDfaThresholdHigh, InpScaleMargin);
    if (h_htfDfa == INVALID_HANDLE) {
      h_htfDfa = iCustom(_Symbol, InpTimeframe, "Indicators\\Hybrid_DFA_EA\\DFA", PERIOD_CURRENT,
                         InpDfaWindowSize, InpMinBoxSize, InpMaxBoxSize, InpSmoothPeriod,
                         InpDfaThresholdLow, InpDfaThresholdHigh, InpScaleMargin);
    }
    if (h_htfDfa == INVALID_HANDLE) {
      PrintFormat("[DFA] 上位足 %s の内部DFAハンドル取得に失敗しました。", EnumToString(InpTimeframe));
      return INIT_FAILED;
    }
  } else {
    // 同時間軸計算用: Super Smoother 平滑化係数の計算
    if (InpSmoothPeriod > 1) {
      double a = MathExp(-1.41421356 * M_PI / (double)InpSmoothPeriod);
      double b = 2.0 * a * MathCos(1.41421356 * M_PI / (double)InpSmoothPeriod);
      ssC2 = b;
      ssC3 = -a * a;
      ssC1 = 1.0 - ssC2 - ssC3;
    }
  }

  PrintFormat("[DFA] OnInit 実行: Timeframe=%s, InpDfaWindowSize=%d, InpMinBoxSize=%d, InpMaxBoxSize=%d, InpSmoothPeriod=%d",
              tfName, InpDfaWindowSize, InpMinBoxSize, InpMaxBoxSize, InpSmoothPeriod);

  if (InpDfaWindowSize < 30) {
    Print("[DFA] エラー: インプットパラメータが不正です。");
    return INIT_PARAMETERS_INCORRECT;
  }

  // 静的ワーク配列の事前確保 (OnInit で1回だけ実行)
  int N = InpDfaWindowSize;
  int returnCount = N - 1;
  int sMinCalc = (InpMinBoxSize >= 4) ? InpMinBoxSize : 4;
  g_sMax = (InpMaxBoxSize > sMinCalc) ? InpMaxBoxSize : (returnCount / 4);
  if (g_sMax <= sMinCalc) g_sMax = sMinCalc + 2;

  ArrayResize(g_returns, returnCount);
  ArrayResize(g_Y, returnCount);
  ArrayResize(g_logS, 16);
  ArrayResize(g_logF, 16);
  ArrayResize(g_blockX, g_sMax);
  ArrayResize(g_blockY, g_sMax);

  // blockX[] の静的整数列を事前初期化 (バーループ内での反復初期化を排除)
  for (int j = 0; j < g_sMax; j++) {
    g_blockX[j] = (double)j;
  }

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
//| 最小二乗法による直線回帰 (y = slope * x + intercept)             |
//+------------------------------------------------------------------+
bool LinearRegression(const double &x[], const double &y[], const int count,
                      double &slope, double &intercept) {
  if (count < 2)
    return false;

  double sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumX2 = 0.0;
  for (int i = 0; i < count; i++) {
    sumX += x[i];
    sumY += y[i];
    sumXY += x[i] * y[i];
    sumX2 += x[i] * x[i];
  }

  double denominator = count * sumX2 - sumX * sumX;
  if (MathAbs(denominator) < 1e-12)
    return false;

  slope = (count * sumXY - sumX * sumY) / denominator;
  intercept = (sumY - slope * sumX) / count;
  return true;
}

//+------------------------------------------------------------------+
//| 1つのバー位置 (barIdx は 0=最古, rates_total-1=最新) でのDFA計算  |
//+------------------------------------------------------------------+
double CalculateDfaAlphaAtBar(const double &close[], const int barIdx,
                              const int rates_total) {
  int N = InpDfaWindowSize;
  if (barIdx < N) {
    return 0.5; // データ不足時はデフォルト
  }

  // 1. 対数リターンの計算と平均 (過去から現在へ) — 静的配列 g_returns[] を再利用
  int returnCount = N - 1;

  double sumReturn = 0.0;
  int startPos = barIdx - N + 1;
  for (int i = 0; i < returnCount; i++) {
    int prevPos = startPos + i;
    int currPos = startPos + i + 1;
    if (close[prevPos] <= 0.0 || close[currPos] <= 0.0) {
      g_returns[i] = 0.0;
    } else {
      g_returns[i] = MathLog(close[currPos] / close[prevPos]);
    }
    sumReturn += g_returns[i];
  }
  double meanReturn = sumReturn / returnCount;

  // 2. 累積和系列 Y_k の作成 (時系列順: 過去から現在へ) — 静的配列 g_Y[] を再利用
  double cumSum = 0.0;
  for (int i = 0; i < returnCount; i++) {
    cumSum += (g_returns[i] - meanReturn);
    g_Y[i] = cumSum;
  }

  // 3. ボックスサイズ s のリスト選定 — g_sMax は OnInit で事前計算済み
  int sMin = (InpMinBoxSize >= 4) ? InpMinBoxSize : 4;
  int sMax = g_sMax;

  // 対数等間隔でスケール s を決定 (16スケール) — 静的配列 g_logS[], g_logF[] を再利用
  int numScales = 16;
  double logMin = MathLog(sMin);
  double logMax = MathLog(sMax);
  double step = (logMax - logMin) / (numScales - 1);

  int validScales = 0;
  int lastS = -1;

  for (int k = 0; k < numScales; k++) {
    int s = (int)MathRound(MathExp(logMin + k * step));
    if (s == lastS || s < sMin || s > sMax)
      continue;
    lastS = s;

    int numBlocks = returnCount / s;
    if (numBlocks < 1)
      continue;

    double sumSquaredResiduals = 0.0;
    int totalBlocks = 2 * numBlocks;
    int totalPoints = totalBlocks * s;

    for (int b = 0; b < totalBlocks; b++) {
      int blockStart;
      if (b < numBlocks) {
        // 順方向 (先頭から)
        blockStart = b * s;
      } else {
        // 逆方向 (末尾から端数を取り込む)
        blockStart = returnCount - (b - numBlocks + 1) * s;
      }

      for (int j = 0; j < s; j++) {
        g_blockY[j] = g_Y[blockStart + j];
      }

      double slope = 0.0, intercept = 0.0;
      if (LinearRegression(g_blockX, g_blockY, s, slope, intercept)) {
        for (int j = 0; j < s; j++) {
          double yFit = slope * j + intercept;
          double diff = g_blockY[j] - yFit;
          sumSquaredResiduals += diff * diff;
        }
      }
    }

    double F_s = MathSqrt(sumSquaredResiduals / totalPoints);
    if (F_s > 1e-12) {
      g_logS[validScales] = MathLog(s);
      g_logF[validScales] = MathLog(F_s);
      validScales++;
    }
  }

  if (validScales < 3) {
    return 0.5;
  }

  // 4. スケーリング指数 Alpha の回帰 (ln F(s) = Alpha * ln s + C)
  double alpha = 0.5, intercept = 0.0;
  if (LinearRegression(g_logS, g_logF, validScales, alpha, intercept)) {
    return alpha;
  }

  return 0.5;
}

//+------------------------------------------------------------------+
//| カスタムインディケータ計算関数 (0=最古, rates_total-1=最新)      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[]) {
  if (rates_total <= InpDfaWindowSize) {
    return 0;
  }

  ArraySetAsSeries(time, false);
  ArraySetAsSeries(close, false);

  // 1. MTF モード (上位足から取得する場合)
  if (h_htfDfa != INVALID_HANDLE) {
    int start = prev_calculated - 1;
    if (start < 0)
      start = 0;

    for (int i = start; i < rates_total; i++) {
      double buf[1];
      if (CopyBuffer(h_htfDfa, 0, time[i], 1, buf) > 0) {
        AlphaBuffer[i] = buf[0];
        RawAlphaBuffer[i] = buf[0];

        if (AlphaBuffer[i] < InpDfaThresholdLow) {
          AlphaColors[i] = 0.0; // レンジ (赤)
        } else if (AlphaBuffer[i] > InpDfaThresholdHigh) {
          AlphaColors[i] = 2.0; // トレンド (青)
        } else {
          AlphaColors[i] = 1.0; // 中立・遷移 (グレー)
        }
      } else {
        AlphaBuffer[i] = (i > 0) ? AlphaBuffer[i - 1] : EMPTY_VALUE;
        RawAlphaBuffer[i] = (i > 0) ? RawAlphaBuffer[i - 1] : EMPTY_VALUE;
        AlphaColors[i] = (i > 0) ? AlphaColors[i - 1] : 1.0;
      }
    }
    return rates_total;
  }

  // 2. 通常モード (同時間軸で直接計算する場合)
  int start = prev_calculated - 1;
  if (start < InpDfaWindowSize) {
    start = InpDfaWindowSize;
    for (int i = 0; i < start; i++) {
      RawAlphaBuffer[i] = EMPTY_VALUE;
      AlphaBuffer[i] = EMPTY_VALUE;
      AlphaColors[i] = 1.0;
    }
  }

  // 生の DFA Alpha を計算
  for (int i = start; i < rates_total; i++) {
    RawAlphaBuffer[i] = CalculateDfaAlphaAtBar(close, i, rates_total);
  }

  // 平滑化の適用
  if (InpSmoothPeriod > 1) {
    int ssStart = start;
    if (ssStart < InpDfaWindowSize + 2) {
      ssStart = InpDfaWindowSize + 2;
      AlphaBuffer[InpDfaWindowSize] = RawAlphaBuffer[InpDfaWindowSize];
      AlphaBuffer[InpDfaWindowSize + 1] = RawAlphaBuffer[InpDfaWindowSize + 1];
    }
    for (int i = ssStart; i < rates_total; i++) {
      AlphaBuffer[i] = ssC1 * (RawAlphaBuffer[i] + RawAlphaBuffer[i - 1]) * 0.5 +
                       ssC2 * AlphaBuffer[i - 1] +
                       ssC3 * AlphaBuffer[i - 2];
    }
  } else {
    for (int i = start; i < rates_total; i++) {
      AlphaBuffer[i] = RawAlphaBuffer[i];
    }
  }

  // レジーム色分けの設定 (0=レンジ:赤, 1=中立:グレー, 2=トレンド:青)
  for (int i = start; i < rates_total; i++) {
    if (AlphaBuffer[i] == EMPTY_VALUE) {
      AlphaColors[i] = 1.0;
    } else if (AlphaBuffer[i] < InpDfaThresholdLow) {
      AlphaColors[i] = 0.0; // レンジ (赤)
    } else if (AlphaBuffer[i] > InpDfaThresholdHigh) {
      AlphaColors[i] = 2.0; // トレンド (青)
    } else {
      AlphaColors[i] = 1.0; // 中立・遷移 (グレー)
    }
  }

  return rates_total;
}
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
