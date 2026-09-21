#define SKINNED
#ifdef SKINNED
	uniform mat4 pv;
	uniform mat4 fastanim_xform;
	uniform vec4 fastanim_bones[64];
#else
	uniform mat4 MatrixP;
	uniform mat4 MatrixV;
	uniform mat4 MatrixW;
#endif
uniform vec4 TIMEPARAMS;
uniform vec3 FLOAT_PARAMS;

uniform vec3 CAMERARIGHT;

attribute vec4 POS2D_UV;                  // x, y, u + samplerIndex * 2, v

varying vec3 PS_TEXCOORD;
varying vec2 DA_LOCAL_METRES;
varying vec3 PS_POS;

#if defined( FADE_OUT ) || defined( HAUNT )
	uniform vec4 EROSION_PARAMS;
	uniform mat4 STATIC_WORLD_MATRIX;
	varying vec2 FADE_UV;

#	define EROSION_CAMERAROT			EROSION_PARAMS.w
#endif

#if defined( UI_HOLO )
	varying vec3 PS_TEXCOORD1;
#endif

#if defined( HOLO )
	float filmSkipRand() // This should match the function with the same name in anim.ps
	{
		float steps = 12.;
		float c = fract(sin(ceil(TIMEPARAMS.x * steps) / steps) * 10000.);
		return (c * -.36) * step(.78, c);
	}
#endif

void main()
{
#ifdef SKINNED
	// Oh damn, the samper index is encoded already in the POS2D_UV. Can I encode the array index in there as well?
	// sure we can
    	float boneIndex = floor((POS2D_UV.w + 0.5)/2.0);
    	float samplerIndex = floor(POS2D_UV.z/2.0);
	//int matrix_index = int(POSITION.z + 0.5);
	// This needs thought. There is already a V from UV in it. Can I maybe give up precision? I probably can, they're floats
	// Can I maybe store them as half floats? Does every shader model support that? HMMMMMM
        // Alternatively 4 bits from the U and 4 from the V
	int matrix_index = int(boneIndex);
    	vec3 TEXCOORD0 = vec3(POS2D_UV.z - 2.0*samplerIndex, POS2D_UV.w - 2.0 * boneIndex, samplerIndex);

	float _a = fastanim_bones[matrix_index*2].x;
	float _b = fastanim_bones[matrix_index*2].y;
	float _c = fastanim_bones[matrix_index*2].z;
	float _d = fastanim_bones[matrix_index*2].w;
	float tx = fastanim_bones[matrix_index*2+1].x;
	float ty = fastanim_bones[matrix_index*2+1].y;

	mat4 matWorld = mat4(_a,_b, 0, 0,
						 _c,_d, 0, 0,
						 0, 0, 1, 0,
						 tx, ty, 0, 1); // Column-major!

	mat4 mat = fastanim_xform * matWorld;
	mat4 pvw = pv * mat;

    	vec3 POSITION = vec3(POS2D_UV.xy, 0);
	gl_Position = pvw * vec4(POSITION, 1.0); 

	vec4 world_pos = mat * vec4( POSITION, 1.0 );
//	gl_Position = pv * vec4(POSITION, 1.0);
#else
    	vec3 POSITION = vec3(POS2D_UV.xy, 0);
	// Take the samplerIndex out of the U.
    float samplerIndex = floor(POS2D_UV.z/2.0);
    vec3 TEXCOORD0 = vec3(POS2D_UV.z - 2.0*samplerIndex, POS2D_UV.w, samplerIndex);

	vec3 object_pos = POSITION.xyz;
	vec4 world_pos = MatrixW * vec4( object_pos, 1.0 );

	if(FLOAT_PARAMS.z > 0.0)
	{
		float world_x = MatrixW[3][0];
		float world_z = MatrixW[3][2];
		world_pos.y += sin(world_x + world_z + TIMEPARAMS.x * 3.0) * 0.025;
	}

	mat4 mtxPV = MatrixP * MatrixV;
	gl_Position = mtxPV * world_pos;

#endif

	#if defined( HOLO )
		float filmSkipOffset = sin(filmSkipRand()) * .4;
		gl_Position.y += filmSkipOffset;
	#endif

	PS_TEXCOORD = TEXCOORD0;
	PS_POS = world_pos.xyz;
	// >>> BCAS/DA: per-symbol local metres, the only legal source for the
	// relief normal. Ported from daylight_architecture (shader_src/*.vert).
	// The engine may use a per-symbol MatrixW on the ordinary draw path; the
	// skinned path carries it in fastanim_xform instead.
#ifdef SKINNED
	vec3 da_origin = fastanim_xform[3].xyz;
	vec3 da_right = fastanim_xform[0].xyz;
#else
	vec3 da_origin = MatrixW[3].xyz;
	vec3 da_right = MatrixW[0].xyz;
#endif
	da_right /= max(length(da_right), 0.0001);
	vec3 da_delta = world_pos.xyz - da_origin;
	DA_LOCAL_METRES = vec2(dot(da_delta, da_right), da_delta.y);
	// <<< BCAS/DA

#if defined( FADE_OUT ) || defined( HAUNT )
	vec4 static_world_pos = STATIC_WORLD_MATRIX * vec4( POSITION.xyz, 1.0 );
    FADE_UV = vec2( static_world_pos.x / 4.0, static_world_pos.y / 8.0 );
	// Do we want a camera space wiggle
	if (EROSION_CAMERAROT != 0.0)
	{
		float camera_x = MatrixV[3][0];
		float camera_z = MatrixV[3][2];
		vec2 cam_pos = vec2(camera_x, camera_z);

		float obj_x = STATIC_WORLD_MATRIX[3][0];
		float obj_z = STATIC_WORLD_MATRIX[3][2];

		vec2 obj_pos = vec2(obj_x, obj_z);
		vec2 delta = obj_pos - cam_pos;

		// add some lateral parallax
		vec2 right_vec = CAMERARIGHT.xz;
		vec2 forward_vec = normalize(vec2(-CAMERARIGHT.z, CAMERARIGHT.x));
		float right = dot(delta, right_vec);
		float forward = dot(delta, forward_vec);
		vec2 totdelta = forward_vec * delta.y + right_vec * -delta.x;
		totdelta.y = -totdelta.y;
		FADE_UV += (totdelta * 0.05);
	}
#endif

#if defined( UI_HOLO )
	PS_TEXCOORD1 = gl_Position.xyw;
#endif
}
