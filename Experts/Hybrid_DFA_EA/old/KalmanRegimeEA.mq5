//+------------------------------------------------------------------+
//|                                               KalmanRegimeEA.mq5 |
//|                                  Copyright 2026, Quant Research  |
//|               Kalman Filter Regime Estimator Trend Following EA  |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Quant Research"
#property link        "https://www.mql5.com"
#property version     "1.20"
#property description "KalmanRegimeEstimatorのレジーム判定に基づく自動売買EA（サブフォルダ完全対応・テスターキャッシュ自動補正版）"

//--- ストラテジーテスター用インジケーター依存関係の明示（エージェントフォルダへの自動転送）
// バックスラッシュ記法とスラッシュ記法の両方を明示してテスターへのファイル転送を確実に保証
#property tester_indicator "Hybrid_DFA_EA\\KalmanRegimeEstimator.ex5"
#property tester_indicator "Hybrid_DFA_EA/KalmanRegimeEstimator.ex5"
#property tester_indicator "KalmanRegimeEstimator.ex5"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- デフォルト配置パス定義
#define DEFAULT_INDICATOR_PATH "Hybrid_DFA_EA\\KalmanRegimeEstimator"

//--- レジーム定義定数 (インジケーター側と整合)
#define REGIME_UP     1.0    // 上昇トレンド
#define REGIME_DOWN  -1.0    // 下降トレンド
#define REGIME_RANGE  0.0    // レンジ相場

//--- ロット計算方式
enum ENUM_LOT_MODE
{
   LOT_MODE_FIXED,        // 固定ロット
   LOT_MODE_RISK_PERCENT  // 口座残高に対する許容リスク比率 (%)
};

//--- 手仕舞い方式
enum ENUM_EXIT_MODE
{
   EXIT_ON_REGIME_RANGE,  // レジームがレンジ(0.0)に脱落したら即時決済
   EXIT_ON_REVERSAL_ONLY  // 逆方向のトレンドレジーム転換までホールド (ドテンのみ)
};

//+------------------------------------------------------------------+
//| 入力パラメータ                                                   |
//+------------------------------------------------------------------+
input group "=== EA システム設定 ==="
input ulong             InpMagicNumber          = 20260927;       // マジックナンバー
input string            InpTradeComment         = "KalmanRegime"; // 注文コメント
input double            InpMaxSpreadPoints      = 30.0;           // 許容最大スプレッド (Points)
input ulong             InpDeviation            = 10;             // 許容スリッページ (Points)

input group "=== インジケーター接続パラメータ (KalmanRegimeEstimator) ==="
// パラメータ名を InpIndicatorPath に変更してテスターの古いキャッシュを自動リセット
input string            InpIndicatorPath        = DEFAULT_INDICATOR_PATH; // インジケーターパス (Hybrid_DFA_EA\\KalmanRegimeEstimator)
input ENUM_TIMEFRAMES   InpIndicatorTF          = PERIOD_CURRENT; // 計算時間足 (上位足MTF指定可能)
input bool              InpIndAutoTimeframeScale= true;           // 時間足に応じたノイズ自動スケーリング
input bool              InpIndAutoCalibration   = true;           // Rice推定量による解析的自動キャリブレーション
input double            InpIndTargetLagBars     = 10.0;           // ターゲット時定数 (抽出スイング幅: 8〜15本推奨)
input int               InpIndCalibSamples      = 1000;           // 観測ノイズ計測バー数
input double            InpIndManualQMu         = 0.0;            // プロセスノイズ (水準: 手動用)
input double            InpIndManualQBeta       = 1e-8;           // プロセスノイズ (傾き: 手動用)
input double            InpIndManualR           = 1e-4;           // 観測ノイズ (R: 手動用)
input double            InpIndManualInitialP    = 1.0;            // 初期誤差共分散スケール
input double            InpIndZEnter            = 2.0;            // トレンド突入閾値 (|z| >= z_enter)
input double            InpIndZExit             = 1.0;            // トレンド離脱閾値 (|z| <= z_exit)
input bool              InpIndAllowDirectReversal= true;          // 急反転時の即時ドテン許可
input ENUM_APPLIED_PRICE InpIndAppliedPrice     = PRICE_CLOSE;   // 適用価格

input group "=== エントリー / エグジット戦略 ==="
input ENUM_EXIT_MODE    InpExitMode             = EXIT_ON_REGIME_RANGE; // レンジ転落時の手仕舞い方針
input bool              InpAllowReversal        = true;           // 逆シグナル時の即時ドテン決済・エントリー
input double            InpMinSlopeThreshold    = 0.0;            // 傾き(beta)の絶対値下限フィルター (0.0で無効)

input group "=== 資金管理 / 決済パラメータ ==="
input ENUM_LOT_MODE     InpLotMode              = LOT_MODE_FIXED; // ロット計算方式
input double            InpFixedLot             = 0.10;           // 固定ロット数
input double            InpRiskPercent          = 1.0;            // 1トレードあたりの許容リスク (%)
input int               InpATRPeriod            = 14;             // ATR計算期間 (ボラティリティ計測用)
input double            InpSL_ATRFactor         = 2.5;            // ストップロス (ATR倍率: 0.0で無効)
input double            InpTP_ATRFactor         = 0.0;            // テイクプロフィット (ATR倍率: 0.0で無効)
input bool              InpUseTrailingStop      = true;           // ATRトレーリングストップの利用
input double            InpTrail_ATRFactor      = 2.0;            // トレーリング幅 (ATR倍率)

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
CTrade         g_trade;
CPositionInfo  g_position;
int            g_kalman_handle = INVALID_HANDLE;
int            g_atr_handle    = INVALID_HANDLE;
datetime       g_last_bar_time = 0;

//+------------------------------------------------------------------+
//| ロットサイズの動的計算                                           |
//+------------------------------------------------------------------+
double CalculateLotSize(const double stop_loss_points)
{
   if(InpLotMode == LOT_MODE_FIXED || stop_loss_points <= 0.0)
   {
      double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double lots = MathFloor(InpFixedLot / step_lot) * step_lot;
      return MathMax(min_lot, MathMin(max_lot, lots));
   }

   // リスクパーセント方式
   double equity        = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount   = equity * (InpRiskPercent / 100.0);
   double tick_value    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point         = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tick_value <= 0.0 || tick_size <= 0.0 || point <= 0.0)
      return InpFixedLot;

   double loss_per_lot = (stop_loss_points * point / tick_size) * tick_value;
   if(loss_per_lot <= 0.0)
      return InpFixedLot;

   double calc_lots = risk_amount / loss_per_lot;
   double min_lot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   calc_lots = MathFloor(calc_lots / step_lot) * step_lot;
   return MathMax(min_lot, MathMin(max_lot, calc_lots));
}

//+------------------------------------------------------------------+
//| 保有ポジションの決済                                             |
//+------------------------------------------------------------------+
void CloseAllPositions(const ENUM_POSITION_TYPE filter_type = (ENUM_POSITION_TYPE)-1)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_position.SelectByIndex(i))
      {
         if(g_position.Symbol() == _Symbol && g_position.Magic() == InpMagicNumber)
         {
            if((int)filter_type == -1 || g_position.PositionType() == filter_type)
            {
               g_trade.PositionClose(g_position.Ticket(), InpDeviation);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ATRトレーリングストップの更新                                    |
//+------------------------------------------------------------------+
void UpdateTrailingStop(const double current_atr)
{
   if(!InpUseTrailingStop || current_atr <= 0.0 || InpTrail_ATRFactor <= 0.0)
      return;

   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits       = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double trail_dist = current_atr * InpTrail_ATRFactor;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_position.SelectByIndex(i))
      {
         if(g_position.Symbol() == _Symbol && g_position.Magic() == InpMagicNumber)
         {
            ulong  ticket = g_position.Ticket();
            double open_price = g_position.PriceOpen();
            double cur_sl     = g_position.StopLoss();
            double cur_tp     = g_position.TakeProfit();

            if(g_position.PositionType() == POSITION_TYPE_BUY)
            {
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               double new_sl = NormalizeDouble(bid - trail_dist, digits);

               if(new_sl > open_price && (cur_sl == 0.0 || new_sl > cur_sl + (10 * point)))
               {
                  g_trade.PositionModify(ticket, new_sl, cur_tp);
               }
            }
            else if(g_position.PositionType() == POSITION_TYPE_SELL)
            {
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double new_sl = NormalizeDouble(ask + trail_dist, digits);

               if(new_sl < open_price && (cur_sl == 0.0 || new_sl < cur_sl - (10 * point)))
               {
                  g_trade.PositionModify(ticket, new_sl, cur_tp);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| インジケーターハンドル生成ヘルパー関数                           |
//+------------------------------------------------------------------+
int CreateKalmanIndicatorHandle(const string indicator_path)
{
   return iCustom(_Symbol, _Period, indicator_path,
                  // --- Group 1: マルチタイムフレーム (MTF) 設定 ---
                  "=== マルチタイムフレーム (MTF) 設定 ===",
                  InpIndicatorTF,
                  InpIndAutoTimeframeScale,

                  // --- Group 2: 解析的自律キャリブレーション ---
                  "=== 解析的自律キャリブレーション (Closed-Form Analytical) ===",
                  InpIndAutoCalibration,
                  InpIndTargetLagBars,
                  InpIndCalibSamples,

                  // --- Group 3: カルマンフィルター パラメータ ---
                  "=== カルマンフィルター パラメータ (手動設定時またはフォールバック) ===",
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
//| 初期化関数                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   // トレード管理クラスの設定
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviation);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   // テスターの古いキャッシュ（"KalmanRegimeEstimator" 等）が残っている場合の自動補正
   string resolved_path = InpIndicatorPath;
   if(resolved_path == "KalmanRegimeEstimator" || resolved_path == "" || resolved_path == "KalmanRegimeEstimator2")
   {
      resolved_path = DEFAULT_INDICATOR_PATH;
      PrintFormat("[*] パスが '%s' に自動補正されました。", resolved_path);
   }

   // 1. 補正済みパスでインジケーターハンドルの生成を試行
   g_kalman_handle = CreateKalmanIndicatorHandle(resolved_path);

   // 2. 失敗した場合、サブフォルダ／ルート直下の候補をフォールバック探索
   if(g_kalman_handle == INVALID_HANDLE)
   {
      string fallback_candidates[4];
      fallback_candidates[0] = "Hybrid_DFA_EA/KalmanRegimeEstimator";
      fallback_candidates[1] = "Hybrid_DFA_EA\\KalmanRegimeEstimator";
      fallback_candidates[2] = "KalmanRegimeEstimator";
      fallback_candidates[3] = "Hybrid_DFA_EA\\KalmanRegimeEstimator2";

      for(int i = 0; i < 4; i++)
      {
         if(fallback_candidates[i] != resolved_path)
         {
            g_kalman_handle = CreateKalmanIndicatorHandle(fallback_candidates[i]);
            if(g_kalman_handle != INVALID_HANDLE)
            {
               PrintFormat("[+] インジケーター '%s' にて接続に成功しました。", fallback_candidates[i]);
               resolved_path = fallback_candidates[i];
               break;
            }
         }
      }
   }

   if(g_kalman_handle == INVALID_HANDLE)
   {
      int err = GetLastError();
      PrintFormat("[Error] インジケーター '%s' の取得に失敗しました (Error Code: %d)。",
                  resolved_path, err);
      PrintFormat("[Hint] MetaEditorで 'MQL5/Indicators/Hybrid_DFA_EA/KalmanRegimeEstimator.mq5' を開き、F7キーでコンパイルして .ex5 ファイルを生成してください。");
      return(INIT_FAILED);
   }

   // ATR インジケーターハンドルの生成
   g_atr_handle = iATR(_Symbol, _Period, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("[Error] ATRインジケーターの作成に失敗しました。");
      return(INIT_FAILED);
   }

   g_last_bar_time = 0;
   PrintFormat("[+] %s が正常に初期化されました (Magic: %d | TargetLag: %.1f)", 
               _Symbol, InpMagicNumber, InpIndTargetLagBars);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 終了処理関数                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // バックテスト時はインジケータハンドルを解放しない（テスト完了後のチャート上にインジケータ表示を残すため）
   if (!MQLInfoInteger(MQL_TESTER))
   {
      if(g_kalman_handle != INVALID_HANDLE)
      {
         IndicatorRelease(g_kalman_handle);
         g_kalman_handle = INVALID_HANDLE;
      }
      if(g_atr_handle != INVALID_HANDLE)
      {
         IndicatorRelease(g_atr_handle);
         g_atr_handle = INVALID_HANDLE;
      }
   }
}

//+------------------------------------------------------------------+
//| ティック処理イベント関数                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   // 最新ATRの取得
   double atr_buf[1];
   if(CopyBuffer(g_atr_handle, 0, 0, 1, atr_buf) <= 0)
      return;
   double current_atr = atr_buf[0];

   // リアルタイム・トレーリングストップ処理
   UpdateTrailingStop(current_atr);

   // バー確定判定 (シグナル重複発注・未確定足のリペイント防止)
   datetime current_bar_time = iTime(_Symbol, _Period, 0);
   if(current_bar_time == g_last_bar_time)
      return; // 同一バー内では新規発注・レジーム判定をスキップ

   // スプレッドチェック
   long spread_points = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread_points > (long)InpMaxSpreadPoints)
   {
      PrintFormat("[Warning] スプレッド過大 (%d > %.0f Points) のためエントリーを待機します。",
                  spread_points, InpMaxSpreadPoints);
      return;
   }

   // 直前2本の確定バーデータをインジケーターから取得 (shift: 1 と 2)
   // バッファ0: ZScore, バッファ2: Slope(beta), バッファ3: Regime
   double regime_buf[2], slope_buf[2], zscore_buf[2];
   if(CopyBuffer(g_kalman_handle, 3, 1, 2, regime_buf) < 2 ||
      CopyBuffer(g_kalman_handle, 2, 1, 2, slope_buf)  < 2 ||
      CopyBuffer(g_kalman_handle, 0, 1, 2, zscore_buf) < 2)
   {
      return;
   }

   // 配列の最新（shift=1）と1つ前（shift=2）を整理
   double cur_regime  = regime_buf[1];
   double prev_regime = regime_buf[0];
   double cur_slope   = slope_buf[1];
   double cur_zscore  = zscore_buf[1];

   // 現在のポジション保有状況を確認
   bool has_buy  = false;
   bool has_sell = false;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(g_position.SelectByIndex(i))
      {
         if(g_position.Symbol() == _Symbol && g_position.Magic() == InpMagicNumber)
         {
            if(g_position.PositionType() == POSITION_TYPE_BUY)
               has_buy = true;
            else if(g_position.PositionType() == POSITION_TYPE_SELL)
               has_sell = true;
         }
      }
   }

   // =================================================================
   // 1. エグジット（手仕舞い）判定ロジック
   // =================================================================
   if(has_buy)
   {
      bool need_close = false;
      if(InpExitMode == EXIT_ON_REGIME_RANGE && cur_regime == REGIME_RANGE)
         need_close = true;
      else if(cur_regime == REGIME_DOWN)
         need_close = true;

      if(need_close)
      {
         CloseAllPositions(POSITION_TYPE_BUY);
         has_buy = false;
         PrintFormat("[Close] BUYポジション手仕舞い (Regime: %.1f | Z: %.2f)", cur_regime, cur_zscore);
      }
   }

   if(has_sell)
   {
      bool need_close = false;
      if(InpExitMode == EXIT_ON_REGIME_RANGE && cur_regime == REGIME_RANGE)
         need_close = true;
      else if(cur_regime == REGIME_UP)
         need_close = true;

      if(need_close)
      {
         CloseAllPositions(POSITION_TYPE_SELL);
         has_sell = false;
         PrintFormat("[Close] SELLポジション手仕舞い (Regime: %.1f | Z: %.2f)", cur_regime, cur_zscore);
      }
   }

   // =================================================================
   // 2. エントリー（新規建て・ドテン）判定ロジック
   // =================================================================
   bool slope_up_ok   = (cur_slope > InpMinSlopeThreshold);
   bool slope_down_ok = (cur_slope < -InpMinSlopeThreshold);

   // 上昇トレンド突入トリガー
   bool buy_trigger = (cur_regime == REGIME_UP && (prev_regime != REGIME_UP || InpAllowReversal)) && slope_up_ok;

   // 下降トレンド突入トリガー
   bool sell_trigger = (cur_regime == REGIME_DOWN && (prev_regime != REGIME_DOWN || InpAllowReversal)) && slope_down_ok;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // --- BUY エントリー ---
   if(buy_trigger && !has_buy)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl_dist = (InpSL_ATRFactor > 0.0) ? (current_atr * InpSL_ATRFactor) : 0.0;
      double tp_dist = (InpTP_ATRFactor > 0.0) ? (current_atr * InpTP_ATRFactor) : 0.0;

      double sl = (sl_dist > 0.0) ? NormalizeDouble(ask - sl_dist, digits) : 0.0;
      double tp = (tp_dist > 0.0) ? NormalizeDouble(ask + tp_dist, digits) : 0.0;
      double sl_points = (sl_dist > 0.0) ? (sl_dist / point) : 0.0;

      double lots = CalculateLotSize(sl_points);

      if(g_trade.Buy(lots, _Symbol, ask, sl, tp, InpTradeComment))
      {
         PrintFormat("[Entry] BUY約定 (Lot: %.2f | Ask: %.5f | SL: %.5f | TP: %.5f | Z: %.2f | Slope: %.5e)",
                     lots, ask, sl, tp, cur_zscore, cur_slope);
      }
   }
   // --- SELL エントリー ---
   else if(sell_trigger && !has_sell)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl_dist = (InpSL_ATRFactor > 0.0) ? (current_atr * InpSL_ATRFactor) : 0.0;
      double tp_dist = (InpTP_ATRFactor > 0.0) ? (current_atr * InpTP_ATRFactor) : 0.0;

      double sl = (sl_dist > 0.0) ? NormalizeDouble(bid + sl_dist, digits) : 0.0;
      double tp = (tp_dist > 0.0) ? NormalizeDouble(bid - tp_dist, digits) : 0.0;
      double sl_points = (sl_dist > 0.0) ? (sl_dist / point) : 0.0;

      double lots = CalculateLotSize(sl_points);

      if(g_trade.Sell(lots, _Symbol, bid, sl, tp, InpTradeComment))
      {
         PrintFormat("[Entry] SELL約定 (Lot: %.2f | Bid: %.5f | SL: %.5f | TP: %.5f | Z: %.2f | Slope: %.5e)",
                     lots, bid, sl, tp, cur_zscore, cur_slope);
      }
   }

   // 確定足の処理完了を記録
   g_last_bar_time = current_bar_time;
}
//+------------------------------------------------------------------+