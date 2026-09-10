// BCAS ocean glint vertex shader.
//
// The quad lies flat on the ground (ANIM_ORIENTATION.OnGround); MatrixW
// carries the camera-follow placement. The camera world position is
// reconstructed from the view matrix here so the fragment stage gets a
// true per-pixel view vector without any per-pixel matrix math.
//
// Single non-skinned variant: the glint entity is a plain AnimState, never
// skinned, so the SKINNED branches of the vanilla anim shader are dropped
// (also keeps the uniform table exactly matching the ksh entries).
uniform mat4 MatrixP;
uniform mat4 MatrixV;
uniform mat4 MatrixW;

attribute vec4 POS2D_UV;                  // x, y, u + samplerIndex * 2, v

varying vec3 PS_TEXCOORD;
varying vec3 PS_POS;
varying vec3 PS_CAMERA_POS;

void main()
{
    vec3 POSITION = vec3(POS2D_UV.xy, 0.0);
    float samplerIndex = floor(POS2D_UV.z / 2.0);
    vec3 TEXCOORD0 = vec3(POS2D_UV.z - 2.0 * samplerIndex, POS2D_UV.w, samplerIndex);

    vec4 world_pos = MatrixW * vec4(POSITION, 1.0);
    gl_Position = MatrixP * MatrixV * world_pos;

    PS_TEXCOORD = TEXCOORD0;
    PS_POS = world_pos.xyz;

    // Camera world position: the view matrix holds the camera basis, with
    // MatrixV[3] = -R^T * camPos, so camPos = -R^T * t. Expanded by hand
    // because GLSL ES 1.00 has no transpose().
    vec3 view_trans = MatrixV[3].xyz;
    PS_CAMERA_POS = -vec3(
        dot(MatrixV[0].xyz, view_trans),
        dot(MatrixV[1].xyz, view_trans),
        dot(MatrixV[2].xyz, view_trans));
}
