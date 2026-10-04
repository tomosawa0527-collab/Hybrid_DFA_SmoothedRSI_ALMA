//+------------------------------------------------------------------+
//|                                       KalmanStrategy_Common.mqh |
//|                                  Copyright 2026, Quant Research  |
//|       FX売買戦略仕様書（実運用完全版・カルマンフィルター統合版）共通定義 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Quant Research"
#property link "https://www.mql5.com"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| カルマンレジーム定数 (仕様書第3.1章)                             |
//+------------------------------------------------------------------+
#define KALMAN_REGIME_UP     1.0    // 上昇トレンドレジーム
#define KALMAN_REGIME_DOWN  -1.0    // 下降トレンドレジーム
#define KALMAN_REGIME_RANGE  0.0    // レンジ相場レジーム

// 後方互換用レジーム種別定義
enum ENUM_REGIME_TYPE {
  REGIME_NONE = 0,       // 未判定
  REGIME_RANGE = 1,      // レンジ相場 (反発性 / 平均回帰)
  REGIME_TRANSITION = 2, // 遷移状態 / ランダムウォーク (不感帯・静観)
  REGIME_TREND = 3,      // トレンド相場 (持続性 / 追従 - 汎用)
  REGIME_UP_TREND = 4,   // 上昇トレンド (カルマン Z >= 2.0)
  REGIME_DOWN_TREND = 5, // 下降トレンド (カルマン Z <= -2.0)
  REGIME_ALL = 6         // レジーム制限なし (無効時)
};

//+------------------------------------------------------------------+
//| 通貨クラスタ定義 (仕様書第8.2章)                                 |
//+------------------------------------------------------------------+
enum ENUM_CURRENCY_CLUSTER {
  CLUSTER_UNKNOWN     = 0,
  CLUSTER_USD         = 1, // USD (上限 1.0%)
  CLUSTER_EUR_GBP_CHF = 2, // EUR, GBP, CHF (欧州: 上限 1.0%)
  CLUSTER_COMMODITY   = 3, // AUD, NZD, CAD (資源国: 上限 1.0%)
  CLUSTER_JPY         = 4  // JPY (上限 1.0%)
};

//+------------------------------------------------------------------+
//| エントリー戦略ソース (ポジションの由来追跡用)                   |
//+------------------------------------------------------------------+
enum ENUM_STRATEGY_SOURCE {
  STRATEGY_NONE  = 0, // なし
  STRATEGY_RANGE = 1, // レンジ戦略 由来
  STRATEGY_TREND = 2  // トレンド戦略 由来
};

//+------------------------------------------------------------------+
//| トレンド戦略 移動平均種別定義                                    |
//+------------------------------------------------------------------+
enum ENUM_TREND_MA_TYPE {
  TREND_MA_SMA  = 0, // SMA (単純移動平均)
  TREND_MA_EMA  = 1, // EMA (指数平滑移動平均)
  TREND_MA_SMMA = 2, // SMMA (平滑移動平均)
  TREND_MA_LWMA = 3, // LWMA (線形加重移動平均: 仕様書標準)
  TREND_MA_ALMA = 4  // ALMA (Arnaud Legoux 移動平均)
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
  double kalman_z;         // 最新カルマンZスコア
  double kalman_slope;     // 最新カルマン局所傾き (beta)
  double alpha;            // 最新DFA指数 (後方互換用)
  double super_smoother;   // 最新Super Smoother値
  double smoothed_rsi_1;   // 前バー Smoothed RSI
  double smoothed_rsi_2;   // 前々バー Smoothed RSI
  double alma_fast_1;      // 前バー 短期ALMA
  double alma_fast_2;      // 前々バー 短期ALMA
  double alma_slow_1;      // 前バー 長期ALMA
  double alma_slow_2;      // 前々バー 長期ALMA
  double alma_signal_1;    // 前バー ALMAシグナル状態
  double alma_signal_2;    // 前々バー ALMAシグナル状態
  double atr;              // 最新ATR値
  ENUM_REGIME_TYPE regime; // 判定レジーム
};

//+------------------------------------------------------------------+
//| ブローカー許容充填モードの自動判定                               |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillType(const string symbol) {
  long fillMode = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
  if ((fillMode & SYMBOL_FILLING_FOK) != 0)
    return ORDER_FILLING_FOK;
  if ((fillMode & SYMBOL_FILLING_IOC) != 0)
    return ORDER_FILLING_IOC;
  return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| ストップレベル/スプレッドを考慮したSL/TP距離の補正                |
//+------------------------------------------------------------------+
double AdjustStopDistance(const string symbol, const double desiredDistance) {
  long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
  long spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  if (point <= 0.0) return desiredDistance;

  double minStopPoints = MathMax((double)stopsLevel, (double)spreadPoints) + 2.0;
  double minDistance = minStopPoints * point;

  if (desiredDistance >= minDistance) {
    return desiredDistance;
  }

  PrintFormat("[KalmanStrategy] SL/TP距離補正: %.5f -> %.5f (ストップレベル=%d, スプレッド=%d)",
              desiredDistance, minDistance, (int)stopsLevel, (int)spreadPoints);
  return minDistance;
}

//+------------------------------------------------------------------+
//| SYMBOL_VOLUME_STEP に基づく動的ロット正規化                      |
//+------------------------------------------------------------------+
double NormalizeLot(const string symbol, const double lot) {
  double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

  if (lotStep <= 0.0) lotStep = 0.01;

  int digits = 0;
  double tmp = lotStep;
  while (MathAbs(tmp - MathRound(tmp)) > 1e-9 && digits < 8) {
    tmp *= 10.0;
    digits++;
  }

  // 端数切り捨て (FLOOR処理: 仕様書第2.3章)
  double result = MathFloor(lot / lotStep) * lotStep;

  if (result < minLot) result = 0.0;
  if (result > maxLot) result = maxLot;

  return NormalizeDouble(result, digits);
}

//+------------------------------------------------------------------+
//| 通貨ペアからBase通貨とQuote通貨をパース (仕様書第8章)            |
//+------------------------------------------------------------------+
bool ParseSymbolCurrencies(const string symbol, string &baseCurr, string &quoteCurr) {
  baseCurr = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
  quoteCurr = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
  if (baseCurr != "" && quoteCurr != "")
    return true;

  // シンボル名文字列からのフォールバック解析
  string clean = symbol;
  StringReplace(clean, "_", "");
  StringReplace(clean, ".", "");
  StringReplace(clean, "-", "");
  StringReplace(clean, "#", "");

  if (StringLen(clean) >= 6) {
    baseCurr = StringSubstr(clean, 0, 3);
    quoteCurr = StringSubstr(clean, 3, 3);
    return true;
  }
  return false;
}

//+------------------------------------------------------------------+
//| 通貨名から所属クラスタを取得 (仕様書第8.2章)                     |
//+------------------------------------------------------------------+
ENUM_CURRENCY_CLUSTER GetCurrencyCluster(const string curr) {
  if (curr == "USD") return CLUSTER_USD;
  if (curr == "EUR" || curr == "GBP" || curr == "CHF") return CLUSTER_EUR_GBP_CHF;
  if (curr == "AUD" || curr == "NZD" || curr == "CAD") return CLUSTER_COMMODITY;
  if (curr == "JPY") return CLUSTER_JPY;
  return CLUSTER_UNKNOWN;
}

//+------------------------------------------------------------------+
//| クロス円ペア判定 (仕様書第2.2章)                                 |
//+------------------------------------------------------------------+
bool IsJpyCross(const string symbol) {
  string baseCurr, quoteCurr;
  ParseSymbolCurrencies(symbol, baseCurr, quoteCurr);
  return (quoteCurr == "JPY" || baseCurr == "JPY" || StringFind(symbol, "JPY") >= 0);
}

//+------------------------------------------------------------------+
//| PipSize 取得 (仕様書第2.2章)                                     |
//| JPYペア: 0.01, Non-JPYペア: 0.0001                               |
//+------------------------------------------------------------------+
double GetPipSize(const string symbol) {
  return IsJpyCross(symbol) ? 0.01 : 0.0001;
}

//+------------------------------------------------------------------+
//| 1.0 Lotあたりの 1 Pip 価値 (口座通貨ベース) (仕様書第2.2章)       |
//+------------------------------------------------------------------+
double GetPipValuePerLot(const string symbol) {
  double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
  double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
  double pip_size   = GetPipSize(symbol);

  if (tick_size > 0.0 && tick_value > 0.0) {
    return (pip_size / tick_size) * tick_value;
  }

  // フォールバック計算 (口座通貨がJPYの場合)
  string accCurr = AccountInfoString(ACCOUNT_CURRENCY);
  if (accCurr == "JPY") {
    if (IsJpyCross(symbol)) {
      return 1000.0; // 100,000 * 0.01 = 1,000 JPY
    }
    double usdjpy = SymbolInfoDouble("USDJPY", SYMBOL_BID);
    if (usdjpy <= 0.0) usdjpy = 150.0;
    return 10.0 * usdjpy;
  }

  return 10.0;
}

//+------------------------------------------------------------------+
//| Swing Low 算出 (仕様書第3.5章: 当日バー除外の過去N本最小値)       |
//+------------------------------------------------------------------+
double GetSwingLow(const string symbol, const ENUM_TIMEFRAMES tf, const int period = 20, const int shift = 1) {
  double lows[];
  ArraySetAsSeries(lows, true);
  int copied = CopyLow(symbol, tf, shift, period, lows);
  if (copied < period) return 0.0;

  double minVal = lows[0];
  for (int i = 1; i < copied; i++) {
    if (lows[i] < minVal) minVal = lows[i];
  }
  return minVal;
}

//+------------------------------------------------------------------+
//| Swing High 算出 (仕様書第3.5章: 当日バー除外の過去N本最大値)      |
//+------------------------------------------------------------------+
double GetSwingHigh(const string symbol, const ENUM_TIMEFRAMES tf, const int period = 20, const int shift = 1) {
  double highs[];
  ArraySetAsSeries(highs, true);
  int copied = CopyHigh(symbol, tf, shift, period, highs);
  if (copied < period) return 0.0;

  double maxVal = highs[0];
  for (int i = 1; i < copied; i++) {
    if (highs[i] > maxVal) maxVal = highs[i];
  }
  return maxVal;
}

//+------------------------------------------------------------------+
//| LWMA アンサンブル合致度 (Ensemble Ratio) 算出 (仕様書第4.3章)    |
//| 短期(10/30), 中期(20/60), 長期(40/120)                           |
//+------------------------------------------------------------------+
void CalcEnsembleRatios(const double lwma10, const double lwma30,
                        const double lwma20, const double lwma60,
                        const double lwma40, const double lwma120,
                        double &outLongRatio, double &outShortRatio) {
  double flag_l1 = (lwma10 > lwma30) ? 1.0 : 0.0;
  double flag_l2 = (lwma20 > lwma60) ? 1.0 : 0.0;
  double flag_l3 = (lwma40 > lwma120) ? 1.0 : 0.0;
  outLongRatio = (flag_l1 + flag_l2 + flag_l3) / 3.0;

  double flag_s1 = (lwma10 < lwma30) ? 1.0 : 0.0;
  double flag_s2 = (lwma20 < lwma60) ? 1.0 : 0.0;
  double flag_s3 = (lwma40 < lwma120) ? 1.0 : 0.0;
  outShortRatio = (flag_s1 + flag_s2 + flag_s3) / 3.0;
}

//+------------------------------------------------------------------+
//| 仕様書第6章に基づく厳格ロットサイジング                          |
//| MaxRiskAmount = AccountEquity * 0.005                            |
//| RiskDistance = max(|Close[t] - StopPrice_init|, 0.5 * ATR(14))   |
//| RiskInPips = RiskDistance / PipSize                              |
//| BaseLots = MaxRiskAmount / (RiskInPips * PipValuePerLot)         |
//| FinalLots = floor((BaseLots * EnsembleRatio) / 0.01) * 0.01      |
//+------------------------------------------------------------------+
double CalculateSpecificationLotSize(const string symbol,
                                     const double riskDistance,
                                     const double ensembleRatio,
                                     const double riskPercent = 0.5) {
  if (riskDistance <= 0.0 || ensembleRatio <= 0.0 || riskPercent <= 0.0)
    return 0.0;

  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double maxRiskAmount = equity * (riskPercent / 100.0);

  double pipSize  = GetPipSize(symbol);
  double pipValue = GetPipValuePerLot(symbol);
  if (pipSize <= 0.0 || pipValue <= 0.0) return 0.0;

  double riskInPips = riskDistance / pipSize;
  if (riskInPips <= 0.0) return 0.0;

  double baseLots = maxRiskAmount / (riskInPips * pipValue);
  double finalLots = MathFloor((baseLots * ensembleRatio) / 0.01) * 0.01;

  double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  if (finalLots < minLot)
    return 0.0; // 0.01未満は見送り (仕様書第6.3章)

  return NormalizeLot(symbol, finalLots);
}

//+------------------------------------------------------------------+
//| クラスタリスク状態構造体 (仕様書第8章)                           |
//+------------------------------------------------------------------+
struct SClusterRiskState {
  double usd_long;
  double usd_short;
  double eur_gbp_chf_long;
  double eur_gbp_chf_short;
  double commodity_long;
  double commodity_short;
  double jpy_long;
  double jpy_short;
  double total_risk; // ポートフォリオ総オープンリスク
};

//+------------------------------------------------------------------+
//| クラスタ別リスク加算内部ヘルパー                                 |
//+------------------------------------------------------------------+
void AddClusterRiskAmount(SClusterRiskState &risks, const ENUM_CURRENCY_CLUSTER cluster, const bool isLong, const double amount) {
  switch (cluster) {
    case CLUSTER_USD:
      if (isLong) risks.usd_long += amount; else risks.usd_short += amount;
      break;
    case CLUSTER_EUR_GBP_CHF:
      if (isLong) risks.eur_gbp_chf_long += amount; else risks.eur_gbp_chf_short += amount;
      break;
    case CLUSTER_COMMODITY:
      if (isLong) risks.commodity_long += amount; else risks.commodity_short += amount;
      break;
    case CLUSTER_JPY:
      if (isLong) risks.jpy_long += amount; else risks.jpy_short += amount;
      break;
    default:
      break;
  }
}

//+------------------------------------------------------------------+
//| クラスタ別リスク参照内部ヘルパー                                 |
//+------------------------------------------------------------------+
double GetClusterRiskAmount(const SClusterRiskState &risks, const ENUM_CURRENCY_CLUSTER cluster, const bool isLong) {
  switch (cluster) {
    case CLUSTER_USD:
      return isLong ? risks.usd_long : risks.usd_short;
    case CLUSTER_EUR_GBP_CHF:
      return isLong ? risks.eur_gbp_chf_long : risks.eur_gbp_chf_short;
    case CLUSTER_COMMODITY:
      return isLong ? risks.commodity_long : risks.commodity_short;
    case CLUSTER_JPY:
      return isLong ? risks.jpy_long : risks.jpy_short;
    default:
      return 0.0;
  }
}

//+------------------------------------------------------------------+
//| 保有ポジションから現在のクラスタ別リスクを集計 (仕様書第8章)     |
//+------------------------------------------------------------------+
void CalculateCurrentClusterRisks(const ulong magicFilter, SClusterRiskState &risks, const double riskPerPosPercent = 0.5) {
  ZeroMemory(risks);
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double riskAmount = equity * (riskPerPosPercent / 100.0);

  int total = PositionsTotal();
  for (int i = 0; i < total; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket > 0) {
      if (magicFilter == 0 || PositionGetInteger(POSITION_MAGIC) == magicFilter) {
        string sym = PositionGetString(POSITION_SYMBOL);
        ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

        string baseCurr, quoteCurr;
        if (!ParseSymbolCurrencies(sym, baseCurr, quoteCurr)) continue;

        ENUM_CURRENCY_CLUSTER baseCluster = GetCurrencyCluster(baseCurr);
        ENUM_CURRENCY_CLUSTER quoteCluster = GetCurrencyCluster(quoteCurr);

        // BUY: Baseロング, Quoteショート
        // SELL: Baseショート, Quoteロング
        bool baseIsLong = (pType == POSITION_TYPE_BUY);
        bool quoteIsLong = (pType == POSITION_TYPE_SELL);

        AddClusterRiskAmount(risks, baseCluster, baseIsLong, riskAmount);
        AddClusterRiskAmount(risks, quoteCluster, quoteIsLong, riskAmount);

        risks.total_risk += riskAmount;
      }
    }
  }
}

//+------------------------------------------------------------------+
//| 2通貨分解クラスタ制限バリデーション (仕様書第8.3章・第8.4章)      |
//| 各クラスタ同方向上限: 口座資産比 1.0%                            |
//| ポートフォリオ総オープンリスク上限: 口座資産比 2.0%              |
//+------------------------------------------------------------------+
bool ValidateDualCurrencyClusterLimits(const string symbol,
                                      const ENUM_POSITION_TYPE orderType,
                                      const ulong magicFilter,
                                      const double riskPerPosPercent = 0.5) {
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  if (equity <= 0.0) return false;

  double maxClusterRisk = equity * 0.010; // 1.0% (仕様書第8.2章)
  double maxTotalRisk   = equity * 0.020; // 2.0% (仕様書第8.4章)
  double newRiskAmount  = equity * (riskPerPosPercent / 100.0); // 0.5%

  SClusterRiskState currentRisks;
  CalculateCurrentClusterRisks(magicFilter, currentRisks, riskPerPosPercent);

  // 1. ポートフォリオ総オープンリスク上限チェック
  if (currentRisks.total_risk + newRiskAmount > maxTotalRisk + 1e-4) {
    PrintFormat("[ClusterRisk] 発注拒絶: ポートフォリオ総オープンリスク上限(2.0%%)超過 (現在: %.2f + 新規: %.2f > 上限: %.2f)",
                currentRisks.total_risk, newRiskAmount, maxTotalRisk);
    return false;
  }

  string baseCurr, quoteCurr;
  if (!ParseSymbolCurrencies(symbol, baseCurr, quoteCurr)) return true;

  ENUM_CURRENCY_CLUSTER baseCluster = GetCurrencyCluster(baseCurr);
  ENUM_CURRENCY_CLUSTER quoteCluster = GetCurrencyCluster(quoteCurr);

  bool baseIsLong = (orderType == POSITION_TYPE_BUY);
  bool quoteIsLong = (orderType == POSITION_TYPE_SELL);

  // 2. 通貨A (Base) クラスタ上限チェック (1.0%)
  if (baseCluster != CLUSTER_UNKNOWN) {
    double baseCurrent = GetClusterRiskAmount(currentRisks, baseCluster, baseIsLong);
    if (baseCurrent + newRiskAmount > maxClusterRisk + 1e-4) {
      PrintFormat("[ClusterRisk] 発注拒絶: Base通貨(%s) クラスタ同方向リスク上限(1.0%%)超過 (現在: %.2f + 新規: %.2f > 上限: %.2f)",
                  baseCurr, baseCurrent, newRiskAmount, maxClusterRisk);
      return false;
    }
  }

  // 3. 通貨B (Quote) クラスタ上限チェック (1.0%)
  if (quoteCluster != CLUSTER_UNKNOWN) {
    double quoteCurrent = GetClusterRiskAmount(currentRisks, quoteCluster, quoteIsLong);
    if (quoteCurrent + newRiskAmount > maxClusterRisk + 1e-4) {
      PrintFormat("[ClusterRisk] 発注拒絶: Quote通貨(%s) クラスタ同方向リスク上限(1.0%%)超過 (現在: %.2f + 新規: %.2f > 上限: %.2f)",
                  quoteCurr, quoteCurrent, newRiskAmount, maxClusterRisk);
      return false;
    }
  }

  return true;
}

//+------------------------------------------------------------------+
//| 実効レバレッジ算出 (仕様書第7.1章: <= 5.0)                       |
//+------------------------------------------------------------------+
double CalculateEffectiveLeverage(const ulong magicFilter = 0) {
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  if (equity <= 0.0) return 999.0;

  double totalNotional = 0.0;
  int total = PositionsTotal();
  for (int i = 0; i < total; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket > 0) {
      if (magicFilter == 0 || PositionGetInteger(POSITION_MAGIC) == magicFilter) {
        string sym = PositionGetString(POSITION_SYMBOL);
        double volume = PositionGetDouble(POSITION_VOLUME);
        double price = PositionGetDouble(POSITION_PRICE_OPEN);
        ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        ENUM_ORDER_TYPE oType = (pType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

        double margin = 0.0;
        if (OrderCalcMargin(oType, sym, volume, price, margin)) {
          long lev = AccountInfoInteger(ACCOUNT_LEVERAGE);
          if (lev <= 0) lev = 25;
          totalNotional += (margin * (double)lev);
        } else {
          double contractSize = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
          totalNotional += (volume * contractSize * price);
        }
      }
    }
  }
  return totalNotional / equity;
}

//+------------------------------------------------------------------+
//| 証拠金維持率取得 (仕様書第7.2章)                                 |
//+------------------------------------------------------------------+
double GetAccountMarginLevel() {
  double margin = AccountInfoDouble(ACCOUNT_MARGIN);
  if (margin <= 0.0) return 99999.0;
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  return (equity / margin) * 100.0;
}

//+------------------------------------------------------------------+
//| 緊急リスクオフゲート (仕様書第7.2章: 維持率 < 150% 時)           |
//| 含み損の大きいポジションから順に 50% を強制成行決済              |
//+------------------------------------------------------------------+
void TriggerEmergencyRiskOff(CTrade &trade, const ulong magicFilter = 0) {
  Print("[Emergency] 証拠金維持率が150%未満に急落しました。緊急リスクオフ(含み損順50%決済)を実行します。");

  struct SLossPos {
    ulong ticket;
    double loss;
    double volume;
  };

  SLossPos lossPositions[];
  int total = PositionsTotal();
  for (int i = 0; i < total; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket > 0) {
      if (magicFilter == 0 || PositionGetInteger(POSITION_MAGIC) == magicFilter) {
        double profit = PositionGetDouble(POSITION_PROFIT);
        if (profit < 0.0) {
          int sz = ArraySize(lossPositions);
          ArrayResize(lossPositions, sz + 1);
          lossPositions[sz].ticket = ticket;
          lossPositions[sz].loss = profit;
          lossPositions[sz].volume = PositionGetDouble(POSITION_VOLUME);
        }
      }
    }
  }

  int count = ArraySize(lossPositions);
  if (count == 0) return;

  // 損失大順(マイナスが大きい順)にソート
  for (int i = 0; i < count - 1; i++) {
    for (int j = i + 1; j < count; j++) {
      if (lossPositions[j].loss < lossPositions[i].loss) {
        SLossPos tmp = lossPositions[i];
        lossPositions[i] = lossPositions[j];
        lossPositions[j] = tmp;
      }
    }
  }

  // 順次 50% 決済
  for (int i = 0; i < count; i++) {
    if (PositionSelectByTicket(lossPositions[i].ticket)) {
      string sym = PositionGetString(POSITION_SYMBOL);
      double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      double minVol = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double closeVol = MathFloor((lossPositions[i].volume * 0.5) / step) * step;

      if (closeVol >= minVol && (lossPositions[i].volume - closeVol) >= minVol) {
        trade.PositionClosePartial(lossPositions[i].ticket, closeVol);
        PrintFormat("[Emergency] チケット #%I64u を50%%強制決済 (Vol: %.2f -> %.2f, 損失: %.2f)",
                    lossPositions[i].ticket, lossPositions[i].volume, closeVol, lossPositions[i].loss);
      } else {
        trade.PositionClose(lossPositions[i].ticket);
        PrintFormat("[Emergency] チケット #%I64u を全強制決済 (Vol: %.2f, 損失: %.2f)",
                    lossPositions[i].ticket, lossPositions[i].volume, lossPositions[i].loss);
      }

      if (GetAccountMarginLevel() >= 150.0) {
        Print("[Emergency] 証拠金維持率が150%以上に回復したため、緊急リスクオフを終了します。");
        break;
      }
    }
  }
}

//+------------------------------------------------------------------+
//| 週末持ち越しリスク判定時刻チェック (仕様書第9.1章)               |
//| 金曜日のNYクローズ1時間前 (サーバー時間 22:00〜23:00 等)        |
//+------------------------------------------------------------------+
bool IsFridayWeekendRiskTime(const datetime serverTime) {
  MqlDateTime dt;
  TimeToStruct(serverTime, dt);
  // 金曜日 (day_of_week == 5) かつ 22時以降
  return (dt.day_of_week == 5 && dt.hour >= 22);
}

//+------------------------------------------------------------------+
//| 週末持ち越しリスク管理 (仕様書第9.1章)                           |
//| 含み損かつSLまで 0.5 * ATR(14) 未満なら全決済                    |
//+------------------------------------------------------------------+
void CheckWeekendCarryRisk(CTrade &trade, const string symbol, const ulong magicFilter, const double currentATR) {
  if (currentATR <= 0.0) return;
  double minDistance = 0.5 * currentATR;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket > 0) {
      if (PositionGetString(POSITION_SYMBOL) == symbol &&
          (magicFilter == 0 || PositionGetInteger(POSITION_MAGIC) == magicFilter)) {
        double profit = PositionGetDouble(POSITION_PROFIT);
        if (profit < 0.0) {
          double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
          double sl = PositionGetDouble(POSITION_SL);
          if (sl > 0.0) {
            double dist = MathAbs(currentPrice - sl);
            if (dist < minDistance) {
              PrintFormat("[WeekendCarry] 週末リスク防護発動: 含み損(%.2f)かつSL接近(距離=%.5f < 0.5*ATR=%.5f)のため成行全決済します。Ticket=#%I64u",
                          profit, dist, minDistance, ticket);
              trade.PositionClose(ticket);
            }
          }
        }
      }
    }
  }
}

//+------------------------------------------------------------------+
//| 後方互換用: 旧関数群                                             |
//+------------------------------------------------------------------+
double CalculateLotSize(const string symbol, const double riskPercent,
                        const double fixedLot,
                        const double stopLossDistancePrice) {
  if (riskPercent <= 0.0) return NormalizeLot(symbol, fixedLot);
  double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  double riskAmount = accountEquity * (riskPercent / 100.0);
  if (stopLossDistancePrice <= 0.0) return NormalizeLot(symbol, fixedLot);

  double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
  double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
  double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  if (tickSize <= 0.0 || tickValue <= 0.0 || lotStep <= 0.0) return NormalizeLot(symbol, fixedLot);

  double ticksAtRisk = stopLossDistancePrice / tickSize;
  double moneyLossPerOneLot = ticksAtRisk * tickValue;
  if (moneyLossPerOneLot <= 0.0) return NormalizeLot(symbol, fixedLot);

  return NormalizeLot(symbol, riskAmount / moneyLossPerOneLot);
}

ENUM_REGIME_TYPE DetermineRegime(const double alpha, const double thresholdLow, const double thresholdHigh) {
  if (!MathIsValidNumber(alpha) || alpha == EMPTY_VALUE) return REGIME_TRANSITION;
  if (alpha > thresholdHigh) return REGIME_TREND;
  if (alpha < thresholdLow) return REGIME_RANGE;
  return REGIME_TRANSITION;
}

bool ShouldCloseRegimePosition(const ENUM_STRATEGY_SOURCE source, const double alpha, const double centerLine = 0.50) {
  if (!MathIsValidNumber(alpha) || alpha == EMPTY_VALUE) return false;
  if (source == STRATEGY_TREND) return (alpha < centerLine);
  if (source == STRATEGY_RANGE) return (alpha > centerLine);
  return false;
}

ENUM_REGIME_TYPE UpdateRegimeWithHysteresis(const ENUM_REGIME_TYPE prevRegime, const double alpha, const double thresholdLow, const double thresholdHigh) {
  return DetermineRegime(alpha, thresholdLow, thresholdHigh);
}

ENUM_REGIME_TYPE DetermineKalmanRegime(const double z, const double threshold = 2.0) {
  if (!MathIsValidNumber(z) || z == EMPTY_VALUE) return REGIME_RANGE;
  if (z >= threshold) return REGIME_UP_TREND;
  if (z <= -threshold) return REGIME_DOWN_TREND;
  return REGIME_RANGE;
}

bool ShouldCloseKalmanPosition(const ENUM_STRATEGY_SOURCE source, const ENUM_POSITION_TYPE posType, const double z, const double threshold = 2.0, const double centerLine = 0.0) {
  if (!MathIsValidNumber(z) || z == EMPTY_VALUE) return false;
  if (source == STRATEGY_RANGE) return (MathAbs(z) >= threshold);
  if (source == STRATEGY_TREND) {
    if (posType == POSITION_TYPE_BUY) return (z < centerLine);
    if (posType == POSITION_TYPE_SELL) return (z > centerLine);
  }
  return false;
}
