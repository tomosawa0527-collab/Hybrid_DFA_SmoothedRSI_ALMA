# **カルマンフィルターによる局所トレンド・傾き検知とレジーム推定 MQL5技術仕様書 (完全因果的ローリングRice推定量版)**

## **1\. 概要と設計思想**

従来のテクニカル指標や静的な適応フィルターは、全期間に単一のパラメータを一律適用するか、インジケーター起動時点の現在データから求めたパラメータを数年前の過去足にも適用する「先読みバイアス（Look-Ahead Bias / 未来情報リーク）」を構造的に抱えていました。  
本システムでは、時系列計量経済学における平滑トレンドモデル（Smooth Trend Model / Integrated Random Walk）**に、**「確定足ローリングRice推定量 ＋ 現在足リアルタイム追従」**の完全分離アーキテクチャを導入。 各バー t において、**「直前確定足（Bar 1）までの過去 W 本のデータのみ」を用いて観測ノイズ R\_t を安定計測し、極配置解析解 q\_{\\beta, t} \= \\frac{R\_t}{\\tau^4} によって傾きプロセスノイズを動的更新します。**現在バーの突発的なティック変動によるパラメータ汚染を完全に遮断しながら、カルマン状態推定はリアルタイムに追従**します。

### **本バージョンの技術的特徴**

> * **完全な因果性（先読みバイアスの徹底排除）**: 過去バーの計算では、そのバー時点の過去 W 本のみを参照。未来のボラティリティ水準が過去の計算に漏洩することは物理的に一切ありません。ライブ増分計算とバックテスト/チャート再読み込みで、数学的に100%同一の結果が再現されます。  
> * **確定足キャリブレーション ＋ 未確定足リアルタイム追従の完全分離**: 観測ノイズ R\_t と傾きノイズ q\_{\\beta, t}（測るものさし）は確定足のみで決定して固定化。最新価格に対するカルマン状態更新（\\mu\_t, \\beta\_t, z\_t）は毎ティック遅延ゼロで即時反映します。  
> * **ボラティリティ・クラスタリングへの完全追従**: USDJPYが膠着していた低ボラティリティ期から、年間数十円動く高ボラティリティ期まで、観測ノイズ R\_t が自動伸縮し、フィルターの無次元感度が常に一定に保たれます。  
> * **周波数極配置比率の不変性（ピントがボケない）**: q\_{\\beta, t} \= \\frac{R\_t}{\\tau^4} より、q\_{\\beta, t} / R\_t \= 1/\\tau^4 \= \\text{const}。ボラティリティが急変しても、抽出したいスイング波長（時定数 \\tau \= 10 本）の時間的ピントは一切ボケません。  
> * **二階差分累積和による真の \\mathcal{O}(1) 差分更新**: 過去 W 本の二階差分二乗和 \\sum (\\Delta^2 y\_t)^2 を累積和配列（Prefix Sum）の引き算で計算。毎ティックの計算量は四則演算数回（\\mathcal{O}(1)）であり、過去足走査やEAバックテストが一切重くなりません。  
> * **完全な \\Delta t ゲイン不変性スケーリング**: 手動モード時、プロセスノイズ Q、観測ノイズ R、および初期共分散 P\_0 をすべて同一比率 \\text{scale} \= \\Delta t / 86400 で連動補正。初期過渡応答の収束速度とカルマンゲインの時間足不変性を厳密に維持します。  
> * **真の \\mathcal{O}(1) MTF（マルチタイムフレーム）キャッシュ**: 上位足のデータ取得・因果的ローリング計算・チャート足へのマッピングもすべて定数時間 \\mathcal{O}(1) で完結。

## **2\. 状態空間モデルの定式化（平滑トレンドモデル）**

観測値 y\_t \= \\ln(P\_t)（対数価格）、直接観測できない状態ベクトル x\_t \= \[\\mu\_t, \\beta\_t\]^T を仮定します。

### **(1) 状態空間方程式**

\\begin{bmatrix} \\mu\_t \\\\ \\beta\_t \\end{bmatrix} \= \\begin{bmatrix} 1 & 1 \\\\ 0 & 1 \\end{bmatrix} \\begin{bmatrix} \\mu\_{t-1} \\\\ \\beta\_{t-1} \\end{bmatrix} \+ \\begin{bmatrix} 0 \\\\ w\_{\\beta, t} \\end{bmatrix}, \\quad w\_{\\beta, t} \\sim \\mathcal{N}(0, q\_{\\beta, t}) y\_t \= \\begin{bmatrix} 1 & 0 \\end{bmatrix} \\begin{bmatrix} \\mu\_t \\\\ \\beta\_t \\end{bmatrix} \+ v\_t, \\quad v\_t \\sim \\mathcal{N}(0, R\_t)

### **(2) 時間足スケーリング理論（ゲイン不変性の完全証明）**

手動固定モード時（\!InpAutoCalibration && InpAutoTimeframeScale）、日足を基準（86,400秒）とした連続時間ブラウン運動のスケーリング則（\\text{scale} \= \\Delta t / 86400）を導入します。  
Q\_{\\Delta t} \= \\text{scale} \\cdot Q, \\quad R\_{\\Delta t} \= \\text{scale} \\cdot R, \\quad P\_{0, \\Delta t} \= \\text{scale} \\cdot P\_0  
事前予測共分散 P\_{\\text{pred}} \= F P F^T \+ Q および残差共分散 S \= P\_{00, \\text{pred}} \+ R はすべて厳密に \\text{scale} 倍となります。カルマンゲインは比率計算であるため：  
K \= \\frac{P\_{\\text{pred}} H^T}{S} \= \\frac{\\text{scale} \\cdot P\_{\\text{pred}, \\text{base}} H^T}{\\text{scale} \\cdot S\_{\\text{base}}} \= K\_{\\text{base}}  
P\_0 も同時にスケールされるため、初期足における過渡応答速度を含め、カルマンゲイン K は時間足の長さに依存せず**理論的に完全不変**となります。

## **3\. バー毎完全因果的キャリブレーション（確定足分離）の数理**

### **(1) 先読みゼロの局所ノイズ計測**

時点 t における二階差分 d\_t は、確定した対数価格のみから定義されます。  
d\_t \= \\Delta^2 y\_t \= y\_t \- 2y\_{t-1} \+ y\_{t-2} \\quad (t \\ge 2\)  
平滑トレンド（\\Delta^2 \\mu\_t \\approx 0）の前提のもとで、\\text{Var}(d\_t) \= 6 R\_t となります。 指定された観測窓幅 W（デフォルト: 200本）に対し、直前確定足（i \< \\text{last\\\_bar\\\_idx}）における因果的Rice推定量は次式で求まります。  
\\hat{R}\_t \= \\frac{1}{6 M\_t} \\sum\_{k \= \\max(2, t \- W \+ 1)}^t (\\Delta^2 y\_k)^2  
（ただし M\_t \= t \- \\max(2, t \- W \+ 1\) \+ 1）

### **(2) 累積和（Prefix Sum）による計算量 \\mathcal{O}(1) の実現**

二階差分二乗の累積和配列 A\_t \= \\sum\_{k=2}^t d\_k^2 を確定足ごとに逐次更新（A\_t \= A\_{t-1} \+ d\_t^2）することで、任意の窓内の和を四則演算1回（\\mathcal{O}(1)）で算出します。

\\sum\_{k \= \\text{start}\_k}^t d\_k^2 \= A\_t \- A\_{\\text{start}\_k \- 1} \\quad (\\text{start}\_k \= \\max(2, t \- W \+ 1))

### **(3) 極配置解析解による動的適応**

抽出したいスイング波長（時定数 \\tau 本、デフォルト: 10.0本）に基づき、各バーの傾きプロセスノイズ q\_{\\beta, t} を動的に逆算します。  
q\_{\\beta, t} \= \\frac{\\hat{R}\_t}{\\tau^4}  
比率 q\_{\\beta, t} / \\hat{R}\_t \= 1/\\tau^4 は厳密に一定であるため、フィルターの周波数カットオフ特性（スイング感度）はボラティリティ環境に左右されず不変に保たれます。

## **4\. 逐次更新アルゴリズム（スカラー代数展開）**

各バー t において動的パラメータ（q\_{\\beta, t}, R\_t）および適切にスケールされた初期共分散 P\_0 を用いて以下のスカラー漸化式を実行します。

### **ステップ 1: 予測ステップ (Time Update)**

\\mu\_{t\\vert{}t-1} \= \\mu\_{t-1\\vert{}t-1} \+ \\beta\_{t-1\\vert{}t-1} \\beta\_{t\\vert{}t-1} \= \\beta\_{t-1\\vert{}t-1} P\_{00, \\text{pred}} \= P\_{00} \+ 2 P\_{01} \+ P\_{11} \\quad (q\_\\mu \= 0\) P\_{01, \\text{pred}} \= P\_{01} \+ P\_{11} P\_{11, \\text{pred}} \= P\_{11} \+ q\_{\\beta, t}

### **ステップ 2: 更新ステップ (Measurement Update)**

e\_t \= y\_t \- \\mu\_{t\\vert{}t-1} \\quad (\\text{観測残差}) S\_t \= P\_{00, \\text{pred}} \+ R\_t \\quad (\\text{残差分散}) K\_0 \= \\frac{P\_{00, \\text{pred}}}{S\_t}, \\quad K\_1 \= \\frac{P\_{01, \\text{pred}}}{S\_t} \\quad (\\text{カルマンゲイン}) \\mu\_{t\\vert{}t} \= \\mu\_{t\\vert{}t-1} \+ K\_0 e\_t \\beta\_{t\\vert{}t} \= \\beta\_{t\\vert{}t-1} \+ K\_1 e\_t P\_{00} \= P\_{00, \\text{pred}} \- K\_0 P\_{00, \\text{pred}} P\_{01} \= P\_{01, \\text{pred}} \- K\_0 P\_{01, \\text{pred}} P\_{11} \= P\_{11, \\text{pred}} \- K\_1 P\_{01, \\text{pred}}

## **5\. レジーム判定ロジックとヒステリシス設計**

### **(1) 標準化モメンタム強度スコア（z スコア）**

z\_t \= \\frac{\\hat{\\beta}\_t}{\\sqrt{\\text{Var}(\\hat{\\beta}\_t)}} \= \\frac{\\beta\_{t\\vert{}t}}{\\sqrt{\\max(P\_{11}, 10^{-15})}}  
推定共分散 P\_{11} は観測ノイズ R\_t に比例して伸縮するため、Zスコアの分母は自然にローカルボラティリティで正規化されます。

### **(2) 2段階ヒステリシス状態遷移マシン**

微小なノイズによる境界チャタリングを防ぐため、突入閾値（InpZEnter）と離脱閾値（InpZExit）を分離（z\_{\\text{enter}} \> z\_{\\text{exit}} \\ge 0）。  
                `┌─────────────────────────────────┐`  
                `│          z >= z_enter           │`  
                `▼                                 │`  
         `┌─────────────┐                          │`  
         `│             │       z <= z_exit        │`  
         `│  UP_TREND   │─────────────────────┐    │`  
         `│   (+1.0)    │                     ▼    │`  
         `└─────────────┘               ┌───────────┐`  
             `▲     │                   │           │`  
             `│     │ Direct Reversal   │   RANGE   │`  
             `│     │ (z <= -z_enter)   │   (0.0)   │`  
             `│     ▼                   └───────────┘`  
             `│  ┌─────────────┐              ▲    │`  
             `│  │             │              │    │`  
             `│  │ DOWN_TREND  │──────────────┘    │`  
             `│  │   (-1.0)    │  z >= -z_exit     │`  
             `│  └─────────────┘                   │`  
             `│         │                          │`  
             `└─────────┴──────────────────────────┘`  
              `Direct Reversal        z <= -z_enter`  
              `(z >= z_enter)`

## **6\. エキスパートアドバイザー（EA）連携仕様**

### **インジケーターバッファ構成**

| バッファ番号 | タイプ | プロット名 | 格納データ / 役割 | EA利用 |
| :---- | :---- | :---- | :---- | :---- |
| **0** | INDICATOR\_DATA | Kalman Z-Score | 標準化モメンタム強度スコア z\_t | 可 |
| **1** | INDICATOR\_COLOR\_INDEX | Color Index | 描画色（0: 青 / UP, 1: 赤 / DOWN, 2: 灰 / RANGE） | 可 |
| **2** | INDICATOR\_CALCULATIONS | Slope (\\beta) | 推定対数傾き（1足あたりの対数リターン速度） | **推奨** |
| **3** | INDICATOR\_CALCULATIONS | Regime | レジーム値（1.0: UP, \-1.0: DOWN, 0.0: RANGE） | **推奨** |

### **EAからの呼び出し実装テンプレート**

`//+------------------------------------------------------------------+`  
`//|                                              KalmanRegimeEA.mq5  |`  
`//+------------------------------------------------------------------+`  
`#property strict`

`int g_kalman_handle = INVALID_HANDLE;`

`int OnInit()`  
`{`  
   `// 確定足ローリングRice推定量＆現在足リアルタイム追従モードで呼び出し`  
   `g_kalman_handle = iCustom(_Symbol, _Period, "KalmanRegimeEstimator",`  
                             `PERIOD_CURRENT, // InpTimeframe`  
                             `true,           // InpAutoTimeframeScale`  
                             `true,           // InpAutoCalibration (確定足動的推定)`  
                             `10.0,           // InpTargetLagBars (ターゲット時定数: 10本)`  
                             `200,            // InpRollingWindow (ローリング窓長: 過去確定200本のみ使用)`  
                             `0.0,            // InpManualQMu`  
                             `1e-9,           // InpManualQBeta`  
                             `1e-5,           // InpManualR`  
                             `1.0,            // InpManualInitialP`  
                             `2.0,            // InpZEnter`  
                             `1.0,            // InpZExit`  
                             `true,           // InpAllowDirectReversal`  
                             `PRICE_CLOSE);`

   `if(g_kalman_handle == INVALID_HANDLE)`  
   `{`  
      `Print("[Error] インジケーターハンドルの作成に失敗しました。ファイル名が 'KalmanRegimeEstimator.ex5' であるか確認してください。");`  
      `return(INIT_FAILED);`  
   `}`

   `return(INIT_SUCCEEDED);`  
`}`

`void OnDeinit(const int reason)`  
`{`  
   `if(g_kalman_handle != INVALID_HANDLE)`  
   `{`  
      `IndicatorRelease(g_kalman_handle);`  
      `g_kalman_handle = INVALID_HANDLE;`  
   `}`  
`}`

`void OnTick()`  
`{`  
   `// 直前確定足 (shift = 1) のデータを取得`  
   `double regime[1], z_score[1], slope[1];`

   `if(CopyBuffer(g_kalman_handle, 3, 1, 1, regime) <= 0 ||`  
      `CopyBuffer(g_kalman_handle, 0, 1, 1, z_score) <= 0 ||`  
      `CopyBuffer(g_kalman_handle, 2, 1, 1, slope) <= 0)`  
   `{`  
      `return;`  
   `}`

   `double current_regime = regime[0];`  
   `double current_z      = z_score[0];`  
   `double current_slope  = slope[0]; // 対数リターン/足 (例: +0.002 = +0.2%/足)`

   `if(current_regime == 1.0)`  
   `{`  
      `// 【上昇トレンドレジーム】押し目買いエントリー / 空売り手仕舞い`  
   `}`  
   `else if(current_regime == -1.0)`  
   `{`  
      `// 【下降トレンドレジーム】戻り売りエントリー / 買い手仕舞い`  
   `}`  
   `else`  
   `{`  
      `// 【レンジ相場レジーム (0.0)】トレンドフォロー停止 / 平均回帰戦略`  
   `}`  
`}`  
