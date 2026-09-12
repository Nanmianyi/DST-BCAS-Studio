// BCAS shadow silhouette vertex shader - SKINNED variant.
//
// Ported line for line from the engine's own anim.vs SKINNED branch (as shipped
// in anim_skinned.ksh). Needed because the projected shadows are rendered
// through the engine's skinned vertex layout: the vertex format packs a BONE
// INDEX into the upper bits of POS2D_UV.w, and only this branch unpacks it
// (POS2D_UV.w - 2.0 * boneIndex) and applies fastanim_bones.
//
// Using the plain (non-skinned) transform here was why the shadows came out
// chopped into pieces: with the bone index still in V every symbol sampled the
// wrong rows of the atlas.
//
// The engine picks this file next to bcas_shadow.ksh, the same way it picks
// anim_skinned.ksh next to anim.ksh - so this file is the skinned variant only,
// with the same uniform set as the engine's skinned shader (pv, fastanim_xform,
// fastanim_bones[64]). There is deliberately no non-skinned fallback branch in
// here: the ksh entry table has to match the compiled kernel exactly (an
// unused-but-bound uniform trips ANGLE's program-binary assertion), and the
// non-skinned case is covered by bcas_shadow.ksh.
uniform mat4 pv;
uniform mat4 fastanim_xform;
uniform vec4 fastanim_bones[64];

attribute vec4 POS2D_UV;                  // x, y, u + samplerIndex * 2, v + boneIndex * 2

varying vec3 PS_TEXCOORD;
varying vec3 PS_POS;

void main()
{
	float boneIndex = floor((POS2D_UV.w + 0.5) / 2.0);
	float samplerIndex = floor(POS2D_UV.z / 2.0);
	int matrix_index = int(boneIndex);
	vec3 TEXCOORD0 = vec3(POS2D_UV.z - 2.0 * samplerIndex,
	                      POS2D_UV.w - 2.0 * boneIndex, samplerIndex);

	float _a = fastanim_bones[matrix_index * 2].x;
	float _b = fastanim_bones[matrix_index * 2].y;
	float _c = fastanim_bones[matrix_index * 2].z;
	float _d = fastanim_bones[matrix_index * 2].w;
	float tx = fastanim_bones[matrix_index * 2 + 1].x;
	float ty = fastanim_bones[matrix_index * 2 + 1].y;

	mat4 matWorld = mat4(_a, _b, 0, 0,
	                     _c, _d, 0, 0,
	                     0, 0, 1, 0,
	                     tx, ty, 0, 1);	// column-major, exactly like anim.vs
	mat4 mat = fastanim_xform * matWorld;
	mat4 pvw = pv * mat;

	vec3 POSITION = vec3(POS2D_UV.xy, 0.0);
	vec4 world_pos = mat * vec4(POSITION, 1.0);
	gl_Position = pvw * vec4(POSITION, 1.0);

	PS_TEXCOORD = TEXCOORD0;
	PS_POS = world_pos.xyz;
}
