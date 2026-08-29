

#include "ReShade.fxh"


// ===================== 锐化/结构保护参数（原样保留） =====================
uniform float Strength      < ui_type="drag"; ui_label="锐化强度"; ui_min=0.0; ui_max=5.0; ui_tooltip="控制整体锐化效果的强度。较高的值会产生更清晰的图像，但可能增加伪影风险。"; > = 3.45;
uniform float RangeSigma    < ui_type="drag"; ui_label="范围Sigma (Y)"; ui_min=0.01; ui_max=2.0; ui_tooltip="双边滤波器的范围参数。控制像素颜色相似度对权重的影响。值越小，越只考虑颜色相近的像素；值越大，颜色差异大的像素也能影响中心像素。"; > = 0.26;
uniform float SpatialSigma  < ui_type="drag"; ui_label="空间Sigma (px)"; ui_min=0.0; ui_max=4.0; ui_tooltip="双边滤波器的空间参数。控制像素距离对权重的影响。值越小，越只考虑近距离像素；值越大，远距离像素也能影响中心像素。"; > = 1.10;
uniform float CenterWeight  < ui_type="drag"; ui_label="中心像素权重"; ui_min=0.0; ui_max=4.0; ui_tooltip="双边滤波器中中心像素的权重。增加此值可以使锐化效果更接近原始像素，减少模糊。"; > = 1.0;

uniform bool  EnableNoiseSuppression < ui_type="checkbox"; ui_label="启用降噪"; ui_tooltip="启用基于局部亮度变化的智能降噪功能，减少锐化过程中可能引入的噪声。"; > = true;
uniform float NoiseFloor   < ui_type="drag"; ui_label="噪声基底"; ui_min=0.0; ui_max=0.1; ui_category="Noise Suppression"; ui_category_closed=true; ui_tooltip="定义被认为是噪声的亮度差异阈值。低于此阈值的细节将被视为噪声并进行抑制。"; > = 0.008;
uniform float NoiseSuppress< ui_type="drag"; ui_label="噪声抑制强度"; ui_min=0.0; ui_max=1.0; ui_category="Noise Suppression"; ui_category_closed=true; ui_tooltip="控制降噪的强度。值越高，对低于噪声基底的细节抑制越强。"; > = 0.65;

// 抗过冲 (Y) - AURA (Adaptive Unified Ringing Attenuation)
uniform float AntiRinging  < ui_type="drag"; ui_label="AURA (Adaptive Unified Ringing Attenuation) 主强度 (Y)"; ui_min=0.0; ui_max=1.0; ui_tooltip="控制 AURA 抗过冲（或传统钳位抗振铃）的总强度。较高的值能更有效地抑制边缘光晕和振铃伪影。"; > = 0.60;
uniform float AR_MAD_Threshold < ui_type="drag"; ui_label="AURA 边缘阈值 (Y)"; ui_min=0.0; ui_max=0.02; ui_tooltip="激活 AURA 抗过冲所需的最小边缘强度。低于此阈值的区域不会应用抗过冲，以避免模糊平坦区域。"; > = 0.0015;

// === AURA 参数 ===
uniform bool  EnableAURA_AR < ui_type="checkbox"; ui_label="启用 AURA 抗过冲"; ui_category="抗过冲 (Anti-Ringing)"; ui_category_closed=false; ui_tooltip="启用 AURA 风格的软限制抗过冲，替代传统硬钳位。"; > = true;
uniform bool  EnableAURA_Compression < ui_type="checkbox"; ui_label="启用 AURA 压缩"; ui_category="抗过冲 (Anti-Ringing)"; ui_tooltip="启用细节能量压缩（影响对比）。关闭时只保留纯防过冲。"; > = false;
uniform float AR_L_Overshoot < ui_type="drag"; ui_label="AURA 亮部过冲限制"; ui_min=0.001; ui_max=0.1; ui_category="抗过冲 (Anti-Ringing)"; > = 0.003;
uniform float AR_D_Overshoot < ui_type="drag"; ui_label="AURA 暗部过冲限制"; ui_min=0.001; ui_max=0.1; ui_category="抗过冲 (Anti-Ringing)"; > = 0.009;
uniform float AR_L_ComprLow  < ui_type="drag"; ui_label="AURA 亮部压缩斜率 (低)"; ui_min=0.0; ui_max=1.0; ui_category="抗过冲 (Anti-Ringing)"; > = 0.167;
uniform float AR_L_ComprHigh < ui_type="drag"; ui_label="AURA 亮部压缩斜率 (高)"; ui_min=0.0; ui_max=1.0; ui_category="抗过冲 (Anti-Ringing)"; > = 0.334;
uniform float AR_D_ComprLow  < ui_type="drag"; ui_label="AURA 暗部压缩斜率 (低)"; ui_min=0.0; ui_max=1.0; ui_category="抗过冲 (Anti-Ringing)"; > = 0.250;
uniform float AR_D_ComprHigh < ui_type="drag"; ui_label="AURA 暗部压缩斜率 (高)"; ui_min=0.0; ui_max=1.0; ui_category="抗过冲 (Anti-Ringing)"; > = 0.500;
uniform float AR_PM_P        < ui_type="drag"; ui_label="AURA 幂平均 P 值"; ui_min=0.01; ui_max=1.0; ui_category="抗过冲 (Anti-Ringing)"; > = 0.7;
uniform float AR_EdgeComprMix < ui_type="drag"; ui_label="AURA 边缘压缩混合"; ui_min=0.0; ui_max=1.0; ui_category="抗过冲 (Anti-Ringing)"; > = 0.5;

uniform float OriginalMix  < ui_type="drag"; ui_label="原始图像混合"; ui_min=0.0; ui_max=1.0; ui_tooltip="0 完全处理, 1 完全原始。"; > = 0.05;

// 颜色安全/边缘偏好
uniform float ChromaProtect < ui_type="drag"; ui_label="色度保护 (边缘偏向)"; ui_min=0.0; ui_max=1.0; ui_tooltip="减少色度主导边缘的锐化。"; > = 0.65;
uniform float ChromaDenoise < ui_type="drag"; ui_label="色度降噪 (平坦区域)"; ui_min=0.0; ui_max=0.5; ui_tooltip="对平坦区域的色度进行降噪。"; > = 0.12;

// 色度去伪影 + 门控
uniform float ChromaDirMix  < ui_type="drag"; ui_label="色度方向混合 (切线↔法线)"; ui_min=0.0; ui_max=1.0; > = 0.60;
uniform float BlueGuard     < ui_type="drag"; ui_label="蓝色/色度保护"; ui_min=0.0; ui_max=1.0; > = 0.70;
uniform float ChromaAR      < ui_type="drag"; ui_label="色度抗过冲"; ui_min=0.0; ui_max=1.0; > = 0.45;
uniform float ArtifactCOY   < ui_type="drag"; ui_label="伪影：色度/亮度增益"; ui_min=0.2; ui_max=1.5; ui_category="Advanced"; ui_category_closed=true; > = 1.0;
uniform float ArtifactDirW  < ui_type="drag"; ui_label="伪影：方向不匹配增益"; ui_min=0.2; ui_max=1.5; ui_category="Advanced"; ui_category_closed=true; > = 1.0;
uniform float CheckerBoost  < ui_type="drag"; ui_label="伪影：棋盘格增强"; ui_min=0.0; ui_max=1.0; ui_category="Advanced"; ui_category_closed=true; > = 0.15;

// SCAA（EAA ALU）
uniform bool  EnableSCAA   < ui_type="checkbox"; ui_label="启用 SCAA (EAA ALU)"; > = true;
uniform float SCAAAmount   < ui_type="drag"; ui_label="SCAA/EAA 强度"; ui_min=0.0; ui_max=1.0; > = 0.55;
uniform float SCAAWidth    < ui_type="drag"; ui_label="EAA 宽度 (形状)"; ui_min=0.1; ui_max=1.5; > = 0.80;
uniform float SCAAThresh   < ui_type="drag"; ui_label="EAA 边缘阈值"; ui_min=0.0; ui_max=0.1; > = 0.015;

uniform float MADref       < ui_type="drag"; ui_label="MAD4 参考值 (Y)"; ui_min=0.005; ui_max=0.2; ui_category="Advanced"; ui_category_closed=true; > = 0.05;
uniform float GradAdapt    < ui_type="drag"; ui_label="梯度适应强度"; ui_min=0.0; ui_max=1.0; ui_category="Advanced"; ui_category_closed=true; > = 0.6;

// EAA 核心权重与方向混合
uniform float EAA_CenterW  < ui_type="drag"; ui_label="EAA 中心采样权重"; ui_min=0.0; ui_max=1.0; ui_category="Advanced"; ui_category_closed=true; > = 0.35;
uniform float EAA_NearW    < ui_type="drag"; ui_label="EAA 近距离 ±0.5 权重"; ui_min=0.0; ui_max=1.0; ui_category="Advanced"; ui_category_closed=true; > = 0.30;
uniform float EAA_FarW     < ui_type="drag"; ui_label="EAA 远距离 ±1.0 权重"; ui_min=0.0; ui_max=1.0; ui_category="Advanced"; ui_category_closed=true; > = 0.15;
uniform float EAA_DirMix   < ui_type="drag"; ui_label="EAA 方向混合 (法线↔切线)"; ui_min=0.0; ui_max=1.0; ui_category="Advanced"; ui_category_closed=true; > = 0.65;

// 解析覆盖率混合与底线
uniform float EAA_AnalyticMix < ui_type="drag"; ui_label="解析覆盖率混合"; ui_min=0.0; ui_max=1.0; ui_category="Advanced"; ui_category_closed=true; > = 0.65;
uniform float SCAA_Floor      < ui_type="drag"; ui_label="SCAA 遮罩底线"; ui_min=0.0; ui_max=0.5; ui_category="Advanced"; ui_category_closed=true; > = 0.12;
uniform float ChromaFollow    < ui_type="drag"; ui_label="色度跟随强度"; ui_min=0.0; ui_max=1.0; ui_category="Advanced"; ui_category_closed=true; > = 0.30;

// 暗部保护
uniform bool  EnableDarkProtect < ui_type="checkbox"; ui_label="启用暗部保护"; ui_category="Safety"; ui_category_closed=false; > = true;
uniform float DarkProtect   < ui_type="drag"; ui_label="暗部保护强度 (×噪声基底)"; ui_min=0.0; ui_max=2.0; ui_category="Safety"; ui_category_closed=true; > = 0.125;


// ===================== 电影级调色引擎（CCE）参数（重构，专业曲线） =====================
uniform bool  EnableCCE     < ui_type="checkbox"; ui_label="启用调色引擎"; ui_category="Cinematic Color"; > = false;

// 曝光 & 自适应（线性域）
uniform float ExposureEV     < ui_type="drag"; ui_label="曝光补偿 (EV)"; ui_min=-6.0; ui_max=6.0; ui_category="Cinematic Color"; > = 0.0;
uniform float MidGray        < ui_type="drag"; ui_label="目标中间灰度 (用于局部EV)"; ui_min=0.03; ui_max=0.5; ui_category="Cinematic Color"; > = 0.18;
uniform float AdaptStrength  < ui_type="drag"; ui_label="局部自适应强度"; ui_min=0.0; ui_max=1.0; ui_category="Cinematic Color"; > = 0.0;
uniform float AdaptLimitEV   < ui_type="drag"; ui_label="自适应 EV 限制"; ui_min=0.0; ui_max=4.0; ui_category="Cinematic Color"; > = 1.5;

// 白平衡（线性域）
uniform float WB_Temp < ui_type="drag"; ui_label="白平衡色温"; ui_min=-1.0; ui_max=1.0; ui_category="Cinematic Color"; > = 0.0;
uniform float WB_Tint < ui_type="drag"; ui_label="白平衡色调"; ui_min=-1.0; ui_max=1.0; ui_category="Cinematic Color"; > = 0.0;

// ASC CDL（线性域）
uniform float3 CDL_Slope   < ui_type="color"; ui_label="CDL 斜率 (RGB)";  ui_category="Cinematic Color"; > = float3(1.0, 1.0, 1.0);
uniform float3 CDL_Offset  < ui_type="color"; ui_label="CDL 偏移 (RGB)"; ui_category="Cinematic Color"; > = float3(0.0, 0.0, 0.0);
uniform float3 CDL_Power   < ui_type="color"; ui_label="CDL 幂 (RGB)";  ui_category="Cinematic Color"; > = float3(1.0, 1.0, 1.0);

uniform bool EnableSecondaryCDL < ui_type="checkbox"; ui_label="启用二级 CDL"; ui_category="Secondary CDL"; ui_category_closed=true; > = false;
uniform float3 Secondary_Slope   < ui_type="color"; ui_label="二级斜率 (RGB)";  ui_category="Secondary CDL"; > = float3(1.0, 1.0, 1.0);
uniform float3 Secondary_Offset  < ui_type="color"; ui_label="二级偏移 (RGB)"; ui_category="Secondary CDL"; > = float3(0.0, 0.0, 0.0);
uniform float3 Secondary_Power   < ui_type="color"; ui_label="二级幂 (RGB)";  ui_category="Secondary CDL"; > = float3(1.0, 1.0, 1.0);

// 饱和/自然饱和/高光去饱和（不再有肤色保护）
uniform float SatGlobal     < ui_type="drag"; ui_label="全局饱和度"; ui_min=0.0; ui_max=2.5; ui_category="Cinematic Color"; > = 1.00;
uniform float Vibrance      < ui_type="drag"; ui_label="自然饱和度"; ui_min=-1.0; ui_max=1.0; ui_category="Cinematic Color"; > = 0.00;
uniform float HL_Desat      < ui_type="drag"; ui_label="高光去饱和"; ui_min=0.0; ui_max=1.0; ui_category="Cinematic Color"; > = 0.00;

// —— 色调映射（下拉选项 + 灰点/白点/混合） ——
/* ToneMapProfile:
   0 Off（关闭）, 1 ACES Fitted, 2 Hable (Uncharted2), 3 Reinhard Extended, 4 Uchimura (UC2)
*/
uniform int   ToneMapProfile < ui_type="combo"; ui_label="色调映射"; ui_items="Off\0ACES Fitted\0Hable (Uncharted2)\0Reinhard Extended\0Uchimura (UC2)\0"; ui_category="Cinematic Color"; > = 0;
uniform float ToneMap_Mix      < ui_type="drag"; ui_label="曲线混合强度"; ui_min=0.0; ui_max=1.0; ui_category="Cinematic Color"; > = 1.0;
uniform float ToneMap_GrayPoint< ui_type="drag"; ui_label="灰点（场景线性）"; ui_min=0.05; ui_max=0.5; ui_category="Cinematic Color"; > = 0.18;
uniform float ToneMap_WhitePoint < ui_type="drag"; ui_label="白点（场景线性）"; ui_min=1.0; ui_max=32.0; ui_category="Cinematic Color"; > = 11.2;

// 显示对比度（曲线之后）
uniform float Contrast      < ui_type="drag"; ui_label="显示对比度"; ui_min=-1.0; ui_max=1.0; ui_category="Cinematic Color"; > = 0.00;
uniform float ContrastPivot < ui_type="drag"; ui_label="显示对比中心 (Y)"; ui_min=0.0; ui_max=1.0; ui_category="Cinematic Color"; > = 0.5;


// ===================== LUT 集成（原样保留） =====================
#ifndef fLUT_TextureName
	#define fLUT_TextureName "lut.png"
#endif
uniform bool EnableLUT < ui_type="checkbox"; ui_label="启用 LUT"; ui_category="LUT"; ui_category_closed=true; > = false;
uniform int fLUT_TileSizeXY < ui_type="drag"; ui_label="LUT 瓦片尺寸 XY"; ui_min=16; ui_max=64; ui_category="LUT"; > = 64;
uniform int fLUT_TileAmount < ui_type="drag"; ui_label="LUT 瓦片数量"; ui_min=16; ui_max=64; ui_category="LUT"; > = 64;
uniform float fLUT_AmountChroma < ui_type="drag"; ui_label="LUT 色度强度"; ui_min=0.0; ui_max=1.0; ui_category="LUT"; > = 1.0;
uniform float fLUT_AmountLuma < ui_type="drag"; ui_label="LUT 亮度强度"; ui_min=0.0; ui_max=1.0; ui_category="LUT"; > = 1.0;


// ===================== 调试模式（移除“肤色遮罩”项） =====================
/* DebugMode:
   0 Off, 1 Base Y, 2 Detail Y, 3 Edge Y, 4 Chroma Edge, 5 EAA Mask, 6 Adapt EV, 7 HL Desat Mask,
   8 (保留空位), 9 Edge Strength (MAD4 Y), 10 Edge Direction, 11 EAA DeltaY, 12 Edge Uniformity,
   13 Isolated Edge, 14 Anti-Ringing Strength, 15 Detail Compress, 16 AURA Pos Scale, 17 AURA Neg Scale
*/
uniform int DebugMode < ui_type="drag"; ui_label="调试模式 (0..17)"; ui_min=0; ui_max=17; > = 0;


// ===================== 采样器 =====================
texture TexColor : COLOR;
sampler sTexColor { Texture = TexColor; SRGBTexture = true; }; // 采样为线性域

texture texLUT < source = fLUT_TextureName; > { Format = RGBA8; };
sampler SamplerLUT { Texture = texLUT; };


// ===================== 辅助函数 =====================
static const int2 OFF_C[4] = { int2(0,-1), int2(-1,0), int2(1,0), int2(0,1) };

void RGB_to_YCoCg(in float3 rgb, out float Y, out float Co, out float Cg)
{
    Y  = 0.25 * rgb.r + 0.5 * rgb.g + 0.25 * rgb.b;
    Co = rgb.r - rgb.b;
    Cg = rgb.g - 0.5 * (rgb.r + rgb.b);
}
float3 YCoCg_to_RGB(const float Y, const float Co, const float Cg)
{
    float tmp = Y - 0.5 * Cg;
    float G = Cg + tmp;
    float R = tmp + 0.5 * Co;
    float B = tmp - 0.5 * Co;
    return float3(R, G, B);
}

float MAD4(const float c, const float b, const float d, const float f, const float h)
{
    return 0.25 * (abs(b - c) + abs(d - c) + abs(f - c) + abs(h - c));
}
float wRangeGauss(const float dl, const float inv2sig2)
{
    return exp(-(dl * dl) * inv2sig2);
}
float BilateralY_Cross3(const float Ye, const float Yb, const float Yd, const float Yf, const float Yh,
                        const float inv2sigR, const float wS1, const float CenterWeight)
{
    float acc  = Ye * CenterWeight;
    float wsum = CenterWeight;

    float Yn, wr, w;
    Yn = Yb; wr = wRangeGauss(Yn - Ye, inv2sigR); w = wr * wS1; acc += Yn * w; wsum += w;
    Yn = Yd; wr = wRangeGauss(Yn - Ye, inv2sigR); w = wr * wS1; acc += Yn * w; wsum += w;
    Yn = Yf; wr = wRangeGauss(Yn - Ye, inv2sigR); w = wr * wS1; acc += Yn * w; wsum += w;
    Yn = Yh; wr = wRangeGauss(Yn - Ye, inv2sigR); w = wr * wS1; acc += Yn * w; wsum += w;

    return acc / max(wsum, 1e-6);
}
float soft_lim_tanh(const float x, const float s)
{
    const float ss = max(s, 1e-6);
    return ss * tanh(x / ss);
}
float smoothstepf(const float a, const float b, const float x)
{
    const float t = saturate((x - a) / max(b - a, 1e-6));
    return t * t * (3.0 - 2.0 * t);
}
float luma709(float3 x){ return dot(x, float3(0.2126, 0.7152, 0.0722)); }
float invL1_px(float2 v, float2 px)
{
    float dx = abs(v.x) / max(px.x, 1e-8);
    float dy = abs(v.y) / max(px.y, 1e-8);
    float d1 = max(dx + dy, 0.5);
    return 1.0 / d1;
}

// 白平衡/对比/色彩
float3 apply_wb(float3 x, float temp, float tint)
{
    float kt = 0.20;
    float kg = 0.12;
    float rGain = exp2( kt * temp);
    float bGain = exp2(-kt * temp);
    float gGain = exp2( kg * tint);
    float3 g = float3(rGain, gGain, bGain);
    float norm = 3.0 / (g.r + g.g + g.b + 1e-6);
    return x * (g * norm);
}
float3 apply_cdl(float3 x, float3 slope, float3 offset, float3 power_)
{
    x = x * slope + offset;
    x = saturate(x);
    return pow(max(x, 1e-6), power_);
}
float3 apply_contrast(float3 x, float contrast, float pivot)
{
    return pivot + (x - pivot) * (1.0 + contrast);
}

// —— Tone Mapping Curves（专业实现）——
// ACES Fitted
float3 ACESFitted(float3 v)
{
    v = max(v, 0.0);
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((v*(a*v+b))/(v*(c*v+d)+e));
}
// Hable / Uncharted2（带 white scale）
float3 Hable_UC2(float3 x, float W)
{
    const float A=0.22, B=0.30, C=0.10, D=0.20, E=0.01, F=0.30;
    float3 num = ((x*(A*x+C*B))+D*E);
    float3 den = (x*(A*x+B))+D*F;
    float3 y   = num/den - E/F;

    float w_num = (W*(A*W + C*B)) + D*E;
    float w_den = (W*(A*W + B))   + D*F;
    float white = w_num / w_den - E/F;
    return saturate(y / max(white, 1e-6));
}
// Reinhard Extended（带 Lwhite^2）
float3 ReinhardExtended(float3 x, float Lwhite)
{
    float3 t  = x / (1.0 + x);
    float3 w2 = (Lwhite*Lwhite).xxx;
    return saturate(t * (1.0 + x / max(w2, 1e-6)));
}
// Uchimura / UC2（稳健近似）
float uchimura_curve(float x, float W)
{
    float P = W;
    float a = 1.22;  // toe strength (1+0.22)
    float m = 0.10;  // linear length
    float l = 0.20;  // shoulder strength
    float c = 1.33;  // contrast tune
    float b = (P - m) / (P - m + l);
    float y;
    if (x < m)      y = c * x / (a + x);
    else if (x < P) y = b * (x - m) / (P - m) + c*m/(a+m);
    else            y = b + (1.0 - b) * (1.0 - exp(-(x - P)/l));
    return saturate(y);
}
float3 UchimuraUC2(float3 x, float W)
{
    return float3(uchimura_curve(x.r, W), uchimura_curve(x.g, W), uchimura_curve(x.b, W));
}


// EAA / SCAA 辅助（原样）
float recon_virtual_Y(float2 d_uv, float2 tangent,
                      float Ye, float Yb, float Yd, float Yf, float Yh)
{
    const float2 px = BUFFER_PIXEL_SIZE;
    const float2 pC = float2(0.0, 0.0);
    const float2 pB = float2(0.0, -px.y);
    const float2 pD = float2(-px.x, 0.0);
    const float2 pF = float2( px.x, 0.0);
    const float2 pH = float2(0.0,  px.y);

    float wC = invL1_px(d_uv - pC, px);
    float wB = invL1_px(d_uv - pB, px);
    float wD = invL1_px(d_uv - pD, px);
    float wF = invL1_px(d_uv - pF, px);
    float wH = invL1_px(d_uv - pH, px);

    float wNsum = wB + wD + wF + wH + 1e-6;
    wC = min(wC, wNsum * 0.5);

    float wsum = wC + wNsum + 1e-6;
    float Yv = (Ye*wC + Yb*wB + Yd*wD + Yf*wF + Yh*wH) / wsum;
    return Yv;
}
void edge_samples_1D(float gx, float gy,
                     float Ye, float Yb, float Yd, float Yf, float Yh,
                     out float Yn_m1, out float Yn_0, out float Yn_p1, out float2 n)
{
    float2 g = float2(gx, gy);
    float g2 = dot(g,g);
    if (g2 <= 1e-12) { n = float2(0.0,1.0); Yn_m1=Yn_0=Yn_p1=Ye; return; }
    n = normalize(g);
    if (abs(gx) >= abs(gy)) { Yn_m1 = Yd; Yn_0 = Ye; Yn_p1 = Yf; }
    else                    { Yn_m1 = Yb; Yn_0 = Ye; Yn_p1 = Yh; }
}
float eaa_target_1D(float Yn_m1, float Yn_0, float Yn_p1)
{
    float L_lo = (Yn_m1 + Yn_0) * 0.5;
    float L_hi = (Yn_p1 + Yn_0) * 0.5;
    float side_min = min(L_lo, L_hi);
    float side_max = max(L_lo, L_hi);
    float denom = (Yn_p1 - Yn_m1);
    float t = (denom != 0.0) ? saturate((Yn_0 - Yn_m1) / (denom + 1e-6)) : 0.5;
    float Ycov = lerp(side_min, side_max, t);
    float lo = min(Yn_m1, min(Yn_0, Yn_p1));
    float hi = max(Yn_m1, max(Yn_0, Yn_p1));
    return clamp(Ycov, lo, hi);
}
float wpmean_magnitude(const float a_mag, const float b_mag, const float w, const float p)
{
    if (abs(p) < 1e-6) {
        return exp(w * log(a_mag + 1e-12) + (1.0 - w) * log(b_mag + 1e-12));
    }
    return pow(w * pow(a_mag, p) + (1.0 - w) * pow(b_mag, p), (1.0 / p));
}

// LUT
float3 apply_lut(float3 color)
{
    float2 texelsize = 1.0 / fLUT_TileSizeXY;
    texelsize.x /= fLUT_TileAmount;

    float3 lutcoord = float3((color.xy*fLUT_TileSizeXY-color.xy+0.5)*texelsize.xy,color.z*fLUT_TileSizeXY-color.z);
    float lerpfact = frac(lutcoord.z);
    lutcoord.x += (lutcoord.z-lerpfact)*texelsize.y;

    float3 lutcolor = lerp(tex2D(SamplerLUT, lutcoord.xy).xyz, tex2D(SamplerLUT, float2(lutcoord.x+texelsize.y,lutcoord.y)).xyz,lerpfact);

    color.xyz = lerp(normalize(color.xyz), normalize(lutcolor.xyz), fLUT_AmountChroma) *
                lerp(length(color.xyz),    length(lutcolor.xyz),    fLUT_AmountLuma);
    return color;
}

// 面罩
float highlight_mask(float Y)
{
    float t = saturate((Y - 0.6) / max(1.0 - 0.6, 1e-6));
    return t * t * (3.0 - 2.0 * t);
}


// ===================== 像素着色器 =====================
float4 BCAS_Cinema_PS(float4 vpos:SV_Position, float2 uv:TexCoord) : SV_Target
{
    // === 采样（线性域） ===
    float3 e = tex2D(sTexColor, uv).rgb;
    float3 b = tex2Doffset(sTexColor, uv, OFF_C[0]).rgb;
    float3 d = tex2Doffset(sTexColor, uv, OFF_C[1]).rgb;
    float3 f = tex2Doffset(sTexColor, uv, OFF_C[2]).rgb;
    float3 h = tex2Doffset(sTexColor, uv, OFF_C[3]).rgb;

    float Ye, Coo, Cgo; RGB_to_YCoCg(e, Ye, Coo, Cgo);
    float Yb, Cob, Cgb; RGB_to_YCoCg(b, Yb, Cob, Cgb);
    float Yd, Cod, Cgd; RGB_to_YCoCg(d, Yd, Cod, Cgd);
    float Yf, Cof, Cgf; RGB_to_YCoCg(f, Yf, Cof, Cgf);
    float Yh, Coh, Cgh; RGB_to_YCoCg(h, Yh, Coh, Cgh);

    // === 局部统计 ===
    const float madY  = MAD4(Ye, Yb, Yd, Yf, Yh);
    const float madCo = MAD4(Coo, Cob, Cod, Cof, Coh);
    const float madCg = MAD4(Cgo, Cgb, Cgd, Cgf, Cgh);
    const float madC  = 0.5 * (madCo + madCg);

    float edge_strength = madY;
    float edge_uniformity = 1.0 - (abs(Yb - Yh) + abs(Yd - Yf)) / (4.0 * edge_strength + 1e-6);
    edge_uniformity = saturate(edge_uniformity);
    float is_isolated_edge = saturate((edge_strength - 2.0 * min(madY, madC)) / max(edge_strength, 1e-6));

    // === 双边基底 ===
    float effSigmaR = RangeSigma * (1.0 + GradAdapt * (1.0 - saturate(madY / max(MADref, 1e-6))));
    effSigmaR = clamp(effSigmaR, 0.01, 2.0);
    const float inv2sigR = 0.5 / max(effSigmaR * effSigmaR, 1e-6);

    float wS1 = 1.0;
    if (SpatialSigma > 0.0) {
        const float inv2s2 = 0.5 / max(SpatialSigma * SpatialSigma, 1e-6);
        wS1 = exp(-1.0 * inv2s2);
    }

    const float Ybase = BilateralY_Cross3(Ye, Yb, Yd, Yf, Yh, inv2sigR, wS1, CenterWeight);

    // === 细节层 ===
    float detailY = Ye - Ybase;
    float detail_compress = 1.0;
    detail_compress *= lerp(1.0, 0.6, is_isolated_edge);
    detail_compress *= lerp(1.0, 0.8, edge_uniformity);
    detailY *= detail_compress;

    float noiseMask = 1.0;
    if (EnableNoiseSuppression) {
        const float nf = max(NoiseFloor, 1e-6);
        float t = saturate(madY / nf);
        noiseMask = lerp(1.0 - NoiseSuppress, 1.0, t);
    }

    const float chromaBias = saturate(madC / max(madY + 1e-6, 1e-6));
    const float chromaProtectGain = 1.0 - ChromaProtect * chromaBias;

    float s_initial_sharpen = 0.08 * (1.0 + 3.0 * saturate(madY / max(MADref, 1e-6)));
    s_initial_sharpen *= (0.7 + 0.6 * (4.0 * Ye * (1.0 - Ye)));
    s_initial_sharpen *= (0.75 + 0.25 * chromaProtectGain);

    const float raw_sharpen_amount = detailY * (Strength * noiseMask * chromaProtectGain);
    float pos_initial = soft_lim_tanh(max(0.0,  raw_sharpen_amount), s_initial_sharpen);
    float neg_initial = soft_lim_tanh(min(0.0,  raw_sharpen_amount), s_initial_sharpen);
    float Ysharp_initial = Ye + pos_initial + neg_initial;

    // 暗部保护
    float Ysharp_post_dp = Ysharp_initial;
    if (EnableDarkProtect) {
        const float baseNF = max(NoiseFloor, 0.008);
        const float Yth    = max(1e-6, baseNF * DarkProtect * (1.0 + madY / MADref));
        const float k      = saturate((Ysharp_initial - Yth) / max(0.05, Yth));
        Ysharp_post_dp = lerp(Ye, Ysharp_initial, k);
    }

    // === EAA / SCAA（省略注释，逻辑原样） ===
    float scaa_mask = 0.0;
    float edge_strength_dbg = 0.0;
    float2 tangent_dbg = float2(1.0, 0.0);
    float Ydir_dbg = Ye;

    float Ysharp_post_eaa = Ysharp_post_dp;

    if (EnableSCAA && SCAAAmount > 0.0)
    {
        const float gx = 0.5 * (Yf - Yd);
        const float gy = 0.5 * (Yh - Yb);
        const float g2 = gx*gx + gy*gy;

        if (g2 > 1e-12)
        {
            float2 n = normalize(float2(gx, gy));
            float2 t = float2(-n.y, n.x);
            tangent_dbg = t;

            const float g = sqrt(g2);
            const float edge_strength_eaa = smoothstepf(SCAAThresh, SCAAThresh * 2.0, g);
            edge_strength_dbg = edge_strength_eaa;
            const float edge_ok = edge_strength_eaa * saturate((g - SCAAThresh * 0.5) / max(SCAAThresh * 1.5, 1e-6));

            if (edge_ok > 0.01)
            {
                const float2 px = BUFFER_PIXEL_SIZE;
                float2 p0 = float2(0.0, 0.0);
                float2 p1 = 0.5 * t * px;
                float2 p2 = -p1;
                float2 p3 = 1.0 * t * px;
                float2 p4 = -p3;

                float Yv0 = recon_virtual_Y(p0, t, Ye, Yb, Yd, Yf, Yh);
                float Yv1 = recon_virtual_Y(p1, t, Ye, Yb, Yd, Yf, Yh);
                float Yv2 = recon_virtual_Y(p2, t, Ye, Yb, Yd, Yf, Yh);
                float Yv3 = recon_virtual_Y(p3, t, Ye, Yb, Yd, Yf, Yh);
                float Yv4 = recon_virtual_Y(p4, t, Ye, Yb, Yd, Yf, Yh);

                float wC = EAA_CenterW;
                float wN = EAA_NearW;
                float wF = EAA_FarW;

                float Wt = wC + 2.0*wN + 2.0*wF + 1e-6;
                float Y_tangent = (wC*Yv0 + wN*(Yv1+Yv2) + wF*(Yv3+Yv4)) / Wt;

                float2 q1 = 0.5 * n * px;
                float2 q2 = -q1;
                float Yn1 = recon_virtual_Y(q1, t, Ye, Yb, Yd, Yf, Yh);
                float Yn2 = recon_virtual_Y(q2, t, Ye, Yb, Yd, Yf, Yh);
                float Y_normal = 0.5 * (Yn1 + Yn2);

                float Yn_m1, Yn_0, Yn_p1; float2 n_dir;
                edge_samples_1D(gx, gy, Ye, Yb, Yd, Yf, Yh, Yn_m1, Yn_0, Yn_p1, n_dir);
                float Y_cov = eaa_target_1D(Yn_m1, Yn_0, Yn_p1);

                float Y_eaa_dir = lerp(Y_tangent, Y_normal, saturate(EAA_DirMix));
                float Y_eaa_final = lerp(Y_eaa_dir, Y_cov, saturate(EAA_AnalyticMix));

                float is_peak = step(0.0, (Ysharp_post_dp - Yb)*(Ysharp_post_dp - Yh)) * step(0.0, (Ysharp_post_dp - Yd)*(Ysharp_post_dp - Yf));
                float low_contrast = 1.0 - saturate(madY / max(MADref * 1.5, 1e-6));
                float thin_guard = 1.0 - 0.4 * is_peak * low_contrast;
                float corner = step(0.0, (Yf - Ye)*(Ye - Yd)) + step(0.0, (Yh - Ye)*(Ye - Yb));
                float corner_guard = 1.0 - 0.35 * saturate(corner);

                float width_adapt = max(SCAAWidth * (0.5 + 0.5 * (MADref / (MADref + g))), 0.05);
                float asym = saturate(abs(Ysharp_post_dp - Y_eaa_final) / max(abs(Yf - Yd) + abs(Yh - Yb) + 1e-6, 1e-6));
                float kcurve = smoothstepf(0.0, width_adapt, asym);

                float scaa_local = edge_ok * kcurve * SCAAAmount * thin_guard * corner_guard;
                float dv_h = abs(Yf - Yd);
                float dv_v = abs(Yh - Yb);
                float dv_max = max(dv_h, dv_v);
                float dv_min = min(dv_h, dv_v);
                float dir_conf = saturate((dv_max - dv_min) / (dv_max + 1e-6));
                scaa_local *= lerp(0.8, 1.2, dir_conf);
                float scaa_gate = step(SCAAThresh * 0.75, g);
                scaa_mask = max(scaa_local, SCAA_Floor * scaa_gate);

                Ydir_dbg = Y_eaa_final;
                Ysharp_post_eaa = lerp(Ysharp_post_dp, Y_eaa_final, saturate(scaa_mask));
            }
        }
    }

    // === AURA 抗过冲 ===
    float Ysharp_final = Ysharp_post_eaa;
    float dbg_pos_scale = 0.0;
    float dbg_neg_scale = 0.0;
    float dbg_blend_factor = 0.0;

    if (AntiRinging > 0.0 && madY > AR_MAD_Threshold)
    {
        if (EnableAURA_AR)
        {
            float sharpdiff_raw = Ysharp_post_eaa - Ye;

            float Ymn_5tap = min(min(min(min(Yb, Yd), Yf), Yh), Ye);
            float Ymx_5tap = max(max(max(max(Yb, Yd), Yf), Yh), Ye);

            float min_dist_to_local_bounds = max(min(abs(Ymx_5tap - Ye), abs(Ye - Ymn_5tap)), 1e-6);

            float pos_scale = min_dist_to_local_bounds + AR_L_Overshoot;
            float neg_scale = min_dist_to_local_bounds + AR_D_Overshoot;

            dbg_pos_scale = pos_scale;
            dbg_neg_scale = neg_scale;

            float sharpdiff_pos_limited = soft_lim_tanh(max(0.0, sharpdiff_raw), pos_scale);
            float sharpdiff_neg_limited = soft_lim_tanh(min(0.0, sharpdiff_raw), neg_scale);

            float sharpdiff_pos_processed = sharpdiff_pos_limited;
            float sharpdiff_neg_processed = sharpdiff_neg_limited;

            if (EnableAURA_Compression) {
                float blend_for_compr = saturate(edge_uniformity * AntiRinging);
                dbg_blend_factor = blend_for_compr;

                float cs_light = lerp(AR_L_ComprHigh, AR_L_ComprLow, lerp(blend_for_compr, 1.0 - is_isolated_edge, AR_EdgeComprMix));
                float cs_dark  = lerp(AR_D_ComprHigh, AR_D_ComprLow, lerp(blend_for_compr, 1.0 - is_isolated_edge, AR_EdgeComprMix));

                sharpdiff_pos_processed = wpmean_magnitude(max(0.0, sharpdiff_raw), sharpdiff_pos_limited, cs_light, AR_PM_P);
                sharpdiff_neg_processed = -wpmean_magnitude(abs(min(0.0, sharpdiff_raw)), abs(sharpdiff_neg_limited), cs_dark, AR_PM_P);
            }

            Ysharp_final = Ye + sharpdiff_pos_processed + sharpdiff_neg_processed;
        }
        else
        {
            float Ymn_5tap = min(min(min(min(Yb, Yd), Yf), Yh), Ye);
            float Ymx_5tap = max(max(max(max(Yb, Yd), Yf), Yh), Ye);
            float safe_range2 = (Ymx_5tap - Ymn_5tap) * 0.65;
            safe_range2 *= lerp(1.0, 0.75, edge_uniformity);
            safe_range2 *= lerp(1.0, 0.65, is_isolated_edge);
            safe_range2 = max(safe_range2, 1e-6);

            const float Ylo2 = Ye - AntiRinging * safe_range2;
            const float Yhi2 = Ye + AntiRinging * safe_range2;
            Ysharp_final = clamp(Ysharp_post_eaa, Ylo2, Yhi2);
        }
    }

    float Ysharp = Ysharp_final;

    // === 色度段（降噪/去伪影/抗过冲） ===
    float2 gY  = float2(0.5*(Yf - Yd), 0.5*(Yh - Yb));
    float2 gCo = float2(0.5*(Cof - Cod), 0.5*(Coh - Cob));
    float2 gCg = float2(0.5*(Cgf - Cgd), 0.5*(Cgh - Cgb));

    float gy2   = dot(gY, gY) + 1e-12;
    float gco2  = dot(gCo, gCo);
    float gcg2  = dot(gCg, gCg);
    float gCmag = sqrt(gco2 + gcg2);
    float luma_strength   = sqrt(gy2);
    float chroma_strength = gCmag;

    float chroma_over_y = saturate( (chroma_strength - 0.50 * luma_strength) / (0.20 * max(MADref,1e-6)) );
    chroma_over_y *= ArtifactCOY;

    float2 gCdir = (gCmag > 1e-8) ? normalize(float2(gCo.x + gCg.x, gCo.y + gCg.y)) : float2(1,0);
    float2 gYdir = normalize(gY);
    float dir_mismatch = 1.0 - saturate(0.5 + 0.5 * dot(gCdir, gYdir));
    dir_mismatch *= ArtifactDirW;

    float cb_h = step(0.0, (Cof - Coo)*(Coo - Cod));
    float cb_v = step(0.0, (Coh - Coo)*(Coo - Cob));
    float checker_hint = 0.5*(cb_h + cb_v);

    float artifact_gate = saturate( 0.6*chroma_over_y + 0.4*dir_mismatch );
    artifact_gate = saturate( artifact_gate + CheckerBoost*checker_hint );

    float chroma_contrast = length(float2(Coo, Cgo));
    float guard_base = saturate( (chroma_contrast - 0.06) / 0.20 );
    float guard_lowL = (1.0 - saturate(luma_strength / max(MADref,1e-6)));
    float blue_guard = BlueGuard * guard_base * guard_lowL;

    float2 n = (luma_strength>1e-8) ? normalize(gY) : float2(0,1);
    float2 t = float2(-n.y, n.x);
    const float2 px = BUFFER_PIXEL_SIZE;

    float wC0= invL1_px(float2(0,0), px);
    float wT1= invL1_px(0.5 * t * px, px), wT2= invL1_px(-0.5 * t * px, px);
    float wT3= invL1_px(1.0 * t * px, px), wT4= invL1_px(-1.0 * t * px, px);
    float wN1= invL1_px(0.5 * n * px, px), wN2= invL1_px(-0.5 * n * px, px);
    float Wt = wC0 + wT1 + wT2 + wT3 + wT4 + 1e-6;
    float Wn = wN1 + wN2 + 1e-6;

    float Co_tan = (wC0*Coo + wT1*Cob + wT2*Coh + wT3*Cod + wT4*Cof) / Wt;
    float Cg_tan = (wC0*Cgo + wT1*Cgb + wT2*Cgh + wT3*Cgd + wT4*Cgf) / Wt;
    float Co_nor = (wN1*Cob + wN2*Cof) / Wn;
    float Cg_nor = (wN1*Cgb + wN2*Cgf) / Wn;

    float Co_use = Coo;
    float Cg_use = Cgo;

    float dirmix = ChromaDirMix;
    float Co_dirfix = lerp(Co_tan, Co_nor, dirmix);
    float Cg_dirfix = lerp(Cg_tan, Cg_nor, dirmix);

    float sup_amt = saturate(artifact_gate) * ChromaFollow * (1.0 - 0.7 * blue_guard);
    Co_use = lerp(Co_use, Co_dirfix, sup_amt);
    Cg_use = lerp(Cg_use, Cg_dirfix, sup_amt);

    if (ChromaDenoise > 0.0) {
        float flat   = 1.0 - saturate(madY / max(MADref, 1e-6));
        float noisyC = saturate(madC / max(4.0 * NoiseFloor, 1e-6));
        float dn_mask = 1.0 - 0.8 * saturate( luma_strength / max(luma_strength + chroma_strength + 1e-6, 1e-6) ) * (1.0 - dir_mismatch);
        float dn_amt = ChromaDenoise * flat * noisyC * dn_mask * (1.0 - 0.9 * blue_guard);
        if (dn_amt > 1e-4) {
            float w = wS1;
            float Co_acc = Coo * CenterWeight + (Cob + Cod + Cof + Coh) * (w);
            float Cg_acc = Cgo * CenterWeight + (Cgb + Cgd + Cgf + Cgh) * (w);
            float wsum   = CenterWeight + 4.0 * (w);
            float Co_lp  = Co_acc / max(wsum, 1e-6);
            float Cg_lp  = Cg_acc / max(wsum, 1e-6);
            Co_use = lerp(Co_use, Co_lp, dn_amt);
            Cg_use = lerp(Cg_use, Cg_lp, dn_amt);
        }
    }

    {
        float Co_min = min(min(min(min(Cob, Cod), Cof), Coh), Coo);
        float Co_max = max(max(max(max(Cob, Cod), Cof), Coh), Coo);
        float Cg_min = min(min(min(min(Cgb, Cgd), Cgf), Cgh), Cgo);
        float Cg_max = max(max(max(max(Cgb, Cgd), Cgf), Cgh), Cgo);
        float car = ChromaAR * (0.5 + 0.5 * saturate(artifact_gate));
        Co_use = clamp(Co_use, lerp(Coo, Co_min, car), lerp(Coo, Co_max, car));
        Cg_use = clamp(Cg_use, lerp(Cgo, Cg_min, car), lerp(Cgo, Cg_max, car));
    }

    float saturation_scale = 1.0;
    if (Ye > 1e-6) {
        saturation_scale = max(0.85, min(1.20, Ysharp / Ye));
        float dark_adapt = smoothstep(0.0, 0.1, Ye);
        saturation_scale = lerp(1.0, saturation_scale, dark_adapt);
    }
    Co_use *= saturation_scale;
    Cg_use *= saturation_scale;

    float3 lin = YCoCg_to_RGB(Ysharp, Co_use, Cg_use);
    lin = max(lin, 0.0); // 保留头尾给曲线
    // 不在这里 saturate，留给曲线与显示域限幅


    // ===================== 电影级调色引擎 (CCE) — 修正版 =====================
    float adapt_ev_dbg = 0.0, hl_mask_dbg = 0.0;

    if (EnableCCE)
    {
        // 0) 局部 EV（基于平滑亮度 Ybase）
        float Yloc = saturate(Ybase);
        float ev_local = 0.0;
        if (AdaptStrength > 0.0) {
            ev_local = log2( max(ToneMap_GrayPoint,1e-6) / max(Yloc,1e-6) );
            ev_local = clamp(ev_local, -AdaptLimitEV, AdaptLimitEV) * AdaptStrength;
        }
        float ev_total = ExposureEV + ev_local;
        adapt_ev_dbg = ev_total;

        // 1) 线性域：曝光 / 白平衡 / CDL
        float3 c = lin * exp2(ev_total);
        c = apply_wb(c, WB_Temp, WB_Tint);
        c = apply_cdl(c, CDL_Slope, CDL_Offset, CDL_Power);
        if (EnableSecondaryCDL) {
            c = apply_cdl(c, Secondary_Slope, Secondary_Offset, Secondary_Power);
        }

        // 2) 线性域：饱和&自然饱和&高光去饱和
        float Yt, Co_t, Cg_t; RGB_to_YCoCg(c, Yt, Co_t, Cg_t);
        float Cmag = length(float2(Co_t, Cg_t));
        float vibMask = saturate(1.0 - Cmag / 0.6);
        float WL   = pow(saturate(4.0 * Yt * (1.0 - Yt)), 1.1);
        float hlMask = highlight_mask(luma709(c)) * HL_Desat;
        hl_mask_dbg = hlMask;

        float satFactor = max(0.0, SatGlobal);
        satFactor += Vibrance * (vibMask * WL);
        satFactor *= (1.0 - hlMask);

        float3 c_sat = lerp(Yt.xxx, c, satFactor);

        // 3) 真实色调映射（场景线性 → 显示线性）
        float gp = max(ToneMap_GrayPoint, 1e-6);
        float wp = max(ToneMap_WhitePoint, 1.0);

        // 灰点归一（把输入灰点映射为 0.18）
        float exposure_for_gray = (0.18 / gp);
        float3 cm = c_sat * exposure_for_gray;

        float3 tm = cm;
        if (ToneMapProfile == 1)       tm = ACESFitted(cm);
        else if (ToneMapProfile == 2)  tm = Hable_UC2(cm, wp);
        else if (ToneMapProfile == 3)  tm = ReinhardExtended(cm, wp);
        else if (ToneMapProfile == 4)  tm = UchimuraUC2(cm, wp);

        float3 disp_lin = lerp(c_sat, tm, saturate(ToneMap_Mix)); // 曲线混合，避免“一开就死黑死白”

        // 4) 显示线性域：对比度（最后做）
        disp_lin = apply_contrast(disp_lin, Contrast, ContrastPivot);

        // 5) 限幅到显示域
        lin = saturate(disp_lin);
    }

    // LUT（显示域）
    if (EnableLUT) {
        lin = apply_lut(lin);
    }

    // 调试可视化
    if (DebugMode == 1) return float4(Ybase.xxx, 1.0);
    if (DebugMode == 2) return float4((Ye - Ybase).xxx, 1.0);
    if (DebugMode == 3) return float4(edge_strength.xxx, 1.0);
    if (DebugMode == 4) return float4(madC.xxx, 1.0);
    if (DebugMode == 5) return float4(scaa_mask.xxx, 1.0);
    if (DebugMode == 6) return float4(adapt_ev_dbg.xxx, 1.0);
    if (DebugMode == 7) return float4(hl_mask_dbg.xxx, 1.0);
    // 8 空
    if (DebugMode == 9)  return float4(madY.xxx, 1.0);
    if (DebugMode == 10) return float4(tangent_dbg.x, tangent_dbg.y, 0.0, 1.0);
    if (DebugMode == 11) return float4((Ydir_dbg - Ysharp_post_dp).xxx * 10.0 + 0.5, 1.0);
    if (DebugMode == 12) return float4(edge_uniformity.xxx, 1.0);
    if (DebugMode == 13) return float4(is_isolated_edge.xxx, 1.0);
    if (DebugMode == 14) return float4(AntiRinging.xxx, 1.0);
    if (DebugMode == 15) return float4(detail_compress.xxx, 1.0);
    if (DebugMode == 16) return float4(dbg_pos_scale.xxx * 10.0, 1.0);
    if (DebugMode == 17) return float4(dbg_neg_scale.xxx * 10.0, 1.0);

    return float4(lin, 1.0);
}

technique  BCAS_Workspace
{
    pass { VertexShader = PostProcessVS; PixelShader = BCAS_Cinema_PS; SRGBWriteEnable = true; } // 写出 sRGB
}
