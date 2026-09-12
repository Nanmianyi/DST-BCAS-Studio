// BCAS shadow silhouette vertex shader.
//
// Same entity pipeline as the vanilla anim vertex shader (non-skinned variant
// only - shadows are never skinned): MatrixW carries the world placement of
// each symbol, MatrixP/MatrixV project it. The atlas page index is packed into
// POS2D_UV.z as u + samplerIndex * 2, so it is unpacked here for the fragment
// stage.
uniform mat4 MatrixP;
uniform mat4 MatrixV;
uniform mat4 MatrixW;

attribute vec4 POS2D_UV;                  // x, y, u + samplerIndex * 2, v

varying vec3 PS_TEXCOORD;
varying vec3 PS_POS;

void main()
{
    vec3 POSITION = vec3(POS2D_UV.xy, 0.0);
    float samplerIndex = floor(POS2D_UV.z / 2.0);
    vec3 TEXCOORD0 = vec3(POS2D_UV.z - 2.0 * samplerIndex, POS2D_UV.w, samplerIndex);

    vec4 world_pos = MatrixW * vec4(POSITION, 1.0);
    gl_Position = MatrixP * MatrixV * world_pos;

    PS_TEXCOORD = TEXCOORD0;
    PS_POS = world_pos.xyz;
}
