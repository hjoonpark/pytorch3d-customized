// Copyright (c) Facebook, Inc. and its affiliates. All rights reserved.

#include <ATen/ATen.h>
#include <torch/extension.h>

// Kernel for inputs_packed of shape (F, D), where D > 1
template <typename scalar_t>
__global__ void PackedToPaddedKernel(
    const scalar_t* __restrict__ inputs_packed,
    const int64_t* __restrict__ first_idxs,
    scalar_t* __restrict__ inputs_padded,
    const size_t batch_size,
    const size_t max_size,
    const size_t num_inputs,
    const size_t D) {
  // Batch elements split evenly across blocks (num blocks = batch_size) and
  // values for each element split across threads in the block. Each thread adds
  // the values of its respective input elements to the global inputs_padded
  // tensor.
  const size_t tid = threadIdx.x;
  const size_t batch_idx = blockIdx.x;

  const int64_t start = first_idxs[batch_idx];
  const int64_t end =
      batch_idx + 1 < batch_size ? first_idxs[batch_idx + 1] : num_inputs;
  const int num = end - start;
  for (size_t f = tid; f < num; f += blockDim.x) {
    for (size_t j = 0; j < D; ++j) {
      inputs_padded[batch_idx * max_size * D + f * D + j] =
          inputs_packed[(start + f) * D + j];
    }
  }
}

// Kernel for inputs of shape (F, 1)
template <typename scalar_t>
__global__ void PackedToPaddedKernelD1(
    const scalar_t* __restrict__ inputs_packed,
    const int64_t* __restrict__ first_idxs,
    scalar_t* __restrict__ inputs_padded,
    const size_t batch_size,
    const size_t max_size,
    const size_t num_inputs) {
  // Batch elements split evenly across blocks (num blocks = batch_size) and
  // values for each element split across threads in the block. Each thread adds
  // the values of its respective input elements to the global inputs_padded
  // tensor.
  const size_t tid = threadIdx.x;
  const size_t batch_idx = blockIdx.x;

  const int64_t start = first_idxs[batch_idx];
  const int64_t end =
      batch_idx + 1 < batch_size ? first_idxs[batch_idx + 1] : num_inputs;
  const int num = end - start;
  for (size_t f = tid; f < num; f += blockDim.x) {
    inputs_padded[batch_idx * max_size + f] = inputs_packed[start + f];
  }
}

// Kernel for inputs_padded of shape (B, F, D), where D > 1
template <typename scalar_t>
__global__ void PaddedToPackedKernel(
    const scalar_t* __restrict__ inputs_padded,
    const int64_t* __restrict__ first_idxs,
    scalar_t* __restrict__ inputs_packed,
    const size_t batch_size,
    const size_t max_size,
    const size_t num_inputs,
    const size_t D) {
  // Batch elements split evenly across blocks (num blocks = batch_size) and
  // values for each element split across threads in the block. Each thread adds
  // the values of its respective input elements to the global inputs_packed
  // tensor.
  const size_t tid = threadIdx.x;
  const size_t batch_idx = blockIdx.x;

  const int64_t start = first_idxs[batch_idx];
  const int64_t end =
      batch_idx + 1 < batch_size ? first_idxs[batch_idx + 1] : num_inputs;
  const int num = end - start;
  for (size_t f = tid; f < num; f += blockDim.x) {
    for (size_t j = 0; j < D; ++j) {
      inputs_packed[(start + f) * D + j] =
          inputs_padded[batch_idx * max_size * D + f * D + j];
    }
  }
}

// Kernel for inputs_padded of shape (B, F, 1)
template <typename scalar_t>
__global__ void PaddedToPackedKernelD1(
    const scalar_t* __restrict__ inputs_padded,
    const int64_t* __restrict__ first_idxs,
    scalar_t* __restrict__ inputs_packed,
    const size_t batch_size,
    const size_t max_size,
    const size_t num_inputs) {
  // Batch elements split evenly across blocks (num blocks = batch_size) and
  // values for each element split across threads in the block. Each thread adds
  // the values of its respective input elements to the global inputs_packed
  // tensor.
  const size_t tid = threadIdx.x;
  const size_t batch_idx = blockIdx.x;

  const int64_t start = first_idxs[batch_idx];
  const int64_t end =
      batch_idx + 1 < batch_size ? first_idxs[batch_idx + 1] : num_inputs;
  const int num = end - start;
  for (size_t f = tid; f < num; f += blockDim.x) {
    inputs_packed[start + f] = inputs_padded[batch_idx * max_size + f];
  }
}

at::Tensor PackedToPaddedCuda(
    const at::Tensor inputs_packed,
    const at::Tensor first_idxs,
    const int64_t max_size) {
  const int64_t num_inputs = inputs_packed.size(0);
  const int64_t batch_size = first_idxs.size(0);

  AT_ASSERTM(
      inputs_packed.dim() == 2, "inputs_packed must be a 2-dimensional tensor");
  const int64_t D = inputs_packed.size(1);
  at::Tensor inputs_padded =
      at::zeros({batch_size, max_size, D}, inputs_packed.options());

  const int threads = 512;
  const int blocks = batch_size;
  if (D == 1) {
    AT_DISPATCH_FLOATING_TYPES(
        inputs_packed.scalar_type(), "packed_to_padded_d1_kernel", ([&] {
          PackedToPaddedKernelD1<scalar_t><<<blocks, threads>>>(
              inputs_packed.data_ptr<scalar_t>(),
              first_idxs.data_ptr<int64_t>(),
              inputs_padded.data_ptr<scalar_t>(),
              batch_size,
              max_size,
              num_inputs);
        }));
  } else {
    AT_DISPATCH_FLOATING_TYPES(
        inputs_packed.scalar_type(), "packed_to_padded_kernel", ([&] {
          PackedToPaddedKernel<scalar_t><<<blocks, threads>>>(
              inputs_packed.data_ptr<scalar_t>(),
              first_idxs.data_ptr<int64_t>(),
              inputs_padded.data_ptr<scalar_t>(),
              batch_size,
              max_size,
              num_inputs,
              D);
        }));
  }

  return inputs_padded;
}

at::Tensor PaddedToPackedCuda(
    const at::Tensor inputs_padded,
    const at::Tensor first_idxs,
    const int64_t num_inputs) {
  const int64_t batch_size = inputs_padded.size(0);
  const int64_t max_size = inputs_padded.size(1);

  AT_ASSERTM(batch_size == first_idxs.size(0), "sizes mismatch");
  AT_ASSERTM(
      inputs_padded.dim() == 3,
      "inputs_padded  must be a 3-dimensional tensor");
  const int64_t D = inputs_padded.size(2);

  at::Tensor inputs_packed =
      at::zeros({num_inputs, D}, inputs_padded.options());

  const int threads = 512;
  const int blocks = batch_size;

  if (D == 1) {
    AT_DISPATCH_FLOATING_TYPES(
        inputs_padded.scalar_type(), "padded_to_packed_d1_kernel", ([&] {
          PaddedToPackedKernelD1<scalar_t><<<blocks, threads>>>(
              inputs_padded.data_ptr<scalar_t>(),
              first_idxs.data_ptr<int64_t>(),
              inputs_packed.data_ptr<scalar_t>(),
              batch_size,
              max_size,
              num_inputs);
        }));
  } else {
    AT_DISPATCH_FLOATING_TYPES(
        inputs_padded.scalar_type(), "padded_to_packed_kernel", ([&] {
          PaddedToPackedKernel<scalar_t><<<blocks, threads>>>(
              inputs_padded.data_ptr<scalar_t>(),
              first_idxs.data_ptr<int64_t>(),
              inputs_packed.data_ptr<scalar_t>(),
              batch_size,
              max_size,
              num_inputs,
              D);
        }));
  }

  return inputs_packed;
}
