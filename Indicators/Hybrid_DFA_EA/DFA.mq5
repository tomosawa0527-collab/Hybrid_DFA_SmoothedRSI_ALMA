//+------------------------------------------------------------------+
//|                                                          DFA.mq5 |
//|                                  Copyright 2026, Hybrid DFA System |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA System"
#property link "https://www.mql5.com"
#property version "1.00"
#property indicator_separate_window
#property indicator_buffers 1
#property indicator_plots 1

//--- プロット定義
#property indicator_label1 "DFA Alpha"
#property indicator_type1 DRAW_LINE
#property indicator_color1 clrDodgerBlue
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

//--- レベル設定
#property indicator_level1 0.45
#property indicator_level2 0.55
#property indicator_levelcolor clrSilver
#property indicator_levelstyle STYLE_DOT

//--- 入力パラメータ
//--- DFA 設定
input int InpDfaWindowSize = 300;                     // DFA 計算対象バー数 (N)
input int InpMinBoxSize = 4; // 最小ボックスサイズ (s_min)
input int InpMaxBoxSize = 0; // 最大ボックスサイズ (0: N/4 自動設定)

//--- バッファ
double AlphaBuffer[];

//+------------------------------------------------------------------+
//| カスタムインディケータ初期化関数                                 |
//+------------------------------------------------------------------+
int OnInit() {
  SetIndexBuffer(0, AlphaBuffer, INDICATOR_DATA);
  ArraySetAsSeries(AlphaBuffer, true);

  IndicatorSetString(INDICATOR_SHORTNAME,
                     StringFormat("DFA(N=%d)", InpDfaWindowSize));
  IndicatorSetInteger(INDICATOR_DIGITS, 4);

  if (InpDfaWindowSize < 30) {
    Print("[DFA] エラー: InpDfaWindowSize が小さすぎます (最低30必要)。");
    return INIT_PARAMETERS_INCORRECT;
  }

  return INIT_SUCCEEDED;
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
//| 1つのバー位置におけるDFA スケーリング指数 Alpha の計算           |
//+------------------------------------------------------------------+
double CalculateDfaAlphaAtBar(const double &close[], const int shift,
                              const int rates_total) {
  int N = InpDfaWindowSize;
  if (shift + N >= rates_total) {
    return 0.5; // データ不足時はデフォルト（ランダムウォーク）
  }

  // 1. 対数リターンの計算と平均
  int returnCount = N - 1;
  double returns[];
  ArrayResize(returns, returnCount);

  double sumReturn = 0.0;
  for (int i = 0; i < returnCount; i++) {
    int currentIdx = shift + i;
    int nextIdx = shift + i + 1;
    if (close[nextIdx] <= 0.0 || close[currentIdx] <= 0.0) {
      returns[i] = 0.0;
    } else {
      returns[i] = MathLog(close[currentIdx] / close[nextIdx]);
    }
    sumReturn += returns[i];
  }
  double meanReturn = sumReturn / returnCount;

  // 2. 累積和系列 Y_k の作成 (時系列順: 過去から現在へ)
  double Y[];
  ArrayResize(Y, returnCount);
  double cumSum = 0.0;
  // returns は shift (最新) から過去に向かって格納されているため、
  // 累積和は過去 (returnCount-1) から現在 (0) へ積算
  for (int i = 0; i < returnCount; i++) {
    int rIdx = returnCount - 1 - i;
    cumSum += (returns[rIdx] - meanReturn);
    Y[i] = cumSum;
  }

  // 3. ボックスサイズ s のリスト選定
  int sMin = (InpMinBoxSize >= 4) ? InpMinBoxSize : 4;
  int sMax = (InpMaxBoxSize > sMin) ? InpMaxBoxSize : (returnCount / 4);
  if (sMax <= sMin)
    sMax = sMin + 2;

  // 対数等間隔でスケール s を決定 (10〜16スケール)
  int numScales = 12;
  double logMin = MathLog(sMin);
  double logMax = MathLog(sMax);
  double step = (logMax - logMin) / (numScales - 1);

  double logS[];
  double logF[];
  ArrayResize(logS, numScales);
  ArrayResize(logF, numScales);

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
    int totalPoints = numBlocks * s;

    // 各ブロック内で1次線形フィッティングを行って残差二乗和を積算
    for (int b = 0; b < numBlocks; b++) {
      int blockStart = b * s;
      double blockX[];
      double blockY[];
      ArrayResize(blockX, s);
      ArrayResize(blockY, s);

      for (int j = 0; j < s; j++) {
        blockX[j] = j;
        blockY[j] = Y[blockStart + j];
      }

      double slope = 0.0, intercept = 0.0;
      if (LinearRegression(blockX, blockY, s, slope, intercept)) {
        for (int j = 0; j < s; j++) {
          double yFit = slope * j + intercept;
          double diff = blockY[j] - yFit;
          sumSquaredResiduals += diff * diff;
        }
      }
    }

    double F_s = MathSqrt(sumSquaredResiduals / totalPoints);
    if (F_s > 1e-12) {
      logS[validScales] = MathLog(s);
      logF[validScales] = MathLog(F_s);
      validScales++;
    }
  }

  if (validScales < 3) {
    return 0.5;
  }

  // 4. スケーリング指数 Alpha の回帰 (ln F(s) = Alpha * ln s + C)
  double alpha = 0.5, intercept = 0.0;
  if (LinearRegression(logS, logF, validScales, alpha, intercept)) {
    return alpha;
  }

  return 0.5;
}

//+------------------------------------------------------------------+
//| カスタムインディケータ計算関数                                   |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[]) {
  if (rates_total <= InpDfaWindowSize) {
    return 0;
  }

  // close を時系列配列 (0=最新) に設定
  double closeSeries[];
  ArraySetAsSeries(closeSeries, true);
  ArrayResize(closeSeries, rates_total);
  for (int i = 0; i < rates_total; i++) {
    closeSeries[i] = close[rates_total - 1 - i];
  }

  int limit;
  if (prev_calculated == 0) {
    // 初回計算: 過去バーを計算（負荷軽減のため最大1000本まで）
    limit = MathMin(rates_total - InpDfaWindowSize - 1, 1000);
    for (int i = rates_total - 1; i > limit; i--) {
      AlphaBuffer[i] = 0.5;
    }
  } else {
    // 差分計算: 最新の確定バーおよび最新バー
    limit = rates_total - prev_calculated + 1;
  }

  for (int i = limit; i >= 0; i--) {
    AlphaBuffer[i] = CalculateDfaAlphaAtBar(closeSeries, i, rates_total);
  }

  return rates_total;
}
//+------------------------------------------------------------------+
