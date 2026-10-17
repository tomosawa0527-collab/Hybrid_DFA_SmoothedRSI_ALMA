//+------------------------------------------------------------------+
//|                                       KalmanTrendEnsembleEA.mq5 |
//|                                  Copyright 2026, Quant Research  |
//| Dual-Directional Trend Follow + Normalized Kalman Regime         |
//| + Dual-Layer Hard Stop + ATR Band + Multi-Horizon Ensemble EA    |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Quant Research"
#property link        "https://www.mql5.com"
#property version     "1.00"
#property description "FX売買戦略仕様書（実運用完全版・カルマンフィルター統合版）完全準拠自動売買EA"

//--- ストラテジーテスター用インジケーター依存関係の明示（エージェントフォルダへの自動転送）
#property tester_indicator "Hybrid_DFA_EA\\KalmanRegimeEstimator.ex5"
#property tester_indicator "Hybrid_DFA_EA/KalmanRegimeEstimator.ex5"
#property tester_indicator "KalmanRegimeEstimator.ex5"
#property tester_indicator "Indicators\\Hybrid_DFA_EA\\KalmanRegimeEstimator.ex5"
#property tester_indicator "Hybrid_DFA_EA\\MultiTrendMA.ex5"
#property tester_indicator "Hybrid_DFA_EA/MultiTrendMA.ex5"
#property tester_indicator "MultiTrendMA.ex5"
#property tester_indicator "Indicators\\Hybrid_DFA_EA\\MultiTrendMA.ex5"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include "..\..\Include\Hybrid_DFA_EA\Hybrid_DFA_EA_Common.mqh"

//--- デフォルト配置パス定義
#ifndef DEFAULT_KALMAN_INDICATOR_PATH
#define DEFAULT_KALMAN_INDICATOR_PATH "Hybrid_DFA_EA\\KalmanRegimeEstimator"
#endif

//+------------------------------------------------------------------+
//| 入力パラメータ                                                   |
//+------------------------------------------------------------------+
input group "=== EA 基本設定 ==="
input ulong             InpMagicNumber          = 20260927;       // マジックナンバー
input string            InpTradeComment         = "KalmanEnsemble"; // 注文コメント
input ulong             InpSlippage             = 10;             // 許容スリッページ (Points)
input double            InpMaxSpreadPips        = 2.5;            // 許容最大スプレッド (Pips: 早朝スプレッド待機用)

input group "=== カルマンフィルター (KalmanRegimeEstimator) 設定 ==="
input ENUM_HTF_MODE     InpKalmanTimeframeMode  = HTF_MODE_AUTO_NEXT;     // カルマン計算時間軸 (デフォルト: 1段階上位足)
#define InpKalmanTfMode InpKalmanTimeframeMode // 後方互換用エイリアス
input string            InpIndicatorPath        = DEFAULT_KALMAN_INDICATOR_PATH; // インジケーターパス
input bool              InpIndAutoTimeframeScale= true;           // 時間足に応じたノイズ自動スケーリング
input bool              InpIndAutoCalibration   = true;           // Rice推定量による解析的自動キャリブレーション
input double            InpIndTargetLagBars     = 10.0;           // ターゲット時定数 (抽出スイング幅: 8〜15本推奨)
input int               InpIndRollingWindow     = 200;            // ローリング観測窓長 W (100〜250推奨)
input double            InpIndManualQMu         = 0.0;            // プロセスノイズ (水準: 手動用)
input double            InpIndManualQBeta       = 1e-9;           // プロセスノイズ (傾き: 手動用)
input double            InpIndManualR           = 1e-5;           // 観測ノイズ (R: 手動用)
input double            InpIndManualInitialP    = 1.0;            // 初期誤差共分散スケール

#define InpIndCalibSamples InpIndRollingWindow // 後方互換用エイリアス
input double            InpIndZEnter            = 2.0;            // トレンド突入閾値 (|z| >= z_enter)
input double            InpIndZExit             = 1.0;            // トレンド離脱閾値 (|z| <= z_exit)
input bool              InpIndAllowDirectReversal= true;          // 急反転時の即時ドテン許可
input ENUM_APPLIED_PRICE InpIndAppliedPrice     = PRICE_CLOSE;   // 適用価格

input group "=== MA アンサンブル設定 (MultiTrendMA 仕様書第3.2章) ==="
input ENUM_TREND_MA_TYPE InpEnsembleMaType      = TREND_MA_LWMA;  // 移動平均タイプ (SMA/EMA/SMMA/LWMA/ALMA)
input ENUM_MA_PERIOD    InpLwmaShortFast        = MA_PERIOD_10;   // 短期ペア Fast (LWMA 10)
input ENUM_MA_PERIOD    InpLwmaShortSlow        = MA_PERIOD_30;   // 短期ペア Slow (LWMA 30)
input ENUM_MA_PERIOD    InpLwmaMidFast          = MA_PERIOD_20;   // 中期ペア Fast (LWMA 20: 部分利確基準線)
input ENUM_MA_PERIOD    InpLwmaMidSlow          = MA_PERIOD_60;   // 中期ペア Slow (LWMA 60: ブレイク/ストップ基準線)
input ENUM_MA_PERIOD    InpLwmaLongFast         = MA_PERIOD_40;   // 長期ペア Fast (LWMA 40)
input ENUM_MA_PERIOD    InpLwmaLongSlow         = MA_PERIOD_120;  // 長期ペア Slow (LWMA 120)
input double            InpEnsembleThreshold    = 0.67;           // アンサンブル合致度閾値 (3組中2組以上 = 0.67)

input group "=== ATR & ブレイクアウトバンド設定 (仕様書第3.3章) ==="
input int               InpAtrPeriod            = 14;             // ATR 期間 (Wilder平滑化)
input double            InpAtrBandMultiplier    = 1.2;            // エントリーバンド倍率 (LWMA60 ± 1.2 * ATR)
input double            InpAtrStopMultiplier    = 1.0;            // ストップ基準線倍率 (LWMA60 ± 1.0 * ATR)
input double            InpAtrFloorMultiplier   = 0.5;            // 実約定価格最低フロア距離倍率 (0.5 * ATR)

input group "=== RSI モメンタム設定 (仕様書第3.4章) ==="
input int               InpRsiPeriod            = 14;             // RSI 期間
input double            InpRsiLongMin           = 50.0;           // 買いモメンタム下限
input double            InpRsiLongMax           = 80.0;           // 買いモメンタム上限 (初動取り逃し防止緩和値)
input double            InpRsiShortMin          = 20.0;           // 売りモメンタム下限
input double            InpRsiShortMax          = 50.0;           // 売りモメンタム上限

input group "=== スイングハイ・ロー & クールダウン設定 (仕様書第3.5章・第11章) ==="
input int               InpSwingPeriod          = 20;             // スイング参照期間 (過去N本・当日除外)
input int               InpCooldownBars         = 2;              // 決済後クールダウン期間 (バー数: 48時間=2本)

input group "=== 資金管理 & リスク管理設定 (仕様書第6章〜第9章) ==="
input double            InpRiskPercent          = 0.5;            // 1トレード許容リスク (%) (口座総資産比 0.5%)
input double            InpMaxEffectiveLeverage = 5.0;            // 実効レバレッジ上限 (5.0倍)
input double            InpMarginLevelStopNew   = 300.0;          // 新規発注停止 証拠金維持率 (%)
input double            InpMarginLevelEmergency = 150.0;          // 緊急リスクオフ 証拠金維持率 (%)
input bool              InpEnableClusterRisk    = true;           // 2通貨分解クラスタ管理を有効化
input bool              InpEnableWeekendCarry   = true;           // 週末持ち越しリスク管理を有効化

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
CTrade         g_trade;
CPositionInfo  g_position;

// インジケーターハンドル
int h_kalman       = INVALID_HANDLE;
int h_multi_short  = INVALID_HANDLE;
int h_multi_mid    = INVALID_HANDLE;
int h_multi_long   = INVALID_HANDLE;
int h_atr14        = INVALID_HANDLE;
int h_rsi14        = INVALID_HANDLE;

// 実行制御変数
datetime        g_last_bar_time    = 0;
int             g_cooldown_counter = 0;   // クールダウン残バー数
bool            g_partial_closed   = false; // 部分利確済みフラグ
ENUM_TIMEFRAMES g_kalman_tf        = PERIOD_D1; // 実効カルマン時間軸

//+------------------------------------------------------------------+
//| カルマンインジケーターハンドル生成ヘルパー                       |
//+------------------------------------------------------------------+
int CreateKalmanIndicatorHandle(const string indicator_path)
{
   g_kalman_tf = ResolveTimeframe(InpKalmanTimeframeMode, _Period);

   return iCustom(_Symbol, _Period, indicator_path,
                  // --- Group 1: マルチタイムフレーム (MTF) 設定 ---
                  "=== マルチタイムフレーム (MTF) 設定 ===",
                  g_kalman_tf,
                  InpIndAutoTimeframeScale,

                  // --- Group 2: 確定足動的キャリブレーション (完全因果的・先読みゼロ) ---
                  "=== 確定足動的キャリブレーション (完全因果的・先読みゼロ) ===",
                  InpIndAutoCalibration,
                  InpIndTargetLagBars,
                  InpIndRollingWindow,

                  // --- Group 3: カルマンフィルター パラメータ (手動設定時または初期フォールバック) ---
                  "=== カルマンフィルター パラメータ (手動設定時または初期フォールバック) ===",
                  InpIndManualQMu,
                  InpIndManualQBeta,
                  InpIndManualR,
                  InpIndManualInitialP,

                  // --- Group 4: レジーム判定 (ヒステリシス) パラメータ ---
                  "=== レジーム判定 (ヒステリシス) パラメータ ===",
                  InpIndZEnter,
                  InpIndZExit,
                  InpIndAllowDirectReversal,
                  InpIndAppliedPrice);
}

//+------------------------------------------------------------------+
//| MultiTrendMA インジケーターハンドル生成ヘルパー                  |
//+------------------------------------------------------------------+
int CreateMultiTrendMaHandle(const ENUM_TIMEFRAMES tf,
                            const ENUM_TREND_MA_TYPE ma_type,
                            const ENUM_MA_PERIOD fast_win,
                            const ENUM_MA_PERIOD slow_win)
{
   string candidates[4];
   candidates[0] = "Hybrid_DFA_EA\\MultiTrendMA";
   candidates[1] = "Indicators\\Hybrid_DFA_EA\\MultiTrendMA";
   candidates[2] = "Hybrid_DFA_EA/MultiTrendMA";
   candidates[3] = "MultiTrendMA";

   for(int i = 0; i < 4; i++)
   {
      // チャート足(_Period)でバインドし、MTF設定としてtf(_Period等)を渡す
      int h = iCustom(_Symbol, _Period, candidates[i],
                      // === マルチタイムフレーム (MTF) 設定 ===
                      "=== マルチタイムフレーム (MTF) 設定 ===",
                      tf,
                      // === 移動平均線 基本設定 ===
                      "=== 移動平均線 基本設定 ===",
                      ma_type,            // InpFastMaType
                      fast_win,           // InpFastWindow
                      ma_type,            // InpMidMaType
                      MA_PERIOD_DISABLED, // InpMidWindow (Midは無効)
                      ma_type,            // InpSlowMaType
                      slow_win,           // InpSlowWindow
                      PRICE_CLOSE);
      if(h != INVALID_HANDLE)
         return h;
   }
   return INVALID_HANDLE;
}

//+------------------------------------------------------------------+
//| 初期化関数                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(DetectFillType(_Symbol));

   // 1. カルマンレジーム推定インジケーターの接続試行 (InpKalmanTF 指定足)
   string resolved_path = InpIndicatorPath;
   if(resolved_path == "KalmanRegimeEstimator" || resolved_path == "")
      resolved_path = DEFAULT_KALMAN_INDICATOR_PATH;

   h_kalman = CreateKalmanIndicatorHandle(resolved_path);
   if(h_kalman == INVALID_HANDLE)
   {
      string fallback_candidates[4];
      fallback_candidates[0] = "Hybrid_DFA_EA/KalmanRegimeEstimator";
      fallback_candidates[1] = "Hybrid_DFA_EA\\KalmanRegimeEstimator";
      fallback_candidates[2] = "KalmanRegimeEstimator";
      fallback_candidates[3] = "Indicators\\Hybrid_DFA_EA\\KalmanRegimeEstimator";

      for(int i = 0; i < 4; i++)
      {
         if(fallback_candidates[i] != resolved_path)
         {
            h_kalman = CreateKalmanIndicatorHandle(fallback_candidates[i]);
            if(h_kalman != INVALID_HANDLE)
            {
               PrintFormat("[+] カルマンインジケーター '%s' で接続成功", fallback_candidates[i]);
               resolved_path = fallback_candidates[i];
               break;
            }
         }
      }
   }

   if(h_kalman == INVALID_HANDLE)
   {
      PrintFormat("[Error] カルマンインジケーターのハンドル取得に失敗しました (Error Code: %d)。", GetLastError());
      return(INIT_FAILED);
   }

   // 2. MultiTrendMA アンサンブル (3ペア) のハンドル生成 (カレント足 _Period 連動)
   h_multi_short = CreateMultiTrendMaHandle(_Period, InpEnsembleMaType, InpLwmaShortFast, InpLwmaShortSlow);
   h_multi_mid   = CreateMultiTrendMaHandle(_Period, InpEnsembleMaType, InpLwmaMidFast,   InpLwmaMidSlow);
   h_multi_long  = CreateMultiTrendMaHandle(_Period, InpEnsembleMaType, InpLwmaLongFast,  InpLwmaLongSlow);

   if(h_multi_short == INVALID_HANDLE || h_multi_mid == INVALID_HANDLE || h_multi_long == INVALID_HANDLE)
   {
      Print("[Error] MultiTrendMA インジケーターの初期化に失敗しました。");
      return(INIT_FAILED);
   }

   // チャート上にLWMAインジケーターを自動アタッチ (バックテスト完了後チャートおよびリアル運用で可視化)
   ChartIndicatorAdd(0, 0, h_multi_short);
   ChartIndicatorAdd(0, 0, h_multi_mid);
   ChartIndicatorAdd(0, 0, h_multi_long);

   // 3. ATR(14) および RSI(14) のハンドル生成 (カレント足 _Period 連動)
   h_atr14 = iATR(_Symbol, _Period, InpAtrPeriod);
   h_rsi14 = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);

   if(h_atr14 == INVALID_HANDLE || h_rsi14 == INVALID_HANDLE)
   {
      Print("[Error] ATRまたはRSIインジケーターの初期化に失敗しました。");
      return(INIT_FAILED);
   }

   g_last_bar_time    = 0;
   g_cooldown_counter = 0;
   g_partial_closed   = false;

   PrintFormat("[+] KalmanTrendEnsembleEA 初期化成功 | Symbol: %s | 執行足: %s | カルマン足: %s (モード: %s) | Magic: %d | Risk: %.1f%%",
               _Symbol, EnumToString(_Period), EnumToString(g_kalman_tf), EnumToString(InpKalmanTimeframeMode), InpMagicNumber, InpRiskPercent);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 終了処理関数                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // バックテスト時はインジケータハンドルを解放しない（テスト完了後のチャート上にインジケータ表示を残すため）
   if(!MQLInfoInteger(MQL_TESTER))
   {
      if(h_kalman != INVALID_HANDLE)      IndicatorRelease(h_kalman);
      if(h_multi_short != INVALID_HANDLE) IndicatorRelease(h_multi_short);
      if(h_multi_mid != INVALID_HANDLE)   IndicatorRelease(h_multi_mid);
      if(h_multi_long != INVALID_HANDLE)  IndicatorRelease(h_multi_long);
      if(h_atr14 != INVALID_HANDLE)       IndicatorRelease(h_atr14);
      if(h_rsi14 != INVALID_HANDLE)       IndicatorRelease(h_rsi14);
   }
   PrintFormat("[*] KalmanTrendEnsembleEA 終了処理完了 (Reason: %d)", reason);
}

//+------------------------------------------------------------------+
//| 最新の確定足指標データを取得                                     |
//+------------------------------------------------------------------+
bool GetShift1IndicatorData(double &kalman_regime,
                            double &kalman_zscore,
                            double &kalman_slope,
                            double &lwma10, double &lwma30,
                            double &lwma20, double &lwma60,
                            double &lwma40, double &lwma120,
                            double &atr14,
                            double &rsi14,
                            double &close1)
{
   double k_reg[1], k_z[1], k_s[1];
   // Buffer 3: Regime, Buffer 0: Z-Score, Buffer 2: Slope (Shift: 1)
   if(CopyBuffer(h_kalman, 3, 1, 1, k_reg) <= 0 ||
      CopyBuffer(h_kalman, 0, 1, 1, k_z)   <= 0 ||
      CopyBuffer(h_kalman, 2, 1, 1, k_s)   <= 0)
   {
      return false;
   }
   kalman_regime = k_reg[0];
   kalman_zscore = k_z[0];
   kalman_slope  = k_s[0];

   double buf_fast[1], buf_slow[1];
   // 短期ペア (Fast: ShortFast, Slow: ShortSlow)
   if(CopyBuffer(h_multi_short, MULTI_TREND_MA_BUFFER_FAST, 1, 1, buf_fast) <= 0 ||
      CopyBuffer(h_multi_short, MULTI_TREND_MA_BUFFER_SLOW, 1, 1, buf_slow) <= 0)
   {
      return false;
   }
   lwma10 = buf_fast[0];
   lwma30 = buf_slow[0];

   // 中期ペア (Fast: MidFast, Slow: MidSlow)
   if(CopyBuffer(h_multi_mid, MULTI_TREND_MA_BUFFER_FAST, 1, 1, buf_fast) <= 0 ||
      CopyBuffer(h_multi_mid, MULTI_TREND_MA_BUFFER_SLOW, 1, 1, buf_slow) <= 0)
   {
      return false;
   }
   lwma20 = buf_fast[0];
   lwma60 = buf_slow[0];

   // 長期ペア (Fast: LongFast, Slow: LongSlow)
   if(CopyBuffer(h_multi_long, MULTI_TREND_MA_BUFFER_FAST, 1, 1, buf_fast) <= 0 ||
      CopyBuffer(h_multi_long, MULTI_TREND_MA_BUFFER_SLOW, 1, 1, buf_slow) <= 0)
   {
      return false;
   }
   lwma40  = buf_fast[0];
   lwma120 = buf_slow[0];

   double buf_atr[1], buf_rsi[1];
   if(CopyBuffer(h_atr14, 0, 1, 1, buf_atr) <= 0 ||
      CopyBuffer(h_rsi14, 0, 1, 1, buf_rsi) <= 0)
   {
      return false;
   }
   atr14 = buf_atr[0];
   rsi14 = buf_rsi[0];

   close1 = iClose(_Symbol, _Period, 1);
   if(close1 <= 0.0) return false;

   return true;
}

//+------------------------------------------------------------------+
//| ティックイベント処理関数                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   // 最新ATRの取得 (週末持ち越しリスク判定用)
   double atr_cur[1];
   double cur_atr_val = 0.0;
   if(CopyBuffer(h_atr14, 0, 0, 1, atr_cur) > 0)
      cur_atr_val = atr_cur[0];

   // 1. 週末持ち越しリスク管理 (仕様書第9.1章: 金曜NYクローズ1時間前)
   if(InpEnableWeekendCarry && IsFridayWeekendRiskTime(TimeCurrent()))
   {
      CheckWeekendCarryRisk(g_trade, _Symbol, InpMagicNumber, cur_atr_val);
   }

   // 2. 証拠金維持率 緊急リスクオフゲート (仕様書第7.2章: 維持率 < 150%)
   if(GetAccountMarginLevel() < InpMarginLevelEmergency)
   {
      TriggerEmergencyRiskOff(g_trade, InpMagicNumber);
      return;
   }

   // 3. 新バー確定判定 (カレント足新バー形成時に1度のみ執行)
   datetime cur_bar_time = iTime(_Symbol, _Period, 0);
   if(cur_bar_time == g_last_bar_time)
      return; // 同一バー内では新規判定・更新をスキップ

   // クールダウンカウンターの更新 (新バー確定時に1減算)
   if(g_cooldown_counter > 0)
   {
      g_cooldown_counter--;
      PrintFormat("[*] クールダウン進行中: 残り %d 本", g_cooldown_counter);
   }

   // 4. 指標データの取得 (Shift: 1 確定足)
   double kalman_regime, kalman_zscore, kalman_slope;
   double lwma10, lwma30, lwma20, lwma60, lwma40, lwma120;
   double atr14, rsi14, close1;

   if(!GetShift1IndicatorData(kalman_regime, kalman_zscore, kalman_slope,
                              lwma10, lwma30, lwma20, lwma60, lwma40, lwma120,
                              atr14, rsi14, close1))
   {
      return;
   }

   // スイングハイ・ローの計算 (過去20本・前足除外: Shift 1 起点)
   double swing_low  = GetSwingLow(_Symbol, _Period, InpSwingPeriod, 1);
   double swing_high = GetSwingHigh(_Symbol, _Period, InpSwingPeriod, 1);
   if(swing_low <= 0.0 || swing_high <= 0.0) return;

   // 現在の保有ポジション確認
   bool has_position = false;
   ulong pos_ticket  = 0;
   ENUM_POSITION_TYPE pos_type = POSITION_TYPE_BUY;
   double pos_lots   = 0.0;
   double cur_sl     = 0.0;
   double cur_tp     = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(g_position.SelectByIndex(i))
      {
         if(g_position.Symbol() == _Symbol && g_position.Magic() == InpMagicNumber)
         {
            has_position = true;
            pos_ticket   = g_position.Ticket();
            pos_type     = g_position.PositionType();
            pos_lots     = g_position.Volume();
            cur_sl       = g_position.StopLoss();
            cur_tp       = g_position.TakeProfit();
            break;
         }
      }
   }

   // =================================================================
   // 5. 保有ポジションの監視・ソフト決済およびハードSLトレイリング更新 (仕様書第5章)
   // =================================================================
   if(has_position)
   {
      // --- ロングポジションの監視 ---
      if(pos_type == POSITION_TYPE_BUY)
      {
         // [第2防護壁: ソフト全決済判定 (仕様書第5.2章 A.1)]
         bool soft_exit_full = false;
         string exit_reason = "";

         if(kalman_regime == KALMAN_REGIME_DOWN)
         {
            soft_exit_full = true;
            exit_reason = "カルマン下降転換 (-1.0)";
         }
         else if(close1 < (lwma60 - InpAtrStopMultiplier * atr14))
         {
            soft_exit_full = true;
            exit_reason = "ATRバンド割れ (Close < LWMA60 - 1.0*ATR)";
         }
         else if(close1 < swing_low)
         {
            soft_exit_full = true;
            exit_reason = "Swing Low 割れ (Close < SwingLow)";
         }

         if(soft_exit_full)
         {
            if(g_trade.PositionClose(pos_ticket))
            {
               PrintFormat("[SoftExit] BUY全決済執行: %s (Ticket: #%I64u, Close: %.5f)",
                           exit_reason, pos_ticket, close1);
               g_cooldown_counter = InpCooldownBars;
               g_partial_closed   = false;
               g_last_bar_time = cur_bar_time;
               return;
            }
         }
         // [第2防護壁: ソフト部分利確判定 (仕様書第5.2章 A.2)]
         else if(close1 < lwma20 && !g_partial_closed)
         {
            if(pos_lots >= 0.02)
            {
               double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
               double partial_lots = MathFloor((pos_lots * 0.5) / step) * step;
               if(partial_lots >= 0.01)
               {
                  if(g_trade.PositionClosePartial(pos_ticket, partial_lots))
                  {
                     PrintFormat("[PartialTP] BUY 50%%部分利確執行: Close < LWMA20 (Lot: %.2f -> %.2f)",
                                 pos_lots, pos_lots - partial_lots);
                     g_partial_closed = true;
                  }
               }
            }
         }

         // [第1防護壁: ハードSLの有利方向トレイリング更新 (仕様書第5.1章 C)]
         double new_sl = MathMin(lwma60 - InpAtrStopMultiplier * atr14, swing_low);
         new_sl = NormalizeDouble(new_sl, _Digits);

         // 有利方向（上方）への移動のみ許可
         if(new_sl > cur_sl + (0.5 * _Point))
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
            double minStopDist = (double)stopsLevel * _Point;

            if((bid - new_sl) >= minStopDist)
            {
               if(g_trade.PositionModify(pos_ticket, new_sl, cur_tp))
               {
                  PrintFormat("[HardSL] BUY ハードSL切り上げ: %.5f -> %.5f (LWMA60-1.0*ATR: %.5f, SwingLow: %.5f)",
                              cur_sl, new_sl, lwma60 - InpAtrStopMultiplier * atr14, swing_low);
               }
            }
         }
      }
      // --- ショートポジションの監視 ---
      else if(pos_type == POSITION_TYPE_SELL)
      {
         // [第2防護壁: ソフト全決済判定 (仕様書第5.2章 B.1)]
         bool soft_exit_full = false;
         string exit_reason = "";

         if(kalman_regime == KALMAN_REGIME_UP)
         {
            soft_exit_full = true;
            exit_reason = "カルマン上昇転換 (+1.0)";
         }
         else if(close1 > (lwma60 + InpAtrStopMultiplier * atr14))
         {
            soft_exit_full = true;
            exit_reason = "ATRバンド超え (Close > LWMA60 + 1.0*ATR)";
         }
         else if(close1 > swing_high)
         {
            soft_exit_full = true;
            exit_reason = "Swing High 超え (Close > SwingHigh)";
         }

         if(soft_exit_full)
         {
            if(g_trade.PositionClose(pos_ticket))
            {
               PrintFormat("[SoftExit] SELL全決済執行: %s (Ticket: #%I64u, Close: %.5f)",
                           exit_reason, pos_ticket, close1);
               g_cooldown_counter = InpCooldownBars;
               g_partial_closed   = false;
               g_last_bar_time = cur_bar_time;
               return;
            }
         }
         // [第2防護壁: ソフト部分利確判定 (仕様書第5.2章 B.2)]
         else if(close1 > lwma20 && !g_partial_closed)
         {
            if(pos_lots >= 0.02)
            {
               double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
               double partial_lots = MathFloor((pos_lots * 0.5) / step) * step;
               if(partial_lots >= 0.01)
               {
                  if(g_trade.PositionClosePartial(pos_ticket, partial_lots))
                  {
                     PrintFormat("[PartialTP] SELL 50%%部分利確執行: Close > LWMA20 (Lot: %.2f -> %.2f)",
                                 pos_lots, pos_lots - partial_lots);
                     g_partial_closed = true;
                  }
               }
            }
         }

         // [第1防護壁: ハードSLの有利方向トレイリング更新 (仕様書第5.1章 C)]
         double new_sl = MathMax(lwma60 + InpAtrStopMultiplier * atr14, swing_high);
         new_sl = NormalizeDouble(new_sl, _Digits);

         // 有利方向（下方）への移動のみ許可
         if(cur_sl == 0.0 || new_sl < cur_sl - (0.5 * _Point))
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
            double minStopDist = (double)stopsLevel * _Point;

            if((new_sl - ask) >= minStopDist)
            {
               if(g_trade.PositionModify(pos_ticket, new_sl, cur_tp))
               {
                  PrintFormat("[HardSL] SELL ハードSL切り下げ: %.5f -> %.5f (LWMA60+1.0*ATR: %.5f, SwingHigh: %.5f)",
                              cur_sl, new_sl, lwma60 + InpAtrStopMultiplier * atr14, swing_high);
               }
            }
         }
      }

      g_last_bar_time = cur_bar_time;
      return;
   }

   // =================================================================
   // 6. 新規エントリーシグナル判定および発注 (仕様書第4章・第5.1章)
   // =================================================================

   // クールダウン中は新規エントリーを拒絶 (仕様書第11章)
   if(g_cooldown_counter > 0)
   {
      g_last_bar_time = cur_bar_time;
      return;
   }

   // 証拠金維持率ゲート (仕様書第7.2章: < 300% で新規停止)
   if(GetAccountMarginLevel() < InpMarginLevelStopNew)
   {
      PrintFormat("[Gate] 新規発注停止: 証拠金維持率不足 (%.1f%% < %.1f%%)",
                  GetAccountMarginLevel(), InpMarginLevelStopNew);
      g_last_bar_time = cur_bar_time;
      return;
   }

   // 実効レバレッジゲート (仕様書第7.1章: > 5.0 で新規停止)
   if(CalculateEffectiveLeverage(InpMagicNumber) >= InpMaxEffectiveLeverage)
   {
      PrintFormat("[Gate] 新規発注停止: 実効レバレッジ上限到達 (%.2f >= %.2f)",
                  CalculateEffectiveLeverage(InpMagicNumber), InpMaxEffectiveLeverage);
      g_last_bar_time = cur_bar_time;
      return;
   }

   // スプレッドチェック (早朝スプレッド待機: 仕様書第10.1章)
   double pip_size = GetPipSize(_Symbol);
   double cur_spread_pips = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / pip_size;
   if(cur_spread_pips > InpMaxSpreadPips)
   {
      PrintFormat("[Spread] スプレッド拡大中 (%.1f > %.1f Pips) のため待機します。",
                  cur_spread_pips, InpMaxSpreadPips);
      return; // バー完了とせず次のティックで再評価
   }

   // アンサンブル比率の算出 (仕様書第4.3章)
   double long_ratio = 0.0, short_ratio = 0.0;
   CalcEnsembleRatios(lwma10, lwma30, lwma20, lwma60, lwma40, lwma120, long_ratio, short_ratio);

   // --- 買いエントリー判定 (Long: 仕様書第4.1章) ---
   bool long_signal = (kalman_regime == KALMAN_REGIME_UP) &&
                      (close1 >= lwma60 + InpAtrBandMultiplier * atr14) &&
                      (long_ratio >= InpEnsembleThreshold) &&
                      (InpRsiLongMin < rsi14 && rsi14 <= InpRsiLongMax);

   // --- 売りエントリー判定 (Short: 仕様書第4.2章) ---
   bool short_signal = (kalman_regime == KALMAN_REGIME_DOWN) &&
                       (close1 <= lwma60 - InpAtrBandMultiplier * atr14) &&
                       (short_ratio >= InpEnsembleThreshold) &&
                       (InpRsiShortMin <= rsi14 && rsi14 < InpRsiShortMax);

   if(long_signal)
   {
      // 基準ストップ価格 (StopPrice_init: 仕様書第5.1章 A.1)
      double stop_price_init = MathMin(lwma60 - InpAtrStopMultiplier * atr14, swing_low);
      double risk_dist = MathMax(close1 - stop_price_init, InpAtrFloorMultiplier * atr14);

      // ロット数計算 (仕様書第6章)
      double lots = CalculateSpecificationLotSize(_Symbol, risk_dist, long_ratio, InpRiskPercent);

      // 2通貨分解クラスタ管理の検証 (仕様書第8章)
      bool cluster_ok = !InpEnableClusterRisk ||
                        ValidateDualCurrencyClusterLimits(_Symbol, POSITION_TYPE_BUY, InpMagicNumber, InpRiskPercent);

      if(lots >= 0.01 && cluster_ok)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl_init = NormalizeDouble(stop_price_init, _Digits);

         // ステップ1: 成行発注 (確定足ベースのStopPrice_initを初期付与: 仕様書第5.1章 B.1)
         if(g_trade.Buy(lots, _Symbol, ask, sl_init, 0.0, InpTradeComment))
         {
            PrintFormat("[Entry] BUY約定送信 (Lot: %.2f | Ask: %.5f | StopInit: %.5f | Ratio: %.2f | Z: %.2f)",
                        lots, ask, sl_init, long_ratio, kalman_zscore);

            // ステップ2: 実約定価格に基づくフロア確定・即時更新 (仕様書第5.1章 B.2)
            Sleep(50); // 約定反映ウェイト
            for(int k = 0; k < PositionsTotal(); k++)
            {
               if(g_position.SelectByIndex(k))
               {
                  if(g_position.Symbol() == _Symbol && g_position.Magic() == InpMagicNumber)
                  {
                     double open_price = g_position.PriceOpen();
                     double hard_sl = MathMin(stop_price_init, open_price - InpAtrFloorMultiplier * atr14);
                     hard_sl = NormalizeDouble(hard_sl, _Digits);

                     if(MathAbs(hard_sl - sl_init) > (0.5 * _Point))
                     {
                        if(g_trade.PositionModify(g_position.Ticket(), hard_sl, 0.0))
                        {
                           PrintFormat("[Step2] ハードSL確定更新 (BUY): OldSL=%.5f -> NewSL=%.5f (OpenPrice: %.5f)",
                                       sl_init, hard_sl, open_price);
                        }
                     }
                     break;
                  }
               }
            }
            g_partial_closed = false;
         }
      }
      else
      {
         PrintFormat("[Entry] BUYシグナル不成立: Lot不足(%.2f) または クラスタ制限超過(%s)",
                     lots, cluster_ok ? "OK" : "NG");
      }
   }
   else if(short_signal)
   {
      // 基準ストップ価格 (StopPrice_init: 仕様書第5.1章 A.1)
      double stop_price_init = MathMax(lwma60 + InpAtrStopMultiplier * atr14, swing_high);
      double risk_dist = MathMax(stop_price_init - close1, InpAtrFloorMultiplier * atr14);

      // ロット数計算 (仕様書第6章)
      double lots = CalculateSpecificationLotSize(_Symbol, risk_dist, short_ratio, InpRiskPercent);

      // 2通貨分解クラスタ管理の検証 (仕様書第8章)
      bool cluster_ok = !InpEnableClusterRisk ||
                        ValidateDualCurrencyClusterLimits(_Symbol, POSITION_TYPE_SELL, InpMagicNumber, InpRiskPercent);

      if(lots >= 0.01 && cluster_ok)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double sl_init = NormalizeDouble(stop_price_init, _Digits);

         // ステップ1: 成行発注 (確定足ベースのStopPrice_initを初期付与: 仕様書第5.1章 B.1)
         if(g_trade.Sell(lots, _Symbol, bid, sl_init, 0.0, InpTradeComment))
         {
            PrintFormat("[Entry] SELL約定送信 (Lot: %.2f | Bid: %.5f | StopInit: %.5f | Ratio: %.2f | Z: %.2f)",
                        lots, bid, sl_init, short_ratio, kalman_zscore);

            // ステップ2: 実約定価格に基づくフロア確定・即時更新 (仕様書第5.1章 B.2)
            Sleep(50); // 約定反映ウェイト
            for(int k = 0; k < PositionsTotal(); k++)
            {
               if(g_position.SelectByIndex(k))
               {
                  if(g_position.Symbol() == _Symbol && g_position.Magic() == InpMagicNumber)
                  {
                     double open_price = g_position.PriceOpen();
                     double hard_sl = MathMax(stop_price_init, open_price + InpAtrFloorMultiplier * atr14);
                     hard_sl = NormalizeDouble(hard_sl, _Digits);

                     if(MathAbs(hard_sl - sl_init) > (0.5 * _Point))
                     {
                        if(g_trade.PositionModify(g_position.Ticket(), hard_sl, 0.0))
                        {
                           PrintFormat("[Step2] ハードSL確定更新 (SELL): OldSL=%.5f -> NewSL=%.5f (OpenPrice: %.5f)",
                                       sl_init, hard_sl, open_price);
                        }
                     }
                     break;
                  }
               }
            }
            g_partial_closed = false;
         }
      }
      else
      {
         PrintFormat("[Entry] SELLシグナル不成立: Lot不足(%.2f) または クラスタ制限超過(%s)",
                     lots, cluster_ok ? "OK" : "NG");
      }
   }

   g_last_bar_time = cur_bar_time;
}
//+------------------------------------------------------------------+

