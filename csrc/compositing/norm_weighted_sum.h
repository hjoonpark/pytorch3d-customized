// Copyright (c) Facebook, Inc. and its affiliates. All rights reserved.

#include <torch/extension.h>
#include "utils/pytorch3d_cutils.h"

#include <vector>

// Perform normalized weighted sum compositing of points in a z-buffer.
//
// Inputs:
//    features: FloatTensor of shape (C, P) which gives the features
//            of each point where C is the size of the feature and
//            P the number of points.
//    alphas: FloatTensor of shape (N, points_per_pixel, W, W) where
//            points_per_pixel is the number of points in the z-buffer
//            sorted in z-order, and W is the image size.
//    points_idx: IntTensor of shape (N, points_per_pixel, W, W) giving the
//            indices of the nearest points at each pixel, sorted in z-order.
// Returns:
//    weighted_fs: FloatTensor of shape (N, C, W, W) giving the accumulated
//            feature in each point. Concretely, it gives:
//                 weighted_fs[b,c,i,j] = sum_k alphas[b,k,i,j] *
//                   features[c,points_idx[b,k,i,j]] / sum_k alphas[b,k,i,j]

// CUDA declarations
#ifdef WITH_CUDA
torch::Tensor weightedSumNormCudaForward(
    const torch::Tensor& features,
    const torch::Tensor& alphas,
    const torch::Tensor& points_idx);

std::tuple<torch::Tensor, torch::Tensor> weightedSumNormCudaBackward(
    const torch::Tensor& grad_outputs,
    const torch::Tensor& features,
    const torch::Tensor& alphas,
    const torch::Tensor& points_idx);
#endif

// C++ declarations
torch::Tensor weightedSumNormCpuForward(
    const torch::Tensor& features,
    const torch::Tensor& alphas,
    const torch::Tensor& points_idx);

std::tuple<torch::Tensor, torch::Tensor> weightedSumNormCpuBackward(
    const torch::Tensor& grad_outputs,
    const torch::Tensor& features,
    const torch::Tensor& alphas,
    const torch::Tensor& points_idx);

torch::Tensor weightedSumNormForward(
    torch::Tensor& features,
    torch::Tensor& alphas,
    torch::Tensor& points_idx) {
  features = features.contiguous();
  alphas = alphas.contiguous();
  points_idx = points_idx.contiguous();

  if (features.is_cuda()) {
#ifdef WITH_CUDA
    CHECK_CONTIGUOUS_CUDA(features);
    CHECK_CONTIGUOUS_CUDA(alphas);
    CHECK_CONTIGUOUS_CUDA(points_idx);

    return weightedSumNormCudaForward(features, alphas, points_idx);
#else
    AT_ERROR("Not compiled with GPU support");
#endif
  } else {
    CHECK_CONTIGUOUS(features);
    CHECK_CONTIGUOUS(alphas);
    CHECK_CONTIGUOUS(points_idx);

    return weightedSumNormCpuForward(features, alphas, points_idx);
  }
}

std::tuple<torch::Tensor, torch::Tensor> weightedSumNormBackward(
    torch::Tensor& grad_outputs,
    torch::Tensor& features,
    torch::Tensor& alphas,
    torch::Tensor& points_idx) {
  grad_outputs = grad_outputs.contiguous();
  features = features.contiguous();
  alphas = alphas.contiguous();
  points_idx = points_idx.contiguous();

  if (grad_outputs.is_cuda()) {
#ifdef WITH_CUDA
    CHECK_CONTIGUOUS_CUDA(grad_outputs);
    CHECK_CONTIGUOUS_CUDA(features);
    CHECK_CONTIGUOUS_CUDA(alphas);
    CHECK_CONTIGUOUS_CUDA(points_idx);

    return weightedSumNormCudaBackward(
        grad_outputs, features, alphas, points_idx);
#else
    AT_ERROR("Not compiled with GPU support");
#endif
  } else {
    CHECK_CONTIGUOUS(grad_outputs);
    CHECK_CONTIGUOUS(features);
    CHECK_CONTIGUOUS(alphas);
    CHECK_CONTIGUOUS(points_idx);

    return weightedSumNormCpuBackward(
        grad_outputs, features, alphas, points_idx);
  }
}
