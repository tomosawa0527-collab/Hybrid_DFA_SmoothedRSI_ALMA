//+------------------------------------------------------------------+
//|                                              Hybrid_DFA_EA.mq5 |
//|                                  Copyright 2026, Hybrid DFA System |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA System"
#property link "https://www.mql5.com"
#property version "1.00"

#include "..\Include\Hybrid_DFA_EA\DFA_Common.mqh"
#include <Trade\PositionInfo.mqh>
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
//--- 資金管理
input group "=== 資金管理パラメータ ===" input double InpRiskPercent = 1.0; // 1トレードあたりの許容リスク (%) (0で固定ロット)
input double InpFixedLot = 0.1;                                             // 固定ロット数
input ulong InpMagicNumber = 20260823;                                      // マジックナンバー
input ulong InpSlippage = 10;                                               // 許容スリッページ (points)

//--- DFA レジーム判定設定
input group "=== DFA (レジーム判定) 設定 ==="
input bool InpUseDfa = true;                                                // DFA レジーム判定を有効化
input ENUM_HTF_MODE InpDfaTimeframeMode = HTF_MODE_AUTO_NEXT;               // DFA 計算時間軸 (デフォルト: 1段階上位足)
input int InpDfaWindowSize = 300;                                           // DFAの計算対象バー数
input int InpDfaSmoothPeriod = 5;                                           // DFA平滑化期間 (1で平滑化なし)
input double InpDfaThresholdLow = 0.45;                                     // レンジ判定閾値 (これ未満でレンジ)
input double InpDfaThresholdHigh = 0.55;                                    // トレンド判定閾値 (これ超過でトレンド)

//--- レンジ戦略 (Super Smoother + RSI) 設定
input group "=== レンジ戦略 (Super Smoother + RSI) ==="
input bool InpUseRangeStrategy = true;                                      // レンジ戦略 (Super Smoother + RSI) を有効化
input int InpSSPeriod = 14;                                                 // Super Smoother 遮断周期
input int InpRsiPeriod = 7;                                                 // RSI 計算期間
input double InpRsiOverbought = 65.0;                                       // RSI 買われすぎ境界値
input double InpRsiOversold = 35.0;                                         // RSI 売られすぎ境界値

//--- トレンド戦略 (Dual ALMA Cross) 設定
input group "=== トレンド戦略 (Dual ALMA) ==="
input bool InpUseTrendStrategy = true;                                      // トレンド戦略 (Dual ALMA Cross) を有効化
input int InpAlmaFastWindow = 9;                                            // 短期 ALMA 窓幅
input int InpAlmaSlowWindow = 21;                                           // 長期 ALMA 窓幅
input double InpAlmaOffset = 0.85;                                          // ALMA Offset (共通)
input double InpAlmaSigma = 6.0;                                            // ALMA Sigma (共通)

//--- 出口戦略 (ATR Risk Management)
input group "=== 出口戦略 (ATR) ==="
input bool InpUseAtrExit = true;                                            // ATR 出口戦略 (SL/TP) を有効化
input ENUM_HTF_MODE InpAtrTimeframeMode = HTF_MODE_AUTO_NEXT;               // ATR 計算時間軸 (デフォルト: 1段階上位足)
input int InpAtrPeriod = 14;                                                // ATR 期間
input double InpAtrSlFactor = 1.5;                                          // ストップロス (ATR倍率)
input double InpAtrTpFactor = 3.0;                                          // テイクプロフィット (ATR倍率)

//+------------------------------------------------------------------+
//| グローバル変数・オブジェクト                                     |
//+------------------------------------------------------------------+
CTrade m_trade;
CPositionInfo m_position;

int h_dfa = INVALID_HANDLE;
int h_smoothedRsi = INVALID_HANDLE;
int h_dualAlma = INVALID_HANDLE;
int h_atr = INVALID_HANDLE;

ENUM_TIMEFRAMES m_dfaTf = PERIOD_CURRENT;
ENUM_TIMEFRAMES m_atrTf = PERIOD_CURRENT;

datetime m_lastBarTime = 0;

// Phase 3: レジーム状態遷移機械の状態保持
ENUM_REGIME_TYPE g_currentRegime = REGIME_NONE;

// マジックナンバー個別オフセット（戦略ソース追跡用）
#define MAGIC_RANGE_OFFSET 1
#define MAGIC_TREND_OFFSET 2

//+------------------------------------------------------------------+
//| 初期化関数                                                       |
//+------------------------------------------------------------------+
int OnInit() {
    m_trade.SetExpertMagicNumber(InpMagicNumber);
    m_trade.SetDeviationInPoints(InpSlippage);
    // Phase 2: ブローカー許容充填モードの自動判定に置換
    m_trade.SetTypeFilling(DetectFillType(_Symbol));

    // 計算時間軸の解決 (DFA / ATR)
    m_dfaTf = ResolveTimeframe(InpDfaTimeframeMode, _Period);
    m_atrTf = ResolveTimeframe(InpAtrTimeframeMode, _Period);

    PrintFormat("[Hybrid_DFA_EA] チャート時間軸: %s | DFA計算時間軸: %s | ATR計算時間軸: %s",
                EnumToString(_Period), EnumToString(m_dfaTf), EnumToString(m_atrTf));

    // 1. DFA インディケータハンドル取得 (チャート足上で上位足算出: サブウィンドウ1)
    if (InpUseDfa) {
        h_dfa = iCustom(_Symbol, _Period, "Hybrid_DFA_EA\\DFA", m_dfaTf, InpDfaWindowSize, 10, 0,
                        0, InpDfaSmoothPeriod, InpDfaThresholdLow, InpDfaThresholdHigh, 0.25);
        if (h_dfa == INVALID_HANDLE) {
            // パスプレフィックス付きでフォールバック
            h_dfa = iCustom(_Symbol, _Period, "Indicators\\Hybrid_DFA_EA\\DFA", m_dfaTf, InpDfaWindowSize, 10, 0,
                            0, InpDfaSmoothPeriod, InpDfaThresholdLow, InpDfaThresholdHigh, 0.25);
        }
        if (h_dfa == INVALID_HANDLE) {
            Print("[Hybrid_DFA_EA] DFA インディケータのハンドル取得に失敗しました。");
            return INIT_FAILED;
        }
    }

    // 2. Smoothed RSI インディケータハンドル取得 (チャート足: サブウィンドウ2)
    if (InpUseRangeStrategy) {
        h_smoothedRsi =
            iCustom(_Symbol, _Period, "Hybrid_DFA_EA\\SmoothedRSI", InpSSPeriod, InpRsiPeriod,
                    InpRsiOverbought, InpRsiOversold, PRICE_CLOSE);
        if (h_smoothedRsi == INVALID_HANDLE) {
            h_smoothedRsi =
                iCustom(_Symbol, _Period, "Indicators\\Hybrid_DFA_EA\\SmoothedRSI", InpSSPeriod,
                        InpRsiPeriod, InpRsiOverbought, InpRsiOversold, PRICE_CLOSE);
        }
        if (h_smoothedRsi == INVALID_HANDLE) {
            Print("[Hybrid_DFA_EA] SmoothedRSI "
                  "インディケータのハンドル取得に失敗しました。");
            return INIT_FAILED;
        }
    }

    // 3. Dual ALMA インディケータハンドル取得 (チャート足: メインウィンドウ)
    if (InpUseTrendStrategy) {
        h_dualAlma =
            iCustom(_Symbol, _Period, "Hybrid_DFA_EA\\DualALMA", InpAlmaFastWindow,
                    InpAlmaSlowWindow, InpAlmaOffset, InpAlmaSigma, PRICE_CLOSE);
        if (h_dualAlma == INVALID_HANDLE) {
            h_dualAlma =
                iCustom(_Symbol, _Period, "Indicators\\Hybrid_DFA_EA\\DualALMA", InpAlmaFastWindow,
                        InpAlmaSlowWindow, InpAlmaOffset, InpAlmaSigma, PRICE_CLOSE);
        }
        if (h_dualAlma == INVALID_HANDLE) {
            Print("[Hybrid_DFA_EA] DualALMA "
                  "インディケータのハンドル取得に失敗しました。");
            return INIT_FAILED;
        }
    }

    // 4. ATR インディケータハンドル取得 (上位足)
    if (InpUseAtrExit) {
        h_atr = iATR(_Symbol, m_atrTf, InpAtrPeriod);
        if (h_atr == INVALID_HANDLE) {
            Print("[Hybrid_DFA_EA] ATR インディケータのハンドル取得に失敗しました。");
            return INIT_FAILED;
        }
    }

    Print("[Hybrid_DFA_EA] 初期化が正常に完了しました。");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理関数                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    // バックテスト時はインジケータハンドルを解放しない（テスト完了後のチャート上にインジケータ表示を残すため）
    if (!MQLInfoInteger(MQL_TESTER)) {
        if (h_dfa != INVALID_HANDLE)
            IndicatorRelease(h_dfa);
        if (h_smoothedRsi != INVALID_HANDLE)
            IndicatorRelease(h_smoothedRsi);
        if (h_dualAlma != INVALID_HANDLE)
            IndicatorRelease(h_dualAlma);
        if (h_atr != INVALID_HANDLE)
            IndicatorRelease(h_atr);
    }

    Print("[Hybrid_DFA_EA] 終了処理完了。理由コード: ", reason);
}

//+------------------------------------------------------------------+
//| 新バー確定判定ヘルパー                                           |
//+------------------------------------------------------------------+
bool IsNewBar() {
    datetime currentBarTime = iTime(_Symbol, _Period, 0);
    if (currentBarTime != m_lastBarTime) {
        m_lastBarTime = currentBarTime;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| 最新のシステム状態を取得                                         |
//+------------------------------------------------------------------+
bool UpdateSystemState(SSystemState& state) {
    ZeroMemory(state);
    state.regime = REGIME_ALL;

    // チャート足の Bar 1 時刻 (SmoothedRSI / DualALMA はチャート足基準で参照)
    // ※ DFA / ATR は Phase 4 で各々上位足の iTime で個別取得に変更済み
    datetime bar1_time = iTime(_Symbol, _Period, 1);

    // 1. DFA 指数の取得
    if (InpUseDfa && h_dfa != INVALID_HANDLE) {
        double dfaBuf[];
        ArraySetAsSeries(dfaBuf, true);

        // Phase 4: h_dfa はチャート足上で上位足から同期展開されているため、チャート足の直近確定足(Bar 1)を参照
        int copied = CopyBuffer(h_dfa, 0, 1, 1, dfaBuf);
        if (copied <= 0) {
            copied = CopyBuffer(h_dfa, 0, bar1_time, 1, dfaBuf);
        }
        if (copied > 0) {
            state.alpha = dfaBuf[0];
            // Phase 3: ヒステリシス付き状態遷移機械でレジーム判定
            ENUM_REGIME_TYPE newRegime = UpdateRegimeWithHysteresis(
                g_currentRegime, state.alpha, InpDfaThresholdLow, InpDfaThresholdHigh);
            if (newRegime != g_currentRegime) {
                string prevStr = (g_currentRegime == REGIME_RANGE ? "RANGE" :
                                  (g_currentRegime == REGIME_TREND ? "TREND" :
                                   (g_currentRegime == REGIME_TRANSITION ? "TRANSITION" : "NONE")));
                string newStr = (newRegime == REGIME_RANGE ? "RANGE" :
                                 (newRegime == REGIME_TREND ? "TREND" : "TRANSITION"));
                PrintFormat("[Hybrid_DFA_EA] レジーム遷移: %s -> %s (Alpha=%.4f)",
                            prevStr, newStr, state.alpha);
                g_currentRegime = newRegime;
            }
            state.regime = g_currentRegime;
        } else {
            Print("[Hybrid_DFA_EA] DFA バッファ取得エラー");
            return false;
        }
    }

    // 2. Smoothed RSI の取得 (バー1, バー2)
    if (InpUseRangeStrategy && h_smoothedRsi != INVALID_HANDLE) {
        double rsiBuf[];
        ArraySetAsSeries(rsiBuf, true);
        if (CopyBuffer(h_smoothedRsi, 0, 1, 2, rsiBuf) == 2) {
            state.smoothed_rsi_1 = rsiBuf[0];
            state.smoothed_rsi_2 = rsiBuf[1];
        } else {
            Print("[Hybrid_DFA_EA] Smoothed RSI バッファ取得エラー");
            return false;
        }
    }

    // 3. Dual ALMA の取得 (バー1, バー2)
    if (InpUseTrendStrategy && h_dualAlma != INVALID_HANDLE) {
        double fastBuf[], slowBuf[];
        ArraySetAsSeries(fastBuf, true);
        ArraySetAsSeries(slowBuf, true);
        if (CopyBuffer(h_dualAlma, 0, 1, 2, fastBuf) == 2 &&
            CopyBuffer(h_dualAlma, 1, 1, 2, slowBuf) == 2) {
            state.alma_fast_1 = fastBuf[0];
            state.alma_fast_2 = fastBuf[1];
            state.alma_slow_1 = slowBuf[0];
            state.alma_slow_2 = slowBuf[1];
        } else {
            Print("[Hybrid_DFA_EA] Dual ALMA バッファ取得エラー");
            return false;
        }
    }

    // 4. ATR の取得
    if (InpUseAtrExit && h_atr != INVALID_HANDLE) {
        double atrBuf[];
        ArraySetAsSeries(atrBuf, true);

        // Phase 4: 上位足の確定足タイムスタンプを厳密に指定
        datetime atr_bar1_time = iTime(_Symbol, m_atrTf, 1);
        int copied = CopyBuffer(h_atr, 0, atr_bar1_time, 1, atrBuf);
        if (copied <= 0) {
            copied = CopyBuffer(h_atr, 0, 1, 1, atrBuf);
        }
        if (copied > 0) {
            state.atr = atrBuf[0];
        } else {
            Print("[Hybrid_DFA_EA] ATR バッファ取得エラー");
            return false;
        }
    }

    static bool isFirstUpdate = true;
    if (isFirstUpdate) {
        isFirstUpdate = false;
        string regStr = (state.regime == REGIME_RANGE ? "RANGE" : (state.regime == REGIME_TREND ? "TREND" : "TRANSITION"));
        PrintFormat("[Hybrid_DFA_EA] 初回状態取得成功: DFA Alpha=%.4f (Regime=%s), RSI[1]=%.2f, ALMA Fast[1]=%.5f Slow[1]=%.5f",
                    state.alpha, regStr, state.smoothed_rsi_1, state.alma_fast_1, state.alma_slow_1);
    }

    return true;
}

//+------------------------------------------------------------------+
//| ポジションクローズヘルパー (特定戦略または全クローズ)            |
//+------------------------------------------------------------------+
void ClosePositionsByStrategy(const ENUM_STRATEGY_SOURCE targetSource) {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (m_position.SelectByIndex(i)) {
            if (m_position.Symbol() == _Symbol) {
                ulong posMagic = m_position.Magic();
                bool shouldClose = false;

                if (targetSource == STRATEGY_RANGE &&
                    posMagic == InpMagicNumber + MAGIC_RANGE_OFFSET) {
                    shouldClose = true;
                } else if (targetSource == STRATEGY_TREND &&
                           posMagic == InpMagicNumber + MAGIC_TREND_OFFSET) {
                    shouldClose = true;
                } else if (targetSource == STRATEGY_NONE &&
                           (posMagic == InpMagicNumber + MAGIC_RANGE_OFFSET ||
                            posMagic == InpMagicNumber + MAGIC_TREND_OFFSET)) {
                    shouldClose = true;
                }

                if (shouldClose) {
                    m_trade.PositionClose(m_position.Ticket());
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 保有中ポジションの有無とタイプをカウント                         |
//+------------------------------------------------------------------+
void CountOpenPositions(int& rangeBuys, int& rangeSells, int& trendBuys,
                        int& trendSells) {
    rangeBuys = 0;
    rangeSells = 0;
    trendBuys = 0;
    trendSells = 0;

    for (int i = 0; i < PositionsTotal(); i++) {
        if (m_position.SelectByIndex(i)) {
            if (m_position.Symbol() == _Symbol) {
                ulong magic = m_position.Magic();
                if (magic == InpMagicNumber + MAGIC_RANGE_OFFSET) {
                    if (m_position.PositionType() == POSITION_TYPE_BUY)
                        rangeBuys++;
                    if (m_position.PositionType() == POSITION_TYPE_SELL)
                        rangeSells++;
                } else if (magic == InpMagicNumber + MAGIC_TREND_OFFSET) {
                    if (m_position.PositionType() == POSITION_TYPE_BUY)
                        trendBuys++;
                    if (m_position.PositionType() == POSITION_TYPE_SELL)
                        trendSells++;
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| ティック処理メイン関数                                           |
//+------------------------------------------------------------------+
void OnTick() {
    // バー確定時のみシグナル評価とレジーム監視を実行
    if (!IsNewBar()) {
        return;
    }

    SSystemState state;
    if (!UpdateSystemState(state)) {
        return;
    }

    int rangeBuys = 0, rangeSells = 0, trendBuys = 0, trendSells = 0;
    CountOpenPositions(rangeBuys, rangeSells, trendBuys, trendSells);

    //------------------------------------------------------------------
    // 1. レジーム逆行時の強制決済 (0.50 基準線跨ぎ判定) (仕様 4.2)
    //------------------------------------------------------------------
    if (InpUseDfa) {
        // レンジポジション保有中、DFA Alpha が 0.50 を上回ったら強制決済
        if ((rangeBuys > 0 || rangeSells > 0) && ShouldCloseRegimePosition(STRATEGY_RANGE, state.alpha, 0.50)) {
            PrintFormat("[Hybrid_DFA_EA] レジーム逆行検知: DFA Alpha (%.4f) が 0.50 を上回ったためレンジポジションを決済します。",
                        state.alpha);
            ClosePositionsByStrategy(STRATEGY_RANGE);
            rangeBuys = 0;
            rangeSells = 0;
        }

        // トレンドポジション保有中、DFA Alpha が 0.50 を下回ったら強制決済
        if ((trendBuys > 0 || trendSells > 0) && ShouldCloseRegimePosition(STRATEGY_TREND, state.alpha, 0.50)) {
            PrintFormat("[Hybrid_DFA_EA] レジーム逆行検知: DFA Alpha (%.4f) が 0.50 を下回ったためトレンドポジションを決済します。",
                        state.alpha);
            ClosePositionsByStrategy(STRATEGY_TREND);
            trendBuys = 0;
            trendSells = 0;
        }
    }

    //------------------------------------------------------------------
    // 2. レンジポジション保有中のRSIによる利確・損切り決済 (単独エグジット)
    //------------------------------------------------------------------
    if (InpUseRangeStrategy) {
        // レンジBUYポジション保有時
        if (rangeBuys > 0) {
            // 利確: 50クロス/到達 (RSI >= 50.0)
            if (state.smoothed_rsi_1 >= 50.0) {
                PrintFormat("[Hybrid_DFA_EA] レンジBUY利確決済 (RSIが50.0以上に到達): RSI=%.2f", state.smoothed_rsi_1);
                ClosePositionsByStrategy(STRATEGY_RANGE);
                rangeBuys = 0;
            }
            // 損切り: 売られすぎ水準(InpRsiOversold)未満に逆行 (RSI < InpRsiOversold)
            else if (state.smoothed_rsi_1 < InpRsiOversold) {
                PrintFormat("[Hybrid_DFA_EA] レンジBUY損切り決済 (RSIが売られすぎ%.2f未満に逆行): RSI=%.2f", InpRsiOversold, state.smoothed_rsi_1);
                ClosePositionsByStrategy(STRATEGY_RANGE);
                rangeBuys = 0;
            }
        }
        // レンジSELLポジション保有時
        if (rangeSells > 0) {
            // 利確: 50クロス/到達 (RSI <= 50.0)
            if (state.smoothed_rsi_1 <= 50.0) {
                PrintFormat("[Hybrid_DFA_EA] レンジSELL利確決済 (RSIが50.0以下に到達): RSI=%.2f", state.smoothed_rsi_1);
                ClosePositionsByStrategy(STRATEGY_RANGE);
                rangeSells = 0;
            }
            // 損切り: 買われすぎ水準(InpRsiOverbought)より大きい値に逆行 (RSI > InpRsiOverbought)
            else if (state.smoothed_rsi_1 > InpRsiOverbought) {
                PrintFormat("[Hybrid_DFA_EA] レンジSELL損切り決済 (RSIが買われすぎ%.2f超に逆行): RSI=%.2f", InpRsiOverbought, state.smoothed_rsi_1);
                ClosePositionsByStrategy(STRATEGY_RANGE);
                rangeSells = 0;
            }
        }
    }

    //------------------------------------------------------------------
    // 3. トレンドポジション保有中のALMA逆交差による決済
    //------------------------------------------------------------------
    if (InpUseTrendStrategy) {
        // トレンドBUY保有中にデッドクロス発生
        if (trendBuys > 0 && state.alma_fast_2 >= state.alma_slow_2 &&
            state.alma_fast_1 < state.alma_slow_1) {
            Print("[Hybrid_DFA_EA] "
                  "トレンドBUY保有中にデッドクロスが発生したためクローズします。");
            ClosePositionsByStrategy(STRATEGY_TREND);
            trendBuys = 0;
        }
        // トレンドSELL保有中にゴールデンクロス発生
        if (trendSells > 0 && state.alma_fast_2 <= state.alma_slow_2 &&
            state.alma_fast_1 > state.alma_slow_1) {
            Print(
                "[Hybrid_DFA_EA] "
                "トレンドSELL保有中にゴールデンクロスが発生したためクローズします。");
            ClosePositionsByStrategy(STRATEGY_TREND);
            trendSells = 0;
        }
    }

    //------------------------------------------------------------------
    // 2. エントリーシグナル判定
    //------------------------------------------------------------------
    bool allowRange =
        InpUseRangeStrategy && (!InpUseDfa || state.regime == REGIME_RANGE);
    bool allowTrend =
        InpUseTrendStrategy && (!InpUseDfa || state.regime == REGIME_TREND);

    // A. レンジ戦略シグナル (Super Smoother + RSI) - ゾーン復帰・脱出クロス方式
    if (allowRange) {
        // BUY: RSI[2] <= Oversold && RSI[1] > Oversold (売られすぎゾーンから反転上昇脱出)
        if (state.smoothed_rsi_2 <= InpRsiOversold &&
            state.smoothed_rsi_1 > InpRsiOversold) {
            if (rangeSells > 0) {
                ClosePositionsByStrategy(STRATEGY_RANGE);
                rangeSells = 0;
            }
            if (rangeBuys == 0) {
                PrintFormat("[Hybrid_DFA_EA] レンジBUYシグナル検知: Alpha=%.4f (Low=%.2f), RSI[2]=%.2f, RSI[1]=%.2f",
                            state.alpha, InpDfaThresholdLow, state.smoothed_rsi_2, state.smoothed_rsi_1);
                ExecuteOrder(ORDER_TYPE_BUY, STRATEGY_RANGE, state.atr);
            }
        }
        // SELL: RSI[2] >= Overbought && RSI[1] < Overbought (買われすぎゾーンから反転下落脱出)
        else if (state.smoothed_rsi_2 >= InpRsiOverbought &&
                 state.smoothed_rsi_1 < InpRsiOverbought) {
            if (rangeBuys > 0) {
                ClosePositionsByStrategy(STRATEGY_RANGE);
                rangeBuys = 0;
            }
            if (rangeSells == 0) {
                PrintFormat("[Hybrid_DFA_EA] レンジSELLシグナル検知: Alpha=%.4f (Low=%.2f), RSI[2]=%.2f, RSI[1]=%.2f",
                            state.alpha, InpDfaThresholdLow, state.smoothed_rsi_2, state.smoothed_rsi_1);
                ExecuteOrder(ORDER_TYPE_SELL, STRATEGY_RANGE, state.atr);
            }
        }
    }

    // B. トレンド戦略シグナル (Dual ALMA Cross)
    if (allowTrend) {
        // BUY (ゴールデンクロス): Fast[2] <= Slow[2] && Fast[1] > Slow[1]
        if (state.alma_fast_2 <= state.alma_slow_2 &&
            state.alma_fast_1 > state.alma_slow_1) {
            if (trendSells > 0) {
                ClosePositionsByStrategy(STRATEGY_TREND);
                trendSells = 0;
            }
            if (trendBuys == 0) {
                PrintFormat("[Hybrid_DFA_EA] トレンドBUYシグナル検知: Alpha=%.4f (High=%.2f), Fast[1]=%.3f, Slow[1]=%.3f",
                            state.alpha, InpDfaThresholdHigh, state.alma_fast_1, state.alma_slow_1);
                ExecuteOrder(ORDER_TYPE_BUY, STRATEGY_TREND, state.atr);
            }
        }
        // SELL (デッドクロス): Fast[2] >= Slow[2] && Fast[1] < Slow[1]
        else if (state.alma_fast_2 >= state.alma_slow_2 &&
                 state.alma_fast_1 < state.alma_slow_1) {
            if (trendBuys > 0) {
                ClosePositionsByStrategy(STRATEGY_TREND);
                trendBuys = 0;
            }
            if (trendSells == 0) {
                PrintFormat("[Hybrid_DFA_EA] トレンドSELLシグナル検知: Alpha=%.4f (High=%.2f), Fast[1]=%.3f, Slow[1]=%.3f",
                            state.alpha, InpDfaThresholdHigh, state.alma_fast_1, state.alma_slow_1);
                ExecuteOrder(ORDER_TYPE_SELL, STRATEGY_TREND, state.atr);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 発注実行関数                                                     |
//+------------------------------------------------------------------+
bool ExecuteOrder(const ENUM_ORDER_TYPE orderType,
                  const ENUM_STRATEGY_SOURCE source, const double atr) {
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double slDistance = 0.0;
    double slPrice = 0.0;
    double tpPrice = 0.0;

    if (InpUseAtrExit && atr > 0.0) {
        slDistance = atr * InpAtrSlFactor;
        double tpDistance = atr * InpAtrTpFactor;

        // Phase 2: ストップレベル/スプレッドを考慮したSL/TP距離の補正
        slDistance = AdjustStopDistance(_Symbol, slDistance);
        tpDistance = AdjustStopDistance(_Symbol, tpDistance);

        if (orderType == ORDER_TYPE_BUY) {
            slPrice = NormalizeDouble(ask - slDistance, _Digits);
            tpPrice = NormalizeDouble(ask + tpDistance, _Digits);
        } else if (orderType == ORDER_TYPE_SELL) {
            slPrice = NormalizeDouble(bid + slDistance, _Digits);
            tpPrice = NormalizeDouble(bid - tpDistance, _Digits);
        }
    }

    double lotSize =
        CalculateLotSize(_Symbol, InpRiskPercent, InpFixedLot, slDistance);

    ulong magicNumber = InpMagicNumber;
    string comment = "DFA_Hybrid";

    if (source == STRATEGY_RANGE) {
        magicNumber += MAGIC_RANGE_OFFSET;
        comment = "DFA_Range";
    } else if (source == STRATEGY_TREND) {
        magicNumber += MAGIC_TREND_OFFSET;
        comment = "DFA_Trend";
    }

    m_trade.SetExpertMagicNumber(magicNumber);

    bool success = false;
    if (orderType == ORDER_TYPE_BUY) {
        success = m_trade.Buy(lotSize, _Symbol, ask, slPrice, tpPrice, comment);
    } else if (orderType == ORDER_TYPE_SELL) {
        success = m_trade.Sell(lotSize, _Symbol, bid, slPrice, tpPrice, comment);
    }

    if (success) {
        PrintFormat("[Hybrid_DFA_EA] 発注成功: %s %s Lot: %.2f Price: %.5f SL: "
                    "%.5f TP: %.5f (%s)",
                    (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), _Symbol,
                    lotSize, (orderType == ORDER_TYPE_BUY ? ask : bid), slPrice,
                    tpPrice, comment);
    } else {
        PrintFormat("[Hybrid_DFA_EA] 発注失敗: %s %s エラーコード: %d",
                    (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), _Symbol,
                    GetLastError());
    }

    return success;
}
//+------------------------------------------------------------------+
