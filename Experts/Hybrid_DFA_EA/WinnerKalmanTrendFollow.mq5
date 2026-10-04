//+------------------------------------------------------------------+
//|                                     WinnerKalmanTrendFollow.mq5  |
//|                                  Copyright 2026, Quant Research  |
//|               Strict Trend-Following System based on WinnerCode  |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Quant Research"
#property link        "https://www.mql5.com"
#property version     "1.00"
#property description "カルマンレジーム推定器と移動平均クロスに基づくWinnerCode型トレンドフォロー売買システム"
#property strict

//--- 外部インジケーターハンドル
int g_kalman_handle   = INVALID_HANDLE;
int g_ma_fast_handle  = INVALID_HANDLE;
int g_ma_mid_handle   = INVALID_HANDLE;
int g_ma_slow_handle  = INVALID_HANDLE;
int g_atr_handle      = INVALID_HANDLE;
int g_atr_fast_handle = INVALID_HANDLE;
int g_atr_slow_handle = INVALID_HANDLE;
int g_rsi_handle      = INVALID_HANDLE;

//--- システム状態管理構造体
struct SystemState
{
   bool     armed_buy;
   bool     armed_sell;
   int      armed_bar_counter;
   double   armed_reference_price;
   datetime armed_bar_time_buy;
   datetime armed_bar_time_sell;
   datetime reset_bar_time_buy;
   datetime reset_bar_time_sell;
   datetime last_processed_bar;
   
   // サーキットブレーカー管理変数 (永続化対象)
   int      consecutive_losses;
   int      cooldown_bars_remaining; // 連敗クールダウン残りバー数（確定足ベース）
   double   peak_equity;
   bool     system_halted;
   int      current_month;
   double   month_start_balance;
   bool     monthly_halted;
   int      saved_reset_token;
};
SystemState g_state;

//--- 入力パラメータ宣言
input group "=== システム基本設定 ==="
input ulong           InpMagicNumber             = 20260328;       // マジックナンバー
input double          InpRiskPercent             = 1.0;            // リスク許容率 (%)
input ENUM_TIMEFRAMES InpSystemTF                = PERIOD_H1;      // システム統一タイムフレーム

input group "=== カルマンレジーム推定器設定 ==="
input double          InpTargetLagBars           = 10.0;           // カルマン時定数 (tau)
input double          InpZEnter                  = 2.0;            // レジーム突入閾値
input double          InpZExit                   = 1.0;            // レジーム離脱閾値

input group "=== 移動平均線 & オシレーター設定 ==="
input int             InpFastMAPeriod            = 8;              // 短期LWMA期間
input int             InpMidMAPeriod             = 21;             // 中期EMA期間
input int             InpSlowMAPeriod            = 89;             // 長期SMA期間
input int             InpATRPeriod               = 14;             // 基準ATR期間
input double          InpATRRatioThreshold       = 1.5;            // ATR Ratio 上限 (盾)
input int             InpMaxArmedBars            = 10;             // 待機有効足数 (バー)

input group "=== エグジット & トレーリング設定 ==="
input double          InpTrailingATRMult         = 2.5;            // トレーリングATR乗数

input group "=== サーキットブレーカー & 安全制御 ==="
input int             InpMaxConsecLoss           = 5;              // 連続損失停止回数
input int             InpConsecLossCooldownBars  = 48;             // 連敗クールダウン確定足数 (バー)
input double          InpMaxAccountDD            = 20.0;           // 最大許容DD (%) [永久停止]
input double          InpMaxMonthlyLoss          = 10.0;           // 月間最大許容損失 (%)
input bool            InpNewsFilter              = true;           // 経済指標ブラックアウト有効化
input int             InpNewsMinutes             = 180;            // 指標発表前後停止時間 (分)
input int             InpResetToken              = 0;              // 停止解除用トークン (前回と異なる正の数値で1回実行)

//+------------------------------------------------------------------+
//| 約定充填モード (Filling Mode) の自動判定                         |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return(ORDER_FILLING_FOK);
   if((filling & SYMBOL_FILLING_IOC) != 0) return(ORDER_FILLING_IOC);
   return(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| Pip単位取得関数 (ブローカー桁数自動判定)                         |
//+------------------------------------------------------------------+
double GetPipPoint()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return(_Point * 10.0);
   return(_Point);
}

//+------------------------------------------------------------------+
//| 武装状態の完全初期化 (クリーンアップ)                            |
//+------------------------------------------------------------------+
void ResetArmedState()
{
   g_state.armed_buy             = false;
   g_state.armed_sell            = false;
   g_state.armed_bar_counter     = 0;
   g_state.armed_reference_price = 0.0;
   g_state.armed_bar_time_buy    = 0;
   g_state.armed_bar_time_sell   = 0;
}

//+------------------------------------------------------------------+
//| 自EA保有ポジション数の取得                                       |
//+------------------------------------------------------------------+
int GetOwnPositionsCount()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && 
         PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         count++;
      }
   }
   return(count);
}

//+------------------------------------------------------------------+
//| グローバル変数プレフィックス生成                                 |
//+------------------------------------------------------------------+
string GetPersistentPrefix()
{
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   return StringFormat("WK_%I64d_%I64u_%s_", login, InpMagicNumber, _Symbol);
}

//+------------------------------------------------------------------+
//| グローバル変数による状態永続化 (ディスク強制フラッシュ付)        |
//+------------------------------------------------------------------+
void SavePersistentState()
{
   string prefix = GetPersistentPrefix();
   GlobalVariableSet(prefix + "HALTED", g_state.system_halted ? 1.0 : 0.0);
   GlobalVariableSet(prefix + "CONSEC_LOSS", (double)g_state.consecutive_losses);
   GlobalVariableSet(prefix + "COOLDOWN_BARS", (double)g_state.cooldown_bars_remaining);
   GlobalVariableSet(prefix + "PEAK_EQUITY", g_state.peak_equity);
   GlobalVariableSet(prefix + "MONTH", (double)g_state.current_month);
   GlobalVariableSet(prefix + "MONTH_START", g_state.month_start_balance);
   GlobalVariableSet(prefix + "MONTH_HALTED", g_state.monthly_halted ? 1.0 : 0.0);
   GlobalVariableSet(prefix + "RESET_TOKEN", (double)g_state.saved_reset_token);
   GlobalVariablesFlush(); // クラッシュ耐性のための物理ディスク同期
}

void LoadPersistentState()
{
   string prefix = GetPersistentPrefix();
   if(GlobalVariableCheck(prefix + "HALTED"))
      g_state.system_halted = (GlobalVariableGet(prefix + "HALTED") > 0.5);
   else
      g_state.system_halted = false;

   if(GlobalVariableCheck(prefix + "CONSEC_LOSS"))
      g_state.consecutive_losses = (int)GlobalVariableGet(prefix + "CONSEC_LOSS");
   else
      g_state.consecutive_losses = 0;

   if(GlobalVariableCheck(prefix + "COOLDOWN_BARS"))
      g_state.cooldown_bars_remaining = (int)GlobalVariableGet(prefix + "COOLDOWN_BARS");
   else
      g_state.cooldown_bars_remaining = 0;

   if(GlobalVariableCheck(prefix + "PEAK_EQUITY"))
      g_state.peak_equity = GlobalVariableGet(prefix + "PEAK_EQUITY");
   else
      g_state.peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);

   MqlDateTime dt;
   TimeGMT(dt);
   if(GlobalVariableCheck(prefix + "MONTH"))
      g_state.current_month = (int)GlobalVariableGet(prefix + "MONTH");
   else
      g_state.current_month = dt.mon;

   if(GlobalVariableCheck(prefix + "MONTH_START"))
      g_state.month_start_balance = GlobalVariableGet(prefix + "MONTH_START");
   else
      g_state.month_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(GlobalVariableCheck(prefix + "MONTH_HALTED"))
      g_state.monthly_halted = (GlobalVariableGet(prefix + "MONTH_HALTED") > 0.5);
   else
      g_state.monthly_halted = false;

   if(GlobalVariableCheck(prefix + "RESET_TOKEN"))
      g_state.saved_reset_token = (int)GlobalVariableGet(prefix + "RESET_TOKEN");
   else
      g_state.saved_reset_token = 0;
}

//+------------------------------------------------------------------+
//| カルマンインジケーターハンドル生成ヘルパー                       |
//+------------------------------------------------------------------+
int CreateKalmanHandle()
{
   string candidates[4];
   candidates[0] = "Hybrid_DFA_EA\\KalmanRegimeEstimator";
   candidates[1] = "Indicators\\Hybrid_DFA_EA\\KalmanRegimeEstimator";
   candidates[2] = "Hybrid_DFA_EA/KalmanRegimeEstimator";
   candidates[3] = "KalmanRegimeEstimator";

   for(int i = 0; i < 4; i++)
   {
      // チャート足(_Period)でバインドしつつ、計算時間軸としてInpSystemTFを渡す
      int h = iCustom(_Symbol, _Period, candidates[i],
                      // --- Group 1: マルチタイムフレーム (MTF) 設定 ---
                      "=== マルチタイムフレーム (MTF) 設定 ===",
                      InpSystemTF,
                      true, // InpAutoTimeframeScale

                      // --- Group 2: 解析的自律キャリブレーション ---
                      "=== 解析的自律キャリブレーション (Closed-Form Analytical) ===",
                      true, // InpAutoCalibration
                      InpTargetLagBars,
                      1000, // InpCalibSamples

                      // --- Group 3: カルマンフィルター パラメータ ---
                      "=== カルマンフィルター パラメータ (手動設定時またはフォールバック) ===",
                      0.0,  // InpManualQMu
                      1e-8, // InpManualQBeta
                      1e-4, // InpManualR
                      1.0,  // InpManualInitialP

                      // --- Group 4: レジーム判定 (ヒステリシス) パラメータ ---
                      "=== レジーム判定 (ヒステリシス) パラメータ ===",
                      InpZEnter,
                      InpZExit,
                      true, // InpAllowDirectReversal
                      PRICE_CLOSE);
      if(h != INVALID_HANDLE)
      {
         PrintFormat("[+] KalmanRegimeEstimator ハンドル取得成功: '%s'", candidates[i]);
         return(h);
      }
   }
   return(INVALID_HANDLE);
}

//+------------------------------------------------------------------+
//| 初期化処理                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   if(MQLInfoInteger(MQL_TESTER) && InpNewsFilter)
   {
      Print("[Tester Warning] ストラテジーテスター環境ではMQL5カレンダーAPIが無効なため、経済指標フィルターは機能しません。指標停止を厳密に再現する場合は外部CSV連携が必要です。");
   }

   g_kalman_handle = CreateKalmanHandle();
   if(g_kalman_handle == INVALID_HANDLE)
   {
      Print("[Fatal Error] KalmanRegimeEstimator のロードに失敗しました。");
      return(INIT_FAILED);
   }

   g_ma_fast_handle = iMA(_Symbol, InpSystemTF, InpFastMAPeriod, 0, MODE_LWMA, PRICE_CLOSE);
   g_ma_mid_handle  = iMA(_Symbol, InpSystemTF, InpMidMAPeriod,  0, MODE_EMA,  PRICE_CLOSE);
   g_ma_slow_handle = iMA(_Symbol, InpSystemTF, InpSlowMAPeriod, 0, MODE_SMA,  PRICE_CLOSE);

   g_atr_handle      = iATR(_Symbol, InpSystemTF, InpATRPeriod);
   g_atr_fast_handle = iATR(_Symbol, InpSystemTF, 5);
   g_atr_slow_handle = iATR(_Symbol, InpSystemTF, 20);
   g_rsi_handle      = iRSI(_Symbol, InpSystemTF, 14, PRICE_CLOSE);

   if(g_ma_fast_handle == INVALID_HANDLE || g_ma_mid_handle == INVALID_HANDLE || g_ma_slow_handle == INVALID_HANDLE ||
      g_atr_handle == INVALID_HANDLE || g_atr_fast_handle == INVALID_HANDLE || g_atr_slow_handle == INVALID_HANDLE ||
      g_rsi_handle == INVALID_HANDLE)
   {
      Print("[Fatal Error] 基本インジケーターハンドルの取得に失敗しました。");
      return(INIT_FAILED);
   }

   ResetArmedState();
   g_state.reset_bar_time_buy  = 0;
   g_state.reset_bar_time_sell = 0;
   g_state.last_processed_bar  = 0;

   LoadPersistentState();

   // トークン方式による安全な手動リセット処理
   if(InpResetToken > 0 && InpResetToken != g_state.saved_reset_token)
   {
      g_state.system_halted           = false;
      g_state.monthly_halted          = false;
      g_state.consecutive_losses      = 0;
      g_state.cooldown_bars_remaining = 0;
      g_state.peak_equity             = AccountInfoDouble(ACCOUNT_EQUITY);
      g_state.saved_reset_token       = InpResetToken;
      SavePersistentState();
      PrintFormat("[Circuit Breaker] 新規リセットトークン(%d)を受理。停止状態およびDD基準を1回リセットしました。", InpResetToken);
   }

   if(g_state.system_halted)
      Print("[Init Warning] 永続化された永久停止フラグ(system_halted)が有効です。取引は再開されません。");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // バックテスト時はインジケータハンドルを解放しない（テスト完了後のチャート上にインジケータ表示を残すため）
   if(!MQLInfoInteger(MQL_TESTER))
   {
      if(g_kalman_handle   != INVALID_HANDLE) IndicatorRelease(g_kalman_handle);
      if(g_ma_fast_handle  != INVALID_HANDLE) IndicatorRelease(g_ma_fast_handle);
      if(g_ma_mid_handle   != INVALID_HANDLE) IndicatorRelease(g_ma_mid_handle);
      if(g_ma_slow_handle  != INVALID_HANDLE) IndicatorRelease(g_ma_slow_handle);
      if(g_atr_handle      != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
      if(g_atr_fast_handle != INVALID_HANDLE) IndicatorRelease(g_atr_fast_handle);
      if(g_atr_slow_handle != INVALID_HANDLE) IndicatorRelease(g_atr_slow_handle);
      if(g_rsi_handle      != INVALID_HANDLE) IndicatorRelease(g_rsi_handle);
   }
}

//+------------------------------------------------------------------+
//| 取引履歴イベント監視 (連敗カウント・決済後ステートリセット)      |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal_ticket = trans.deal;
      if(deal_ticket > 0 && HistoryDealSelect(deal_ticket))
      {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
         string symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
         ulong magic   = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);

         if(symbol == _Symbol && magic == InpMagicNumber && (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT))
         {
            double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT)
                          + HistoryDealGetDouble(deal_ticket, DEAL_SWAP)
                          + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);

            if(profit < 0.0)
            {
               g_state.consecutive_losses++;
               PrintFormat("[Trade Closed] 損失確定: %.2f | 連続損失回数: %d / %d",
                           profit, g_state.consecutive_losses, InpMaxConsecLoss);
               
               if(g_state.consecutive_losses >= InpMaxConsecLoss && g_state.cooldown_bars_remaining == 0)
               {
                  g_state.cooldown_bars_remaining = InpConsecLossCooldownBars;
                  PrintFormat("[Circuit Breaker] 連続損失上限到達。確定足ベースのクールダウン(%dバー)を開始します。",
                              InpConsecLossCooldownBars);
               }
            }
            else if(profit > 0.0)
            {
               g_state.consecutive_losses = 0;
               PrintFormat("[Trade Closed] 利益確定: %.2f | 連続損失カウントをリセット", profit);
            }

            SavePersistentState();
            ResetArmedState();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 確定足更新判定                                                   |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime current_bar_time = iTime(_Symbol, InpSystemTF, 0);
   if(current_bar_time != g_state.last_processed_bar)
   {
      g_state.last_processed_bar = current_bar_time;
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| 重要経済指標前の建値移動保護 (保有ポジション常時監視)           |
//+------------------------------------------------------------------+
void CheckNewsBreakevenProtection()
{
   if(!InpNewsFilter || GetOwnPositionsCount() == 0) return;
   if(MQLInfoInteger(MQL_TESTER)) return;

   datetime server_now = TimeTradeServer();
   datetime time_from  = server_now;
   datetime time_to    = server_now + 1800; // 直前30分以内

   MqlCalendarValue values[];
   string currencies[2];
   currencies[0] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   currencies[1] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   for(int c = 0; c < 2; c++)
   {
      ResetLastError();
      int count = CalendarValueHistory(values, time_from, time_to, NULL, currencies[c]);
      if(count > 0)
      {
         for(int i = 0; i < count; i++)
         {
            MqlCalendarEvent event;
            if(CalendarEventById(values[i].event_id, event))
            {
               if(event.importance == CALENDAR_IMPORTANCE_HIGH)
               {
                  for(int p = PositionsTotal() - 1; p >= 0; p--)
                  {
                     ulong ticket = PositionGetTicket(p);
                     if(ticket > 0 && 
                        PositionGetString(POSITION_SYMBOL) == _Symbol && 
                        PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
                     {
                        double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
                        double current_sl = PositionGetDouble(POSITION_SL);
                        ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

                        bool move_be = false;
                        if(ptype == POSITION_TYPE_BUY  && (current_sl < open_price || current_sl == 0.0)) move_be = true;
                        if(ptype == POSITION_TYPE_SELL && (current_sl > open_price || current_sl == 0.0)) move_be = true;

                        if(move_be)
                        {
                           MqlTradeRequest tr_req;
                           MqlTradeResult  tr_res;
                           ZeroMemory(tr_req);
                           ZeroMemory(tr_res);
                           tr_req.action       = TRADE_ACTION_SLTP;
                           tr_req.position     = ticket;
                           tr_req.symbol       = _Symbol;
                           tr_req.magic        = InpMagicNumber;
                           tr_req.sl           = NormalizeDouble(open_price, _Digits);
                           tr_req.tp           = PositionGetDouble(POSITION_TP);
                           tr_req.type_filling = GetFillingMode();
                           if(OrderSend(tr_req, tr_res))
                           {
                              PrintFormat("[News Protection] 重要指標30分前検知。SLを建値に移動: Ticket %I64u", ticket);
                           }
                        }
                     }
                  }
                  return;
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 重要経済指標ブラックアウト判定 (新規エントリー遮断用)            |
//+------------------------------------------------------------------+
bool IsNewsBlackoutActive()
{
   if(!InpNewsFilter) return(false);
   if(MQLInfoInteger(MQL_TESTER)) return(false);

   datetime server_now = TimeTradeServer();
   datetime time_from  = server_now - (InpNewsMinutes * 60);
   datetime time_to    = server_now + (InpNewsMinutes * 60);

   MqlCalendarValue values[];
   string currencies[2];
   currencies[0] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   currencies[1] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   for(int c = 0; c < 2; c++)
   {
      ResetLastError();
      int count = CalendarValueHistory(values, time_from, time_to, NULL, currencies[c]);
      if(count > 0)
      {
         for(int i = 0; i < count; i++)
         {
            MqlCalendarEvent event;
            if(CalendarEventById(values[i].event_id, event))
            {
               if(event.importance == CALENDAR_IMPORTANCE_HIGH)
                  return(true);
            }
         }
      }
   }
   return(false);
}

//+------------------------------------------------------------------+
//| 実需時間窓判定 (発注直前ゲート評価用)                            |
//+------------------------------------------------------------------+
bool CheckTimeWindow()
{
   datetime gmt_time = TimeGMT();
   MqlDateTime gmt_dt;
   TimeToStruct(gmt_time, gmt_dt);

   if(gmt_dt.day_of_week == 6) return(false); // 土曜日
   if(gmt_dt.day_of_week == 5 && gmt_dt.hour >= 21) return(false); // 金曜クローズ前
   if(gmt_dt.day_of_week == 0 && gmt_dt.hour < 21) return(false);  // 日曜オープン前

   bool is_nakane_time = ((gmt_dt.hour == 23 && gmt_dt.min >= 30) || (gmt_dt.hour == 0 && gmt_dt.min <= 55));
   bool is_fix_time = ((gmt_dt.hour == 14 && gmt_dt.min >= 45) || gmt_dt.hour == 15 || (gmt_dt.hour == 16 && gmt_dt.min <= 15));

   if(is_nakane_time || is_fix_time) return(true);

   datetime jst_time = gmt_time + 9 * 3600;
   MqlDateTime jst_dt;
   TimeToStruct(jst_time, jst_dt);

   bool is_tokyo_core_hours = (jst_dt.hour >= 8 && jst_dt.hour < 11);

   if(is_tokyo_core_hours && jst_dt.day_of_week >= 1 && jst_dt.day_of_week <= 5)
   {
      int d   = jst_dt.day;
      int dow = jst_dt.day_of_week;

      bool is_gotobi = false;
      if(d % 5 == 0) is_gotobi = true;
      if(dow == 5 && ((d + 1) % 5 == 0 || (d + 2) % 5 == 0)) is_gotobi = true;

      if(is_gotobi) return(true);

      int days_in_month = 31;
      if(jst_dt.mon == 4 || jst_dt.mon == 6 || jst_dt.mon == 9 || jst_dt.mon == 11) days_in_month = 30;
      else if(jst_dt.mon == 2)
      {
         bool is_leap = ((jst_dt.year % 4 == 0 && jst_dt.year % 100 != 0) || (jst_dt.year % 400 == 0));
         days_in_month = is_leap ? 29 : 28;
      }

      if(d <= 2 || d >= (days_in_month - 1)) return(true);
   }

   return(false);
}

//+------------------------------------------------------------------+
//| 動的ロットサイジング計算 (DynamicLotSizing)                      |
//+------------------------------------------------------------------+
double CalculateDynamicLot(const double sl_distance)
{
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = equity * (InpRiskPercent / 100.0);
   double tick_value  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(sl_distance <= 0.0 || tick_value <= 0.0 || tick_size <= 0.0) return(0.0);

   double loss_per_lot = (sl_distance / tick_size) * tick_value;
   double raw_lot      = risk_amount / loss_per_lot;

   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step_lot <= 0.0) step_lot = 0.01;

   double lot = MathFloor(raw_lot / step_lot) * step_lot;
   if(lot < min_lot) return(0.0);
   if(lot > max_lot) lot = max_lot;

   return(lot);
}

//+------------------------------------------------------------------+
//| 自EAポジション決済処理                                           |
//+------------------------------------------------------------------+
bool CloseAllPositions(const string comment)
{
   bool all_closed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && 
         PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         MqlTradeRequest request;
         MqlTradeResult  result;
         ZeroMemory(request);
         ZeroMemory(result);

         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         request.action       = TRADE_ACTION_DEAL;
         request.position     = ticket;
         request.symbol       = _Symbol;
         request.magic        = InpMagicNumber;
         request.volume       = PositionGetDouble(POSITION_VOLUME);
         request.type         = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         request.price        = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         request.deviation    = 10;
         request.comment      = comment;
         request.type_filling = GetFillingMode();

         if(!OrderSend(request, result) || (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED))
         {
            PrintFormat("[Error] ポジション決済失敗 Ticket: %I64u, RetCode: %u", ticket, result.retcode);
            all_closed = false;
         }
      }
   }
   return(all_closed);
}

//+------------------------------------------------------------------+
//| リトライ機能付き成行発注関数                                     |
//+------------------------------------------------------------------+
bool ExecuteOrderWithRetry(const ENUM_ORDER_TYPE order_type, const double lot, const double sl_dist, const string comment)
{
   int max_retries = 3;
   for(int attempt = 1; attempt <= max_retries; attempt++)
   {
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      double price = (order_type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl    = (order_type == ORDER_TYPE_BUY) ? NormalizeDouble(price - sl_dist, _Digits) : NormalizeDouble(price + sl_dist, _Digits);
      double tp    = (order_type == ORDER_TYPE_BUY) ? NormalizeDouble(price + 5.0 * (sl_dist * 0.5), _Digits) : NormalizeDouble(price - 5.0 * (sl_dist * 0.5), _Digits);

      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.magic        = InpMagicNumber;
      req.volume       = lot;
      req.type         = order_type;
      req.price        = price;
      req.sl           = sl;
      req.tp           = tp;
      req.deviation    = 10;
      req.comment      = comment;
      req.type_filling = GetFillingMode();

      if(OrderSend(req, res))
      {
         if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
         {
            PrintFormat("[Order Executed] 発注成功 Ticket: %I64u, Price: %.5f (試行回数: %d)", res.order, res.price, attempt);
            return(true);
         }
         else
         {
            PrintFormat("[Order Retry Warning] 受理も約定未完了 RetCode: %u (試行: %d/%d)", res.retcode, attempt, max_retries);
         }
      }
      else
      {
         PrintFormat("[Order Error] OrderSend失敗 ErrorCode: %d (試行: %d/%d)", GetLastError(), attempt, max_retries);
      }
      Sleep(200);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| メインティック処理                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // =================================================================
   // 1. 口座保護：永久サーキットブレーカー最優先ゲート
   // =================================================================
   if(g_state.system_halted)
   {
      if(GetOwnPositionsCount() > 0)
         CloseAllPositions("System Halted Close Retry");
      return;
   }

   // ドローダウン計算および永久停止判定
   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(current_equity > g_state.peak_equity)
   {
      g_state.peak_equity = current_equity;
      GlobalVariableSet(GetPersistentPrefix() + "PEAK_EQUITY", g_state.peak_equity);
      static datetime last_peak_flush = 0;
      datetime server_now = TimeTradeServer();
      if(server_now - last_peak_flush >= 30)
      {
         GlobalVariablesFlush(); // ピーク更新の物理ディスク同期
         last_peak_flush = server_now;
      }
   }
   double current_dd = (g_state.peak_equity > 0.0) ? 
                       ((g_state.peak_equity - current_equity) / g_state.peak_equity * 100.0) : 0.0;

   if(current_dd >= InpMaxAccountDD)
   {
      PrintFormat("[Circuit Breaker] 口座保護発動: DD=%.2f%% (上限%.1f%%)。全取引を永久停止します。",
                  current_dd, InpMaxAccountDD);
      CloseAllPositions("CircuitBreaker Permanent Halt");
      g_state.system_halted = true;
      SavePersistentState();
      return;
   }

   // 月間最大損失判定 (月首残高比 10%)
   MqlDateTime dt;
   TimeGMT(dt);
   if(dt.mon != g_state.current_month)
   {
      g_state.current_month       = dt.mon;
      g_state.month_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_state.monthly_halted      = false;
      SavePersistentState();
   }

   if(g_state.month_start_balance > 0.0)
   {
      double monthly_loss = (g_state.month_start_balance - current_equity) / g_state.month_start_balance * 100.0;
      if(monthly_loss >= InpMaxMonthlyLoss)
      {
         if(!g_state.monthly_halted)
         {
            PrintFormat("[Monthly Circuit Breaker] 当月損失限度到達: %.2f%% (上限%.1f%%)。当月末まで取引を凍結します。",
                        monthly_loss, InpMaxMonthlyLoss);
            CloseAllPositions("Monthly Loss Limit Close");
            g_state.monthly_halted = true;
            SavePersistentState();
         }
         return;
      }
   }
   if(g_state.monthly_halted) return;

   // =================================================================
   // 2. 重要経済指標直前 (30分前) の建値保護 (毎ティック・スロットリング監視)
   // =================================================================
   if(GetOwnPositionsCount() > 0)
   {
      static datetime last_news_check = 0;
      datetime server_now = TimeTradeServer();
      if(server_now - last_news_check >= 10)
      {
         CheckNewsBreakevenProtection();
         last_news_check = server_now;
      }
   }

   // =================================================================
   // 3. 確定足（Bar Shift = 1）基準の実行確認
   // =================================================================
   if(!IsNewBar()) return;
   
   // 確定足到達時に連敗クールダウン残りバー数を1減算（市場開場バー数ベース）
   if(g_state.cooldown_bars_remaining > 0)
   {
      g_state.cooldown_bars_remaining--;
      PrintFormat("[Circuit Breaker] 連敗クールダウン経過: 残り %d 確定足", g_state.cooldown_bars_remaining);
      if(g_state.cooldown_bars_remaining == 0)
      {
         Print("[Circuit Breaker] 連敗クールダウン満了。取引待機状態を解除します。");
         g_state.consecutive_losses = 0;
      }
   }

   SavePersistentState();

   datetime current_bar_time = iTime(_Symbol, InpSystemTF, 1);

   // 動的配列として宣言（静的配列 double arr[2] では ArraySetAsSeries が false となり機能しないため）
   double regime[], slope[];
   ArraySetAsSeries(regime, true);
   ArraySetAsSeries(slope,  true);
   if(CopyBuffer(g_kalman_handle, 3, 1, 2, regime) <= 0 || CopyBuffer(g_kalman_handle, 2, 1, 2, slope) <= 0) return;

   double ma_fast[], ma_mid[], ma_slow[];
   ArraySetAsSeries(ma_fast, true);
   ArraySetAsSeries(ma_mid,  true);
   ArraySetAsSeries(ma_slow, true);
   if(CopyBuffer(g_ma_fast_handle, 0, 1, 2, ma_fast) <= 0 ||
      CopyBuffer(g_ma_mid_handle,  0, 1, 2, ma_mid)  <= 0 ||
      CopyBuffer(g_ma_slow_handle, 0, 1, 2, ma_slow) <= 0) return;

   double atr[], atr_fast[], atr_slow[], rsi[];
   ArraySetAsSeries(atr,      true);
   ArraySetAsSeries(atr_fast, true);
   ArraySetAsSeries(atr_slow, true);
   ArraySetAsSeries(rsi,      true);
   if(CopyBuffer(g_atr_handle,      0, 1, 1, atr)      <= 0 ||
      CopyBuffer(g_atr_fast_handle, 0, 1, 1, atr_fast) <= 0 ||
      CopyBuffer(g_atr_slow_handle, 0, 1, 1, atr_slow) <= 0 ||
      CopyBuffer(g_rsi_handle,      0, 1, 1, rsi)      <= 0) return;

   // ArraySetAsSeries(arr, true) により [0] が直前確定足(shift 1), [1] が前々回確定足(shift 2)
   double current_regime = regime[0];
   double current_slope  = slope[0];
   double current_atr    = atr[0];
   double atr_ratio      = (atr_slow[0] > 0.0) ? (atr_fast[0] / atr_slow[0]) : 2.0;

   // =================================================================
   // 4. ポジション保有中のエグジット管理 (自EA 1ポジション厳守)
   //    ※損小利大を破壊する短期MA逆クロス決済は撤廃し、トレーリングとレジームに一本化
   // =================================================================
   if(GetOwnPositionsCount() > 0)
   {
      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && 
            PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

            // A. レジーム離脱・反転判定 (大局トレンドの消失・逆転)
            if(pos_type == POSITION_TYPE_BUY && current_regime <= 0.5)
            {
               CloseAllPositions("Regime Exit Buy");
               ResetArmedState();
               return;
            }
            if(pos_type == POSITION_TYPE_SELL && current_regime >= -0.5)
            {
               CloseAllPositions("Regime Exit Sell");
               ResetArmedState();
               return;
            }

            // B. シャンデリアトレーリング更新 (利益伸長追従)
            double current_sl = PositionGetDouble(POSITION_SL);
            double stop_level = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

            if(pos_type == POSITION_TYPE_BUY)
            {
               double highest = iHigh(_Symbol, InpSystemTF, 1);
               double new_sl  = highest - InpTrailingATRMult * current_atr;
               double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

               // ストップレベル違反および現在価格以上のSL設置防止
               if(new_sl < (bid - stop_level) && (new_sl > current_sl || current_sl == 0.0))
               {
                  MqlTradeRequest tr_req;
                  MqlTradeResult  tr_res;
                  ZeroMemory(tr_req);
                  ZeroMemory(tr_res);
                  tr_req.action       = TRADE_ACTION_SLTP;
                  tr_req.position     = ticket;
                  tr_req.symbol       = _Symbol;
                  tr_req.magic        = InpMagicNumber;
                  tr_req.sl           = NormalizeDouble(new_sl, _Digits);
                  tr_req.tp           = PositionGetDouble(POSITION_TP);
                  if(!OrderSend(tr_req, tr_res) || (tr_res.retcode != TRADE_RETCODE_DONE && tr_res.retcode != TRADE_RETCODE_PLACED))
                  {
                     PrintFormat("[Trailing Warning] 買いSL更新失敗 Ticket: %I64u, RetCode: %u", ticket, tr_res.retcode);
                  }
               }
            }
            else if(pos_type == POSITION_TYPE_SELL)
            {
               double lowest = iLow(_Symbol, InpSystemTF, 1);
               double new_sl = lowest + InpTrailingATRMult * current_atr;
               double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

               // ストップレベル違反および現在価格以下のSL設置防止
               if(new_sl > (ask + stop_level) && (new_sl < current_sl || current_sl == 0.0))
               {
                  MqlTradeRequest tr_req;
                  MqlTradeResult  tr_res;
                  ZeroMemory(tr_req);
                  ZeroMemory(tr_res);
                  tr_req.action       = TRADE_ACTION_SLTP;
                  tr_req.position     = ticket;
                  tr_req.symbol       = _Symbol;
                  tr_req.magic        = InpMagicNumber;
                  tr_req.sl           = NormalizeDouble(new_sl, _Digits);
                  tr_req.tp           = PositionGetDouble(POSITION_TP);
                  tr_req.type_filling = GetFillingMode();
                  if(!OrderSend(tr_req, tr_res) || (tr_res.retcode != TRADE_RETCODE_DONE && tr_res.retcode != TRADE_RETCODE_PLACED))
                  {
                     PrintFormat("[Trailing Warning] 売りSL更新失敗 Ticket: %I64u, RetCode: %u", ticket, tr_res.retcode);
                  }
               }
            }
         }
      }
      return;
   }

   // 連敗クールダウン判定フラグ (新規発注のみブロック、ステートマシン更新は継続)
   bool cooldown_active = (g_state.cooldown_bars_remaining > 0);

   // =================================================================
   // 5. ステートマシン管理 (時間窓外でも確定足ごとに24時間常時更新)
   // =================================================================
   // A. 環境崩壊による失効
   if(g_state.armed_buy && (current_regime < 0.5 || current_slope <= 0.0))
   {
      g_state.armed_buy = false;
      g_state.reset_bar_time_buy = current_bar_time;
   }
   if(g_state.armed_sell && (current_regime > -0.5 || current_slope >= 0.0))
   {
      g_state.armed_sell = false;
      g_state.reset_bar_time_sell = current_bar_time;
   }

   // B. タイムアウト更新
   if(g_state.armed_buy || g_state.armed_sell)
   {
      g_state.armed_bar_counter++;
      if(g_state.armed_bar_counter > InpMaxArmedBars)
      {
         if(g_state.armed_buy)  { g_state.armed_buy = false;  g_state.reset_bar_time_buy = current_bar_time; }
         if(g_state.armed_sell) { g_state.armed_sell = false; g_state.reset_bar_time_sell = current_bar_time; }
      }
   }

   double close1 = iClose(_Symbol, InpSystemTF, 1);

   // C. 第3段階：発火条件判定 (※時間窓および構造フィルターは発注直前ゲートとしてのみ評価)
   if(g_state.armed_buy && g_state.armed_bar_time_buy != current_bar_time)
   {
      if(close1 < g_state.armed_reference_price - 1.5 * current_atr)
      {
         g_state.armed_buy = false;
         g_state.reset_bar_time_buy = current_bar_time;
         return;
      }
      if(MathAbs(close1 - ma_slow[0]) <= 3.0 * current_atr)
      {
         // 真のゴールデンクロス判定: shift 2 で fast <= mid かつ shift 1 で fast > mid
         if(ma_fast[1] <= ma_mid[1] && ma_fast[0] > ma_mid[0])
         {
            // === 発注直前ゲート（クールダウン・指標・時間窓・盾・スプレッド） ===
            double pip_point   = GetPipPoint();
            double spread_dist = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
            double spread_pips = (pip_point > 0.0) ? (spread_dist / pip_point) : 0.0;

            if(!cooldown_active && 
               !IsNewsBlackoutActive() && 
               CheckTimeWindow() && 
               atr_ratio <= InpATRRatioThreshold && 
               spread_dist <= 1.5 * current_atr && spread_pips <= 2.0)
            {
               double sl_dist = 2.0 * current_atr;
               double lot     = CalculateDynamicLot(sl_dist);
               if(lot > 0.0)
               {
                  if(ExecuteOrderWithRetry(ORDER_TYPE_BUY, lot, sl_dist, "WinnerKalman Buy"))
                  {
                     ResetArmedState();
                     return;
                  }
               }
            }
         }
      }
   }
   else if(g_state.armed_sell && g_state.armed_bar_time_sell != current_bar_time)
   {
      if(close1 > g_state.armed_reference_price + 1.5 * current_atr)
      {
         g_state.armed_sell = false;
         g_state.reset_bar_time_sell = current_bar_time;
         return;
      }
      if(MathAbs(close1 - ma_slow[0]) <= 3.0 * current_atr)
      {
         // 真のデッドクロス判定: shift 2 で fast >= mid かつ shift 1 で fast < mid
         if(ma_fast[1] >= ma_mid[1] && ma_fast[0] < ma_mid[0])
         {
            // === 発注直前ゲート（クールダウン・指標・時間窓・盾・スプレッド） ===
            double pip_point   = GetPipPoint();
            double spread_dist = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
            double spread_pips = (pip_point > 0.0) ? (spread_dist / pip_point) : 0.0;

            if(!cooldown_active && 
               !IsNewsBlackoutActive() && 
               CheckTimeWindow() && 
               atr_ratio <= InpATRRatioThreshold && 
               spread_dist <= 1.5 * current_atr && spread_pips <= 2.0)
            {
               double sl_dist = 2.0 * current_atr;
               double lot     = CalculateDynamicLot(sl_dist);
               if(lot > 0.0)
               {
                  if(ExecuteOrderWithRetry(ORDER_TYPE_SELL, lot, sl_dist, "WinnerKalman Sell"))
                  {
                     ResetArmedState();
                     return;
                  }
               }
            }
         }
      }
   }

   // D. 第1段階 ＆ 第2段階：環境認識と待機状態 (armed) への移行 (時間窓外でも常時評価)
   if(!g_state.armed_buy && g_state.reset_bar_time_buy != current_bar_time)
   {
      // ma_slow[0] > ma_slow[1] は shift 1 > shift 2 (上向き傾き)
      if(current_regime > 0.5 && current_slope > 0.0 && ma_slow[0] > ma_slow[1])
      {
         if((close1 < ma_fast[0] || ma_fast[0] < ma_mid[0]) && (rsi[0] >= 40.0 && rsi[0] <= 60.0))
         {
            g_state.armed_buy             = true;
            g_state.armed_bar_counter     = 0;
            g_state.armed_bar_time_buy    = current_bar_time;
            g_state.armed_reference_price = close1;
         }
      }
   }

   if(!g_state.armed_sell && g_state.reset_bar_time_sell != current_bar_time)
   {
      // ma_slow[0] < ma_slow[1] は shift 1 < shift 2 (下向き傾き)
      if(current_regime < -0.5 && current_slope < 0.0 && ma_slow[0] < ma_slow[1])
      {
         if((close1 > ma_fast[0] || ma_fast[0] > ma_mid[0]) && (rsi[0] >= 40.0 && rsi[0] <= 60.0))
         {
            g_state.armed_sell            = true;
            g_state.armed_bar_counter     = 0;
            g_state.armed_bar_time_sell   = current_bar_time;
            g_state.armed_reference_price = close1;
         }
      }
   }
}
//+------------------------------------------------------------------+
