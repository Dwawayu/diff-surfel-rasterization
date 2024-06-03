/*
 * Copyright (C) 2023, Inria
 * GRAPHDECO research group, https://team.inria.fr/graphdeco
 * All rights reserved.
 *
 * This software is free for non-commercial, research and evaluation use 
 * under the terms of the LICENSE.md file.
 *
 * For inquiries contact  george.drettakis@inria.fr
 */

#include "forward.h"
#include "auxiliary.h"
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
namespace cg = cooperative_groups;

// Forward method for converting the input spherical harmonics
// coefficients of each Gaussian to a simple RGB color.
__device__ glm::vec3 computeColorFromSH(int idx, int deg, int max_coeffs, const glm::vec3* means, glm::vec3 campos, const float* shs, bool* clamped)
{
	// The implementation is loosely based on code for 
	// "Differentiable Point-Based Radiance Fields for 
	// Efficient View Synthesis" by Zhang et al. (2022)
	glm::vec3 pos = means[idx];
	glm::vec3 dir = pos - campos;
	dir = dir / glm::length(dir);

	glm::vec3* sh = ((glm::vec3*)shs) + idx * max_coeffs;
	glm::vec3 result = SH_C0 * sh[0];

	if (deg > 0)
	{
		float x = dir.x;
		float y = dir.y;
		float z = dir.z;
		result = result - SH_C1 * y * sh[1] + SH_C1 * z * sh[2] - SH_C1 * x * sh[3];

		if (deg > 1)
		{
			float xx = x * x, yy = y * y, zz = z * z;
			float xy = x * y, yz = y * z, xz = x * z;
			result = result +
				SH_C2[0] * xy * sh[4] +
				SH_C2[1] * yz * sh[5] +
				SH_C2[2] * (2.0f * zz - xx - yy) * sh[6] +
				SH_C2[3] * xz * sh[7] +
				SH_C2[4] * (xx - yy) * sh[8];

			if (deg > 2)
			{
				result = result +
					SH_C3[0] * y * (3.0f * xx - yy) * sh[9] +
					SH_C3[1] * xy * z * sh[10] +
					SH_C3[2] * y * (4.0f * zz - xx - yy) * sh[11] +
					SH_C3[3] * z * (2.0f * zz - 3.0f * xx - 3.0f * yy) * sh[12] +
					SH_C3[4] * x * (4.0f * zz - xx - yy) * sh[13] +
					SH_C3[5] * z * (xx - yy) * sh[14] +
					SH_C3[6] * x * (xx - 3.0f * yy) * sh[15];
			}
		}
	}
	result += 0.5f;

	// RGB colors are clamped to positive values. If values are
	// clamped, we need to keep track of this for the backward pass.
	clamped[3 * idx + 0] = (result.x < 0);
	clamped[3 * idx + 1] = (result.y < 0);
	clamped[3 * idx + 2] = (result.z < 0);
	return glm::max(result, 0.0f);
}


__device__ bool computeCov3D(const glm::vec3 &p_world, const glm::vec4 &quat, const glm::vec2 &scale, const float *viewmat, const float4 &intrins, float tan_fovx, float tan_fovy, float* cov3D, float3 &normal) {
	// camera information 
	const glm::mat3 W = glm::mat3(
		viewmat[0],viewmat[1],viewmat[2],
		viewmat[4],viewmat[5],viewmat[6],
		viewmat[8],viewmat[9],viewmat[10]
	); // viewmat 


	const glm::vec3 cam_pos = glm::vec3(viewmat[12], viewmat[13], viewmat[14]); // camera center
	const glm::mat4 P = glm::mat4(
		intrins.x, 0.0, 0.0, 0.0,
		0.0, intrins.y, 0.0, 0.0,
		intrins.z, intrins.w, 1.0, 1.0,
		0.0, 0.0, 0.0, 0.0
	);

	glm::vec3 p_view = W * p_world + cam_pos;
	glm::mat3 R = quat_to_rotmat(quat) * scale_to_mat({scale.x, scale.y, 1.0f}, 1.0f);

#if VIEW_FRUSTUM_CULLING
#if PLUS_R
	const float r = max(glm::length(R[0]), glm::length(R[1])) / p_view.z;
#else
	const float r = 0.0f;
#endif
	const float limx = CLIP_THRESH * tan_fovx + r;
	const float limy = CLIP_THRESH * tan_fovy + r;
	// culing spalt that outside the view frustum
	const float pxpz = (p_view.x) / p_view.z;
	const float pypz = (p_view.y) / p_view.z;
#if HARD_CULLING
	if (pxpz < -limx || pxpz > limx || pypz < -limy || pypz > limy) {
		return false;
	}
#else
	p_view.x = min(limx, max(-limx, pxpz)) * p_view.z;
	p_view.y = min(limy, max(-limy, pypz)) * p_view.z;
#endif
#endif

	glm::mat3 M = glm::mat3(W * R[0], W * R[1], p_view);
	// don't draw if the matrix is singular
	// if (glm::determinant(M) == 0.0f) return false;
	// back face culling ? or parallel face culling?
	glm::vec3 tn = W*R[2];
	float cos = glm::dot(-tn, p_view);
	if (cos == 0.0f) return false;

#if RENDER_AXUTILITY and DUAL_VISIABLE
	float multiplier = cos > 0 ? 1 : -1;
	tn *= multiplier;
#endif

	glm::mat4x3 T = glm::transpose(P * glm::mat3x4(
		glm::vec4(M[0], 0.0),
		glm::vec4(M[1], 0.0),
		glm::vec4(M[2], 1.0)
	));

	cov3D[0] = T[0].x;
	cov3D[1] = T[0].y;
	cov3D[2] = T[0].z;
	cov3D[3] = T[1].x;
	cov3D[4] = T[1].y;
	cov3D[5] = T[1].z;
	cov3D[6] = T[2].x;
	cov3D[7] = T[2].y;
	cov3D[8] = T[2].z;
	normal = {tn.x, tn.y, tn.z};
	return true;
}

__device__ bool computeCenter(const float *cov3D, float2 & center, float2 & extent) {
	glm::mat4x3 T = glm::mat4x3(
		cov3D[0], cov3D[1], cov3D[2],
		cov3D[3], cov3D[4], cov3D[5],
		cov3D[6], cov3D[7], cov3D[8],
		cov3D[6], cov3D[7], cov3D[8]
	);

	float d = glm::dot(glm::vec3(1.0, 1.0, -1.0), T[3] * T[3]);
	
	if (d == 0.0f) return false;

	glm::vec3 f = glm::vec3(1.0, 1.0, -1.0) * (1.0f / d);

	glm::vec3 p = glm::vec3(
		glm::dot(f, T[0] * T[3]),
		glm::dot(f, T[1] * T[3]), 
		glm::dot(f, T[2] * T[3]));
	
	glm::vec3 h0 = p * p - 
		glm::vec3(
			glm::dot(f, T[0] * T[0]),
			glm::dot(f, T[1] * T[1]), 
			glm::dot(f, T[2] * T[2])
		);

	glm::vec3 h = sqrt(max(glm::vec3(0.0), h0)) + glm::vec3(0.0, 0.0, 1e-2);
	center = {p.x, p.y};
	extent = {h.x, h.y};
	return true;
}

// Perform initial steps for each Gaussian prior to rasterization.
template<int C>
__global__ void preprocessCUDA(int P, int D, int M,
	const float* orig_points,
	const glm::vec2* scales,
	const float scale_modifier,
	const glm::vec4* rotations,
	const float* opacities,
	const float* shs,
	bool* clamped,
	const float* cov3D_precomp,
	// const float* colors_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const glm::vec3* cam_pos,
	const int W, int H,
	const float tan_fovx, const float tan_fovy,
	const float focal_x, const float focal_y,
	int* radii,
	float2* points_xy_image,
	float* depths,
	float* cov3Ds,
	float* rgb,
	float4* conic_opacity,
	const dim3 grid,
	uint32_t* tiles_touched,
	bool prefiltered)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	// Initialize radius and touched tiles to 0. If this isn't changed,
	// this Gaussian will not be processed further.
	radii[idx] = 0;
	tiles_touched[idx] = 0;

	glm::vec3 p_world = glm::vec3(orig_points[3 * idx], orig_points[3 * idx + 1], orig_points[3 * idx + 2]);
	// Perform near culling, quit if outside.
	float3 p_view;
	if (!in_frustum(idx, orig_points, viewmatrix, projmatrix, prefiltered, p_view))
		return;
	
	float4 intrins = {focal_x, focal_y, float(W)/2.0, float(H)/2.0};
	glm::vec2 scale = scales[idx];
	glm::vec4 quat = rotations[idx];
	// view frustum cullling TODO
	const float* cov3D;
	bool ok;
	float3 normal;
	if (cov3D_precomp != nullptr)
	{
		cov3D = cov3D_precomp + idx * 9;
	}
	else
	{
		ok = computeCov3D(p_world, quat, scale, viewmatrix, intrins, tan_fovx, tan_fovy, cov3Ds + idx * 9, normal);
		if (!ok) return;
		cov3D = cov3Ds + idx * 9;
	}
	
	//  compute center and extent
	float2 center;
	float2 extent;
	ok = computeCenter(cov3D, center, extent);
	if (!ok) return;

	// add the bounding of countour
#if TIGHTBBOX
	// the effective extent is now depended on the opacity of gaussian.
	float truncated_R = sqrtf(max(9.f + logf(opacities[idx]), 0.000001));
	// if (truncated_R < 1.0) printf("%.2f\n", truncated_R);
#else
	float truncated_R = 3.f;
#endif
	float radius = ceil(truncated_R * max(max(extent.x, extent.y), FilterSize));

	uint2 rect_min, rect_max;
	getRect(center, radius, rect_min, rect_max, grid);
	if ((rect_max.x - rect_min.x) * (rect_max.y - rect_min.y) == 0)
		return;

	// compute colors 
	// if (colors_precomp == nullptr) {
	glm::vec3 result = computeColorFromSH(idx, D, M, (glm::vec3*)orig_points, *cam_pos, shs, clamped);
	rgb[idx * C + 0] = result.x;
	rgb[idx * C + 1] = result.y;
	rgb[idx * C + 2] = result.z;
	// }

	// assign values
	depths[idx] = p_view.z;
	radii[idx] = (int)radius;
	points_xy_image[idx] = center;
	conic_opacity[idx] = {normal.x, normal.y, normal.z, opacities[idx]};
	tiles_touched[idx] = (rect_max.y - rect_min.y) * (rect_max.x - rect_min.x);

	// if (idx % 32 == 0) {
	//     printf("%d center %.4f %.4f\n", idx, center.x, center.y);
	//     printf("%d extent %.4f %.4f %.4f\n", idx, extent.x, extent.y);
	// }
}

// Main rasterization method. Collaboratively works on one tile per
// block, each thread treats one pixel. Alternates between fetching 
// and rasterizing data.
template <uint32_t CHANNELS>
__global__ void __launch_bounds__(BLOCK_X * BLOCK_Y)
renderCUDA(
	const uint2* __restrict__ ranges,
	const uint32_t* __restrict__ point_list,
	int W, int H,
	float focal_x, float focal_y,
	const float2* __restrict__ points_xy_image,
	const float* __restrict__ features,
	const float* __restrict__ features_misc,
	const float* __restrict__ cov3Ds,
	const float* __restrict__ depths,
	const float4* __restrict__ conic_opacity,
	float* __restrict__ final_T,
	uint32_t* __restrict__ n_contrib,
	const float* __restrict__ bg_color,
	const int channel_misc,
	float* __restrict__ out_color,
	float* __restrict__ out_depth,
	float* __restrict__ out_misc)
{
	// Identify current tile and associated min/max pixel range.
	auto block = cg::this_thread_block();
	uint32_t horizontal_blocks = (W + BLOCK_X - 1) / BLOCK_X;
	uint2 pix_min = { block.group_index().x * BLOCK_X, block.group_index().y * BLOCK_Y };
	uint2 pix_max = { min(pix_min.x + BLOCK_X, W), min(pix_min.y + BLOCK_Y , H) };
	uint2 pix = { pix_min.x + block.thread_index().x, pix_min.y + block.thread_index().y };
	uint32_t pix_id = W * pix.y + pix.x;
	float2 pixf = { (float)pix.x + 0.5, (float)pix.y + 0.5};

	// Check if this thread is associated with a valid pixel or outside.
	bool inside = pix.x < W&& pix.y < H;
	// Done threads can help with fetching, but don't rasterize
	bool done = !inside;

	// Load start/end range of IDs to process in bit sorted list.
	uint2 range = ranges[block.group_index().y * horizontal_blocks + block.group_index().x];
	const int rounds = ((range.y - range.x + BLOCK_SIZE - 1) / BLOCK_SIZE);
	int toDo = range.y - range.x;

	// Allocate storage for batches of collectively fetched data.
	__shared__ int collected_id[BLOCK_SIZE];
	__shared__ float2 collected_xy[BLOCK_SIZE];
	__shared__ float4 collected_conic_opacity[BLOCK_SIZE];
	__shared__ float3 collected_Tu[BLOCK_SIZE];
	__shared__ float3 collected_Tv[BLOCK_SIZE];
	__shared__ float3 collected_Tw[BLOCK_SIZE];

	// Initialize helper variables
	float T = 1.0f;
	uint32_t contributor = 0;
	uint32_t last_contributor = 0;
	float C[CHANNELS] = { 0 };


#if RENDER_AXUTILITY
	// render axutility ouput
	float D = { 0 };
	float N[3] = {0};
	float dist1 = {0};
	float dist2 = {0};
	float distortion = {0};
	float max_depth = {0};
	float max_weight = {0};
	float max_contributor = {-1};

#endif

	extern __shared__ float acc_miscs[];
	// float misc[3] = { 0 };
	float* misc = acc_miscs + channel_misc * block.thread_rank();
	for (int ch = 0; ch < channel_misc; ch++)
		misc[ch] = 0;

	// Iterate over batches until all done or range is complete
	for (int i = 0; i < rounds; i++, toDo -= BLOCK_SIZE)
	{
		// End if entire block votes that it is done rasterizing
		int num_done = __syncthreads_count(done);
		if (num_done == BLOCK_SIZE)
			break;

		// Collectively fetch per-Gaussian data from global to shared
		int progress = i * BLOCK_SIZE + block.thread_rank();
		if (range.x + progress < range.y)
		{
			int coll_id = point_list[range.x + progress];
			collected_id[block.thread_rank()] = coll_id;
			collected_xy[block.thread_rank()] = points_xy_image[coll_id];
			collected_conic_opacity[block.thread_rank()] = conic_opacity[coll_id];
			collected_Tu[block.thread_rank()] = {cov3Ds[9 * coll_id+0], cov3Ds[9 * coll_id+1], cov3Ds[9 * coll_id+2]};
			collected_Tv[block.thread_rank()] = {cov3Ds[9 * coll_id+3], cov3Ds[9 * coll_id+4], cov3Ds[9 * coll_id+5]};
			collected_Tw[block.thread_rank()] = {cov3Ds[9 * coll_id+6], cov3Ds[9 * coll_id+7], cov3Ds[9 * coll_id+8]};
		}
		block.sync();

		// Iterate over current batch
		for (int j = 0; !done && j < min(BLOCK_SIZE, toDo); j++)
		{
			// Keep track of current position in range
			contributor++;

			// compute ray-splat intersection
			// float2 xy = collected_xy[j];
			float3 Tu = collected_Tu[j];
			float3 Tv = collected_Tv[j];
			float3 Tw = collected_Tw[j];
			// compute two planes intersection as the ray intersection
			float3 k = {-Tu.x + pixf.x * Tw.x, -Tu.y + pixf.x * Tw.y, -Tu.z + pixf.x * Tw.z};
			float3 l = {-Tv.x + pixf.y * Tw.x, -Tv.y + pixf.y * Tw.y, -Tv.z + pixf.y * Tw.z};

			float3 p = crossProduct(k, l);

#if SKIL_NEGATIVE
			if (p.z == 0.0) continue; // there is not intersection
#endif

			float2 s = {p.x / p.z, p.y / p.z};
			float rho3d = (s.x * s.x + s.y * s.y); // splat distance
			
			// add low pass filter according to Botsch et al. [2005]. 
			float2 xy = collected_xy[j];
			float2 d = {xy.x - pixf.x, xy.y - pixf.y};
			float rho2d = FilterInvSquare * (d.x * d.x + d.y * d.y); // screen distance
			float rho = min(rho3d, rho2d);
			
			// compute accurate depth when necessary
#if RENDER_AXUTILITY and INTERSECT_DEPTH
			// float depth = (s.x * Tw.x + s.y * Tw.y) + Tw.z;
			float depth = (rho3d <= rho2d) ? (s.x * Tw.x + s.y * Tw.y) + Tw.z : Tw.z; // splat depth
#if SKIL_NEGATIVE
			if (depth < NEAR_PLANE) continue;
#endif
#else
			float depth = Tw.z; // center depth
#endif
			float4 con_o = collected_conic_opacity[j];
			float normal[3] = {con_o.x, con_o.y, con_o.z};
			float power = -0.5f * rho;
			// power = -0.5f * 100.f * max(rho - 1, 0.0f);
			if (power > 0.0f)
				continue;

			// Eq. (2) from 3D Gaussian splatting paper.
			// Obtain alpha by multiplying with Gaussian opacity
			// and its exponential falloff from mean.
			// Avoid numerical instabilities (see paper appendix). 
			float alpha = min(0.99f, con_o.w * exp(power));
			if (alpha < 1.0f / 255.0f)
				continue;
			float test_T = T * (1 - alpha);
			if (test_T < 0.0001f)
			{
				done = true;
				continue;
			}

			float weight = alpha * T;

#if RENDER_AXUTILITY
// render distortion map
			float A = 1-T;
#if MAPPED_Z
			float mapped_depth = (FAR_PLANE * depth - FAR_PLANE * NEAR_PLANE) / ((FAR_PLANE - NEAR_PLANE) * depth);
#else		
			float mapped_depth = depth;
#endif
			float error = mapped_depth * mapped_depth * A + dist2 - 2 * mapped_depth * dist1;
			distortion += error * weight;

			// if (alpha * T >= max_weight) {
			if (T > 0.5) {
				max_depth = depth;
				max_weight = weight;
				max_contributor = contributor;
			}

#if DEBUG
			if (collected_id[j] > 0 && pix.x == W / 4 && pix.y == H / 2) {
				printf("%d forward %d %d\n", contributor, pix.x, pix.y);
				printf("%d forward %d normal %.4f %.4f %.4f\n", contributor, normal[0], normal[1], normal[2]);
				printf("%d forward %d A %.8f\n", contributor, collected_id[j], A);
				printf("%d forward %d depth %.8f\n", contributor, collected_id[j], depth);
				printf("%d forward %d D %.8f\n", contributor, collected_id[j], D);
				printf("%d forward %d alpha %.8f\n", contributor, collected_id[j], alpha);
				printf("%d forward %d last_alpha %.8f\n", contributor, collected_id[j], 1-T);
				printf("%d forward %d A %.8f\n", contributor, collected_id[j], A);
				printf("%d forward %d error %.8f\n", contributor, collected_id[j], error);
				printf("%d forward %d loss %.8f\n", contributor, collected_id[j], distortion);
				printf("%d forward %d map_depth %.8f\n", contributor, collected_id[j], mapped_depth);
				printf("%d forward %d contrib %d\n", contributor, collected_id[j], max_contributor);
				printf("-----------\n");
			}
#endif
			// render normal map
			for (int ch=0; ch<3; ch++) N[ch] += normal[ch] * weight;

			// render depth map
			D += depth * weight;
			// mapped depth
			dist1 += mapped_depth * weight;
			dist2 += mapped_depth * mapped_depth * weight;
#endif

			// Eq. (3) from 3D Gaussian splatting paper.
			for (int ch = 0; ch < CHANNELS; ch++)
				C[ch] += features[collected_id[j] * CHANNELS + ch] * weight;
			for (int ch = 0; ch < channel_misc; ch++)
				misc[ch] += features_misc[collected_id[j] * channel_misc + ch] * weight;
			T = test_T;

			// Keep track of last range entry to update this
			// pixel.
			last_contributor = contributor;
		}
	}

	// All threads that treat valid pixel write out their final
	// rendering data to the frame and auxiliary buffers.
	if (inside)
	{
		final_T[pix_id] = T;
		n_contrib[pix_id] = last_contributor;
		for (int ch = 0; ch < CHANNELS; ch++)
			out_color[ch * H * W + pix_id] = C[ch] + T * bg_color[ch];
		for (int ch = 0; ch < channel_misc; ch++)
			out_misc[ch * H * W + pix_id] = misc[ch];

#if RENDER_AXUTILITY
		n_contrib[pix_id + H * W] = max_contributor;
		final_T[pix_id + H * W] = dist1;
		final_T[pix_id + 2 * H * W] = dist2;
		out_depth[pix_id + DEPTH_OFFSET * H * W] = D;
		out_depth[pix_id + ALPHA_OFFSET * H * W] = 1 - T;
		for (int ch=0; ch<3; ch++) out_depth[pix_id + (NORMAL_OFFSET+ch) * H * W] = N[ch];
		out_depth[pix_id + MAXDEPTH_OFFSET * H * W] = max_depth;
		out_depth[pix_id + DISTORTION_OFFSET * H * W] = distortion;
		out_depth[pix_id + MAX_WEIGHT_OFFSET * H * W] = max_weight;
#endif
	}
}

void FORWARD::render(
	const dim3 grid, dim3 block,
	const uint2* ranges,
	const uint32_t* point_list,
	int W, int H,
	float focal_x, float focal_y,
	const float2* means2D,
	const float* colors,
	const float* colors_precomp,
	const float* cov3Ds,
	const float* depths,
	const float4* conic_opacity,
	float* final_T,
	uint32_t* n_contrib,
	const float* bg_color,
	const int channel_misc,
	float* out_color,
	float* out_depth,
	float* out_misc)
{
	renderCUDA<NUM_CHANNELS> << <grid, block, channel_misc * BLOCK_SIZE * sizeof(float)>> > (
		ranges,
		point_list,
		W, H,
		focal_x, focal_y,
		means2D,
		colors,
		colors_precomp,
		cov3Ds,
		depths,
		conic_opacity,
		final_T,
		n_contrib,
		bg_color,
		channel_misc,
		out_color,
		out_depth,
		out_misc);
}

void FORWARD::preprocess(int P, int D, int M,
	const float* means3D,
	const glm::vec2* scales,
	const float scale_modifier,
	const glm::vec4* rotations,
	const float* opacities,
	const float* shs,
	bool* clamped,
	const float* cov3D_precomp,
	// const float* colors_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const glm::vec3* cam_pos,
	const int W, const int H,
	const float focal_x, const float focal_y,
	const float tan_fovx, const float tan_fovy,
	int* radii,
	float2* means2D,
	float* depths,
	float* cov3Ds,
	float* rgb,
	float4* conic_opacity,
	const dim3 grid,
	uint32_t* tiles_touched,
	bool prefiltered)
{
	preprocessCUDA<NUM_CHANNELS> << <(P + 255) / 256, 256 >> > (
		P, D, M,
		means3D,
		scales,
		scale_modifier,
		rotations,
		opacities,
		shs,
		clamped,
		cov3D_precomp,
		// colors_precomp,
		viewmatrix, 
		projmatrix,
		cam_pos,
		W, H,
		tan_fovx, tan_fovy,
		focal_x, focal_y,
		radii,
		means2D,
		depths,
		cov3Ds,
		rgb,
		conic_opacity,
		grid,
		tiles_touched,
		prefiltered
		);
}
