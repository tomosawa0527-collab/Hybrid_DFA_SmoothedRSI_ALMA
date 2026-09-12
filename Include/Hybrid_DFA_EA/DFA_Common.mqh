//+------------------------------------------------------------------+
//|                                                   DFA_Common.mqh |
//|                                  Copyright 2026, Hybrid DFA System |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA System"
#property link "https://www.mql5.com"
#property strict

//+------------------------------------------------------------------+
//| レジーム種別定義                                                 |
//+------------------------------------------------------------------+
enum ENUM_REGIME_TYPE {
  REGIME_NONE = 0,       // 未判定
  REGIME_RANGE = 1,      // レンジ相場 (反発性 / 平均回帰)
  REGIME_TRANSITION = 2, // 遷移状態 / ランダムウォーク (不感帯・静観)
  REGIME_TREND = 3,      // トレンド相場 (持続性 / 追従)
  REGIME_ALL = 4         // レジーム制限なし (DFA無効時)
};

//+------------------------------------------------------------------+
//| エントリー戦略ソース (ポジションの由来追跡用)                   |
//+------------------------------------------------------------------+
enum ENUM_STRATEGY_SOURCE {
  STRATEGY_NONE = 0,  // なし
  STRATEGY_RANGE = 1, // レンジ戦略 (Super Smoother + RSI) 由来
  STRATEGY_TREND = 2  // トレンド戦略 (Dual ALMA) 由来
};

//+------------------------------------------------------------------+
//| シグナル種別                                                     |
//+------------------------------------------------------------------+
enum ENUM_SIGNAL_TYPE { SIGNAL_NONE = 0, SIGNAL_BUY = 1, SIGNAL_SELL = -1 };

//+------------------------------------------------------------------+
//| 上位足/タイムフレーム選択列挙体                                  |
//+------------------------------------------------------------------+
enum ENUM_HTF_MODE {
  HTF_MODE_AUTO_NEXT = 0,       // 自動 (1段階上の上位足)
  HTF_MODE_CURRENT   = 1,       // チャート時間軸 (同時間軸)
  HTF_MODE_M1        = PERIOD_M1,
  HTF_MODE_M5        = PERIOD_M5,
  HTF_MODE_M15       = PERIOD_M15,
  HTF_MODE_M30       = PERIOD_M30,
  HTF_MODE_H1        = PERIOD_H1,
  HTF_MODE_H4        = PERIOD_H4,
  HTF_MODE_D1        = PERIOD_D1,
  HTF_MODE_W1        = PERIOD_W1,
  HTF_MODE_MN1       = PERIOD_MN1
};

//+------------------------------------------------------------------+
//| 1段階上の上位足を判定するヘルパー                                |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetNextHigherTimeframe(const ENUM_TIMEFRAMES current_tf) {
  ENUM_TIMEFRAMES tf = (current_tf == PERIOD_CURRENT) ? _Period : current_tf;
  switch (tf) {
    case PERIOD_M1:  return PERIOD_M5;
    case PERIOD_M2:
    case PERIOD_M3:
    case PERIOD_M4:
    case PERIOD_M5:  return PERIOD_M15;
    case PERIOD_M6:
    case PERIOD_M10:
    case PERIOD_M12:
    case PERIOD_M15: return PERIOD_M30;
    case PERIOD_M20:
    case PERIOD_M30: return PERIOD_H1;
    case PERIOD_H1:
    case PERIOD_H2:
    case PERIOD_H3:  return PERIOD_H4;
    case PERIOD_H4:
    case PERIOD_H6:
    case PERIOD_H8:
    case PERIOD_H12: return PERIOD_D1;
    case PERIOD_D1:  return PERIOD_W1;
    case PERIOD_W1:  return PERIOD_MN1;
    default:         return PERIOD_MN1;
  }
}

//+------------------------------------------------------------------+
//| 設定から実効タイムフレームを解決するヘルパー                     |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES ResolveTimeframe(const ENUM_HTF_MODE mode, const ENUM_TIMEFRAMES current_tf = PERIOD_CURRENT) {
  ENUM_TIMEFRAMES base_tf = (current_tf == PERIOD_CURRENT) ? _Period : current_tf;
  if (mode == HTF_MODE_AUTO_NEXT) {
    return GetNextHigherTimeframe(base_tf);
  } else if (mode == HTF_MODE_CURRENT) {
    return base_tf;
  }
  return (ENUM_TIMEFRAMES)mode;
}

//+------------------------------------------------------------------+
//| システム内部状態構造体                                           |
//+------------------------------------------------------------------+
struct SSystemState {
  double alpha;            // 最新DFA指数
  double super_smoother;   // 最新Super Smoother値
  double smoothed_rsi_1;   // 前バー Smoothed RSI
  double smoothed_rsi_2;   // 前々バー Smoothed RSI
  double alma_fast_1;      // 前バー 短期ALMA
  double alma_fast_2;      // 前々バー 短期ALMA
  double alma_slow_1;      // 前バー 長期ALMA
  double alma_slow_2;      // 前々バー 長期ALMA
  double atr;              // 最新ATR値
  ENUM_REGIME_TYPE regime; // 判定レジーム
};

//+------------------------------------------------------------------+
//| ブローカー許容充填モードの自動判定 (Phase 2)                    |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillType(const string symbol) {
  long fillMode = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

  // 優先度順: FOK > IOC > RETURN
  if ((fillMode & SYMBOL_FILLING_FOK) != 0)
    return ORDER_FILLING_FOK;
  if ((fillMode & SYMBOL_FILLING_IOC) != 0)
    return ORDER_FILLING_IOC;

  return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| ストップレベル/スプレッドを考慮したSL/TP距離の補正 (Phase 2)      |
//+------------------------------------------------------------------+
double AdjustStopDistance(const string symbol, const double desiredDistance) {
  // ストップレベル (ポイント単位)
  long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
  // 現在スプレッド (ポイント単位)
  long spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

  if (point <= 0.0) return desiredDistance;

  // 最小許容距離 = max(ストップレベル, スプレッド) * point + マージン(2ポイント)
  double minStopPoints = MathMax((double)stopsLevel, (double)spreadPoints) + 2.0;
  double minDistance = minStopPoints * point;

  if (desiredDistance >= minDistance) {
    return desiredDistance;
  }

  PrintFormat("[DFA_Common] SL/TP距離を補正: %.5f -> %.5f (ストップレベル=%d, スプレッド=%d)",
              desiredDistance, minDistance, (int)stopsLevel, (int)spreadPoints);
  return minDistance;
}

//+------------------------------------------------------------------+
//| SYMBOL_VOLUME_STEP に基づく動的ロット正規化 (Phase 2)              |
//+------------------------------------------------------------------+
double NormalizeLot(const string symbol, const double lot) {
  double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

  if (lotStep <= 0.0) lotStep = 0.01;

  // lotStep の小数桁数を動的に取得
  int digits = 0;
  double tmp = lotStep;
  while (MathAbs(tmp - MathRound(tmp)) > 1e-9 && digits < 8) {
    tmp *= 10.0;
    digits++;
  }

  // lotStep へのアライメント (切り捨て)
  double result = MathFloor(lot / lotStep) * lotStep;

  // 最小・最大制限
  if (result < minLot) result = minLot;
  if (result > maxLot) result = maxLot;

  return NormalizeDouble(result, digits);
}

//+------------------------------------------------------------------+
//| 許容リスク%または固定ロットから取引ロット数を計算                |
//+------------------------------------------------------------------+
double CalculateLotSize(const string symbol, const double riskPercent,
                        const double fixedLot,
                        const double stopLossDistancePrice) {
  if (riskPercent <= 0.0) {
    return NormalizeLot(symbol, fixedLot);
  }

  // Phase 2: ACCOUNT_BALANCE → ACCOUNT_EQUITY に変更 (含み損時の過剰レバレッジを防止)
  double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  double riskAmount = accountEquity * (riskPercent / 100.0);

  if (stopLossDistancePrice <= 0.0) {
    return NormalizeLot(symbol, fixedLot);
  }

  double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
  double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
  double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

  if (tickSize <= 0.0 || tickValue <= 0.0 || lotStep <= 0.0) {
    return NormalizeLot(symbol, fixedLot);
  }

  double ticksAtRisk = stopLossDistancePrice / tickSize;
  double moneyLossPerOneLot = ticksAtRisk * tickValue;

  if (moneyLossPerOneLot <= 0.0) {
    return NormalizeLot(symbol, fixedLot);
  }

  double calculatedLot = riskAmount / moneyLossPerOneLot;

  // Phase 2: NormalizeLot で SYMBOL_VOLUME_STEP に適合した動的精度正規化
  return NormalizeLot(symbol, calculatedLot);
}

//+------------------------------------------------------------------+
//| ヒステリシス付きレジーム状態遷移 (Phase 3)                      |
//| 既存の ThresholdLow / ThresholdHigh をヒステリシスバンドとして使用  |
//| 一度確定したレジームを覆すには反対側の閾値を超える必要がある  |
//+------------------------------------------------------------------+
ENUM_REGIME_TYPE UpdateRegimeWithHysteresis(
    const ENUM_REGIME_TYPE prevRegime,
    const double alpha,
    const double thresholdLow,
    const double thresholdHigh) {

  switch (prevRegime) {
    case REGIME_RANGE:
      // RANGE → TREND: α が ThresholdHigh を超えて初めて遷移
      if (alpha > thresholdHigh)
        return REGIME_TREND;
      // RANGE → TRANSITION: α が不感帯に入っても RANGE を維持 (粘り)
      return REGIME_RANGE;

    case REGIME_TREND:
      // TREND → RANGE: α が ThresholdLow を下回って初めて遷移
      if (alpha < thresholdLow)
        return REGIME_RANGE;
      // TREND → TRANSITION: α が不感帯に入っても TREND を維持 (粘り)
      return REGIME_TREND;

    case REGIME_TRANSITION:
    case REGIME_NONE:
    case REGIME_ALL:
    default:
      // 初回または未判定状態: 従来通りの閾値判定
      if (alpha < thresholdLow)
        return REGIME_RANGE;
      if (alpha > thresholdHigh)
        return REGIME_TREND;
      return REGIME_TRANSITION;
  }
}
