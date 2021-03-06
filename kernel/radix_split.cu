/*
* Copyright 1993-2009 NVIDIA Corporation.  All rights reserved.
*
* NVIDIA Corporation and its licensors retain all intellectual property and
* proprietary rights in and to this software and related documentation and
* any modifications thereto.  Any use, reproduction, disclosure, or distribution
* of this software and related documentation without an express license
* agreement from NVIDIA Corporation is strictly prohibited.
*
*/

// -----------------------------------------------------------------------
// Fast CUDA Radix Sort Implementation
//
// The parallel radix sort algorithm implemented by this code is described
// in the following paper.
//
// Satish, N., Harris, M., and Garland, M. "Designing Efficient Sorting
// Algorithms for Manycore GPUs". In Proceedings of IEEE International
// Parallel & Distributed Processing Symposium 2009 (IPDPS 2009).
//
// -----------------------------------------------------------------------

#include "../inc/radix_split.h"
#include <algorithm>
#include <stdio.h>
#include <stdlib.h>
#include <device_functions.h>
#include <cuda.h>
#include <thrust/count.h>
#include <thrust/transform.h>
#include <thrust/functional.h>
#include <thrust/scan.h>
#include <thrust/device_ptr.h>
#include <thrust/sort.h>

#define BLOCK_ID (gridDim.y * blockIdx.x + blockIdx.y)
#define THREAD_ID (threadIdx.x)
#define TID (BLOCK_ID * blockDim.x + THREAD_ID)


enum kernelName
{
    SORT_KERNEL_EMPTY,
    SORT_KERNEL_RADIX_SORT_BLOCKS,
    SORT_KERNEL_RADIX_SORT_BLOCKS_KEYSONLY,
    SORT_KERNEL_FIND_RADIX_OFFSETS,
    SORT_KERNEL_REORDER_DATA,
    SORT_KERNEL_REORDER_DATA_KEYSONLY,
    SORT_KERNEL_COUNT,
};

bool bManualCoalesce = false;
unsigned int numCTAs[SORT_KERNEL_COUNT] = { 0, 0, 0, 0, 0, 0 };
unsigned int numSMs = 0;
unsigned int persistentCTAThreshold[2] = { 0, 0 };
unsigned int persistentCTAThresholdFullBlocks[2] = { 0, 0 };


// Replace <stl> library min/max equivalents with MIN/MAX
#define MIN(a,b) (a < b ? a : b)
#define MAX(a,b) (a > b ? a : b)

extern "C"
void initDeviceParameters()
{
    int deviceID = -1;
    if (cudaSuccess == cudaGetDevice(&deviceID))
    {
        cudaDeviceProp devprop;
        cudaGetDeviceProperties(&devprop, deviceID);
        // sm_12 and later devices don't need help with coalesce
        bManualCoalesce = (devprop.major < 2 && devprop.minor < 2);

        // Empirically we have found that for some (usually larger) sort
        // sizes it is better to use exactly as many "persistent" CTAs
        // as can fill the GPU, which loop over the "blocks" of work. For smaller
        // arrays it is better to use the typical CUDA approach of launching one CTA
        // per block of work.
        // 0-element of these two-element arrays is for key-value sorts
        // 1-element is for key-only sorts
        persistentCTAThreshold[0] = bManualCoalesce ? 16777216 : 524288;
        persistentCTAThresholdFullBlocks[0] = bManualCoalesce ? 2097152: 524288;
        persistentCTAThreshold[1] = bManualCoalesce ? 16777216 : 8388608;
        persistentCTAThresholdFullBlocks[1] = bManualCoalesce ? 2097152: 0;

        // Determine the maximum number of CTAs that can be run simultaneously for each kernel
        // This is equivalent to the calculation done in the CUDA Occupancy Calculator spreadsheet
        unsigned regAllocationUnit = (devprop.major < 2 && devprop.minor < 2) ? 256 : 512; // in registers
        unsigned smemAllocationUnit = 512;                                                 // in bytes
        unsigned maxThreadsPerSM = bManualCoalesce ? 768 : 1024; // sm_12 GPUs increase threads/SM to 1024

        // These values were obtained using --ptxas-options=-v
        // Note on compute version 1.1 and earlier (sm_11) GPUs the code
        // must be compiled with -maxrregcount=32 (that's a good idea in general)
        unsigned regsPerThread[SORT_KERNEL_COUNT] =  {0, 32, 28, 8, 14, 13};
        unsigned sharedMemBytes[SORT_KERNEL_COUNT] = {32, 4144, 4144, 3120, 4352, 2288};

        numSMs = devprop.multiProcessorCount;

        for (int i = 0; i < SORT_KERNEL_COUNT; ++i)
        {
            size_t regsPerCTA = regsPerThread[i] * RadixSort::CTA_SIZE;
            regsPerCTA += (regsPerCTA % regAllocationUnit);  // round up to nearest allocation unit
            regsPerCTA = MAX(regsPerCTA, regAllocationUnit); // ensure we round up very small amounts correctly
            size_t ctaLimitRegs = (unsigned)devprop.regsPerBlock / regsPerCTA;

            size_t smemPerCTA = MAX(smemAllocationUnit, sharedMemBytes[i] + (sharedMemBytes[i] % smemAllocationUnit));
            size_t ctaLimitSMem = devprop.sharedMemPerBlock / smemPerCTA;

            size_t ctaLimitThreads = maxThreadsPerSM / RadixSort::CTA_SIZE;

            numCTAs[i] = numSMs * MIN(ctaLimitRegs, MIN(ctaLimitSMem, MIN(ctaLimitThreads, 8)));
        }
    }
}

// In emulationmode, we need __syncthreads() inside warp-synchronous code,
// but we don't in code running on the GPU, so we define this macro to use
// in the warp-scan portion of the radix sort (see CUDPP for information
// on the warp scan algorithm.
#ifdef __DEVICE_EMULATION__
#define __SYNC __syncthreads();
#else
#define __SYNC
#endif

typedef unsigned int uint;

extern "C"
void checkCudaError(const char *msg)
{
#if defined(_DEBUG) || defined(DEBUG)
    cudaError_t e = cudaThreadSynchronize();
    if( e != cudaSuccess )
    {
        fprintf(stderr, "CUDA Error %s : %s\n", msg, cudaGetErrorString(e));
        exit(EXIT_FAILURE);
    }
    e = cudaGetLastError();
    if( e != cudaSuccess )
    {
        fprintf(stderr, "CUDA Error %s : %s\n", msg, cudaGetErrorString(e));
        exit(EXIT_FAILURE);
    }
#endif
}

// -----------------------------------------------------------------------------------------------
// The floatFlip and floatUnflip functions below are based on code in the web article
// "Radix Tricks" by Michael Herf (http://www.stereopsis.com/radix.html). They are used to convert
// floating point values into sortable unsigned integers (and back).
//
// Paraphrasing Michael: Binary single-precision floating point numbers have two features that
// keep them from being directly sortable. First, the sign bit is set when the value is negative,
// which means that all negative numbers are bigger than positive ones. Second, the values are
// signed-magnitude, so "more negative" floating point numbers actually look bigger to a normal
// bitwise comparison.
//
// "To fix our floating point numbers, we define the following rules:
//
//   1. Always flip the sign bit.
//   2. If the sign bit was set, flip the other bits too.
//
// To get back, we flip the sign bit always, and if the sign bit was not set, we flip the other
// bits too."
//
// This is a very inexpensive operation and it is only done on the first and last steps of the
// sort.
// -----------------------------------------------------------------------------------------------


// ================================================================================================
// Flip a float for sorting
//  finds SIGN of fp number.
//  if it's 1 (negative float), it flips all bits
//  if it's 0 (positive float), it flips the sign only
// ================================================================================================
template <bool doFlip>
__device__ uint floatFlip(uint f)
{
    if (doFlip)
    {
        uint mask = -int(f >> 31) | 0x80000000;
	return f ^ mask;
    }
    else
        return f;
}

// ================================================================================================
// flip a float back (invert FloatFlip)
//  signed was flipped from above, so:
//  if sign is 1 (negative), it flips the sign bit back
//  if sign is 0 (positive), it flips all bits back
// ================================================================================================
template <bool doFlip>
__device__ uint floatUnflip(uint f)
{
    if (doFlip)
    {
        uint mask = ((f >> 31) - 1) | 0x80000000;
	    return f ^ mask;
    }
    else
        return f;
}
// ================================================================================================
// Kernel to flip all floats in an array (see floatFlip, above)
// Each thread flips four values (each 256-thread CTA flips 1024 values).
// ================================================================================================
__global__ void flipFloats(uint *values, uint numValues)
{
    uint index = __umul24(blockDim.x*4, blockIdx.x) + threadIdx.x;
    if (index < numValues) values[index] = floatFlip<true>(values[index]);
    index += blockDim.x;
    if (index < numValues) values[index] = floatFlip<true>(values[index]);
    index += blockDim.x;
    if (index < numValues) values[index] = floatFlip<true>(values[index]);
    index += blockDim.x;
    if (index < numValues) values[index] = floatFlip<true>(values[index]);
}

// ================================================================================================
// Kernel to unflip all floats in an array (see floatUnflip, above)
// Each thread unflips four values (each 256-thread CTA unflips 1024 values).
// ================================================================================================
__global__ void unflipFloats(uint *values, uint numValues)
{
    uint index = __umul24(blockDim.x*4, blockIdx.x) + threadIdx.x;
    if (index < numValues) values[index] = floatUnflip<true>(values[index]);
    index += blockDim.x;
    if (index < numValues) values[index] = floatUnflip<true>(values[index]);
    index += blockDim.x;
    if (index < numValues) values[index] = floatUnflip<true>(values[index]);
    index += blockDim.x;
    if (index < numValues) values[index] = floatUnflip<true>(values[index]);
}

//----------------------------------------------------------------------------
// Scans each warp in parallel ("warp-scan"), one element per thread.
// uses 2 numElements of shared memory per thread (64 = elements per warp)
//----------------------------------------------------------------------------

//template<class T, int maxlevel>
__device__ uint scanwarp(uint val, volatile uint* sData, int maxlevel)
{

    // The following is the same as 2 * WARP_SIZE * warpId + threadInWarp =
    // 64*(threadIdx.x >> 5) + (threadIdx.x & (WARP_SIZE - 1))
    int idx = 2 * threadIdx.x - (threadIdx.x & (RadixSort::WARP_SIZE - 1));
    sData[idx] = 0;

    idx += RadixSort::WARP_SIZE;
    uint t = sData[idx] = val;

    if (0 <= maxlevel) { sData[idx] = t = t + sData[idx - 1]; }
    if (1 <= maxlevel) { sData[idx] = t = t + sData[idx - 2]; }
    if (2 <= maxlevel) { sData[idx] = t = t + sData[idx - 4]; }
    if (3 <= maxlevel) { sData[idx] = t = t + sData[idx - 8]; }
    if (4 <= maxlevel) { sData[idx] = t = t + sData[idx -16]; }

    return sData[idx] - val;  // convert inclusive -> exclusive
}
//----------------------------------------------------------------------------
// scan4 scans 4*RadixSort::CTA_SIZE numElements in a block (4 per thread), using
// a warp-scan algorithm
//----------------------------------------------------------------------------
__device__ uint4 scan4(uint4 idata)
{
    extern  __shared__  uint ptr[];

    uint idx = threadIdx.x;

    uint4 val4 = idata;

    uint sum[3];
    sum[0] = val4.x;
    sum[1] = val4.y + sum[0];
    sum[2] = val4.z + sum[1];

    uint val = val4.w + sum[2];

    val = scanwarp(val, ptr, 4);

    __syncthreads();

    if ((idx & (RadixSort::WARP_SIZE - 1)) == RadixSort::WARP_SIZE - 1)
    {
        ptr[idx >> 5] = val + val4.w + sum[2];
    }
    __syncthreads();

    if (idx < RadixSort::WARP_SIZE)
    {
        ptr[idx] = scanwarp(ptr[idx], ptr, 2);
    }
    __syncthreads();

    val += ptr[idx >> 5];

    val4.x = val;
    val4.y = val + sum[0];
    val4.z = val + sum[1];
    val4.w = val + sum[2];

    return val4;
}


//----------------------------------------------------------------------------
//
// Rank is the core of the radix sort loop.  Given a predicate, it
// computes the output position for each thread in an ordering where all
// True threads come first, followed by all False threads.
//
// This version handles 4 predicates per thread; hence, "rank4".
//
//----------------------------------------------------------------------------

template <int ctasize>
__device__ uint4 rank4(uint4 preds)
{
    uint4 address = scan4(preds);

    __shared__ uint numtrue;
    if (threadIdx.x == ctasize-1)
    {
        numtrue = address.w + preds.w;
    }
    __syncthreads();

    uint4 rank;
    uint idx = threadIdx.x << 2;
    rank.x = (preds.x) ? address.x : numtrue + idx   - address.x;
    rank.y = (preds.y) ? address.y : numtrue + idx + 1 - address.y;
    rank.z = (preds.z) ? address.z : numtrue + idx + 2 - address.z;
    rank.w = (preds.w) ? address.w : numtrue + idx + 3 - address.w;

    return rank;
}


//----------------------------------------------------------------------------
// Uses rank to sort one bit at a time: Sorts a block according
// to bits startbit -> nbits + startbit
//
// Each thread sorts 4 elements by nbits bits
//----------------------------------------------------------------------------

//bucket range should be 0-15

__device__ uint getbucket(uint key)
{
	uint bk = (uint)__log2f((uint)key-1)+!((uint)key==1);

	if(bk > 12 && bk <= 16)
		bk = 12;
	else if (bk > 16 && bk <= 32)
		bk = 13;
	else if (bk == 33)
		bk = 15;

	return bk;
	
	//return key;
}

__device__ uint4 getbucket4(uint4 key)
{
	uint4 bucket;
	bucket.x = getbucket(key.x);
	bucket.y = getbucket(key.y);
	bucket.z = getbucket(key.z);
	bucket.w = getbucket(key.w);

	return bucket;
}

__device__ uint2 getbucket2(uint2 key)
{
	uint2 bucket;
	bucket.x = getbucket(key.x);
	bucket.y = getbucket(key.y);

	return bucket;
}


/*
template<uint nbits, uint startbit>
__device__ void radixSortBlock(uint4 &key, uint4 &value)
{
    extern __shared__ uint sMem1[];

    for(uint shift = startbit; shift < (startbit + nbits); ++shift)
    {
        uint4 lsb;

	//lsb.x = !((((uint)__log2f(key.x-1)+((key.x==1)?0:1)) >> shift) & 0x1);
	//lsb.y = !((((uint)__log2f(key.y-1)+((key.y==1)?0:1)) >> shift) & 0x1);
	//lsb.z = !((((uint)__log2f(key.z-1)+((key.z==1)?0:1)) >> shift) & 0x1);
	//lsb.w = !((((uint)__log2f(key.w-1)+((key.w==1)?0:1)) >> shift) & 0x1);

	lsb.x = !((key.x >> shift) & 0x1);
        lsb.y = !((key.y >> shift) & 0x1);
        lsb.z = !((key.z >> shift) & 0x1);
        lsb.w = !((key.w >> shift) & 0x1);

        uint4 r = rank4<RadixSort::CTA_SIZE>(lsb);

        // This arithmetic strides the ranks across 4 CTA_SIZE regions
        sMem1[(r.x & 3) * RadixSort::CTA_SIZE + (r.x >> 2)] = key.x;
        sMem1[(r.y & 3) * RadixSort::CTA_SIZE + (r.y >> 2)] = key.y;
        sMem1[(r.z & 3) * RadixSort::CTA_SIZE + (r.z >> 2)] = key.z;
        sMem1[(r.w & 3) * RadixSort::CTA_SIZE + (r.w >> 2)] = key.w;
        __syncthreads();

        // The above allows us to read without 4-way bank conflicts:
        key.x = sMem1[threadIdx.x];
        key.y = sMem1[threadIdx.x +     RadixSort::CTA_SIZE];
        key.z = sMem1[threadIdx.x + 2 * RadixSort::CTA_SIZE];
        key.w = sMem1[threadIdx.x + 3 * RadixSort::CTA_SIZE];

        __syncthreads();

        sMem1[(r.x & 3) * RadixSort::CTA_SIZE + (r.x >> 2)] = value.x;
        sMem1[(r.y & 3) * RadixSort::CTA_SIZE + (r.y >> 2)] = value.y;
        sMem1[(r.z & 3) * RadixSort::CTA_SIZE + (r.z >> 2)] = value.z;
        sMem1[(r.w & 3) * RadixSort::CTA_SIZE + (r.w >> 2)] = value.w;
        __syncthreads();

        value.x = sMem1[threadIdx.x];
        value.y = sMem1[threadIdx.x +     RadixSort::CTA_SIZE];
        value.z = sMem1[threadIdx.x + 2 * RadixSort::CTA_SIZE];
        value.w = sMem1[threadIdx.x + 3 * RadixSort::CTA_SIZE];

        __syncthreads();
    }

}*/

template<uint nbits, uint startbit>
__device__ void radixSortBlock(uint4 &key, uint4 &value)
{
    extern __shared__ uint sMem1[];


    for(uint shift = startbit; shift < (startbit + nbits); ++shift)
    {
        uint4 lsb;

        //lsb.x = !((key.x >> shift) & 0x1);
        //lsb.y = !((key.y >> shift) & 0x1);
        //lsb.z = !((key.z >> shift) & 0x1);
        //lsb.w = !((key.w >> shift) & 0x1);
	
    	uint4 bucket = getbucket4(key);
        lsb.x = !((bucket.x >> shift) & 0x1);
        lsb.y = !((bucket.y >> shift) & 0x1);
        lsb.z = !((bucket.z >> shift) & 0x1);
        lsb.w = !((bucket.w >> shift) & 0x1);

        uint4 r = rank4<256>(lsb);

        // This arithmetic strides the ranks across 4 SORT_CTA_SIZE regions
        sMem1[(r.x & 3) * RadixSort::CTA_SIZE + (r.x >> 2)] = key.x;
        sMem1[(r.y & 3) * RadixSort::CTA_SIZE + (r.y >> 2)] = key.y;
        sMem1[(r.z & 3) * RadixSort::CTA_SIZE + (r.z >> 2)] = key.z;
        sMem1[(r.w & 3) * RadixSort::CTA_SIZE + (r.w >> 2)] = key.w;
        __syncthreads();

        // The above allows us to read without 4-way bank conflicts:
        key.x = sMem1[threadIdx.x];
        key.y = sMem1[threadIdx.x +     RadixSort::CTA_SIZE];
        key.z = sMem1[threadIdx.x + 2 * RadixSort::CTA_SIZE];
        key.w = sMem1[threadIdx.x + 3 * RadixSort::CTA_SIZE];

        __syncthreads();

        sMem1[(r.x & 3) * RadixSort::CTA_SIZE + (r.x >> 2)] = value.x;
        sMem1[(r.y & 3) * RadixSort::CTA_SIZE + (r.y >> 2)] = value.y;
        sMem1[(r.z & 3) * RadixSort::CTA_SIZE + (r.z >> 2)] = value.z;
        sMem1[(r.w & 3) * RadixSort::CTA_SIZE + (r.w >> 2)] = value.w;
        __syncthreads();

        value.x = sMem1[threadIdx.x];
        value.y = sMem1[threadIdx.x +     RadixSort::CTA_SIZE];
        value.z = sMem1[threadIdx.x + 2 * RadixSort::CTA_SIZE];
        value.w = sMem1[threadIdx.x + 3 * RadixSort::CTA_SIZE];

        __syncthreads();

    }
}



__global__ void emptyKernel() {}

//----------------------------------------------------------------------------
//
// radixSortBlocks sorts all blocks of data independently in shared
// memory.  Each thread block (CTA) sorts one block of 4*CTA_SIZE elements
//
// The radix sort is done in two stages.  This stage calls radixSortBlock on each
// block independently, sorting on the basis of bits (startbit) -> (startbit + nbits)
//
// Template parameters are used to generate efficient code for various special cases
// For example, we have to handle arrays that are a multiple of the block size (fullBlocks)
// differently than arrays that are not.  "flip" is used to only compile in the
// float flip code when float keys are used.  "loop" is used when persistent CTAs
// are used.
//
// By persistent CTAs we mean that we launch only as many thread blocks as can
// be resident in the GPU and no more, rather than launching as many threads as
// we have elements. Persistent CTAs loop over blocks of elements until all work
// is complete.  This can be faster in some cases.  In our tests it is faster
// for large sorts (and the threshold is higher on compute version 1.1 and earlier
// GPUs than it is on compute version 2.0 GPUs.
//----------------------------------------------------------------------------
template<uint nbits, uint startbit, bool fullBlocks, bool flip, bool loop>
__global__ void radixSortBlocks(uint4* keysOut, uint4* valuesOut,
                                uint4* keysIn, uint4* valuesIn,
                                uint numElements, uint totalBlocks)
{
    extern __shared__ uint4 sMem[];

    uint4 key, value;


    uint blockId = blockIdx.x;

    while (!loop || blockId < totalBlocks)
    {
        uint i = blockId * blockDim.x + threadIdx.x;
        uint idx = i << 2;

        // handle non-full last block if array is not multiple of 1024 numElements
        if (!fullBlocks && idx+3 >= numElements)
        {
            if (idx >= numElements)
            {
                key   = make_uint4(UINT_MAX, UINT_MAX, UINT_MAX, UINT_MAX);
                value = make_uint4(UINT_MAX, UINT_MAX, UINT_MAX, UINT_MAX);
            }
            else
            {
                // for non-full block, we handle uint1 values instead of uint4
                uint *keys1    = (uint*)keysIn;
                uint *values1  = (uint*)valuesIn;
		
                key.x = (idx   < numElements) ? floatFlip<flip>(keys1[idx])   : UINT_MAX;
                key.y = (idx+1 < numElements) ? floatFlip<flip>(keys1[idx+1]) : UINT_MAX;
                key.z = (idx+2 < numElements) ? floatFlip<flip>(keys1[idx+2]) : UINT_MAX;
                key.w = UINT_MAX;

                value.x = (idx   < numElements) ? values1[idx]   : UINT_MAX;
                value.y = (idx+1 < numElements) ? values1[idx+1] : UINT_MAX;
                value.z = (idx+2 < numElements) ? values1[idx+2] : UINT_MAX;
                value.w = UINT_MAX;
            }
        }
        else
        {
            key = keysIn[i];
            value = valuesIn[i];

            if (flip)
            {
                key.x = floatFlip<flip>(key.x);
                key.y = floatFlip<flip>(key.y);
                key.z = floatFlip<flip>(key.z);
                key.w = floatFlip<flip>(key.w);
            }
        }

        __syncthreads();
	
	
        radixSortBlock<nbits, startbit>(key, value);

	
        // handle non-full last block if array is not multiple of 1024 numElements
        if(!fullBlocks && idx+3 >= numElements)
        {
            if (idx < numElements)
            {
                // for non-full block, we handle uint1 values instead of uint4
                uint *keys1   = (uint*)keysOut;
                uint *values1 = (uint*)valuesOut;

                keys1[idx]   = key.x;
                values1[idx] = value.x;

                if (idx + 1 < numElements)
                {
                    keys1[idx + 1]   = key.y;
                    values1[idx + 1] = value.y;

                    if (idx + 2 < numElements)
                    {
                        keys1[idx + 2]   = key.z;
                        values1[idx + 2] = value.z;
                    }
                }
            }
        }
        else
        {
            keysOut[i]   = key;
            valuesOut[i] = value;

        }

        if (loop)
            blockId += gridDim.x;
        else
            break;
    }
}

//----------------------------------------------------------------------------
// Given an array with blocks sorted according to a 4-bit radix group, each
// block counts the number of keys that fall into each radix in the group, and
// finds the starting offset of each radix in the block.  It then writes the radix
// counts to the counters array, and the starting offsets to the blockOffsets array.
//
// Template parameters are used to generate efficient code for various special cases
// For example, we have to handle arrays that are a multiple of the block size
// (fullBlocks) differently than arrays that are not. "loop" is used when persistent
// CTAs are used.
//
// By persistent CTAs we mean that we launch only as many thread blocks as can
// be resident in the GPU and no more, rather than launching as many threads as
// we have elements. Persistent CTAs loop over blocks of elements until all work
// is complete.  This can be faster in some cases.  In our tests it is faster
// for large sorts (and the threshold is higher on compute version 1.1 and earlier
// GPUs than it is on compute version 2.0 GPUs.
//
//----------------------------------------------------------------------------
template<uint startbit, bool fullBlocks, bool loop>
__global__ void findRadixOffsets(uint2 *keys,
                                 uint  *counters,
                                 uint  *blockOffsets,
                                 uint   numElements,
                                 uint   totalBlocks)
{
    extern __shared__ uint2 sMem2[];

    uint2 *sRadix2         = (uint2*)sMem2;
    uint  *sRadix1         = (uint*) sRadix2;
    uint  *sStartPointers  = (uint*)(sMem2 + RadixSort::CTA_SIZE);

    uint blockId = blockIdx.x;

    while (!loop || blockId < totalBlocks)
    {
        uint2 radix2;

        uint i       = blockId * blockDim.x + threadIdx.x;

        // handle non-full last block if array is not multiple of 1024 numElements
        if(!fullBlocks && ((i + 1) << 1 ) > numElements )
        {
            // handle uint1 rather than uint2 for non-full blocks
            uint *keys1 = (uint*)keys;
            uint j = i << 1;

            radix2.x = (j < numElements) ? getbucket(keys1[j]) : 0x0F;
            j++;
            radix2.y = (j < numElements) ? getbucket(keys1[j]) : 0x0F;
        }
        else
        {
            //radix2 = keys[i];
	    radix2 = getbucket2(keys[i]);
        }


        sRadix1[2 * threadIdx.x]     = (radix2.x >> startbit) & 0xF;
        sRadix1[2 * threadIdx.x + 1] = (radix2.y >> startbit) & 0xF;

        // Finds the position where the sRadix1 entries differ and stores start
        // index for each radix.
        if(threadIdx.x < 16)
        {
            sStartPointers[threadIdx.x] = 0;
        }
        __syncthreads();

        if((threadIdx.x > 0) && (sRadix1[threadIdx.x] != sRadix1[threadIdx.x - 1]) )
        {
            sStartPointers[sRadix1[threadIdx.x]] = threadIdx.x;
        }
        if(sRadix1[threadIdx.x + RadixSort::CTA_SIZE] != sRadix1[threadIdx.x + RadixSort::CTA_SIZE - 1])
        {
            sStartPointers[sRadix1[threadIdx.x + RadixSort::CTA_SIZE]] = threadIdx.x + RadixSort::CTA_SIZE;
        }
        __syncthreads();

        if(threadIdx.x < 16)
        {
            blockOffsets[blockId*16 + threadIdx.x] = sStartPointers[threadIdx.x];
        }
        __syncthreads();

        // Compute the sizes of each block.
        if((threadIdx.x > 0) && (sRadix1[threadIdx.x] != sRadix1[threadIdx.x - 1]) )
        {
            sStartPointers[sRadix1[threadIdx.x - 1]] =
                threadIdx.x - sStartPointers[sRadix1[threadIdx.x - 1]];
        }
        if(sRadix1[threadIdx.x + RadixSort::CTA_SIZE] != sRadix1[threadIdx.x + RadixSort::CTA_SIZE - 1] )
        {
            sStartPointers[sRadix1[threadIdx.x + RadixSort::CTA_SIZE - 1]] =
                threadIdx.x + RadixSort::CTA_SIZE - sStartPointers[sRadix1[threadIdx.x + RadixSort::CTA_SIZE - 1]];
        }

        if(threadIdx.x == RadixSort::CTA_SIZE - 1)
        {
            sStartPointers[sRadix1[2 * RadixSort::CTA_SIZE - 1]] =
                2 * RadixSort::CTA_SIZE - sStartPointers[sRadix1[2 * RadixSort::CTA_SIZE - 1]];
        }
        __syncthreads();

        if(threadIdx.x < 16)
        {
            counters[threadIdx.x * totalBlocks + blockId] =
                sStartPointers[threadIdx.x];
        }

        if (loop)
            blockId += gridDim.x;
        else
            break;
    }
}

//----------------------------------------------------------------------------
// reorderData shuffles data in the array globally after the radix offsets
// have been found. On compute version 1.1 and earlier GPUs, this code depends
// on RadixSort::CTA_SIZE being 16 * number of radices (i.e. 16 * 2^nbits).
//
// On compute version 1.1 GPUs ("manualCoalesce=true") this function ensures
// that all writes are coalesced using extra work in the kernel.  On later
// GPUs coalescing rules have been relaxed, so this extra overhead hurts
// performance.  On these GPUs we set manualCoalesce=false and directly store
// the results.
//
// Template parameters are used to generate efficient code for various special cases
// For example, we have to handle arrays that are a multiple of the block size
// (fullBlocks) differently than arrays that are not.  "loop" is used when persistent
// CTAs are used.
//
// By persistent CTAs we mean that we launch only as many thread blocks as can
// be resident in the GPU and no more, rather than launching as many threads as
// we have elements. Persistent CTAs loop over blocks of elements until all work
// is complete.  This can be faster in some cases.  In our tests it is faster
// for large sorts (and the threshold is higher on compute version 1.1 and earlier
// GPUs than it is on compute version 2.0 GPUs.
//----------------------------------------------------------------------------
template<uint startbit, bool fullBlocks, bool manualCoalesce, bool unflip, bool loop>
__global__ void reorderData(uint  *outKeys,
                            uint  *outValues,
                            uint2 *keys,
                            uint2 *values,
                            uint  *blockOffsets,
                            uint  *offsets,
                            uint  *sizes,
                            uint   numElements,
                            uint   totalBlocks)
{
    __shared__ uint2 sKeys2[RadixSort::CTA_SIZE];
    __shared__ uint2 sValues2[RadixSort::CTA_SIZE];
    __shared__ uint sOffsets[16];
    __shared__ uint sBlockOffsets[16];

    uint *sKeys1   = (uint*)sKeys2;
    uint *sValues1 = (uint*)sValues2;

    uint blockId = blockIdx.x;

    while (!loop || blockId < totalBlocks)
    {
        uint i = blockId * blockDim.x + threadIdx.x;

        // handle non-full last block if array is not multiple of 1024 numElements
        if(!fullBlocks && (((i + 1) << 1) > numElements))
        {
            uint *keys1   = (uint*)keys;
            uint *values1 = (uint*)values;
            uint j = i << 1;

            sKeys1[threadIdx.x << 1]   = (j < numElements) ? keys1[j]   : UINT_MAX;
            sValues1[threadIdx.x << 1] = (j < numElements) ? values1[j] : UINT_MAX;
            j++;
            sKeys1[(threadIdx.x << 1) + 1]   = (j < numElements) ? keys1[j]   : UINT_MAX;
            sValues1[(threadIdx.x << 1) + 1] = (j < numElements) ? values1[j] : UINT_MAX;
        }
        else
        {
            sKeys2[threadIdx.x]   = keys[i];
            sValues2[threadIdx.x] = values[i];
        }

        if (!manualCoalesce)
        {
            if(threadIdx.x < 16)
            {
                sOffsets[threadIdx.x]      = offsets[threadIdx.x * totalBlocks + blockId];
                sBlockOffsets[threadIdx.x] = blockOffsets[blockId * 16 + threadIdx.x];
            }
            __syncthreads();

            uint radix = (getbucket(sKeys1[threadIdx.x]) >> startbit) & 0xF;
            uint globalOffset = sOffsets[radix] + threadIdx.x - sBlockOffsets[radix];

            if (fullBlocks || globalOffset < numElements)
            {
                outKeys[globalOffset]   = floatUnflip<unflip>(sKeys1[threadIdx.x]);
                outValues[globalOffset] = sValues1[threadIdx.x];
            }

            radix = (getbucket(sKeys1[threadIdx.x + RadixSort::CTA_SIZE]) >> startbit) & 0xF;
            globalOffset = sOffsets[radix] + threadIdx.x + RadixSort::CTA_SIZE - sBlockOffsets[radix];

            if (fullBlocks || globalOffset < numElements)
            {
                outKeys[globalOffset]   = floatUnflip<unflip>(sKeys1[threadIdx.x + RadixSort::CTA_SIZE]);
                outValues[globalOffset] = sValues1[threadIdx.x + RadixSort::CTA_SIZE];
            }
        }
        else
        {
            __shared__ uint sSizes[16];

            if(threadIdx.x < 16)
            {
                sOffsets[threadIdx.x]      = offsets[threadIdx.x * totalBlocks + blockId];
                sBlockOffsets[threadIdx.x] = blockOffsets[blockId * 16 + threadIdx.x];
                sSizes[threadIdx.x]        = sizes[threadIdx.x * totalBlocks + blockId];
            }
            __syncthreads();

            // 1 half-warp is responsible for writing out all values for 1 radix.
            // Loops if there are more than 16 values to be written out.
            // All start indices are rounded down to the nearest multiple of 16, and
            // all end indices are rounded up to the nearest multiple of 16.
            // Thus it can do extra work if the start and end indices are not multiples of 16
            // This is bounded by a factor of 2 (it can do 2X more work at most).

            const uint halfWarpID     = threadIdx.x >> 4;

            const uint halfWarpOffset = threadIdx.x & 0xF;
            const uint leadingInvalid = sOffsets[halfWarpID] & 0xF;

            uint startPos = sOffsets[halfWarpID] & 0xFFFFFFF0;
            uint endPos   = (sOffsets[halfWarpID] + sSizes[halfWarpID]) + 15 -
                ((sOffsets[halfWarpID] + sSizes[halfWarpID] - 1) & 0xF);
            uint numIterations = endPos - startPos;

            uint outOffset = startPos + halfWarpOffset;
            uint inOffset  = sBlockOffsets[halfWarpID] - leadingInvalid + halfWarpOffset;

            for(uint j = 0; j < numIterations; j += 16, outOffset += 16, inOffset += 16)
            {
                if( (outOffset >= sOffsets[halfWarpID]) &&
                    (inOffset - sBlockOffsets[halfWarpID] < sSizes[halfWarpID]))
                {
                    if(blockId < totalBlocks - 1 || outOffset < numElements)
                    {
                        outKeys[outOffset]   = floatUnflip<unflip>(sKeys1[inOffset]);
                        outValues[outOffset] = sValues1[inOffset];
                    }
                }
            }
        }

        if (loop)
        {
            blockId += gridDim.x;
            __syncthreads();
        }
        else
            break;
    }
}

//----------------------------------------------------------------------------
// Perform one step of the radix sort.  Sorts by nbits key bits per step,
// starting at startbit.
//
// Uses cudppScan() for the prefix sum of radix counters.
//----------------------------------------------------------------------------
template<uint nbits, uint startbit, bool flip, bool unflip>
void radixSortStep(uint *keys,
                   uint *values,
                   uint *tempKeys,
                   uint *tempValues,
                   uint *counters,
                   uint *countersSum,
                   uint *blockOffsets,
                   uint numElements)
{
    const uint eltsPerBlock = RadixSort::CTA_SIZE * 4;
    const uint eltsPerBlock2 = RadixSort::CTA_SIZE * 2;

    bool fullBlocks = ((numElements % eltsPerBlock) == 0);
    uint numBlocks = (fullBlocks) ?
        (numElements / eltsPerBlock) :
        (numElements / eltsPerBlock + 1);
    uint numBlocks2 = ((numElements % eltsPerBlock2) == 0) ?
        (numElements / eltsPerBlock2) :
        (numElements / eltsPerBlock2 + 1);

    bool loop = numBlocks > 65535;
    bool loop2 = numBlocks2 > 65535;
    uint blocks = loop ? 65535 : numBlocks;
    uint blocksFind = loop2 ? 65535 : numBlocks2;
    uint blocksReorder = loop2 ? 65535 : numBlocks2;

    uint threshold = fullBlocks ? persistentCTAThresholdFullBlocks[0] : persistentCTAThreshold[0];



    if (numElements >= threshold)
    {
        loop = (numElements > 262144) || (numElements >= 32768 && numElements < 65536);
        loop2 = (numElements > 262144) || (numElements >= 32768 && numElements < 65536);
        blocks = loop ? numCTAs[SORT_KERNEL_RADIX_SORT_BLOCKS] : numBlocks;
        blocksFind = loop ? numCTAs[SORT_KERNEL_FIND_RADIX_OFFSETS] : numBlocks2;
        blocksReorder = loop ? numCTAs[SORT_KERNEL_REORDER_DATA] : numBlocks2;

        // Run an empty kernel -- this seems to reset some of the CTA scheduling hardware
	// on GT200, resulting in better scheduling and lower run times
        if (startbit > 0)
            emptyKernel<<<numCTAs[SORT_KERNEL_EMPTY], RadixSort::CTA_SIZE>>>();
    }
	
	/*
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if(err != cudaSuccess)
		printf("last cudaerr is3 %d\n", err);
	*/

    if (fullBlocks)
    {
        if (loop)
        {
            radixSortBlocks<nbits, startbit, true, flip, true>
                <<<blocks, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)tempKeys, (uint4*)tempValues, (uint4*)keys, (uint4*)values, numElements, numBlocks);
        }
        else
        {

            radixSortBlocks<nbits, startbit, true, flip, false>
                <<<blocks, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)tempKeys, (uint4*)tempValues, (uint4*)keys, (uint4*)values, numElements, numBlocks);

        }
    }
    else
    {
        if (loop)
        {

	/*
	    printf("loop %d, %d, %d, %d, %d, %d, %d\n", tempKeys==0, tempValues==0, keys==0, values==0, numElements, numBlocks, blocks);
	size_t* freed;
	size_t* total;
	freed = (size_t*)malloc(sizeof(size_t));
	total = (size_t*)malloc(sizeof(size_t));
	cudaMemGetInfo(freed, total);
	printf("/////////free memory is %zd, and total is %zd\n", (*freed), (*total));
	free(freed);
	free(total);
	*/

            radixSortBlocks<nbits, startbit, false, flip, true>
                <<<blocks, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)tempKeys, (uint4*)tempValues, (uint4*)keys, (uint4*)values, numElements, numBlocks);
        }
        else
        {

            radixSortBlocks<nbits, startbit, false, flip, false>
                <<<blocks, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)tempKeys, (uint4*)tempValues, (uint4*)keys, (uint4*)values, numElements, numBlocks);
        }
    }


    if (fullBlocks)
    {
        if (loop2)
            findRadixOffsets<startbit, true, true>
                <<<blocksFind, RadixSort::CTA_SIZE, 3 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint2*)tempKeys, counters, blockOffsets, numElements, numBlocks2);
        else
            findRadixOffsets<startbit, true, false>
                <<<blocksFind, RadixSort::CTA_SIZE, 3 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint2*)tempKeys, counters, blockOffsets, numElements, numBlocks2);
    }
    else
    {
        if (loop2)
            findRadixOffsets<startbit, false, true>
                <<<blocksFind, RadixSort::CTA_SIZE, 3 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint2*)tempKeys, counters, blockOffsets, numElements, numBlocks2);
        else
            findRadixOffsets<startbit, false, false>
                <<<blocksFind, RadixSort::CTA_SIZE, 3 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint2*)tempKeys, counters, blockOffsets, numElements, numBlocks2);
    }

	thrust::device_ptr<uint> d_input_ptr = thrust::device_pointer_cast(counters);
	thrust::device_ptr<uint> d_output_ptr = thrust::device_pointer_cast(countersSum);
	thrust::exclusive_scan(d_input_ptr, d_input_ptr+16*numBlocks2, d_output_ptr);

	//cudppScan(scanPlan, countersSum, counters, 16*numBlocks2);

    if (fullBlocks)
    {
        if (bManualCoalesce)
        {
            if (loop2)
                reorderData<startbit, true, true, unflip, true>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, values, (uint2*)tempKeys, (uint2*)tempValues,
                    blockOffsets, countersSum, counters, numElements, numBlocks2);
            else
                reorderData<startbit, true, true, unflip, false>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, values, (uint2*)tempKeys, (uint2*)tempValues,
                    blockOffsets, countersSum, counters, numElements, numBlocks2);
        }
        else
        {
            if (loop2)
                reorderData<startbit, true, false, unflip, true>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, values, (uint2*)tempKeys, (uint2*)tempValues,
                    blockOffsets, countersSum, counters, numElements, numBlocks2);
            else
                reorderData<startbit, true, false, unflip, false>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, values, (uint2*)tempKeys, (uint2*)tempValues,
                    blockOffsets, countersSum, counters, numElements, numBlocks2);
        }
    }
    else
    {
        if (bManualCoalesce)
        {
            if (loop2)
                reorderData<startbit, false, true, unflip, true>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, values, (uint2*)tempKeys, (uint2*)tempValues,
                    blockOffsets, countersSum, counters, numElements, numBlocks2);
            else
                reorderData<startbit, false, true, unflip, false>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, values, (uint2*)tempKeys, (uint2*)tempValues,
                    blockOffsets, countersSum, counters, numElements, numBlocks2);
        }
        else
        {
            if (loop2)
                reorderData<startbit, false, false, unflip, true>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, values, (uint2*)tempKeys, (uint2*)tempValues,
                    blockOffsets, countersSum, counters, numElements, numBlocks2);
            else
                reorderData<startbit, false, false, unflip, false>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, values, (uint2*)tempKeys, (uint2*)tempValues,
                    blockOffsets, countersSum, counters, numElements, numBlocks2);

        }
    }

	/*
	uint *h_counters = (uint*)malloc(numElements*sizeof(uint));
	uint *h_countersSum = (uint*)malloc(numElements*sizeof(uint));

	cudaMemcpy(h_counters, 	   keys,    numElements*sizeof(uint), cudaMemcpyDeviceToHost);
	cudaMemcpy(h_countersSum,  values,  numElements*sizeof(uint), cudaMemcpyDeviceToHost);
		
        //printf("4 * RadixSort::CTA_SIZE * sizeof(uint) is %d\n", 4 * RadixSort::CTA_SIZE * sizeof(uint));
	for(int i=0; i<numElements; i++)
		printf("%d: %d, %d\n", i, h_counters[i], h_countersSum[i]);

	free(h_counters);
	free(h_countersSum);
	*/
	


    checkCudaError("radixSortStep");
}

//----------------------------------------------------------------------------
// Optimization for sorts of fewer than 4 * CTA_SIZE elements
//----------------------------------------------------------------------------
template <bool flip>
void radixSortSingleBlock(uint *keys,
                          uint *values,
                          uint numElements)
{
    bool fullBlocks = (numElements % (RadixSort::CTA_SIZE * 4) == 0);
    if (fullBlocks)
    {
        radixSortBlocks<32, 0, true, flip, false>
            <<<1, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)keys, (uint4*)values,
                 (uint4*)keys, (uint4*)values,
                 numElements, 1 );
    }
    else
    {
        radixSortBlocks<32, 0, false, flip, false>
            <<<1, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)keys, (uint4*)values,
                 (uint4*)keys, (uint4*)values,
                 numElements, 1 );
    }

    if (flip)
            unflipFloats<<<1, RadixSort::CTA_SIZE>>>(keys, numElements);

    checkCudaError("radixSortSingleBlock");
}

//----------------------------------------------------------------------------
// Optimization for sorts of WARP_SIZE or fewer elements
//----------------------------------------------------------------------------
template <bool flip>
__global__
void radixSortSingleWarp(uint *keys,
                         uint *values,
                         uint numElements)
{
    volatile __shared__ uint sKeys[RadixSort::WARP_SIZE];
    volatile __shared__ uint sValues[RadixSort::WARP_SIZE];
    volatile __shared__ uint sFlags[RadixSort::WARP_SIZE];

    sKeys[threadIdx.x]   = floatFlip<flip>(keys[threadIdx.x]);
    sValues[threadIdx.x] = values[threadIdx.x];

    __SYNC // emulation only

    for(uint i = 1; i < numElements; i++)
    {
        uint key_i = sKeys[i];
        uint val_i = sValues[i];

        sFlags[threadIdx.x] = 0;

        if( (threadIdx.x < i) && (sKeys[threadIdx.x] > key_i))
        {
            uint temp = sKeys[threadIdx.x];
            uint tempval = sValues[threadIdx.x];
            sFlags[threadIdx.x] = 1;
            sKeys[threadIdx.x + 1] = temp;
            sValues[threadIdx.x + 1] = tempval;
            sFlags[threadIdx.x + 1] = 0;
        }
        if(sFlags[threadIdx.x] == 1 )
        {
            sKeys[threadIdx.x] = key_i;
            sValues[threadIdx.x] = val_i;
        }

        __SYNC // emulation only

    }
    keys[threadIdx.x]   = floatUnflip<flip>(sKeys[threadIdx.x]);
    values[threadIdx.x] = sValues[threadIdx.x];
}

//----------------------------------------------------------------------------
// Main radix sort function.  Sorts in place in the keys and values arrays,
// but uses the other device arrays as temporary storage.  All pointer
// parameters are device pointers.
//----------------------------------------------------------------------------
extern "C"
void radixSort(uint *keys,
               uint *values,
               uint *tempKeys,
               uint *tempValues,
               uint *counters,
               uint *countersSum,
               uint *blockOffsets,
               uint numElements,
               uint keyBits,
               bool flipBits = false)
{
    if(numElements <= RadixSort::WARP_SIZE)
    {
        if (flipBits)
            radixSortSingleWarp<true><<<1, numElements>>>(keys, values, numElements);
        else
            radixSortSingleWarp<false><<<1, numElements>>>(keys, values, numElements);
        return;
    }
    if(numElements <= RadixSort::CTA_SIZE * 4)
    {
        if (flipBits)
            radixSortSingleBlock<true>(keys, values, numElements);
        else
            radixSortSingleBlock<false>(keys, values, numElements);
        return;
    }

    // flip float bits on the first pass, unflip on the last pass
    if (flipBits)
    {
            radixSortStep<4,  0, true, false>(keys, values, tempKeys, tempValues,
                                              counters, countersSum, blockOffsets, numElements);
    }
    else
    {		
	     radixSortStep<4,  0, false, false>(keys, values, tempKeys, tempValues,
                                               counters, countersSum, blockOffsets, numElements);
    }

    if (keyBits > 4)
    {
            radixSortStep<4,  4, false, false>(keys, values, tempKeys, tempValues,
                                               counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 8)
    {
            radixSortStep<4,  8, false, false>(keys, values, tempKeys, tempValues,
                                               counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 12)
    {
            radixSortStep<4, 12, false, false>(keys, values, tempKeys, tempValues,
                                               counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 16)
    {
            radixSortStep<4, 16, false, false>(keys, values, tempKeys, tempValues,
                                               counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 20)
    {
            radixSortStep<4, 20, false, false>(keys, values, tempKeys, tempValues,
                                               counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 24)
    {
            radixSortStep<4, 24, false, false>(keys, values, tempKeys, tempValues,
                                               counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 28)
    {
        if (flipBits) // last pass
        {
            radixSortStep<4, 28, false, true>(keys, values, tempKeys, tempValues,
                                              counters, countersSum, blockOffsets, numElements);
        }
        else
        {
            radixSortStep<4, 28, false, false>(keys, values, tempKeys, tempValues,
                                               counters, countersSum, blockOffsets, numElements);
        }
    }
}

extern "C"
void radixSortFloatKeys(float *keys,
                        uint  *values,
                        float *tempKeys,
                        uint  *tempValues,
                        uint  *counters,
                        uint  *countersSum,
                        uint  *blockOffsets,
                        uint  numElements,
                        uint  keyBits,
                        bool  negativeKeys)
{
    radixSort((uint*)keys, values, (uint*)tempKeys, tempValues, counters,
              countersSum, blockOffsets, numElements, keyBits,
              negativeKeys);
    checkCudaError("radixSortFloatKeys");
}

//----------------------------------------------------------------------------
// Key-only Sorts
//----------------------------------------------------------------------------

//----------------------------------------------------------------------------
// Uses rank to sort one bit at a time: Sorts a block according
// to bits startbit -> nbits + startbit
//----------------------------------------------------------------------------
template<uint nbits, uint startbit>
__device__ void radixSortBlockKeysOnly(uint4 &key)
{
    extern __shared__ uint sMem1[];

    for(uint shift = startbit; shift < (startbit + nbits); ++shift)
    {
        uint4 lsb;
    	uint4 bucket = getbucket4(key);

        lsb.x = !((bucket.x >> shift) & 0x1);
        lsb.y = !((bucket.y >> shift) & 0x1);
        lsb.z = !((bucket.z >> shift) & 0x1);
        lsb.w = !((bucket.w >> shift) & 0x1);

        //lsb.x = !((key.x >> shift) & 0x1);
        //lsb.y = !((key.y >> shift) & 0x1);
        //lsb.z = !((key.z >> shift) & 0x1);
        //lsb.w = !((key.w >> shift) & 0x1);

        uint4 r = rank4<256>(lsb);

#if 1
        // This arithmetic strides the ranks across 4 CTA_SIZE regions
        sMem1[(r.x & 3) * RadixSort::CTA_SIZE + (r.x >> 2)] = key.x;
        sMem1[(r.y & 3) * RadixSort::CTA_SIZE + (r.y >> 2)] = key.y;
        sMem1[(r.z & 3) * RadixSort::CTA_SIZE + (r.z >> 2)] = key.z;
        sMem1[(r.w & 3) * RadixSort::CTA_SIZE + (r.w >> 2)] = key.w;
        __syncthreads();

        // The above allows us to read without 4-way bank conflicts:
        key.x = sMem1[threadIdx.x];
        key.y = sMem1[threadIdx.x +     RadixSort::CTA_SIZE];
        key.z = sMem1[threadIdx.x + 2 * RadixSort::CTA_SIZE];
        key.w = sMem1[threadIdx.x + 3 * RadixSort::CTA_SIZE];
#else
        sMem1[r.x] = key.x;
        sMem1[r.y] = key.y;
        sMem1[r.z] = key.z;
        sMem1[r.w] = key.w;
        __syncthreads();

        // This access has 4-way bank conflicts
        key = sMem[threadIdx.x];
#endif

        __syncthreads();

    }
}

//----------------------------------------------------------------------------
//
// radixSortBlocks sorts all blocks of data independently in shared
// memory.  Each thread block (CTA) sorts one block of 4*CTA_SIZE elements
//
// The radix sort is done in two stages.  This stage calls radixSortBlock on each
// block independently, sorting on the basis of bits (startbit) -> (startbit + nbits)
//
// Template parameters are used to generate efficient code for various special cases
// For example, we have to handle arrays that are a multiple of the block size (fullBlocks)
// differently than arrays that are not.  "flip" is used to only compile in the
// float flip code when float keys are used.  "loop" is used when persistent CTAs
// are used.
//
// By persistent CTAs we mean that we launch only as many thread blocks as can
// be resident in the GPU and no more, rather than launching as many threads as
// we have elements. Persistent CTAs loop over blocks of elements until all work
// is complete.  This can be faster in some cases.  In our tests it is faster
// for large sorts (and the threshold is higher on compute version 1.1 and earlier
// GPUs than it is on compute version 2.0 GPUs.
//----------------------------------------------------------------------------
template<uint nbits, uint startbit, bool fullBlocks, bool flip, bool loop>
__global__ void radixSortBlocksKeysOnly(uint4* keysOut, uint4* keysIn, uint numElements, uint totalBlocks)
{
    extern __shared__ uint4 sMem[];

    uint4 key;

    uint blockId = blockIdx.x;

    while (!loop || blockId < totalBlocks)
    {
        uint i = blockId * blockDim.x + threadIdx.x;
        uint idx = i << 2;

        // handle non-full last block if array is not multiple of 1024 numElements
        if (!fullBlocks && idx+3 >= numElements)
        {
            if (idx >= numElements)
            {
                key   = make_uint4(UINT_MAX, UINT_MAX, UINT_MAX, UINT_MAX);
            }
            else
            {
                // for non-full block, we handle uint1 values instead of uint4
                uint *keys1    = (uint*)keysIn;

                key.x = (idx   < numElements) ? floatFlip<flip>(keys1[idx])   : UINT_MAX;
                key.y = (idx+1 < numElements) ? floatFlip<flip>(keys1[idx+1]) : UINT_MAX;
                key.z = (idx+2 < numElements) ? floatFlip<flip>(keys1[idx+2]) : UINT_MAX;
                key.w = UINT_MAX;
            }
        }
        else
        {
            key = keysIn[i];

            if (flip)
            {
                key.x = floatFlip<flip>(key.x);
                key.y = floatFlip<flip>(key.y);
                key.z = floatFlip<flip>(key.z);
                key.w = floatFlip<flip>(key.w);
            }
        }

        __syncthreads();
        radixSortBlockKeysOnly<nbits, startbit>(key);

        // handle non-full last block if array is not multiple of 1024 numElements
        if(!fullBlocks && idx+3 >= numElements)
        {
            if (idx < numElements)
            {
                // for non-full block, we handle uint1 values instead of uint4
                uint *keys1   = (uint*)keysOut;

                keys1[idx]   = key.x;

                if (idx + 1 < numElements)
                {
                    keys1[idx + 1]   = key.y;

                    if (idx + 2 < numElements)
                    {
                        keys1[idx + 2]   = key.z;
                    }
                }
            }
        }
        else
        {
            keysOut[i]   = key;
        }

        if (loop)
            blockId += gridDim.x;
        else
            break;
    }
}

//----------------------------------------------------------------------------
// reorderData shuffles data in the array globally after the radix offsets
// have been found. On compute version 1.1 and earlier GPUs, this code depends
// on RadixSort::CTA_SIZE being 16 * number of radices (i.e. 16 * 2^nbits).
//
// On compute version 1.1 GPUs ("manualCoalesce=true") this function ensures
// that all writes are coalesced using extra work in the kernel.  On later
// GPUs coalescing rules have been relaxed, so this extra overhead hurts
// performance.  On these GPUs we set manualCoalesce=false and directly store
// the results.
//
// Template parameters are used to generate efficient code for various special cases
// For example, we have to handle arrays that are a multiple of the block size
// (fullBlocks) differently than arrays that are not.  "loop" is used when persistent
// CTAs are used.
//
// By persistent CTAs we mean that we launch only as many thread blocks as can
// be resident in the GPU and no more, rather than launching as many threads as
// we have elements. Persistent CTAs loop over blocks of elements until all work
// is complete.  This can be faster in some cases.  In our tests it is faster
// for large sorts (and the threshold is higher on compute version 1.1 and earlier
// GPUs than it is on compute version 2.0 GPUs.
//----------------------------------------------------------------------------
template<uint startbit, bool fullBlocks, bool manualCoalesce, bool unflip, bool loop>
__global__ void reorderDataKeysOnly(uint  *outKeys,
                                    uint2 *keys,
                                    uint  *blockOffsets,
                                    uint  *offsets,
                                    uint  *sizes,
                                    uint   numElements,
                                    uint   totalBlocks)
{
    __shared__ uint2 sKeys2[RadixSort::CTA_SIZE];
    __shared__ uint sOffsets[16];
    __shared__ uint sBlockOffsets[16];

    uint *sKeys1   = (uint*)sKeys2;

    uint blockId = blockIdx.x;

    while (!loop || blockId < totalBlocks)
    {
        uint i = blockId * blockDim.x + threadIdx.x;

        // handle non-full last block if array is not multiple of 1024 numElements
        if(!fullBlocks && (((i + 1) << 1) > numElements))
        {
            uint *keys1   = (uint*)keys;
            uint j = i << 1;

            sKeys1[threadIdx.x << 1]   = (j < numElements) ? keys1[j]   : UINT_MAX;
            j++;
            sKeys1[(threadIdx.x << 1) + 1]   = (j < numElements) ? keys1[j]   : UINT_MAX;
        }
        else
        {
            sKeys2[threadIdx.x]   = keys[i];
        }

        if (!manualCoalesce)
        {
            if(threadIdx.x < 16)
            {
                sOffsets[threadIdx.x]      = offsets[threadIdx.x * totalBlocks + blockId];
                sBlockOffsets[threadIdx.x] = blockOffsets[blockId * 16 + threadIdx.x];
            }
            __syncthreads();

            uint radix = (getbucket(sKeys1[threadIdx.x]) >> startbit) & 0xF;
            uint globalOffset = sOffsets[radix] + threadIdx.x - sBlockOffsets[radix];

            if (fullBlocks || globalOffset < numElements)
            {
                outKeys[globalOffset]   = floatUnflip<unflip>(sKeys1[threadIdx.x]);
            }

            radix = (getbucket(sKeys1[threadIdx.x + RadixSort::CTA_SIZE]) >> startbit) & 0xF;
            globalOffset = sOffsets[radix] + threadIdx.x + RadixSort::CTA_SIZE - sBlockOffsets[radix];

            if (fullBlocks || globalOffset < numElements)
            {
                outKeys[globalOffset]   = floatUnflip<unflip>(sKeys1[threadIdx.x + RadixSort::CTA_SIZE]);
            }
        }
        else
        {
            __shared__ uint sSizes[16];

            if(threadIdx.x < 16)
            {
                sOffsets[threadIdx.x]      = offsets[threadIdx.x * totalBlocks + blockId];
                sBlockOffsets[threadIdx.x] = blockOffsets[blockId * 16 + threadIdx.x];
                sSizes[threadIdx.x]        = sizes[threadIdx.x * totalBlocks + blockId];
            }
            __syncthreads();

            // 1 half-warp is responsible for writing out all values for 1 radix.
            // Loops if there are more than 16 values to be written out.
            // All start indices are rounded down to the nearest multiple of 16, and
            // all end indices are rounded up to the nearest multiple of 16.
            // Thus it can do extra work if the start and end indices are not multiples of 16
            // This is bounded by a factor of 2 (it can do 2X more work at most).

            const uint halfWarpID     = threadIdx.x >> 4;

            const uint halfWarpOffset = threadIdx.x & 0xF;
            const uint leadingInvalid = sOffsets[halfWarpID] & 0xF;

            uint startPos = sOffsets[halfWarpID] & 0xFFFFFFF0;
            uint endPos   = (sOffsets[halfWarpID] + sSizes[halfWarpID]) + 15 -
                ((sOffsets[halfWarpID] + sSizes[halfWarpID] - 1) & 0xF);
            uint numIterations = endPos - startPos;

            uint outOffset = startPos + halfWarpOffset;
            uint inOffset  = sBlockOffsets[halfWarpID] - leadingInvalid + halfWarpOffset;

            for(uint j = 0; j < numIterations; j += 16, outOffset += 16, inOffset += 16)
            {
                if( (outOffset >= sOffsets[halfWarpID]) &&
                    (inOffset - sBlockOffsets[halfWarpID] < sSizes[halfWarpID]))
                {
                    if(blockId < totalBlocks - 1 || outOffset < numElements)
                    {
                        outKeys[outOffset] = floatUnflip<unflip>(sKeys1[inOffset]);
                    }
                }
            }
        }

        if (loop)
        {
            blockId += gridDim.x;
            __syncthreads();
        }
        else
            break;
    }
}

//----------------------------------------------------------------------------
// Perform one step of the radix sort.  Sorts by nbits key bits per step,
// starting at startbit.
//----------------------------------------------------------------------------
template<uint nbits, uint startbit, bool flip, bool unflip>
void radixSortStepKeysOnly(uint *keys,
                   uint *tempKeys,
                   uint *counters,
                   uint *countersSum,
                   uint *blockOffsets,
                   uint numElements)
{
    const uint eltsPerBlock = RadixSort::CTA_SIZE * 4;
    const uint eltsPerBlock2 = RadixSort::CTA_SIZE * 2;

    bool fullBlocks = ((numElements % eltsPerBlock) == 0);
    uint numBlocks = (fullBlocks) ?
        (numElements / eltsPerBlock) :
        (numElements / eltsPerBlock + 1);
    uint numBlocks2 = ((numElements % eltsPerBlock2) == 0) ?
        (numElements / eltsPerBlock2) :
        (numElements / eltsPerBlock2 + 1);

    bool loop = numBlocks > 65535;
    bool loop2 = numBlocks2 > 65535;
    uint blocks = loop ? 65535 : numBlocks;
    uint blocksFind = loop2 ? 65535 : numBlocks2;
    uint blocksReorder = loop2 ? 65535 : numBlocks2;

    uint threshold = fullBlocks ? persistentCTAThresholdFullBlocks[1] : persistentCTAThreshold[1];

    if (numElements >= threshold)
    {
        loop = (numElements > 262144) || (numElements >= 32768 && numElements < 65536);
        loop2 = (numElements > 262144) || (numElements >= 32768 && numElements < 65536);
        blocks = loop ? numCTAs[SORT_KERNEL_RADIX_SORT_BLOCKS] : numBlocks;
        blocksFind = loop ? numCTAs[SORT_KERNEL_FIND_RADIX_OFFSETS] : numBlocks2;
        blocksReorder = loop ? numCTAs[SORT_KERNEL_REORDER_DATA] : numBlocks2;
    }

    if (fullBlocks)
    {
        if (loop)
            radixSortBlocksKeysOnly<nbits, startbit, true, flip, true>
                <<<blocks, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)tempKeys, (uint4*)keys, numElements, numBlocks);
        else
            radixSortBlocksKeysOnly<nbits, startbit, true, flip, false>
                <<<blocks, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)tempKeys, (uint4*)keys, numElements, numBlocks);
    }
    else
    {
        if (loop)
            radixSortBlocksKeysOnly<nbits, startbit, false, flip, true>
                <<<blocks, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)tempKeys, (uint4*)keys, numElements, numBlocks);
        else
            radixSortBlocksKeysOnly<nbits, startbit, false, flip, false>
                <<<blocks, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)tempKeys, (uint4*)keys, numElements, numBlocks);

    }

    if (fullBlocks)
    {
        if (loop2)
            findRadixOffsets<startbit, true, true>
                <<<blocksFind, RadixSort::CTA_SIZE, 3 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint2*)tempKeys, counters, blockOffsets, numElements, numBlocks2);
        else
            findRadixOffsets<startbit, true, false>
                <<<blocksFind, RadixSort::CTA_SIZE, 3 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint2*)tempKeys, counters, blockOffsets, numElements, numBlocks2);
    }
    else
    {
        if (loop2)
            findRadixOffsets<startbit, false, true>
                <<<blocksFind, RadixSort::CTA_SIZE, 3 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint2*)tempKeys, counters, blockOffsets, numElements, numBlocks2);
        else
            findRadixOffsets<startbit, false, false>
                <<<blocksFind, RadixSort::CTA_SIZE, 3 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint2*)tempKeys, counters, blockOffsets, numElements, numBlocks2);

    }

	thrust::device_ptr<uint> d_input_ptr = thrust::device_pointer_cast(counters);
	thrust::device_ptr<uint> d_output_ptr = thrust::device_pointer_cast(countersSum);
	thrust::exclusive_scan(d_input_ptr, d_input_ptr+16*numBlocks2, d_output_ptr);

    //cudppScan(scanPlan, countersSum, counters, 16*numBlocks2);

    if (fullBlocks)
    {
        if (bManualCoalesce)
        {
            if (loop2)
                reorderDataKeysOnly<startbit, true, true, unflip, true>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, (uint2*)tempKeys, blockOffsets, countersSum, counters,
                     numElements, numBlocks2);
            else
                reorderDataKeysOnly<startbit, true, true, unflip, false>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, (uint2*)tempKeys, blockOffsets, countersSum, counters,
                     numElements, numBlocks2);
        }
        else
        {
            if (loop2)
                reorderDataKeysOnly<startbit, true, false, unflip, true>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, (uint2*)tempKeys, blockOffsets, countersSum, counters,
                    numElements, numBlocks2);
            else
                reorderDataKeysOnly<startbit, true, false, unflip, false>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, (uint2*)tempKeys, blockOffsets, countersSum, counters,
                    numElements, numBlocks2);
        }
    }
    else
    {
        if (bManualCoalesce)
        {
            if (loop2)
                reorderDataKeysOnly<startbit, false, true, unflip, true>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, (uint2*)tempKeys, blockOffsets, countersSum, counters,
                     numElements, numBlocks2);
            else
                reorderDataKeysOnly<startbit, false, true, unflip, false>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, (uint2*)tempKeys, blockOffsets, countersSum, counters,
                     numElements, numBlocks2);
        }
        else
        {
            if (loop2)
                reorderDataKeysOnly<startbit, false, false, unflip, true>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, (uint2*)tempKeys, blockOffsets, countersSum, counters,
                     numElements, numBlocks2);
            else
                reorderDataKeysOnly<startbit, false, false, unflip, false>
                    <<<blocksReorder, RadixSort::CTA_SIZE>>>
                    (keys, (uint2*)tempKeys, blockOffsets, countersSum, counters,
                    numElements, numBlocks2);
        }
    }

    checkCudaError("radixSortStepKeysOnly");
}

//----------------------------------------------------------------------------
// Optimization for sorts of fewer than 4 * CTA_SIZE elements
//----------------------------------------------------------------------------
template <bool flip>
void radixSortSingleBlockKeysOnly(uint *keys,
                                  uint numElements)
{
    bool fullBlocks = (numElements % (RadixSort::CTA_SIZE * 4) == 0);
    if (fullBlocks)
    {
        radixSortBlocksKeysOnly<32, 0, true, flip, false>
            <<<1, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)keys, (uint4*)keys, numElements, 1 );
    }
    else
    {
        radixSortBlocksKeysOnly<32, 0, false, flip, false>
            <<<1, RadixSort::CTA_SIZE, 4 * RadixSort::CTA_SIZE * sizeof(uint)>>>
                ((uint4*)keys, (uint4*)keys, numElements, 1 );
    }

    if (flip)
        unflipFloats<<<1, RadixSort::CTA_SIZE>>>(keys, numElements);


    checkCudaError("radixSortSingleBlock");
}

//----------------------------------------------------------------------------
// Optimization for sorts of WARP_SIZE or fewer elements
//----------------------------------------------------------------------------
template <bool flip>
__global__
void radixSortSingleWarpKeysOnly(uint *keys,
                                 uint numElements)
{
    __shared__ uint sKeys[RadixSort::WARP_SIZE];
    __shared__ uint sFlags[RadixSort::WARP_SIZE];

    sKeys[threadIdx.x]   = floatFlip<flip>(keys[threadIdx.x]);

    __SYNC // emulation only

    for(uint i = 1; i < numElements; i++)
    {
        uint key_i = sKeys[i];

        sFlags[threadIdx.x] = 0;

        if( (threadIdx.x < i) && (sKeys[threadIdx.x] > key_i) )
        {
            uint temp = sKeys[threadIdx.x];
            sFlags[threadIdx.x] = 1;
            sKeys[threadIdx.x + 1] = temp;
            sFlags[threadIdx.x + 1] = 0;
        }
        if(sFlags[threadIdx.x] == 1 )
        {
            sKeys[threadIdx.x] = key_i;
        }

        __SYNC // emulation only

    }
    keys[threadIdx.x]   = floatUnflip<flip>(sKeys[threadIdx.x]);
}

//----------------------------------------------------------------------------
// Main key-only radix sort function.  Sorts in place in the keys and values
// arrays, but uses the other device arrays as temporary storage.  All pointer
// parameters are device pointers.  Uses cudppScan() for the prefix sum of
// radix counters.
//----------------------------------------------------------------------------
extern "C"
void radixSortKeysOnly(uint *keys,
                       uint *tempKeys,
                       uint *counters,
                       uint *countersSum,
                       uint *blockOffsets,
                       uint numElements,
                       uint keyBits,
                       bool flipBits = false)
{
    if(numElements <= RadixSort::WARP_SIZE)
    {
        if (flipBits)
            radixSortSingleWarpKeysOnly<true><<<1, numElements>>>(keys, numElements);
        else
            radixSortSingleWarpKeysOnly<false><<<1, numElements>>>(keys, numElements);
        checkCudaError("radixSortSingleWarp");
        return;
    }
    if(numElements <= RadixSort::CTA_SIZE * 4)
    {
        if (flipBits)
            radixSortSingleBlockKeysOnly<true>(keys, numElements);
        else
	{
            radixSortSingleBlockKeysOnly<false>(keys, numElements);
	}
        return;
    }

    // flip float bits on the first pass, unflip on the last pass
    if (flipBits)
    {
            radixSortStepKeysOnly<4,  0, true, false>(keys, tempKeys,
                                                      counters, countersSum, blockOffsets, numElements);
    }
    else
    {
            radixSortStepKeysOnly<4,  0, false, false>(keys, tempKeys,
                                                       counters, countersSum, blockOffsets, numElements);
    }

    if (keyBits > 4)
    {
            radixSortStepKeysOnly<4,  4, false, false>(keys, tempKeys,
                                                       counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 8)
    {
            radixSortStepKeysOnly<4,  8, false, false>(keys, tempKeys,
                                                       counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 12)
    {
            radixSortStepKeysOnly<4, 12, false, false>(keys, tempKeys,
                                                       counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 16)
    {
            radixSortStepKeysOnly<4, 16, false, false>(keys, tempKeys,
                                                       counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 20)
    {
            radixSortStepKeysOnly<4, 20, false, false>(keys, tempKeys,
                                                       counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 24)
    {
            radixSortStepKeysOnly<4, 24, false, false>(keys, tempKeys,
                                                       counters, countersSum, blockOffsets, numElements);
    }
    if (keyBits > 28)
    {
        if (flipBits) // last pass
        {
            radixSortStepKeysOnly<4, 28, false, true>(keys, tempKeys,
                                                      counters, countersSum, blockOffsets, numElements);
        }
        else
        {
            radixSortStepKeysOnly<4, 28, false, false>(keys, tempKeys,
                                                       counters, countersSum, blockOffsets, numElements);
        }
    }

    checkCudaError("radixSortKeysOnly");
}

//----------------------------------------------------------------------------
// Main float key-only radix sort function.  Sorts in place in the keys and values
// arrays, but uses the other device arrays as temporary storage.  All pointer
// parameters are device pointers.  Uses cudppScan() for the prefix sum of
// radix counters.
//----------------------------------------------------------------------------
extern "C"
void radixSortFloatKeysOnly(float *keys,
                            float *tempKeys,
                            uint  *counters,
                            uint  *countersSum,
                            uint  *blockOffsets,
                            uint  numElements,
                            uint  keyBits,
                            bool  negativeKeys)
{
    radixSortKeysOnly((uint*)keys, (uint*)tempKeys, counters, countersSum, blockOffsets,
                       numElements, keyBits, negativeKeys);
    checkCudaError("radixSortFloatKeys");
}


extern "C"
void radixSortIntKeysOnly(uint *keys,
                            uint *tempKeys,
                            uint  *counters,
                            uint  *countersSum,
                            uint  *blockOffsets,
                            uint  numElements,
                            uint  keyBits,
                            bool  negativeKeys)
{
    radixSortKeysOnly(keys, tempKeys, counters, countersSum, blockOffsets,
                       numElements, keyBits, negativeKeys);
    checkCudaError("radixSortFloatKeys");
}


__global__ void bucketTest(uint *d_data, uint *d_result, uint size)
{
	int tid = TID;
	if(tid >= size)
		return;

	d_result[tid] = getbucket(d_data[tid]);
	//d_data[tid]
}

