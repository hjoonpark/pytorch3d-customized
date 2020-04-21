// Copyright (c) Facebook, Inc. and its affiliates. All rights reserved.

#include <torch/extension.h>
#include <algorithm>
#include <list>
#include <queue>
#include <tuple>
#include "utils/float_math.cuh"
#include "utils/geometry_utils.cuh"
#include "utils/warp_reduce.cuh"

// ****************************************************************************
// *                          PointEdgeDistance                               *
// ****************************************************************************

__global__ void PointEdgeForwardKernel(
    const float* __restrict__ points, // (P, 3)
    const int64_t* __restrict__ points_first_idx, // (B,)
    const float* __restrict__ segms, // (S, 2, 3)
    const int64_t* __restrict__ segms_first_idx, // (B,)
    float* __restrict__ dist_points, // (P,)
    int64_t* __restrict__ idx_points, // (P,)
    const size_t B,
    const size_t P,
    const size_t S) {
  float3* points_f3 = (float3*)points;
  float3* segms_f3 = (float3*)segms;

  // Single shared memory buffer which is split and cast to different types.
  extern __shared__ char shared_buf[];
  float* min_dists = (float*)shared_buf; // float[NUM_THREADS]
  int64_t* min_idxs = (int64_t*)&min_dists[blockDim.x]; // int64_t[NUM_THREADS]

  const size_t batch_idx = blockIdx.y; // index of batch element.

  // start and end for points in batch
  const int64_t startp = points_first_idx[batch_idx];
  const int64_t endp = batch_idx + 1 < B ? points_first_idx[batch_idx + 1] : P;

  // start and end for segments in batch_idx
  const int64_t starts = segms_first_idx[batch_idx];
  const int64_t ends = batch_idx + 1 < B ? segms_first_idx[batch_idx + 1] : S;

  const size_t i = blockIdx.x; // index of point within batch element.
  const size_t tid = threadIdx.x; // thread idx

  // Each block will compute one element of the output idx_points[startp + i],
  // dist_points[startp + i]. Within the block we will use threads to compute
  // the distances between points[startp + i] and segms[j] for all j belonging
  // in the same batch as i, i.e. j in [starts, ends]. Then use a block
  // reduction to take an argmin of the distances.

  // If i exceeds the number of points in batch_idx, then do nothing
  if (i < (endp - startp)) {
    // Retrieve (startp + i) point
    const float3 p_f3 = points_f3[startp + i];

    // Compute the distances between points[startp + i] and segms[j] for
    // all j belonging in the same batch as i, i.e. j in [starts, ends].
    // Here each thread will reduce over (ends-starts) / blockDim.x in serial,
    // and store its result to shared memory
    float min_dist = FLT_MAX;
    size_t min_idx = 0;
    for (size_t j = tid; j < (ends - starts); j += blockDim.x) {
      const float3 v0 = segms_f3[(starts + j) * 2 + 0];
      const float3 v1 = segms_f3[(starts + j) * 2 + 1];
      float dist = PointLine3DistanceForward(p_f3, v0, v1);
      min_dist = (j == tid) ? dist : min_dist;
      min_idx = (dist <= min_dist) ? (starts + j) : min_idx;
      min_dist = (dist <= min_dist) ? dist : min_dist;
    }
    min_dists[tid] = min_dist;
    min_idxs[tid] = min_idx;
    __syncthreads();

    // Perform reduction in shared memory.
    for (int s = blockDim.x / 2; s > 32; s >>= 1) {
      if (tid < s) {
        if (min_dists[tid] > min_dists[tid + s]) {
          min_dists[tid] = min_dists[tid + s];
          min_idxs[tid] = min_idxs[tid + s];
        }
      }
      __syncthreads();
    }

    // Unroll the last 6 iterations of the loop since they will happen
    // synchronized within a single warp.
    if (tid < 32)
      WarpReduce<float>(min_dists, min_idxs, tid);

    // Finally thread 0 writes the result to the output buffer.
    if (tid == 0) {
      idx_points[startp + i] = min_idxs[0];
      dist_points[startp + i] = min_dists[0];
    }
  }
}

std::tuple<torch::Tensor, torch::Tensor> PointEdgeDistanceForwardCuda(
    const torch::Tensor& points,
    const torch::Tensor& points_first_idx,
    const torch::Tensor& segms,
    const torch::Tensor& segms_first_idx,
    const int64_t max_points) {
  const int64_t P = points.size(0);
  const int64_t S = segms.size(0);
  const int64_t B = points_first_idx.size(0);

  AT_ASSERTM(points.size(1) == 3, "points must be of shape Px3");
  AT_ASSERTM(
      (segms.size(1) == 2) && (segms.size(2) == 3),
      "segms must be of shape Sx2x3");
  AT_ASSERTM(segms_first_idx.size(0) == B);

  // clang-format off
  torch::Tensor dists = torch::zeros({P,}, points.options());
  torch::Tensor idxs = torch::zeros({P,}, points_first_idx.options());
  // clang-format on

  const int threads = 128;
  const dim3 blocks(max_points, B);
  size_t shared_size = threads * sizeof(size_t) + threads * sizeof(int64_t);

  PointEdgeForwardKernel<<<blocks, threads, shared_size>>>(
      points.data_ptr<float>(),
      points_first_idx.data_ptr<int64_t>(),
      segms.data_ptr<float>(),
      segms_first_idx.data_ptr<int64_t>(),
      dists.data_ptr<float>(),
      idxs.data_ptr<int64_t>(),
      B,
      P,
      S);

  return std::make_tuple(dists, idxs);
}

__global__ void PointEdgeBackwardKernel(
    const float* __restrict__ points, // (P, 3)
    const float* __restrict__ segms, // (S, 2, 3)
    const int64_t* __restrict__ idx_points, // (P,)
    const float* __restrict__ grad_dists, // (P,)
    float* __restrict__ grad_points, // (P, 3)
    float* __restrict__ grad_segms, // (S, 2, 3)
    const size_t P) {
  float3* points_f3 = (float3*)points;
  float3* segms_f3 = (float3*)segms;

  const size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
  const size_t stride = gridDim.x * blockDim.x;

  for (size_t p = tid; p < P; p += stride) {
    const float3 p_f3 = points_f3[p];

    const int64_t sidx = idx_points[p];
    const float3 v0 = segms_f3[sidx * 2 + 0];
    const float3 v1 = segms_f3[sidx * 2 + 1];

    const float grad_dist = grad_dists[p];

    const auto grads = PointLine3DistanceBackward(p_f3, v0, v1, grad_dist);
    const float3 grad_point = thrust::get<0>(grads);
    const float3 grad_v0 = thrust::get<1>(grads);
    const float3 grad_v1 = thrust::get<2>(grads);

    atomicAdd(grad_points + p * 3 + 0, grad_point.x);
    atomicAdd(grad_points + p * 3 + 1, grad_point.y);
    atomicAdd(grad_points + p * 3 + 2, grad_point.z);

    atomicAdd(grad_segms + sidx * 2 * 3 + 0 * 3 + 0, grad_v0.x);
    atomicAdd(grad_segms + sidx * 2 * 3 + 0 * 3 + 1, grad_v0.y);
    atomicAdd(grad_segms + sidx * 2 * 3 + 0 * 3 + 2, grad_v0.z);

    atomicAdd(grad_segms + sidx * 2 * 3 + 1 * 3 + 0, grad_v1.x);
    atomicAdd(grad_segms + sidx * 2 * 3 + 1 * 3 + 1, grad_v1.y);
    atomicAdd(grad_segms + sidx * 2 * 3 + 1 * 3 + 2, grad_v1.z);
  }
}

std::tuple<torch::Tensor, torch::Tensor> PointEdgeDistanceBackwardCuda(
    const torch::Tensor& points,
    const torch::Tensor& segms,
    const torch::Tensor& idx_points,
    const torch::Tensor& grad_dists) {
  const int64_t P = points.size(0);
  const int64_t S = segms.size(0);

  AT_ASSERTM(points.size(1) == 3, "points must be of shape Px3");
  AT_ASSERTM(
      (segms.size(1) == 2) && (segms.size(2) == 3),
      "segms must be of shape Sx2x3");
  AT_ASSERTM(idx_points.size(0) == P);
  AT_ASSERTM(grad_dists.size(0) == P);

  // clang-format off
  torch::Tensor grad_points = torch::zeros({P, 3}, points.options());
  torch::Tensor grad_segms = torch::zeros({S, 2, 3}, segms.options());
  // clang-format on

  const int blocks = 64;
  const int threads = 512;

  PointEdgeBackwardKernel<<<blocks, threads>>>(
      points.data_ptr<float>(),
      segms.data_ptr<float>(),
      idx_points.data_ptr<int64_t>(),
      grad_dists.data_ptr<float>(),
      grad_points.data_ptr<float>(),
      grad_segms.data_ptr<float>(),
      P);

  return std::make_tuple(grad_points, grad_segms);
}

// ****************************************************************************
// *                          EdgePointDistance                               *
// ****************************************************************************

__global__ void EdgePointForwardKernel(
    const float* __restrict__ points, // (P, 3)
    const int64_t* __restrict__ points_first_idx, // (B,)
    const float* __restrict__ segms, // (S, 2, 3)
    const int64_t* __restrict__ segms_first_idx, // (B,)
    float* __restrict__ dist_segms, // (S,)
    int64_t* __restrict__ idx_segms, // (S,)
    const size_t B,
    const size_t P,
    const size_t S) {
  float3* points_f3 = (float3*)points;
  float3* segms_f3 = (float3*)segms;

  // Single shared memory buffer which is split and cast to different types.
  extern __shared__ char shared_buf[];
  float* min_dists = (float*)shared_buf; // float[NUM_THREADS]
  int64_t* min_idxs = (int64_t*)&min_dists[blockDim.x]; // int64_t[NUM_THREADS]

  const size_t batch_idx = blockIdx.y; // index of batch element.

  // start and end for points in batch_idx
  const int64_t startp = points_first_idx[batch_idx];
  const int64_t endp = batch_idx + 1 < B ? points_first_idx[batch_idx + 1] : P;

  // start and end for segms in batch_idx
  const int64_t starts = segms_first_idx[batch_idx];
  const int64_t ends = batch_idx + 1 < B ? segms_first_idx[batch_idx + 1] : S;

  const size_t i = blockIdx.x; // index of point within batch element.
  const size_t tid = threadIdx.x; // thread index

  // Each block will compute one element of the output idx_segms[starts + i],
  // dist_segms[starts + i]. Within the block we will use threads to compute
  // the distances between segms[starts + i] and points[j] for all j belonging
  // in the same batch as i, i.e. j in [startp, endp]. Then use a block
  // reduction to take an argmin of the distances.

  // If i exceeds the number of segms in batch_idx, then do nothing
  if (i < (ends - starts)) {
    const float3 v0 = segms_f3[(starts + i) * 2 + 0];
    const float3 v1 = segms_f3[(starts + i) * 2 + 1];

    // Compute the distances between segms[starts + i] and points[j] for
    // all j belonging in the same batch as i, i.e. j in [startp, endp].
    // Here each thread will reduce over (endp-startp) / blockDim.x in serial,
    // and store its result to shared memory
    float min_dist = FLT_MAX;
    size_t min_idx = 0;
    for (size_t j = tid; j < (endp - startp); j += blockDim.x) {
      // Retrieve (startp + i) point
      const float3 p_f3 = points_f3[startp + j];

      float dist = PointLine3DistanceForward(p_f3, v0, v1);
      min_dist = (j == tid) ? dist : min_dist;
      min_idx = (dist <= min_dist) ? (startp + j) : min_idx;
      min_dist = (dist <= min_dist) ? dist : min_dist;
    }
    min_dists[tid] = min_dist;
    min_idxs[tid] = min_idx;
    __syncthreads();

    // Perform reduction in shared memory.
    for (int s = blockDim.x / 2; s > 32; s >>= 1) {
      if (tid < s) {
        if (min_dists[tid] > min_dists[tid + s]) {
          min_dists[tid] = min_dists[tid + s];
          min_idxs[tid] = min_idxs[tid + s];
        }
      }
      __syncthreads();
    }

    // Unroll the last 6 iterations of the loop since they will happen
    // synchronized within a single warp.
    if (tid < 32)
      WarpReduce<float>(min_dists, min_idxs, tid);

    // Finally thread 0 writes the result to the output buffer.
    if (tid == 0) {
      idx_segms[starts + i] = min_idxs[0];
      dist_segms[starts + i] = min_dists[0];
    }
  }
}

std::tuple<torch::Tensor, torch::Tensor> EdgePointDistanceForwardCuda(
    const torch::Tensor& points,
    const torch::Tensor& points_first_idx,
    const torch::Tensor& segms,
    const torch::Tensor& segms_first_idx,
    const int64_t max_segms) {
  const int64_t P = points.size(0);
  const int64_t S = segms.size(0);
  const int64_t B = points_first_idx.size(0);

  AT_ASSERTM(points.size(1) == 3, "points must be of shape Px3");
  AT_ASSERTM(
      (segms.size(1) == 2) && (segms.size(2) == 3),
      "segms must be of shape Sx2x3");
  AT_ASSERTM(segms_first_idx.size(0) == B);

  // clang-format off
  torch::Tensor dists = torch::zeros({S,}, segms.options());
  torch::Tensor idxs = torch::zeros({S,}, segms_first_idx.options());
  // clang-format on

  const int threads = 128;
  const dim3 blocks(max_segms, B);
  size_t shared_size = threads * sizeof(size_t) + threads * sizeof(int64_t);

  EdgePointForwardKernel<<<blocks, threads, shared_size>>>(
      points.data_ptr<float>(),
      points_first_idx.data_ptr<int64_t>(),
      segms.data_ptr<float>(),
      segms_first_idx.data_ptr<int64_t>(),
      dists.data_ptr<float>(),
      idxs.data_ptr<int64_t>(),
      B,
      P,
      S);

  return std::make_tuple(dists, idxs);
}

__global__ void EdgePointBackwardKernel(
    const float* __restrict__ points, // (P, 3)
    const float* __restrict__ segms, // (S, 2, 3)
    const int64_t* __restrict__ idx_segms, // (S,)
    const float* __restrict__ grad_dists, // (S,)
    float* __restrict__ grad_points, // (P, 3)
    float* __restrict__ grad_segms, // (S, 2, 3)
    const size_t S) {
  float3* points_f3 = (float3*)points;
  float3* segms_f3 = (float3*)segms;

  const size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
  const size_t stride = gridDim.x * blockDim.x;

  for (size_t s = tid; s < S; s += stride) {
    const float3 v0 = segms_f3[s * 2 + 0];
    const float3 v1 = segms_f3[s * 2 + 1];

    const int64_t pidx = idx_segms[s];

    const float3 p_f3 = points_f3[pidx];

    const float grad_dist = grad_dists[s];

    const auto grads = PointLine3DistanceBackward(p_f3, v0, v1, grad_dist);
    const float3 grad_point = thrust::get<0>(grads);
    const float3 grad_v0 = thrust::get<1>(grads);
    const float3 grad_v1 = thrust::get<2>(grads);

    atomicAdd(grad_points + pidx * 3 + 0, grad_point.x);
    atomicAdd(grad_points + pidx * 3 + 1, grad_point.y);
    atomicAdd(grad_points + pidx * 3 + 2, grad_point.z);

    atomicAdd(grad_segms + s * 2 * 3 + 0 * 3 + 0, grad_v0.x);
    atomicAdd(grad_segms + s * 2 * 3 + 0 * 3 + 1, grad_v0.y);
    atomicAdd(grad_segms + s * 2 * 3 + 0 * 3 + 2, grad_v0.z);

    atomicAdd(grad_segms + s * 2 * 3 + 1 * 3 + 0, grad_v1.x);
    atomicAdd(grad_segms + s * 2 * 3 + 1 * 3 + 1, grad_v1.y);
    atomicAdd(grad_segms + s * 2 * 3 + 1 * 3 + 2, grad_v1.z);
  }
}

std::tuple<torch::Tensor, torch::Tensor> EdgePointDistanceBackwardCuda(
    const torch::Tensor& points,
    const torch::Tensor& segms,
    const torch::Tensor& idx_segms,
    const torch::Tensor& grad_dists) {
  const int64_t P = points.size(0);
  const int64_t S = segms.size(0);

  AT_ASSERTM(points.size(1) == 3, "points must be of shape Px3");
  AT_ASSERTM(
      (segms.size(1) == 2) && (segms.size(2) == 3),
      "segms must be of shape Sx2x3");
  AT_ASSERTM(idx_segms.size(0) == S);
  AT_ASSERTM(grad_dists.size(0) == S);

  // clang-format off
  torch::Tensor grad_points = torch::zeros({P, 3}, points.options());
  torch::Tensor grad_segms = torch::zeros({S, 2, 3}, segms.options());
  // clang-format on

  const int blocks = 64;
  const int threads = 512;

  EdgePointBackwardKernel<<<blocks, threads>>>(
      points.data_ptr<float>(),
      segms.data_ptr<float>(),
      idx_segms.data_ptr<int64_t>(),
      grad_dists.data_ptr<float>(),
      grad_points.data_ptr<float>(),
      grad_segms.data_ptr<float>(),
      S);

  return std::make_tuple(grad_points, grad_segms);
}

// ****************************************************************************
// *                     PointEdgeArrayDistance                               *
// ****************************************************************************

__global__ void PointEdgeArrayForwardKernel(
    const float* __restrict__ points, // (P, 3)
    const float* __restrict__ segms, // (S, 2, 3)
    float* __restrict__ dists, // (P, S)
    const size_t P,
    const size_t S) {
  float3* points_f3 = (float3*)points;
  float3* segms_f3 = (float3*)segms;

  // Parallelize over P * S computations
  const int num_threads = gridDim.x * blockDim.x;
  const int tid = blockIdx.x * blockDim.x + threadIdx.x;

  for (int t_i = tid; t_i < P * S; t_i += num_threads) {
    const int s = t_i / P; // segment index.
    const int p = t_i % P; // point index
    float3 a = segms_f3[s * 2 + 0];
    float3 b = segms_f3[s * 2 + 1];

    float3 point = points_f3[p];
    float dist = PointLine3DistanceForward(point, a, b);
    dists[p * S + s] = dist;
  }
}

torch::Tensor PointEdgeArrayDistanceForwardCuda(
    const torch::Tensor& points,
    const torch::Tensor& segms) {
  const int64_t P = points.size(0);
  const int64_t S = segms.size(0);

  AT_ASSERTM(points.size(1) == 3, "points must be of shape Px3");
  AT_ASSERTM(
      (segms.size(1) == 2) && (segms.size(2) == 3),
      "segms must be of shape Sx2x3");

  torch::Tensor dists = torch::zeros({P, S}, points.options());

  const size_t blocks = 1024;
  const size_t threads = 64;

  PointEdgeArrayForwardKernel<<<blocks, threads>>>(
      points.data_ptr<float>(),
      segms.data_ptr<float>(),
      dists.data_ptr<float>(),
      P,
      S);

  return dists;
}

__global__ void PointEdgeArrayBackwardKernel(
    const float* __restrict__ points, // (P, 3)
    const float* __restrict__ segms, // (S, 2, 3)
    const float* __restrict__ grad_dists, // (P, S)
    float* __restrict__ grad_points, // (P, 3)
    float* __restrict__ grad_segms, // (S, 2, 3)
    const size_t P,
    const size_t S) {
  float3* points_f3 = (float3*)points;
  float3* segms_f3 = (float3*)segms;

  // Parallelize over P * S computations
  const int num_threads = gridDim.x * blockDim.x;
  const int tid = blockIdx.x * blockDim.x + threadIdx.x;

  for (int t_i = tid; t_i < P * S; t_i += num_threads) {
    const int s = t_i / P; // segment index.
    const int p = t_i % P; // point index
    const float3 a = segms_f3[s * 2 + 0];
    const float3 b = segms_f3[s * 2 + 1];

    const float3 point = points_f3[p];
    const float grad_dist = grad_dists[p * S + s];
    const auto grads = PointLine3DistanceBackward(point, a, b, grad_dist);
    const float3 grad_point = thrust::get<0>(grads);
    const float3 grad_a = thrust::get<1>(grads);
    const float3 grad_b = thrust::get<2>(grads);

    atomicAdd(grad_points + p * 3 + 0, grad_point.x);
    atomicAdd(grad_points + p * 3 + 1, grad_point.y);
    atomicAdd(grad_points + p * 3 + 2, grad_point.z);

    atomicAdd(grad_segms + s * 2 * 3 + 0 * 3 + 0, grad_a.x);
    atomicAdd(grad_segms + s * 2 * 3 + 0 * 3 + 1, grad_a.y);
    atomicAdd(grad_segms + s * 2 * 3 + 0 * 3 + 2, grad_a.z);

    atomicAdd(grad_segms + s * 2 * 3 + 1 * 3 + 0, grad_b.x);
    atomicAdd(grad_segms + s * 2 * 3 + 1 * 3 + 1, grad_b.y);
    atomicAdd(grad_segms + s * 2 * 3 + 1 * 3 + 2, grad_b.z);
  }
}

std::tuple<torch::Tensor, torch::Tensor> PointEdgeArrayDistanceBackwardCuda(
    const torch::Tensor& points,
    const torch::Tensor& segms,
    const torch::Tensor& grad_dists) {
  const int64_t P = points.size(0);
  const int64_t S = segms.size(0);

  AT_ASSERTM(points.size(1) == 3, "points must be of shape Px3");
  AT_ASSERTM(
      (segms.size(1) == 2) && (segms.size(2) == 3),
      "segms must be of shape Sx2x3");
  AT_ASSERTM((grad_dists.size(0) == P) && (grad_dists.size(1) == S));

  torch::Tensor grad_points = torch::zeros({P, 3}, points.options());
  torch::Tensor grad_segms = torch::zeros({S, 2, 3}, segms.options());

  const size_t blocks = 1024;
  const size_t threads = 64;

  PointEdgeArrayBackwardKernel<<<blocks, threads>>>(
      points.data_ptr<float>(),
      segms.data_ptr<float>(),
      grad_dists.data_ptr<float>(),
      grad_points.data_ptr<float>(),
      grad_segms.data_ptr<float>(),
      P,
      S);

  return std::make_tuple(grad_points, grad_segms);
}
