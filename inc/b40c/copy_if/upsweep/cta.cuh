/******************************************************************************
 * Copyright (c) 2010-2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2013, NVIDIA CORPORATION.  All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/
/******************************************************************************
 * CTA-processing functionality for Copy-if upsweep
 * reduction kernels
 ******************************************************************************/

#pragma once

#include <b40c/util/reduction/serial_reduce.cuh>
#include <b40c/util/reduction/tree_reduce.cuh>
#include <b40c/util/operators.cuh>
#include <b40c/util/io/load_tile.cuh>
#include <b40c/util/io/initialize_tile.cuh>

namespace b40c {
namespace copy_if {
namespace upsweep {


/**
 * Copy-if upsweep reduction CTA
 */
template <typename KernelPolicy>
struct Cta
{
	//---------------------------------------------------------------------
	// Typedefs
	//---------------------------------------------------------------------

	typedef typename KernelPolicy::KeyType 				KeyType;
	typedef typename KernelPolicy::SizeT 				SizeT;
	typedef typename KernelPolicy::SelectOp				SelectOp;

	typedef int 										LocalFlag;		// Type for noting local discontinuities (just needs to count up to TILE_ELEMENTS_PER_THREAD)
	typedef typename KernelPolicy::SmemStorage 			SmemStorage;

	//---------------------------------------------------------------------
	// Members
	//---------------------------------------------------------------------

	// Accumulator for the number of discontinuities observed (in each thread)
	SizeT			carry;

	// Device pointers
	KeyType 		*d_in_keys;
	SizeT			*d_spine;

	// Shared memory storage for the CTA
	SmemStorage		&smem_storage;

	// Equality operator
	SelectOp		select_op;



	//---------------------------------------------------------------------
	// Methods
	//---------------------------------------------------------------------


	/**
	 * Constructor
	 */
	__device__ __forceinline__ Cta(
		SmemStorage 	&smem_storage,
		KeyType			*d_in_keys,
		SizeT 			*d_spine,
		SelectOp		select_op) :

			smem_storage(smem_storage),
			d_in_keys(d_in_keys),
			d_spine(d_spine),
			select_op(select_op),
			carry(0)
	{}


	/**
	 * Process a single, full tile
	 */
	__device__ __forceinline__ void ProcessTile(
		SizeT cta_offset,
		const SizeT &guarded_elements = KernelPolicy::TILE_ELEMENTS)
	{
		KeyType		keys[KernelPolicy::LOADS_PER_TILE][KernelPolicy::LOAD_VEC_SIZE];
		LocalFlag 	valid[KernelPolicy::LOADS_PER_TILE][KernelPolicy::LOAD_VEC_SIZE];		// Tile of discontinuity head_flags

		// Load tile
		util::io::LoadTile<
			KernelPolicy::LOG_LOADS_PER_TILE,
			KernelPolicy::LOG_LOAD_VEC_SIZE,
			KernelPolicy::THREADS,
			KernelPolicy::READ_MODIFIER,
			KernelPolicy::CHECK_ALIGNMENT>::LoadValid(
				keys,
				d_in_keys,
				cta_offset,
				guarded_elements);

		// Initialize valid flags
		util::io::InitializeTile<
			KernelPolicy::LOG_LOADS_PER_TILE,
			KernelPolicy::LOG_LOAD_VEC_SIZE,
			KernelPolicy::THREADS>::Transform(valid, keys, select_op);

		// Prevent accumulation from being hoisted (otherwise we don't get the desired outstanding loads)
		if (KernelPolicy::LOADS_PER_TILE > 1) __syncthreads();

		// Reduce head_flags, accumulate in carry
		carry += util::reduction::SerialReduce<KernelPolicy::TILE_ELEMENTS_PER_THREAD>::Invoke(
			(LocalFlag*) valid);
	}


	/**
	 * Collective reduction across all threads, stores final reduction to output
	 *
	 * Used to collectively reduce each thread's aggregate after striding through
	 * the input.
	 */
	__device__ __forceinline__ void OutputToSpine()
	{
		// Cooperatively reduce the carries in each thread (thread-0 gets the result)
		util::Sum<SizeT> reduction_op;
		carry = util::reduction::TreeReduce<KernelPolicy::LOG_THREADS, false>::Invoke(				// No need to return aggregate reduction in all threads
			carry,
			smem_storage.reduction_tree,
			reduction_op);

		// Write output
		if (threadIdx.x == 0) {
			util::io::ModifiedStore<KernelPolicy::WRITE_MODIFIER>::St(
				carry, d_spine + blockIdx.x);
		}
	}


	/**
	 * Process work range of tiles
	 */
	__device__ __forceinline__ void ProcessWorkRange(
		util::CtaWorkLimits<SizeT> &work_limits)
	{
		// Make sure we get a local copy of the cta's offset (work_limits may be in smem)
		SizeT cta_offset = work_limits.offset;

		// Process full tiles of tile_elements
		while (cta_offset < work_limits.guarded_offset) {
			ProcessTile(cta_offset);
			cta_offset += KernelPolicy::TILE_ELEMENTS;
		}

		// Clean up last partial tile with guarded-io
		if (work_limits.guarded_elements) {
			ProcessTile(
				cta_offset,
				work_limits.guarded_elements);
		}

		// Produce output in spine
		OutputToSpine();
	}
};



} // namespace upsweep
} // namespace copy_if
} // namespace b40c

