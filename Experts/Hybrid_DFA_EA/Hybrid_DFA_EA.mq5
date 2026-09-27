//+------------------------------------------------------------------+
//|                                              Hybrid_DFA_EA.mq5 |
//|                                  Copyright 2026, Hybrid DFA System |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Hybrid DFA System"
#property link "https://www.mql5.com"
#property version "2.00"

//--- ストラテジーテスター用インジケーター依存関係の明示
#property tester_indicator "Hybrid_DFA_EA\\KalmanRegimeEstimator.ex5"
#property tester_indicator "Hybrid_DFA_EA/KalmanRegimeEstimator.ex5"
#property tester_indicator "KalmanRegimeEstimator.ex5"
#property tester_indicator "Indicators\\Hybrid_DFA_EA\\KalmanRegimeEstimator.ex5"

#include "..\..\Include\Hybrid_DFA_EA\DFA_Common.mqh"
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

//--- カルマンフィルター レジーム判定設定
input group "=== カルマンフィルター (レジーム判定) 設定 ==="
input bool InpUseKalman = true;                                                // カルマンレジーム判定を有効化
input ENUM_HTF_MODE InpKalmanTimeframeMode = HTF_MODE_AUTO_NEXT;               // カルマン計算時間軸 (デフォルト: 1段階上位足)
input bool InpKalmanAutoTimeframeScale = true;                                 // 時間足に応じたノイズ自動スケーリング
input bool InpKalmanAutoCalibration = true;                                    // Rice推定量による解析的自動キャリブレーション
input double InpKalmanTargetLagBars = 10.0;                                    // ターゲット時定数 (目安バー数: 8〜15推奨)
input int InpKalmanCalibSamples = 1000;                                        // 観測ノイズ計測バー数
input double InpKalmanZThreshold = 2.0;                                        // トレンド判定閾値 (>=2.0で上昇, <=-2.0で下降, 間はレンジ)
input double InpKalmanZExit = 1.0;                                             // トレンド離脱閾値 (インジケータ内部ヒステリシス用)
input ENUM_APPLIED_PRICE InpKalmanAppliedPrice = PRICE_CLOSE;                  // 適用価格

//--- レンジ戦略 (Super Smoother + RSI) 設定
input group "=== レンジ戦略 (Super Smoother + RSI) ==="
input bool InpUseRangeStrategy = true;                                      // レンジ戦略 (Super Smoother + RSI) を有効化
input int InpSSPeriod = 14;                                                 // Super Smoother 遮断周期
input int InpRsiPeriod = 7;                                                 // RSI 計算期間
input double InpRsiOverbought = 65.0;                                       // RSI 買われすぎ境界値
input double InpRsiOversold = 35.0;                                         // RSI 売られすぎ境界値

//--- トレンド戦略 (Dual MA Cross) 設定
input group "=== トレンド戦略 (Dual MA Cross) ==="
input bool InpUseTrendStrategy = true;                                      // トレンド戦略 (Dual MA Cross) を有効化
input ENUM_TREND_MA_TYPE InpTrendMaType = TREND_MA_LWMA;                    // 移動平均タイプ (SMA/EMA/SMMA/LWMA/ALMA)
input int InpMaFastWindow = 20;                                             // 短期 MA 期間 / 窓幅 (Fast Window)
input int InpMaSlowWindow = 40;                                             // 長期 MA 期間 / 窓幅 (Slow Window)
input ENUM_APPLIED_PRICE InpMaAppliedPrice = PRICE_CLOSE;                   // 適用価格

//--- ALMA専用パラメータ (InpTrendMaType == TREND_MA_ALMA 時に有効)
input group "--- ALMA 詳細設定 (InpTrendMaType=ALMA時) ---"
input double InpAlmaFastOffset = 0.92;                                      // [ALMA] 短期 Offset (高値ほど低遅延)
input double InpAlmaSlowOffset = 0.90;                                      // [ALMA] 長期 Offset (高値ほど低遅延)
input double InpAlmaFastSigma = 5.5;                                        // [ALMA] 短期 Sigma
input double InpAlmaSlowSigma = 5.5;                                        // [ALMA] 長期 Sigma
input bool InpAlmaUseSuperSmoother = false;                                 // [ALMA] SuperSmoother 前処理 (OFF推奨)
input int InpAlmaSSCutoff = 4;                                              // [ALMA] SS カットオフ周期 (bars)
input bool InpAlmaUseZeroLagLead = false;                                   // [ALMA] 先行モメンタム補正有効化
input double InpAlmaLeadFactor = 0.40;                                      // [ALMA] 先行モメンタム係数
input bool InpAlmaUseSchmittTrigger = false;                                // [ALMA] シュミットトリガー (ヒステリシス) 有効化
input int InpAlmaHysteresisAtrPeriod = 14;                                  // [ALMA] ヒステリシス用 ATR 期間
input double InpAlmaHysteresisFactor = 0.08;                                // [ALMA] ヒステリシス幅係数 (ATR比率)

//--- 出口戦略 (ATR Risk Management)
input group "=== 出口戦略 (ATR) ==="
input bool InpUseAtrExit = true;                                            // ATR 出口戦略 (SL/TP) を有効化
input ENUM_HTF_MODE InpAtrTimeframeMode = HTF_MODE_AUTO_NEXT;               // ATR 計算時間軸 (デフォルト: 1段階上位足)
input int InpAtrPeriod = 20;                                                // ATR 期間
input double InpAtrSlFactor = 1.5;                                          // ストップロス (ATR倍率)
input double InpAtrTpFactor = 3.0;                                          // テイクプロフィット (ATR倍率, 0でTPなし&SLトレーリングストップ)

//+------------------------------------------------------------------+
//| グローバル変数・オブジェクト                                     |
//+------------------------------------------------------------------+
CTrade m_trade;
CPositionInfo m_position;

int h_kalman = INVALID_HANDLE;
int h_smoothedRsi = INVALID_HANDLE;
int h_multiDualMa = INVALID_HANDLE;
int h_atr = INVALID_HANDLE;

ENUM_TIMEFRAMES m_kalmanTf = PERIOD_CURRENT;
ENUM_TIMEFRAMES m_atrTf = PERIOD_CURRENT;

datetime m_lastBarTime = 0;
datetime m_lastM1BarTime = 0;
double g_lastAtr = 0.0;

// Phase 3: レジーム状態遷移機械の状態保持
ENUM_REGIME_TYPE g_currentRegime = REGIME_NONE;

// マジックナンバー個別オフセット（戦略ソース追跡用）
#define MAGIC_RANGE_OFFSET 1
#define MAGIC_TREND_OFFSET 2

//+------------------------------------------------------------------+
//| カルマンインジケーターハンドル生成ヘルパー関数                   |
//+------------------------------------------------------------------+
int CreateKalmanIndicatorHandle(const string indicator_path, const ENUM_TIMEFRAMES tf) {
    return iCustom(_Symbol, _Period, indicator_path,
                   // --- Group 1: マルチタイムフレーム (MTF) 設定 ---
                   "=== マルチタイムフレーム (MTF) 設定 ===",
                   tf,
                   InpKalmanAutoTimeframeScale,

                   // --- Group 2: 解析的自律キャリブレーション ---
                   "=== 解析的自律キャリブレーション (Closed-Form Analytical) ===",
                   InpKalmanAutoCalibration,
                   InpKalmanTargetLagBars,
                   InpKalmanCalibSamples,

                   // --- Group 3: カルマンフィルター パラメータ ---
                   "=== カルマンフィルター パラメータ (手動設定時またはフォールバック) ===",
                   0.0,    // InpManualQMu
                   1e-8,   // InpManualQBeta
                   1e-4,   // InpManualR
                   1.0,    // InpManualInitialP

                   // --- Group 4: レジーム判定 (ヒステリシス) パラメータ ---
                   "=== レジーム判定 (ヒステリシス) パラメータ ===",
                   InpKalmanZThreshold,
                   InpKalmanZExit,
                   true,   // InpAllowDirectReversal
                   InpKalmanAppliedPrice);
}

//+------------------------------------------------------------------+
//| 初期化関数                                                       |
//+------------------------------------------------------------------+
int OnInit() {
    m_trade.SetExpertMagicNumber(InpMagicNumber);
    m_trade.SetDeviationInPoints(InpSlippage);
    // Phase 2: ブローカー許容充填モードの自動判定に置換
    m_trade.SetTypeFilling(DetectFillType(_Symbol));

    // 計算時間軸の解決 (Kalman / ATR)
    m_kalmanTf = ResolveTimeframe(InpKalmanTimeframeMode, _Period);
    m_atrTf = ResolveTimeframe(InpAtrTimeframeMode, _Period);

    PrintFormat("[Hybrid_DFA_EA] チャート時間軸: %s | カルマン計算時間軸: %s | ATR計算時間軸: %s",
                EnumToString(_Period), EnumToString(m_kalmanTf), EnumToString(m_atrTf));

    // 1. カルマンレジーム推定インジケータハンドル取得 (チャート足上で上位足算出)
    if (InpUseKalman) {
        string candidates[4];
        candidates[0] = "Hybrid_DFA_EA\\KalmanRegimeEstimator";
        candidates[1] = "Indicators\\Hybrid_DFA_EA\\KalmanRegimeEstimator";
        candidates[2] = "Hybrid_DFA_EA/KalmanRegimeEstimator";
        candidates[3] = "KalmanRegimeEstimator";

        for (int i = 0; i < 4; i++) {
            h_kalman = CreateKalmanIndicatorHandle(candidates[i], m_kalmanTf);
            if (h_kalman != INVALID_HANDLE) {
                PrintFormat("[Hybrid_DFA_EA] KalmanRegimeEstimator に接続成功: '%s'", candidates[i]);
                break;
            }
        }

        if (h_kalman == INVALID_HANDLE) {
            Print("[Hybrid_DFA_EA] KalmanRegimeEstimator インディケータのハンドル取得に失敗しました。");
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

    // 3. トレンド戦略 MA インディケータハンドル取得 (チャート足: メインウィンドウ)
    // ※ MultiDualMA インディケータが SMA/EMA/SMMA/LWMA/ALMA の全計算を内包し、
    //    Fast(clrOrangeRed: 赤/オレンジ) と Slow(clrDeepSkyBlue: 水色) の2色で全MAタイプ統一描画
    if (InpUseTrendStrategy) {
        string maTypeName = "LWMA";
        switch (InpTrendMaType) {
        case TREND_MA_SMA:  maTypeName = "SMA";  break;
        case TREND_MA_EMA:  maTypeName = "EMA";  break;
        case TREND_MA_SMMA: maTypeName = "SMMA"; break;
        case TREND_MA_LWMA: maTypeName = "LWMA"; break;
        case TREND_MA_ALMA: maTypeName = "ALMA"; break;
        }

        PrintFormat("[Hybrid_DFA_EA] トレンドMAハンドル生成開始: Type=%s, Fast=%d, Slow=%d, Price=%d, ST=%s(HFactor=%.4f)",
                    maTypeName, InpMaFastWindow, InpMaSlowWindow, (int)InpMaAppliedPrice,
                    InpAlmaUseSchmittTrigger ? "ON" : "OFF", InpAlmaHysteresisFactor);

        h_multiDualMa =
            iCustom(_Symbol, _Period, "Hybrid_DFA_EA\\MultiDualMA",
                    InpTrendMaType,
                    InpMaFastWindow, InpMaSlowWindow,
                    InpAlmaFastOffset, InpAlmaSlowOffset,
                    InpAlmaFastSigma, InpAlmaSlowSigma,
                    InpMaAppliedPrice,
                    InpAlmaUseSuperSmoother, InpAlmaSSCutoff,
                    InpAlmaUseZeroLagLead, InpAlmaLeadFactor,
                    InpAlmaUseSchmittTrigger, InpAlmaHysteresisAtrPeriod, InpAlmaHysteresisFactor);
        if (h_multiDualMa == INVALID_HANDLE) {
            h_multiDualMa =
                iCustom(_Symbol, _Period, "Indicators\\Hybrid_DFA_EA\\MultiDualMA",
                        InpTrendMaType,
                        InpMaFastWindow, InpMaSlowWindow,
                        InpAlmaFastOffset, InpAlmaSlowOffset,
                        InpAlmaFastSigma, InpAlmaSlowSigma,
                        InpMaAppliedPrice,
                        InpAlmaUseSuperSmoother, InpAlmaSSCutoff,
                        InpAlmaUseZeroLagLead, InpAlmaLeadFactor,
                        InpAlmaUseSchmittTrigger, InpAlmaHysteresisAtrPeriod, InpAlmaHysteresisFactor);
        }
        if (h_multiDualMa == INVALID_HANDLE) {
            Print("[Hybrid_DFA_EA] MultiDualMA インディケータのハンドル取得に失敗しました。");
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

        // 初期ATR値の取得
        double atrBuf[];
        ArraySetAsSeries(atrBuf, true);
        if (CopyBuffer(h_atr, 0, 1, 1, atrBuf) > 0) {
            g_lastAtr = atrBuf[0];
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
        if (h_kalman != INVALID_HANDLE)
            IndicatorRelease(h_kalman);
        if (h_smoothedRsi != INVALID_HANDLE)
            IndicatorRelease(h_smoothedRsi);
        if (h_multiDualMa != INVALID_HANDLE)
            IndicatorRelease(h_multiDualMa);
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
//| 1分足新バー確定判定ヘルパー (トレーリングストップ用)              |
//+------------------------------------------------------------------+
bool IsNewM1Bar() {
    datetime currentM1Time = iTime(_Symbol, PERIOD_M1, 0);
    if (currentM1Time != m_lastM1BarTime) {
        m_lastM1BarTime = currentM1Time;
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

    // チャート足の Bar 1 時刻 (SmoothedRSI / MultiDualMA はチャート足基準で参照)
    // ※ DFA / ATR は Phase 4 で各々上位足の iTime で個別取得に変更済み
    datetime bar1_time = iTime(_Symbol, _Period, 1);

    // 1. カルマンフィルター レジーム判定の取得
    if (InpUseKalman && h_kalman != INVALID_HANDLE) {
        double zBuf[], slopeBuf[];
        ArraySetAsSeries(zBuf, true);
        ArraySetAsSeries(slopeBuf, true);

        // バッファ0: ZScore, バッファ2: Slope(beta)
        int copiedZ = CopyBuffer(h_kalman, 0, 1, 1, zBuf);
        if (copiedZ <= 0) {
            copiedZ = CopyBuffer(h_kalman, 0, bar1_time, 1, zBuf);
        }

        int copiedSlope = CopyBuffer(h_kalman, 2, 1, 1, slopeBuf);
        if (copiedSlope <= 0) {
            copiedSlope = CopyBuffer(h_kalman, 2, bar1_time, 1, slopeBuf);
        }

        if (copiedZ > 0) {
            state.kalman_z = zBuf[0];
            state.kalman_slope = (copiedSlope > 0) ? slopeBuf[0] : 0.0;
            state.alpha = state.kalman_z; // 後方互換用

            // カルマンレジーム判定 (Z >= 2.0: 上昇トレンド, Z <= -2.0: 下降トレンド, 間: レンジ)
            ENUM_REGIME_TYPE newRegime = DetermineKalmanRegime(state.kalman_z, InpKalmanZThreshold);
            if (newRegime != g_currentRegime) {
                string prevStr = (g_currentRegime == REGIME_RANGE ? "RANGE" :
                                  (g_currentRegime == REGIME_UP_TREND ? "UP_TREND" :
                                   (g_currentRegime == REGIME_DOWN_TREND ? "DOWN_TREND" : "NONE")));
                string newStr = (newRegime == REGIME_RANGE ? "RANGE" :
                                 (newRegime == REGIME_UP_TREND ? "UP_TREND" : "DOWN_TREND"));
                PrintFormat("[Hybrid_DFA_EA] カルマンレジーム遷移: %s -> %s (Z-Score=%.2f, Slope=%.5e)",
                            prevStr, newStr, state.kalman_z, state.kalman_slope);
                g_currentRegime = newRegime;
            }
            state.regime = g_currentRegime;
        } else {
            Print("[Hybrid_DFA_EA] KalmanRegimeEstimator バッファ取得エラー");
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

    // 3. トレンド戦略 MA の取得 (バー1, バー2)
    // ※ MultiDualMA インディケータが全MAタイプ（SMA/EMA/SMMA/LWMA/ALMA）の計算と2色描画を統一担当
    if (InpUseTrendStrategy && h_multiDualMa != INVALID_HANDLE) {
        double fastBuf[], slowBuf[], sigBuf[];
        ArraySetAsSeries(fastBuf, true);
        ArraySetAsSeries(slowBuf, true);
        ArraySetAsSeries(sigBuf, true);

        if (CopyBuffer(h_multiDualMa, 0, 1, 2, fastBuf) == 2 &&
            CopyBuffer(h_multiDualMa, 1, 1, 2, slowBuf) == 2) {
            state.alma_fast_1 = fastBuf[0];
            state.alma_fast_2 = fastBuf[1];
            state.alma_slow_1 = slowBuf[0];
            state.alma_slow_2 = slowBuf[1];
        } else {
            Print("[Hybrid_DFA_EA] トレンド MA バッファ取得エラー");
            return false;
        }

        if (CopyBuffer(h_multiDualMa, 3, 1, 2, sigBuf) == 2) {
            state.alma_signal_1 = sigBuf[0];
            state.alma_signal_2 = sigBuf[1];
        } else {
            // シグナルバッファ取得不可時はクロス判定で代替
            state.alma_signal_1 = (state.alma_fast_1 > state.alma_slow_1) ? 1.0 : -1.0;
            state.alma_signal_2 = (state.alma_fast_2 > state.alma_slow_2) ? 1.0 : -1.0;
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
            g_lastAtr = state.atr;
        } else {
            Print("[Hybrid_DFA_EA] ATR バッファ取得エラー");
            return false;
        }
    }

    static bool isFirstUpdate = true;
    if (isFirstUpdate) {
        isFirstUpdate = false;
        string regStr = (state.regime == REGIME_RANGE ? "RANGE" :
                         (state.regime == REGIME_UP_TREND ? "UP_TREND" :
                          (state.regime == REGIME_DOWN_TREND ? "DOWN_TREND" : "NONE")));
        PrintFormat("[Hybrid_DFA_EA] 初回状態取得成功: Kalman Z=%.2f, Slope=%.5e (Regime=%s), RSI[1]=%.2f, ALMA Fast[1]=%.5f Slow[1]=%.5f Signal[1]=%.1f",
                    state.kalman_z, state.kalman_slope, regStr, state.smoothed_rsi_1, state.alma_fast_1, state.alma_slow_1, state.alma_signal_1);
    }

    return true;
}

//+------------------------------------------------------------------+
//| ポジションクローズヘルパー (特定戦略または全クローズ)            |
//+------------------------------------------------------------------+
void ClosePositionsByStrategy(const ENUM_STRATEGY_SOURCE targetSource, const int filterType = -1) {
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

                if (shouldClose && (filterType == -1 || m_position.PositionType() == filterType)) {
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
//| ATRトレーリングストップ更新 (1分足確定毎に判定)                  |
//+------------------------------------------------------------------+
void UpdateTrailingStop() {
    // ATRが未初期化または無効な場合は最新バッファからの取得を試みる
    if (g_lastAtr <= 0.0 && h_atr != INVALID_HANDLE) {
        double atrBuf[];
        ArraySetAsSeries(atrBuf, true);
        if (CopyBuffer(h_atr, 0, 1, 1, atrBuf) > 0) {
            g_lastAtr = atrBuf[0];
        }
    }

    if (g_lastAtr <= 0.0) {
        return;
    }

    double trailDistance = g_lastAtr * InpAtrSlFactor;
    trailDistance = AdjustStopDistance(_Symbol, trailDistance);

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if (point <= 0.0) point = _Point;

    long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    double minStopDistance = MathMax((double)stopsLevel, (double)spreadPoints) * point + (point * 2.0);

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (m_position.SelectByIndex(i)) {
            if (m_position.Symbol() == _Symbol) {
                ulong posMagic = m_position.Magic();
                if (posMagic == InpMagicNumber + MAGIC_RANGE_OFFSET ||
                    posMagic == InpMagicNumber + MAGIC_TREND_OFFSET) {

                    ENUM_POSITION_TYPE posType = m_position.PositionType();
                    double currentSL = m_position.StopLoss();
                    double currentTP = m_position.TakeProfit();
                    ulong ticket = m_position.Ticket();

                    if (posType == POSITION_TYPE_BUY) {
                        double newSL = NormalizeDouble(bid - trailDistance, _Digits);
                        // 現在SLより切り上がり、かつ現在価格からのストップレベル制限を満たしている場合
                        if (newSL > currentSL + (point * 0.5) && (bid - newSL) >= minStopDistance) {
                            m_trade.SetExpertMagicNumber(posMagic);
                            if (m_trade.PositionModify(ticket, newSL, currentTP)) {
                                PrintFormat("[Hybrid_DFA_EA] ATRトレーリングストップ更新 (BUY): Ticket=%I64u, OldSL=%.5f -> NewSL=%.5f (Bid=%.5f, TrailDist=%.5f)",
                                            ticket, currentSL, newSL, bid, trailDistance);
                            } else {
                                PrintFormat("[Hybrid_DFA_EA] ATRトレーリングストップ更新失敗 (BUY): Ticket=%I64u, エラーコード=%d",
                                            ticket, GetLastError());
                            }
                        }
                    } else if (posType == POSITION_TYPE_SELL) {
                        double newSL = NormalizeDouble(ask + trailDistance, _Digits);
                        // 現在SLが未設定、または現在SLより切り下がり、かつ現在価格からのストップレベル制限を満たしている場合
                        if ((currentSL == 0.0 || newSL < currentSL - (point * 0.5)) && (newSL - ask) >= minStopDistance) {
                            m_trade.SetExpertMagicNumber(posMagic);
                            if (m_trade.PositionModify(ticket, newSL, currentTP)) {
                                PrintFormat("[Hybrid_DFA_EA] ATRトレーリングストップ更新 (SELL): Ticket=%I64u, OldSL=%.5f -> NewSL=%.5f (Ask=%.5f, TrailDist=%.5f)",
                                            ticket, currentSL, newSL, ask, trailDistance);
                            } else {
                                PrintFormat("[Hybrid_DFA_EA] ATRトレーリングストップ更新失敗 (SELL): Ticket=%I64u, エラーコード=%d",
                                            ticket, GetLastError());
                            }
                        }
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| ティック処理メイン関数                                           |
//+------------------------------------------------------------------+
void OnTick() {
    // 1. トレーリングストップの更新 (1分足 M1 新バー確定時に判定・実行)
    if (InpUseAtrExit && InpAtrTpFactor <= 0.0 && InpAtrSlFactor > 0.0) {
        if (IsNewM1Bar()) {
            UpdateTrailingStop();
        }
    }

    // 2. チャート足の新バー確定時のみシグナル評価とレジーム監視を実行
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
    // 1. レジーム逆行時の強制決済
    //------------------------------------------------------------------
    if (InpUseKalman) {
        // レンジポジション保有中、カルマンZスコアがトレンド領域 (|Z| >= InpKalmanZThreshold) に突入したら強制決済
        if ((rangeBuys > 0 || rangeSells > 0) &&
            ShouldCloseKalmanPosition(STRATEGY_RANGE, POSITION_TYPE_BUY, state.kalman_z, InpKalmanZThreshold)) {
            PrintFormat("[Hybrid_DFA_EA] レジーム逆行検知: カルマンZスコア (%.2f) がトレンド領域 (|Z| >= %.1f) に突入したためレンジポジションを決済します。",
                        state.kalman_z, InpKalmanZThreshold);
            ClosePositionsByStrategy(STRATEGY_RANGE);
            rangeBuys = 0;
            rangeSells = 0;
        }

        // トレンドBUY保有中、Zスコアが 0.0 を下回ったら強制決済 (中心線割れ)
        if (trendBuys > 0 &&
            ShouldCloseKalmanPosition(STRATEGY_TREND, POSITION_TYPE_BUY, state.kalman_z, InpKalmanZThreshold, 0.0)) {
            PrintFormat("[Hybrid_DFA_EA] レジーム逆行検知: カルマンZスコア (%.2f) が中央基準線 0.0 を下回ったためトレンドBUYポジションを決済します。",
                        state.kalman_z);
            ClosePositionsByStrategy(STRATEGY_TREND, POSITION_TYPE_BUY);
            trendBuys = 0;
        }

        // トレンドSELL保有中、Zスコアが 0.0 を上回ったら強制決済 (中心線超え)
        if (trendSells > 0 &&
            ShouldCloseKalmanPosition(STRATEGY_TREND, POSITION_TYPE_SELL, state.kalman_z, InpKalmanZThreshold, 0.0)) {
            PrintFormat("[Hybrid_DFA_EA] レジーム逆行検知: カルマンZスコア (%.2f) が中央基準線 0.0 を上回ったためトレンドSELLポジションを決済します。",
                        state.kalman_z);
            ClosePositionsByStrategy(STRATEGY_TREND, POSITION_TYPE_SELL);
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
    // 3. トレンドポジション保有中のMA逆交差による決済
    //------------------------------------------------------------------
    if (InpUseTrendStrategy) {
        bool shouldCloseBuy = false;
        bool shouldCloseSell = false;
        bool useSchmitt = (InpTrendMaType == TREND_MA_ALMA && InpAlmaUseSchmittTrigger);

        if (useSchmitt) {
            // シュミットトリガー有効時: SignalState が弱気(-1.0)に転換した場合にBUY決済
            if (trendBuys > 0 && state.alma_signal_1 < 0.0) {
                shouldCloseBuy = true;
            }
            // SignalState が強気(+1.0)に転換した場合にSELL決済
            if (trendSells > 0 && state.alma_signal_1 > 0.0) {
                shouldCloseSell = true;
            }
        } else {
            // 従来の直接クロス判定 (SMA / EMA / 通常ALMA)
            if (trendBuys > 0 && state.alma_fast_2 >= state.alma_slow_2 &&
                state.alma_fast_1 < state.alma_slow_1) {
                shouldCloseBuy = true;
            }
            if (trendSells > 0 && state.alma_fast_2 <= state.alma_slow_2 &&
                state.alma_fast_1 > state.alma_slow_1) {
                shouldCloseSell = true;
            }
        }

        if (shouldCloseBuy) {
            PrintFormat("[Hybrid_DFA_EA] トレンドBUY決済 (弱気反転シグナル検知): Fast[1]=%.5f, Slow[1]=%.5f, Signal[1]=%.1f",
                        state.alma_fast_1, state.alma_slow_1, state.alma_signal_1);
            ClosePositionsByStrategy(STRATEGY_TREND);
            trendBuys = 0;
        }
        if (shouldCloseSell) {
            PrintFormat("[Hybrid_DFA_EA] トレンドSELL決済 (強気反転シグナル検知): Fast[1]=%.5f, Slow[1]=%.5f, Signal[1]=%.1f",
                        state.alma_fast_1, state.alma_slow_1, state.alma_signal_1);
            ClosePositionsByStrategy(STRATEGY_TREND);
            trendSells = 0;
        }
    }

    //------------------------------------------------------------------
    // 2. エントリーシグナル判定
    //------------------------------------------------------------------
    // レンジ戦略許可: レンジ相場 (|Z| < InpKalmanZThreshold)
    bool allowRange = InpUseRangeStrategy && (!InpUseKalman || state.regime == REGIME_RANGE);

    // トレンド戦略許可: 上昇トレンド(Z >= InpKalmanZThreshold)でBUY許可、下降トレンド(Z <= -InpKalmanZThreshold)でSELL許可
    bool allowTrendBuy  = InpUseTrendStrategy && (!InpUseKalman || state.regime == REGIME_UP_TREND);
    bool allowTrendSell = InpUseTrendStrategy && (!InpUseKalman || state.regime == REGIME_DOWN_TREND);

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
                PrintFormat("[Hybrid_DFA_EA] レンジBUYシグナル検知: Kalman Z=%.2f, RSI[2]=%.2f, RSI[1]=%.2f",
                            state.kalman_z, state.smoothed_rsi_2, state.smoothed_rsi_1);
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
                PrintFormat("[Hybrid_DFA_EA] レンジSELLシグナル検知: Kalman Z=%.2f, RSI[2]=%.2f, RSI[1]=%.2f",
                            state.kalman_z, state.smoothed_rsi_2, state.smoothed_rsi_1);
                ExecuteOrder(ORDER_TYPE_SELL, STRATEGY_RANGE, state.atr);
            }
        }
    }

    // B. トレンド戦略シグナル (Dual MA Cross)
    if (InpUseTrendStrategy) {
        bool signalBuy = false;
        bool signalSell = false;
        bool useSchmitt = (InpTrendMaType == TREND_MA_ALMA && InpAlmaUseSchmittTrigger);

        if (useSchmitt) {
            // シュミットトリガー有効時: 非強気 (<= 0.0) から 強気 (+1.0) へのブレイクアウトでBUY
            if (state.alma_signal_2 <= 0.0 && state.alma_signal_1 > 0.0) {
                signalBuy = true;
            }
            // 非弱気 (>= 0.0) から 弱気 (-1.0) へのブレイクダウンでSELL
            else if (state.alma_signal_2 >= 0.0 && state.alma_signal_1 < 0.0) {
                signalSell = true;
            }
        } else {
            // 従来の直接クロス判定 (SMA / EMA / 通常ALMA)
            if (state.alma_fast_2 <= state.alma_slow_2 &&
                state.alma_fast_1 > state.alma_slow_1) {
                signalBuy = true;
            }
            else if (state.alma_fast_2 >= state.alma_slow_2 &&
                     state.alma_fast_1 < state.alma_slow_1) {
                signalSell = true;
            }
        }

        if (signalBuy && allowTrendBuy) {
            if (trendSells > 0) {
                ClosePositionsByStrategy(STRATEGY_TREND);
                trendSells = 0;
            }
            if (trendBuys == 0) {
                PrintFormat("[Hybrid_DFA_EA] トレンドBUYシグナル検知: Kalman Z=%.2f (>=%.1f), Fast[1]=%.3f, Slow[1]=%.3f, Signal[1]=%.1f",
                            state.kalman_z, InpKalmanZThreshold, state.alma_fast_1, state.alma_slow_1, state.alma_signal_1);
                ExecuteOrder(ORDER_TYPE_BUY, STRATEGY_TREND, state.atr);
            }
        } else if (signalSell && allowTrendSell) {
            if (trendBuys > 0) {
                ClosePositionsByStrategy(STRATEGY_TREND);
                trendBuys = 0;
            }
            if (trendSells == 0) {
                PrintFormat("[Hybrid_DFA_EA] トレンドSELLシグナル検知: Kalman Z=%.2f (<=-%.1f), Fast[1]=%.3f, Slow[1]=%.3f, Signal[1]=%.1f",
                            state.kalman_z, InpKalmanZThreshold, state.alma_fast_1, state.alma_slow_1, state.alma_signal_1);
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
        if (InpAtrSlFactor > 0.0) {
            slDistance = atr * InpAtrSlFactor;
            slDistance = AdjustStopDistance(_Symbol, slDistance);

            if (orderType == ORDER_TYPE_BUY) {
                slPrice = NormalizeDouble(ask - slDistance, _Digits);
            } else if (orderType == ORDER_TYPE_SELL) {
                slPrice = NormalizeDouble(bid + slDistance, _Digits);
            }
        }

        if (InpAtrTpFactor > 0.0) {
            double tpDistance = atr * InpAtrTpFactor;
            tpDistance = AdjustStopDistance(_Symbol, tpDistance);

            if (orderType == ORDER_TYPE_BUY) {
                tpPrice = NormalizeDouble(ask + tpDistance, _Digits);
            } else if (orderType == ORDER_TYPE_SELL) {
                tpPrice = NormalizeDouble(bid - tpDistance, _Digits);
            }
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
