# カルマンフィルターによる局所トレンド・傾き検知とレジーム推定 MQL5技術仕様書

## 1. 概要と設計思想

従来のテクニカル指標（ADX、移動平均乖離、MACDなど）は、過去バーの平滑化に起因する**不可避な位相遅延（タイムラグ）**を抱えており、相場の急変・転換初動での出遅れや、レンジ相場での往復ビンタ（Whipsaw）が構造的な弱点でした。

本システムでは、時系列計量経済学における**平滑トレンドモデル（Smooth Trend Model / Integrated Random Walk）**を採用し、価格系列を「真の平滑化水準（$\mu$）」と「局所的な変化率・速度（傾き $\beta$）」にリアルタイム分解します。カルマンフィルターの逐次ベイズ更新により、ラグを極小に抑えつつノイズを除去し、同時に得られる**傾きの推定誤差共分散（不確実性 $P_{11}$）**を用いて統計的有意性に基づくレジーム判定を行います。

### 本バージョンの技術的特徴
* **実データ駆動によるRice二階差分ノイズ推定量（Rice's Estimator, Rice 1984）**:
  金融時系列において純粋な最尤推定（MLE）が陥る「パイルアップ退化（$q_\beta \to 0$）」および「超高周波過剰適合（$q_\beta \to \text{大}, \tau \to 1.2$本）」を完全に克服。二階差分 $\Delta^2 y_t$ によって低周波トレンドを数学的に消去し、対象銘柄の純粋な観測ノイズ分散 $R$ を直接計測。
* **周波数極配置による解析解導出（Closed-Form Analytical Solution, Harvey & Jaeger 1993）**:
  Hodrick-Prescottフィルターやスプライン平滑化と同値な極配置理論に基づき、抽出したいトレンド時定数 $\tau$（デフォルト: 10本）から、傾きノイズ分散を閉じた式 $q_\beta = \frac{R}{\tau^4}$ で瞬時に逆算。反復探索アルゴリズムの収束失敗や初期値依存性を完全排除（計算時間: 0 ms）。
* **対数価格空間（Log-Price: $\ln(P_t)$）への一本化**:
  幾何ブラウン運動（GBM）の連続複利リターン空間でカルマン更新を行うことで、USDJPY（150円台）やEURUSD（1.08台）などの価格スケール差を根本的に解消。
* **真の $\mathcal{O}(1)$ MTF（マルチタイムフレーム）キャッシュアーキテクチャ**:
  上位足データの増分取得（`CopyRates` 差分マージ）、不連続ギャップ検知フェイルセーフ、およびステップマッピングのインデックス継続により、毎ティックの計算量を完全な定数時間 $\mathcal{O}(1)$ で実現。

---

## 2. 状態空間モデルの定式化（平滑トレンドモデル）

### (1) 状態空間方程式

観測値 $y_t$ を市場価格の自然対数 $y_t = \ln(P_t)$ と定義します。直接観測できない2次元の状態ベクトル $x_t$ を仮定します。

$$
x_t = \begin{bmatrix} \mu_t \\ \beta_t \end{bmatrix}
$$

* $\mu_t$: 時点 $t$ における真の対数価格水準
* $\beta_t$: 時点 $t$ における局所的な対数傾き（1足あたりの連続複利リターン速度）

#### 状態方程式（$q_\mu = 0$ 制約）
$$
\begin{bmatrix} \mu_t \\ \beta_t \end{bmatrix}
= \begin{bmatrix} 1 & 1 \\ 0 & 1 \end{bmatrix} \begin{bmatrix} \mu_{t-1} \\ \beta_{t-1} \end{bmatrix} + \begin{bmatrix} 0 \\ w_{\beta, t} \end{bmatrix}, \quad
w_{\beta, t} \sim \mathcal{N}(0, q_\beta)
$$

* 状態遷移行列: $F = \begin{bmatrix} 1 & 1 \\ 0 & 1 \end{bmatrix}$
* プロセスノイズ共分散行列: $Q = \begin{bmatrix} 0 & 0 \\ 0 & q_\beta \end{bmatrix}$

#### 観測方程式
$$
y_t = \begin{bmatrix} 1 & 0 \end{bmatrix} \begin{bmatrix} \mu_t \\ \beta_t \end{bmatrix} + v_t, \quad v_t \sim \mathcal{N}(0, R)
$$

* 観測行列: $H = \begin{bmatrix} 1 & 0 \end{bmatrix}$
* 観測ノイズ分散: $R$

---

## 3. 解析的自律キャリブレーションの数理的根拠

### ステップ 1: Riceの二階差分分散推定量（観測ノイズ $R$ の直接計測）
観測モデル $y_t = \mu_t + v_t$（ただし $v_t \sim \text{i.i.d.} \mathcal{N}(0, R)$）に対し、二階差分 $\Delta^2 y_t$ を取ります。

$$
\Delta^2 y_t = y_t - 2y_{t-1} + y_{t-2} = \Delta^2 \mu_t + (v_t - 2v_{t-1} + v_{t-2})
$$

平滑トレンドにおいて局所線形性は高く $\Delta^2 \mu_t \approx 0$ であるため、二階差分の分散は純粋な観測ノイズの二項係数二乗和に帰着します。

$$
\text{Var}(\Delta^2 y_t) \approx \text{Var}(v_t - 2v_{t-1} + v_{t-2}) = (1^2 + (-2)^2 + 1^2) R = 6R
$$

したがって、対象銘柄の過去ヒストリカルデータから観測ノイズ分散 $R$ は以下の閉じた式で一意に求まります。

$$
\hat{R} = \frac{1}{6(N-2)} \sum_{t=2}^{N-1} (y_t - 2y_{t-1} + y_{t-2})^2
$$

### ステップ 2: 極配置解析解（傾きノイズ $q_\beta$ の導出）
平滑トレンドカルマンフィルターにおける伝達関数のカットオフ特性およびHodrick-Prescott平滑化パラメータ $\lambda$ と実効時定数（半値幅） $\tau$ の関係式（Harvey & Jaeger 1993）より：

$$
\lambda = \frac{R}{q_\beta} = \tau^4 \quad \Longrightarrow \quad q_\beta = \frac{R}{\tau^4}
$$

トレーダーが監視したいスイングの波長（デフォルト: $\tau = 10.0$ 本）を指定するだけで、**対象銘柄の実測ボラティリティ（$R$）に応じた最適な傾きノイズ $q_\beta$ が閉じた代数式で一意に導出**されます。

---

## 4. 設計上の留意事項：平滑トレンドモデル（$q_\mu = 0$）と価格ジャンプ

本モデルは水準ノイズを厳密にゼロ（$q_\mu = 0$）に固定することで、純粋MLEのパイルアップ退化を回避し、美しい連続平滑トレンドを抽出しています。
この設計には以下の既知の数理的特性（トレードオフ）が存在します。

### (1) 価格ジャンプ（重要指標発表・窓開け）の吸収挙動
雇用統計や政策金利発表などで価格が瞬時に数円飛んだ場合、$q_\mu = 0$ であるため、モデルはそれを「水準の不連続ワープ」として即座に受け入れることができません。
ジャンプ直後は、その価格ギャップが**「急激な観測残差 $e_t$」を経て「傾き $\beta$ の一時的な急伸」および「観測ノイズ $R$」として分散吸収**されます。

### (2) 実運用上のメリットと注意点
* **メリット**: 単発のヒゲ（フラッシュクラッシュやすぐに全戻しされる突発スパイク）に対して、水準が過敏に飛びつかず、トレンドの基調を安定して維持できます。
* **注意点**: 恒久的な窓開けや不可逆なトレンド転換を伴う急変が起きた場合、数本（設定時定数 $\tau$ の数分の一程度）の遅延を伴いながら傾き $\beta$ が急激に立ち上がります。指標トレードのような超短期瞬発系ではなく、数日〜数週間のスイングトレンドを切り取る用途に最適化されています。

---

## 5. 逐次更新アルゴリズム（MQL5向けスカラー展開）

観測行列が $H = \begin{bmatrix} 1 & 0 \end{bmatrix}$ であるため、行列演算をすべて初等代数（スカラー四則演算）へ陽に展開します。

### ステップ 1: 予測ステップ (Time Update)
$$
\mu_{t|t-1} = \mu_{t-1|t-1} + \beta_{t-1|t-1}
$$
$$
\beta_{t|t-1} = \beta_{t-1|t-1}
$$
$$
P_{00, \text{pred}} = P_{00} + 2 P_{01} + P_{11} \quad (q_\mu = 0)
$$
$$
P_{01, \text{pred}} = P_{01} + P_{11}
$$
$$
P_{11, \text{pred}} = P_{11} + q_\beta
$$

### ステップ 2: 更新ステップ (Measurement Update)
$$
e_t = y_t - \mu_{t|t-1} \quad (\text{観測残差})
$$
$$
S_t = P_{00, \text{pred}} + R \quad (\text{残差分散})
$$
$$
K_0 = \frac{P_{00, \text{pred}}}{S_t}, \quad K_1 = \frac{P_{01, \text{pred}}}{S_t} \quad (\text{カルマンゲイン})
$$
$$
\mu_{t|t} = \mu_{t|t-1} + K_0 e_t
$$
$$
\beta_{t|t} = \beta_{t|t-1} + K_1 e_t
$$
$$
P_{00} = P_{00, \text{pred}} - K_0 P_{00, \text{pred}}
$$
$$
P_{01} = P_{01, \text{pred}} - K_0 P_{01, \text{pred}}
$$
$$
P_{11} = P_{11, \text{pred}} - K_1 P_{01, \text{pred}}
$$

---

## 6. レジーム判定ロジックとヒステリシス設計

### (1) 標準化モメンタム強度スコア（$z$ スコア）
$$
z_t = \frac{\hat{\beta}_t}{\sqrt{\text{Var}(\hat{\beta}_t)}} = \frac{\beta_{t|t}}{\sqrt{\max(P_{11}, 10^{-15})}}
$$

### (2) 2段階ヒステリシス状態遷移マシン（不感帯制御）
微小な揺らぎによる境界線チャタリングを遮断するため、突入閾値（`InpZEnter`）と離脱閾値（`InpZExit`）を分離します（制約: $z_{\text{enter}} > z_{\text{exit}} \ge 0$）。

```
                ┌─────────────────────────────────┐
                │          z >= z_enter           │
                ▼                                 │
         ┌─────────────┐                          │
         │             │       z <= z_exit        │
         │  UP_TREND   │─────────────────────┐    │
         │   (+1.0)    │                     ▼    │
         └─────────────┘               ┌───────────┐
             ▲     │                   │           │
             │     │ Direct Reversal   │   RANGE   │
             │     │ (z <= -z_enter)   │   (0.0)   │
             │     ▼                   └───────────┘
             │  ┌─────────────┐              ▲    │
             │  │             │              │    │
             │  │ DOWN_TREND  │──────────────┘    │
             │  │   (-1.0)    │  z >= -z_exit     │
             │  └─────────────┘                   │
             │         │                          │
             └─────────┴──────────────────────────┘
              Direct Reversal        z <= -z_enter
              (z >= z_enter)
```

---

## 7. エキスパートアドバイザー（EA）連携仕様

### インジケーターバッファ構成
| バッファ番号 | タイプ | プロット名 | 格納データ / 役割 | EA利用 |
| :---: | :---: | :---: | :--- | :---: |
| **0** | `INDICATOR_DATA` | Kalman Z-Score | 標準化モメンタム強度スコア $z_t$ | 可 |
| **1** | `INDICATOR_COLOR_INDEX` | Color Index | 描画色（0: 青 / UP, 1: 赤 / DOWN, 2: 灰 / RANGE） | 可 |
| **2** | `INDICATOR_CALCULATIONS` | Slope ($\beta$) | 推定対数傾き（1足あたりの対数リターン速度） | **推奨** |
| **3** | `INDICATOR_CALCULATIONS` | Regime | レジーム値（`1.0`: UP, `-1.0`: DOWN, `0.0`: RANGE） | **推奨** |

### EAからの呼び出し実装テンプレート
```cpp
//+------------------------------------------------------------------+
//|                                              KalmanRegimeEA.mq5  |
//+------------------------------------------------------------------+
#property strict

int g_kalman_handle = INVALID_HANDLE;

int OnInit()
{
   // インジケーター名 "KalmanRegimeEstimator" を指定して呼び出し
   g_kalman_handle = iCustom(_Symbol, _Period, "KalmanRegimeEstimator",
                             PERIOD_CURRENT, // InpTimeframe
                             true,           // InpAutoTimeframeScale
                             true,           // InpAutoCalibration (解析的自律キャリブレーション)
                             10.0,           // InpTargetLagBars (ターゲット時定数: 10本)
                             1000,           // InpCalibSamples
                             0.0,            // InpManualQMu
                             1e-8,           // InpManualQBeta
                             1e-4,           // InpManualR
                             1.0,            // InpManualInitialP
                             2.0,            // InpZEnter
                             1.0,            // InpZExit
                             true,           // InpAllowDirectReversal
                             PRICE_CLOSE);

   if(g_kalman_handle == INVALID_HANDLE)
   {
      Print("[Error] インジケーターハンドルの作成に失敗しました。ファイル名が 'KalmanRegimeEstimator.ex5' であるか確認してください。");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_kalman_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_kalman_handle);
      g_kalman_handle = INVALID_HANDLE;
   }
}

void OnTick()
{
   // 直前確定足 (shift = 1) のデータを取得
   double regime[1], z_score[1], slope[1];

   if(CopyBuffer(g_kalman_handle, 3, 1, 1, regime) <= 0 ||
      CopyBuffer(g_kalman_handle, 0, 1, 1, z_score) <= 0 ||
      CopyBuffer(g_kalman_handle, 2, 1, 1, slope) <= 0)
   {
      return;
   }

   double current_regime = regime[0];
   double current_z      = z_score[0];
   double current_slope  = slope[0]; // 対数リターン/足 (例: +0.002 = +0.2%/足)

   if(current_regime == 1.0)
   {
      // 【上昇トレンドレジーム】押し目買いエントリー / 空売りポジション手仕舞い
   }
   else if(current_regime == -1.0)
   {
      // 【下降トレンドレジーム】戻り売りエントリー / 買いポジション手仕舞い
   }
   else
   {
      // 【レンジ相場レジーム (0.0)】トレンドフォロー停止 / 平均回帰戦略
   }
}