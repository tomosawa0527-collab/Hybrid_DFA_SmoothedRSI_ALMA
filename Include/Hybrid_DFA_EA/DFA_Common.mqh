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
//| 許容リスク%または固定ロットから取引ロット数を計算                |
//+------------------------------------------------------------------+
double CalculateLotSize(const string symbol, const double riskPercent,
                        const double fixedLot,
                        const double stopLossDistancePrice) {
  if (riskPercent <= 0.0) {
    return NormalizeDouble(fixedLot, 2);
  }

  double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  double riskAmount = accountBalance * (riskPercent / 100.0);

  if (stopLossDistancePrice <= 0.0) {
    return NormalizeDouble(fixedLot, 2);
  }

  double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
  double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
  double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

  if (tickSize <= 0.0 || tickValue <= 0.0 || lotStep <= 0.0) {
    return NormalizeDouble(fixedLot, 2);
  }

  double ticksAtRisk = stopLossDistancePrice / tickSize;
  double moneyLossPerOneLot = ticksAtRisk * tickValue;

  if (moneyLossPerOneLot <= 0.0) {
    return NormalizeDouble(fixedLot, 2);
  }

  double calculatedLot = riskAmount / moneyLossPerOneLot;

  // ロットステップへのアライメント
  calculatedLot = MathFloor(calculatedLot / lotStep) * lotStep;

  // 最小・最大制限
  if (calculatedLot < minLot)
    calculatedLot = minLot;
  if (calculatedLot > maxLot)
    calculatedLot = maxLot;

  return NormalizeDouble(calculatedLot, 2);
}
