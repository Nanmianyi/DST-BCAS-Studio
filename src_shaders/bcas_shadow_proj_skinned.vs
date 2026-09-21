// BCAS shadow projection - vertex stage (bloom render pass).
//
// This is the whole shadow system. Every animated entity is drawn a second
// time per frame into the engine's bloom buffer (RENDERPASS.BLOOM, the pass
// the engine itself uses for glow). We hijack that second draw and, instead
// of writing glow, project the entity's geometry onto the ground along the
// sun's world direction:
//
//     ground.xz = world.xz + world.y * shadow_dir_xz * (1 / tan(elevation))
//
// Every vertex carries its own world height (MatrixW column 3), so the canopy
// of a tree lands far from its trunk and the base lands at the trunk: this is
// a true perspective-free oblique projection of the entity's own current
// geometry - skin, equipment, mount, growth stage, animation frame all folded
// in by the engine's own matrix. Nothing is mirrored, cloned or kept in sync.
//
// WHY THE WORLD DIRECTION IS DERIVED HERE
// The module bus (FLOAT_PARAMS, shared with the surface-light pass) carries
// the sun as a camera-space azimuth (theta): cos(theta) is left/right in the
// camera frame, sin(theta) is toward/away from the viewer. The world XZ
// direction is recovered from the camera basis carried by the view matrix
// (GLSL columns: MatrixV[0] is column 0, so row 0 - the camera right axis in
// world space - is vec3(MatrixV[0].x, MatrixV[1].x, MatrixV[2].x)). That is
// the same convention the engine's own fade shader uses when it reads
// MatrixV[3][0] / MatrixV[3][2] as the camera position.
//
//   sun_world  = cos(theta) * camera_right_xz + sin(theta) * camera_back_xz
//   shadow_dir = -sun_world                      (the shadow points away)
//
// On-screen the shadow direction then matches the surface lighting for free:
// both consume the same theta, so a lit face and its cast shadow can never
// disagree.
//
// Flat quads (dropped items, small critters, ground decals) have world.y == 0
// at every vertex: ground == world, so they project onto themselves. That is
// the correct answer - a flat object only has its contact edge - and it needs
// no special case.
//
// Uniform budget: derived from the engine's anim_bloom.ksh entry table
// (MatrixP, MatrixV, MatrixW, SAMPLER). FLOAT_PARAMS is added to that table by
// the generator (the engine binds it on the entity path - anim_bloom_ghost.ksh
// ships with exactly this entry, which is what proves the binding exists).
//
// Every declared uniform must be referenced or the compiler drops it, the
// engine's location lookup returns -1, and ANGLE asserts.
uniform mat4 MatrixP;
uniform mat4 MatrixV;
uniform mat4 MatrixW;
uniform vec3 FLOAT_PARAMS;

attribute vec4 POS2D_UV;                   // x, y, u + samplerIndex * 2, v

varying vec3 PS_TEXCOORD;
varying vec3 PS_POS;                       // projected (ground) world position

void main()
{
    vec3 POSITION = vec3(POS2D_UV.xy, 0.0);
    float samplerIndex = floor(POS2D_UV.z / 2.0);
    vec3 TEXCOORD0 = vec3(POS2D_UV.z - 2.0 * samplerIndex, POS2D_UV.w, samplerIndex);

    vec4 world_pos = MatrixW * vec4(POSITION, 1.0);

    // FLOAT_PARAMS = (packed, packed, packed). The y/z slots have carried a
    // packed payload since 2026-09-21 (layout + rationale: bcas_surface_light.lua
    // M.PackY; spec proven by tools/bus_pack_proof.py) and both MUST stay
    // negative: the engine's `y > 0` discard / `z > 0` bob branches stay asleep.
    // Since 2026-09-22 x carries a payload too (bcas_surface_light.lua M.PackX):
    //   x = cool_q + 64*dark_q + 4096*f_q
    // f_q -- the azimuth this pass needs -- is the HIGH half: floor(x / 4096.0).
    // The LOW 12 bits (x mod 4096 = cool_q + 64*dark_q) are the two backlight
    // sliders, which only the surface-light pixel stage reads.
    // x is a large positive integer now, which is safe: every
    // engine read of FLOAT_PARAMS.x sits inside `if(FLOAT_PARAMS.y > 0.0)`
    // (7 sites in the shipped shaders.zip -- work/_recon12.py), and our y is
    // always negative, so those branches never run.
    float f_q = floor(FLOAT_PARAMS.x / 4096.0);
    float theta = (f_q / 4096.0) * 6.28318530718 - 3.14159265359;
    float el = (mod(-FLOAT_PARAMS.y, 2048.0) / 2047.0) * 1.5707963268;

    // Camera world basis from the view matrix rows (row 0 = right, row 2 =
    // back; the engine's GetDownVec convention: scene -> camera is +back).
    //
    // BOTH HORIZONTAL PROJECTIONS ARE NORMALIZED ON PURPOSE (2026-09-21 fix).
    // theta lives in the HORIZONTAL basis Lua builds from the heading
    // (followcamera.lua:104-111): R = GetRightVec() = (cos(h+90), 0, sin(h+90))
    // and D = GetDownVec() = (cos(h), 0, sin(h)). These matrix rows are the
    // TILTED camera basis instead: row 2 (back) is
    // (cos(p)*cos(h), sin(p), cos(p)*sin(h)), so cback.xz == cos(p) * D.
    // The un-normalized sum evaluated cos(theta)*R + sin(theta)*cos(p)*D --
    // the view-axis part squeezed by cos(p), rotating the shadow away from the
    // sun (max 19.5 deg measured). And p is not constant: followcamera.lua:396/
    // 525 sweeps pitch 30 deg (closest) .. 60 deg (farthest) with the zoom
    // wheel, so cos(p) sweeps 0.866 .. 0.5 -- hence the drift while zooming.
    // Normalizing restores the exact basis the Lua encoder used. Lengths only.
    vec3 cright = vec3(MatrixV[0].x, MatrixV[1].x, MatrixV[2].x);
    vec3 cback = vec3(MatrixV[0].z, MatrixV[1].z, MatrixV[2].z);
    vec2 r_h = cright.xz;
    vec2 b_h = cback.xz;
    float r_len = length(r_h);
    float b_len = length(b_h);
    vec2 cam_right = r_len > 1e-5 ? r_h / r_len : vec2(1.0, 0.0);
    // If the back axis has no horizontal part at all (camera pitched straight
    // down at 90 deg) use the right axis' perpendicular: the constant (0,1)
    // would coincide with the right axis for some headings, making
    // cos(theta)+sin(theta) vanish and the direction collapse.
    vec2 cam_back = b_len > 1e-5 ? b_h / b_len : vec2(-cam_right.y, cam_right.x);
    vec2 sun_dir = cam_right * cos(theta) + cam_back * sin(theta);
    float sun_len = max(length(sun_dir), 1e-4);
    vec2 shadow_dir = -sun_dir / sun_len;

    // 1/tan(el) is the sundial's own shadow-length factor (scale_y); its band is
    // 0.8 (noon) .. 2.4 (sunset / full moon) by bcas_sun_emitter.lua. The old
    // clamp was 0.25 .. 4.0 and those ends were the reported artefacts: at night
    // the bus elevation is the direction to the nearest light, so a torch gives
    // 3..11 and clamped to 4.0 = a needle, a lantern overhead gives 0.25 = a
    // blob. Keeping the light *direction* but clamping the *length* to the
    // sundial's tuned band removes both.
    float stretch = clamp(1.0 / max(tan(max(el, 0.06)), 0.02), 0.8, 2.4);

    float y = world_pos.y;
    vec2 ground_xz = world_pos.xz + shadow_dir * (y * stretch);

    // The ground plane offset keeps the raster above the terrain the same way
    // the discarded dummy system did (0.06 world units): sprites drawn later
    // at the same screen pixel do not fight the ground mesh.
    vec4 ground_pos = vec4(ground_xz.x, 0.06, ground_xz.y, 1.0);

    gl_Position = MatrixP * MatrixV * ground_pos;

    PS_TEXCOORD = TEXCOORD0;
    PS_POS = ground_pos.xyz;
}
