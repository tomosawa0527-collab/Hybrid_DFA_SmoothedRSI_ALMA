//+------------------------------------------------------------------+
//|                                        KalmanRegimeEstimator.mq5 |
//|                                  Copyright 2026, Quant Research  |
//|      Log-Price Local Linear Trend Model with Hysteresis Regime   |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Quant Research"
#property link        "https://www.mql5.com"
#property version     "2.40"
#property description "対数価格局所線形トレンドモデルによるカルマンフィルタ・レジーム推定器 (真のO(1)・最適ノイズ比完全版)"
#property indicator_separate_window
#property indicator_buffers 4
#property indicator_plots   1

//--- プロット定義 (Zスコアカラーライン)
#property indicator_label1  "Kalman Z-Score"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrDodgerBlue, clrCrimson, clrDarkGray
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- レジーム定義定数
#define REGIME_UP     1.0    // 上昇トレンド
#define REGIME_DOWN  -1.0    // 下降トレンド
#define REGIME_RANGE  0.0    // レンジ（方向感なし）

//--- カラーバッファ用インデックス
#define COLOR_UP      0      // clrDodgerBlue
#define COLOR_DOWN    1      // clrCrimson
#define COLOR_RANGE   2      // clrDarkGray

//--- 入力パラメータ
input group "=== マルチタイムフレーム (MTF) 設定 ==="
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_CURRENT; // 計算対象タイムフレーム (上位足を指定可能)
input bool            InpAutoTimeframeScale = true;           // 時間足に応じたノイズ自動スケーリング (Δt補正)

input group "=== カルマンフィルター パラメータ (日足基準対数空間) ==="
// 対数空間における最適比率 (Q/R = 1e-5): 日足のR=1e-4に対してQ=1e-9が適正値
// (※Q=1e-9はチューニング要素。1e-5と大きくすると初動を早くできるがトレンドを検知できない)
input double InpQMu                 = 1e-9;       // プロセスノイズ分散 (水準: q_mu, 日足基準)
input double InpQBeta               = 1e-9;       // プロセスノイズ分散 (傾き: q_beta, 日足基準)
input double InpR                   = 1e-4;       // 観測ノイズ分散 (R, 日足基準)
input double InpInitialP            = 1.0;        // 初期誤差共分散 (P0: 対数空間では1.0で十分大)

input group "=== レジーム判定 パラメータ ==="
input double InpZEnter              = 2.0;        // トレンド突入閾値 (|z| >= z_enter)
input double InpZExit               = 1.0;        // トレンド終了閾値 (|z| <= z_exit)
input bool   InpAllowDirectReversal = true;       // 即時ドテンを許可 (UP <-> DOWN 直行)

input group "=== 価格ソース ==="
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // 適用価格

//--- インジケーターバッファ
double BufferZScore[];   // プロット用: Zスコア
double BufferColor[];    // プロット用: カラーインデックス
double BufferSlope[];    // 計算用/EA取得用: 局所的な傾き beta (対数ドリフト率)
double BufferRegime[];   // 計算用/EA取得用: レジーム (+1: UP, -1: DOWN, 0: RANGE)

//--- カルマンフィルターの内部状態構造体
struct KalmanState
{
   double mu;            // 平滑化された対数水準 ln(P)
   double beta;          // 局所的な傾き (1足あたりの期待対数変化率)
   double p00;           // 共分散 P[0,0]
   double p01;           // 共分散 P[0,1]
   double p11;           // 共分散 P[1,1]
   double regime;        // 現在のレジーム状態
   bool   initialized;   // 初期化フラグ
};

// 全履歴バーのカルマン状態保持用配列（シングル足・状態汚染防止）
KalmanState StateHistory[];
double      g_last_valid_price = 0.0; // シングル足用の直前有効価格

// 上位足(MTF)計算用キャッシュバッファ（O(1) 差分更新用）
MqlRates    g_tf_rates[];             // 上位足レートの動的キャッシュ配列 (時系列昇順: 0が最古)
KalmanState g_tf_state_history[];     // 上位足カルマン状態キャッシュ
double      g_tf_slopes[];            // 上位足傾きキャッシュ
double      g_tf_zscores[];           // 上位足Zスコアキャッシュ
double      g_tf_regimes[];           // 上位足レジームキャッシュ
int         g_tf_prev_rates_total = 0;// 上位足の前回計算済みバー数
int         g_last_mapped_tf_idx  = 0;// チャート足へマッピングした直前の確定上位足インデックス
double      g_tf_last_valid_price = 0.0;// 上位足用の直前有効価格 (異常値フォールバック用)

// スケーリング後の実効ノイズパラメータ
double g_scaled_q_mu   = 1e-9;
double g_scaled_q_beta = 1e-9;
double g_scaled_r      = 1e-4;
double g_scaled_p0     = 1.0;
ENUM_TIMEFRAMES g_calc_tf = PERIOD_CURRENT;

//+------------------------------------------------------------------+
//| 適用価格取得ヘルパー関数 (配列参照版: Path A)                     |
//+------------------------------------------------------------------+
double GetAppliedPrice(const ENUM_APPLIED_PRICE applied_price,
                       const double &open[],
                       const double &high[],
                       const double &low[],
                       const double &close[],
                       const int index)
{
   switch(applied_price)
   {
      case PRICE_CLOSE:    return close[index];
      case PRICE_OPEN:     return open[index];
      case PRICE_HIGH:     return high[index];
      case PRICE_LOW:      return low[index];
      case PRICE_MEDIAN:   return (high[index] + low[index]) * 0.5;
      case PRICE_TYPICAL:  return (high[index] + low[index] + close[index]) / 3.0;
      case PRICE_WEIGHTED: return (high[index] + low[index] + close[index] * 2.0) * 0.25;
      default:             return close[index];
   }
}

//+------------------------------------------------------------------+
//| 適用価格取得ヘルパー関数 (MqlRates構造体版: Path B共通化)         |
//+------------------------------------------------------------------+
double GetAppliedPrice(const ENUM_APPLIED_PRICE applied_price,
                       const MqlRates &rate)
{
   switch(applied_price)
   {
      case PRICE_CLOSE:    return rate.close;
      case PRICE_OPEN:     return rate.open;
      case PRICE_HIGH:     return rate.high;
      case PRICE_LOW:      return rate.low;
      case PRICE_MEDIAN:   return (rate.high + rate.low) * 0.5;
      case PRICE_TYPICAL:  return (rate.high + rate.low + rate.close) / 3.0;
      case PRICE_WEIGHTED: return (rate.high + rate.low + rate.close * 2.0) * 0.25;
      default:             return rate.close;
   }
}

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // 入力バリデーション
   if(InpZExit < 0.0)
   {
      Print("[Error] z_exit は 0.0 以上である必要があります。");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpZEnter <= InpZExit)
   {
      Print("[Error] z_enter は z_exit より大きい必要があります (ヒステリシス要件)。");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpQMu <= 0.0 || InpQBeta <= 0.0 || InpR <= 0.0 || InpInitialP <= 0.0)
   {
      Print("[Error] ノイズパラメータおよび初期共分散は正の実数である必要があります。");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // 対象タイムフレームの判定
   g_calc_tf = (InpTimeframe == PERIOD_CURRENT) ? _Period : InpTimeframe;
   if(g_calc_tf < _Period)
   {
      PrintFormat("[Warning] 指定タイムフレーム(%s)がチャート時間足(%s)より下位です。チャート時間足で計算します。",
                  EnumToString(g_calc_tf), EnumToString(_Period));
      g_calc_tf = _Period;
   }

   // 時間足スケーリング (日足=86400秒を基準とした Δt スケーリング)
   if(InpAutoTimeframeScale)
   {
      int tf_seconds = PeriodSeconds(g_calc_tf);
      double dt_scale = (double)tf_seconds / 86400.0; // 日足に対する比率
      if(dt_scale <= 0.0)
         dt_scale = 1.0;

      g_scaled_q_mu   = InpQMu   * dt_scale;
      g_scaled_q_beta = InpQBeta * dt_scale;
      g_scaled_r      = InpR     * dt_scale;
      g_scaled_p0     = InpInitialP * dt_scale;
   }
   else
   {
      g_scaled_q_mu   = InpQMu;
      g_scaled_q_beta = InpQBeta;
      g_scaled_r      = InpR;
      g_scaled_p0     = InpInitialP;
   }

   // バッファマッピング
   SetIndexBuffer(0, BufferZScore, INDICATOR_DATA);
   SetIndexBuffer(1, BufferColor,  INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, BufferSlope,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, BufferRegime, INDICATOR_CALCULATIONS);

   // グローバル状態・MTFキャッシュのリセット
   g_tf_prev_rates_total = 0;
   g_last_mapped_tf_idx  = 0;
   g_tf_last_valid_price = 0.0;
   g_last_valid_price    = 0.0;
   ArrayFree(g_tf_rates);
   ArrayFree(g_tf_state_history);
   ArrayFree(g_tf_slopes);
   ArrayFree(g_tf_zscores);
   ArrayFree(g_tf_regimes);

   // プロット属性
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, 1);
   IndicatorSetInteger(INDICATOR_DIGITS, 2);

   // インジケーター名の設定 (MTF情報を含む)
   string tf_name = StringSubstr(EnumToString(g_calc_tf), 7);
   string short_name = StringFormat("KalmanRegime(LogPrice,%s,Z:%.1f/%.1f)", tf_name, InpZEnter, InpZExit);
   IndicatorSetString(INDICATOR_SHORTNAME, short_name);

   // サブウィンドウの水平レベル線設定
   IndicatorSetInteger(INDICATOR_LEVELS, 5);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 0,  InpZEnter);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 1,  InpZExit);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 2,  0.0);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 3, -InpZExit);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 4, -InpZEnter);

   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 0, STYLE_DOT);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 1, STYLE_DASH);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 2, STYLE_SOLID);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 3, STYLE_DASH);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 4, STYLE_DOT);

   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 0, clrDodgerBlue);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 1, clrCornflowerBlue);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 2, clrDimGray);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 3, clrIndianRed);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 4, clrCrimson);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 1足分のカルマンフィルター更新とヒステリシスレジーム判定         |
//+------------------------------------------------------------------+
void UpdateKalmanStep(const KalmanState &prevState, 
                      const double log_price, 
                      KalmanState &outState, 
                      double &outSlope, 
                      double &outZScore, 
                      double &outRegime)
{
   // 初回足の初期化
   if(!prevState.initialized)
   {
      outState.mu = log_price;
      outState.beta = 0.0;
      outState.p00 = g_scaled_p0;
      outState.p01 = 0.0;
      outState.p11 = g_scaled_p0;
      outState.regime = REGIME_RANGE;
      outState.initialized = true;

      outSlope = 0.0;
      outZScore = 0.0;
      outRegime = REGIME_RANGE;
      return;
   }

   // -------------------------------------------------------------
   // 1. 予測ステップ (Time Update) - スケーリング済みプロセスノイズ適用
   // -------------------------------------------------------------
   double mu_pred   = prevState.mu + prevState.beta;
   double beta_pred = prevState.beta;

   double p00_pred = prevState.p00 + 2.0 * prevState.p01 + prevState.p11 + g_scaled_q_mu;
   double p01_pred = prevState.p01 + prevState.p11;
   double p11_pred = prevState.p11 + g_scaled_q_beta;

   // -------------------------------------------------------------
   // 2. 更新ステップ (Measurement Update) - スケーリング済み観測ノイズ適用
   // -------------------------------------------------------------
   double residual = log_price - mu_pred;
   double s = p00_pred + g_scaled_r;

   double k0 = p00_pred / s;
   double k1 = p01_pred / s;

   outState.mu   = mu_pred + k0 * residual;
   outState.beta = beta_pred + k1 * residual;

   outState.p00 = p00_pred - k0 * p00_pred;
   outState.p01 = p01_pred - k0 * p01_pred;
   outState.p11 = p11_pred - k1 * p01_pred;
   outState.initialized = true;

   // -------------------------------------------------------------
   // 3. 統計量（傾きとZスコア）の算出
   // -------------------------------------------------------------
   outSlope = outState.beta;
   double slope_variance = (outState.p11 > 1e-12) ? outState.p11 : 1e-12;
   outZScore = outSlope / MathSqrt(slope_variance);

   // -------------------------------------------------------------
   // 4. ヒステリシス付きレジーム判定
   // -------------------------------------------------------------
   double current_regime = prevState.regime;

   if(current_regime == REGIME_RANGE)
   {
      if(outZScore >= InpZEnter)
         current_regime = REGIME_UP;
      else if(outZScore <= -InpZEnter)
         current_regime = REGIME_DOWN;
   }
   else if(current_regime == REGIME_UP)
   {
      if(InpAllowDirectReversal && outZScore <= -InpZEnter)
         current_regime = REGIME_DOWN; // 即時ドテン
      else if(outZScore <= InpZExit)
         current_regime = REGIME_RANGE; // レンジ回帰
   }
   else if(current_regime == REGIME_DOWN)
   {
      if(InpAllowDirectReversal && outZScore >= InpZEnter)
         current_regime = REGIME_UP;   // 即時ドテン
      else if(outZScore >= -InpZExit)
         current_regime = REGIME_RANGE; // レンジ回帰
   }

   outState.regime = current_regime;
   outRegime = current_regime;
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < 2)
      return(0);

   // 配列アクセス方向を時系列順（過去=0, 未来=rates_total-1）に統一
   ArraySetAsSeries(time, false);
   ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(BufferZScore, false);
   ArraySetAsSeries(BufferColor, false);
   ArraySetAsSeries(BufferSlope, false);
   ArraySetAsSeries(BufferRegime, false);

   // =================================================================
   // パス A: カレント時間足（シングルタイムフレーム）計算
   // =================================================================
   if(g_calc_tf == _Period)
   {
      if(ArraySize(StateHistory) != rates_total)
      {
         if(ArrayResize(StateHistory, rates_total) < 0)
         {
            Print("[Error] StateHistoryの動的メモリ確保に失敗しました。");
            return(0);
         }
      }

      int start = (prev_calculated > 0) ? prev_calculated - 1 : 0;
      if(start == 0)
      {
         double p0 = GetAppliedPrice(InpAppliedPrice, open, high, low, close, 0);
         g_last_valid_price = (p0 > 0.0) ? p0 : close[0];
      }

      for(int i = start; i < rates_total && !IsStopped(); i++)
      {
         double raw_price = GetAppliedPrice(InpAppliedPrice, open, high, low, close, i);
         // 異常値フェイルセーフ: ゼロや負値なら直前の正常価格を踏襲し、対数スパイクを防止
         if(raw_price <= 0.0)
            raw_price = g_last_valid_price;
         else
            g_last_valid_price = raw_price;

         double log_price = MathLog(raw_price);
         double slope = 0.0, zScore = 0.0, regime = REGIME_RANGE;

         if(i == 0)
         {
            KalmanState emptyState;
            emptyState.initialized = false;
            emptyState.regime = REGIME_RANGE;
            UpdateKalmanStep(emptyState, log_price, StateHistory[i], slope, zScore, regime);
         }
         else
         {
            UpdateKalmanStep(StateHistory[i - 1], log_price, StateHistory[i], slope, zScore, regime);
         }

         BufferZScore[i] = zScore;
         BufferSlope[i]  = slope;
         BufferRegime[i] = regime;
         BufferColor[i]  = (regime == REGIME_UP) ? COLOR_UP : ((regime == REGIME_DOWN) ? COLOR_DOWN : COLOR_RANGE);
      }
      return(rates_total);
   }

   // =================================================================
   // パス B: マルチタイムフレーム (上位足計算 -> チャート足投影) 真のO(1)最適化
   // =================================================================
   int cached_tf_total = ArraySize(g_tf_rates);

   // 1. 上位足データの取得と動的マージ (データ取得層の O(1) 化)
   if(prev_calculated == 0 || cached_tf_total == 0 || g_tf_prev_rates_total == 0)
   {
      // --- 初回またはデータリセット時: チャート足の全期間をカバーする上位足を取得 ---
      ArrayFree(g_tf_rates);
      ArraySetAsSeries(g_tf_rates, false);

      // チャート足の最古時刻から現在までの上位足を取得
      int copied = CopyRates(_Symbol, g_calc_tf, time[0], TimeCurrent() + PeriodSeconds(g_calc_tf), g_tf_rates);
      if(copied < 2)
      {
         // 最古時刻で取れなかった場合のフォールバック (概算必要本数)
         int needed_bars = (int)((rates_total * (long)PeriodSeconds(_Period)) / PeriodSeconds(g_calc_tf)) + 100;
         copied = CopyRates(_Symbol, g_calc_tf, 0, needed_bars, g_tf_rates);
         if(copied < 2)
            return(0); // データ同期待ち
      }
      ArraySetAsSeries(g_tf_rates, false);
      g_tf_prev_rates_total = 0;
      g_last_mapped_tf_idx  = 0;
      g_tf_last_valid_price = 0.0;
   }
   else
   {
      // --- 毎ティック更新時: 直近の数本(3本)のみを取得してキャッシュ末尾にマージ (O(1)) ---
      MqlRates temp_rates[];
      ArraySetAsSeries(temp_rates, false);
      int temp_copied = CopyRates(_Symbol, g_calc_tf, 0, 3, temp_rates);
      if(temp_copied < 2)
         return(0);

      int last_idx = ArraySize(g_tf_rates) - 1;
      datetime last_time = g_tf_rates[last_idx].time;

      // キャッシュ末尾の時刻が取得した3本の中に存在するか照合（ギャップ・欠落検知）
      int match_idx = -1;
      for(int k = 0; k < temp_copied; k++)
      {
         if(temp_rates[k].time == last_time)
         {
            match_idx = k;
            break;
         }
      }

      // キャッシュ末尾と取得データが不連続（2本以上の欠落や時間巻き戻し）の場合、
      // 安全にキャッシュを破棄してフルフェッチへ
      if(match_idx == -1)
      {
         g_tf_prev_rates_total = 0;
         ArrayFree(g_tf_rates);
         return(0);
      }

      // 一致した位置以降（未確定足の価格更新および新足の追加）を安全にマージ
      for(int m = match_idx; m < temp_copied; m++)
      {
         datetime temp_time = temp_rates[m].time;
         last_idx = ArraySize(g_tf_rates) - 1;

         if(temp_time == g_tf_rates[last_idx].time)
         {
            g_tf_rates[last_idx] = temp_rates[m];
         }
         else if(temp_time > g_tf_rates[last_idx].time)
         {
            int new_size = last_idx + 2;
            if(ArrayResize(g_tf_rates, new_size) > 0)
            {
               g_tf_rates[last_idx + 1] = temp_rates[m];
            }
         }
      }
   }

   int tf_rates_total = ArraySize(g_tf_rates);
   if(tf_rates_total < 2)
      return(0);

   if(ArraySize(g_tf_state_history) < tf_rates_total)
   {
      int new_alloc = tf_rates_total + 256;
      if(ArrayResize(g_tf_state_history, new_alloc) < 0 ||
         ArrayResize(g_tf_slopes, new_alloc) < 0 ||
         ArrayResize(g_tf_zscores, new_alloc) < 0 ||
         ArrayResize(g_tf_regimes, new_alloc) < 0)
      {
         return(0);
      }
   }

   // 2. 上位足系列上でカルマンフィルターを増分差分計算 (O(1))
   int tf_start = 0;
   if(prev_calculated > 0 && g_tf_prev_rates_total > 0 && tf_rates_total >= g_tf_prev_rates_total)
   {
      tf_start = g_tf_prev_rates_total - 1;
   }
   else
   {
      tf_start = 0;
      double p0 = GetAppliedPrice(InpAppliedPrice, g_tf_rates[0]);
      g_tf_last_valid_price = (p0 > 0.0) ? p0 : g_tf_rates[0].close;
   }

   for(int k = tf_start; k < tf_rates_total && !IsStopped(); k++)
   {
      double raw_p = GetAppliedPrice(InpAppliedPrice, g_tf_rates[k]);

      if(raw_p <= 0.0)
         raw_p = g_tf_last_valid_price;
      else
         g_tf_last_valid_price = raw_p;

      double log_p = MathLog(raw_p);
      double s = 0.0, z = 0.0, r = REGIME_RANGE;

      if(k == 0)
      {
         KalmanState emptyState;
         emptyState.initialized = false;
         emptyState.regime = REGIME_RANGE;
         UpdateKalmanStep(emptyState, log_p, g_tf_state_history[k], s, z, r);
      }
      else
      {
         UpdateKalmanStep(g_tf_state_history[k - 1], log_p, g_tf_state_history[k], s, z, r);
      }

      g_tf_slopes[k]  = s;
      g_tf_zscores[k] = z;
      g_tf_regimes[k] = r;
   }

   g_tf_prev_rates_total = tf_rates_total;

   // 3. 上位足の計算結果をチャート足（下位足）にステップ状にマッピング (O(1))
   int chart_start = (prev_calculated > 0) ? prev_calculated - 1 : 0;
   int tf_idx = 0;

   if(chart_start > 0 && g_last_mapped_tf_idx >= 0 && g_last_mapped_tf_idx < tf_rates_total)
   {
      tf_idx = g_last_mapped_tf_idx;
      while(tf_idx > 0 && g_tf_rates[tf_idx].time > time[chart_start])
      {
         tf_idx--;
      }
   }
   else
   {
      tf_idx = 0;
   }

   for(int i = chart_start; i < rates_total && !IsStopped(); i++)
   {
      datetime bar_time = time[i];

      while(tf_idx + 1 < tf_rates_total && g_tf_rates[tf_idx + 1].time <= bar_time)
      {
         tf_idx++;
      }

      if(i < rates_total - 1)
      {
         g_last_mapped_tf_idx = tf_idx;
      }

      double zScore = g_tf_zscores[tf_idx];
      double slope  = g_tf_slopes[tf_idx];
      double regime = g_tf_regimes[tf_idx];

      BufferZScore[i] = zScore;
      BufferSlope[i]  = slope;
      BufferRegime[i] = regime;
      BufferColor[i]  = (regime == REGIME_UP) ? COLOR_UP : ((regime == REGIME_DOWN) ? COLOR_DOWN : COLOR_RANGE);
   }

   return(rates_total);
}
//+------------------------------------------------------------------+