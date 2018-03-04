/*
 *
 * GPU based segment key-value sorter. 
 * This sorter is based on one implementation of radix sort(www.moderngpu.com)
 *
 *     hupmscy@HKUST, Apr 2nd, 2013
 *
 */

#include "sufsort_kernel.h"

typedef unsigned int uint;
typedef unsigned short uint16;
#define NUM_BITS 5
#define NUM_BUCKETS (1<< NUM_BITS)
#define NUM_COUNTERS (1<< NUM_BITS)

#define NUM_COUNTERS_MGPU ((NUM_BUCKETS + 3) / 4)
#define NUM_CHANNELS ((NUM_BUCKETS + 1) / 2)
#define PACKED_SPACING ((1 == NUM_BITS) ? 16 : 8)

// Only reserve as much shared memory as required - NUM_COUNTERS ints per
// thread. For 6 == NUM_BITS, this is 16 ints per thread, for 16384 bytes for a
// 256 thread group, allowing 50% occupancy. All smaller keys give 83% 
// occupancy, as they are register limited.

#define NUM_THREADS 256
#define NUM_BLOCK 64
#define WARP_SIZE 32
#define NUM_WARPS (NUM_THREADS/WARP_SIZE)
#define LOG_WARP_SIZE 5
#define LOG_NUM_WARPS 3
#define NUM_PER_THREAD 16
#define SHARED_WARP_MEM (WARP_SIZE * NUM_COUNTERS_MGPU)
#define GATHER_SUM_MODE 1

#define INNER_LOOP 16

#define DEVICE __device__ __forceinline__

// To sorted_global, write the first key encountered and the last key 
// encountered in the count block if all all values in the count block are 
// sorted. If the values aren't all sorted, don't spend the transaction writing
// to the array.

// NOTE: for 6 == NUM_BITS, high shared memory usage allows only 33% occupancy,
// when using DETECT_SORTED. It may be possible to instead run the inner loop,
// then back up two rows of accumulate, and test for sortedness.
// More work may be required.


// Have each warp process a histogram for one block. If the block has
// NUM_VALUES, each thread process NUM_VALUES / WARP_SIZE. Eg if NUM_VALUES is
// 2048, each thread process 64 values. This operation is safe for NUM_VALUES up
// to 4096.


// retrieve numBits bits from x starting at bit
DEVICE uint bfe(uint x, uint bit, uint numBits) {
	uint ret;
	asm("bfe.u32 %0, %1, %2, %3;" : "=r"(ret) : "r"(x), "r"(bit), "r"(numBits));
	return ret;
}


// Same syntax as __byte_perm, but without nvcc's __byte_perm bug that masks all
// non-immediate index arguments by 0x7777.
DEVICE uint prmt(uint a, uint b, uint index) {
	uint ret;
	asm("prmt.b32 %0, %1, %2, %3;" : "=r"(ret) : "r"(a), "r"(b), "r"(index));
	return ret;
}

DEVICE void _swap(volatile uint *& a,volatile uint *& b)
{
	volatile uint *tmp = a;
	a = b;
	b = tmp;
}


DEVICE uint shl_add(uint a, uint b, uint c) {
#ifdef USE_VIDEO_INSTRUCTIONS
	uint ret;
	asm("vshl.u32.u32.u32.clamp.add %0, %1, %2, %3;" :
		"=r"(ret) : "r"(a), "r"(b), "r"(c));
	return ret;
#else
	return (a<< b) + c;
#endif
}

// insert the first numBits of y into x starting at bit
DEVICE uint bfi(uint x, uint y, uint bit, uint numBits) {
	uint ret;
	asm("bfi.b32 %0, %1, %2, %3, %4;" : 
		"=r"(ret) : "r"(y), "r"(x), "r"(bit), "r"(numBits));
	return ret;
}

template<int ColHeight>
DEVICE void GatherSums(uint lane, int mode, volatile uint* data) {

	uint targetTemp[ColHeight];

	uint sourceLane = lane / 2;
	uint halfHeight = ColHeight / 2;
	uint odd = 1 & lane;

	// Swap the two column pointers to resolve bank conflicts. Even columns read
	// from the left source first, and odd columns read from the right source 
	// first. All these support terms need only be computed once per lane. The 
	// compiler should eliminate all the redundant expressions.
	volatile uint* source1 = data + sourceLane;
	volatile uint* source2 = source1 + WARP_SIZE / 2;
	volatile uint* sourceA = odd ? source2 : source1;
	volatile uint* sourceB = odd ? source1 : source2;

	// Adjust for row. This construction should let the compiler calculate
	// sourceA and sourceB just once, then add odd * colHeight for each 
	// GatherSums call.
	uint sourceOffset = odd * (WARP_SIZE * halfHeight);
	sourceA += sourceOffset;
	sourceB += sourceOffset;
	volatile uint* dest = data + lane;
	
	#pragma unroll
	for(int i = 0; i < halfHeight; ++i) {
		uint a = sourceA[i * WARP_SIZE];
		uint b = sourceB[i * WARP_SIZE];

		if(0 == mode)
			targetTemp[i] = a + b;
		else if(1 == mode) {
			uint x = a + b;
			uint x1 = prmt(x, 0, 0x4140);
			uint x2 = prmt(x, 0, 0x4342);
			targetTemp[2 * i] = x1;
			targetTemp[2 * i + 1] = x2;
		} else if(2 == mode) {
			uint a1 = prmt(a, 0, 0x4140);
			uint a2 = prmt(a, 0, 0x4342);
			uint b1 = prmt(b, 0, 0x4140);
			uint b2 = prmt(b, 0, 0x4342);
			uint x1 = a1 + b1;
			uint x2 = a2 + b2;
			targetTemp[2 * i] = x1;
			targetTemp[2 * i + 1] = x2;
		}
	}

	#pragma unroll
	for(int i = 0; i < ColHeight / 2; ++i)
		dest[i * WARP_SIZE] = targetTemp[i];

	if(mode > 0) {
		#pragma unroll
		for(int i = 0; i < ColHeight / 2; ++i)
			dest[(i + halfHeight) * WARP_SIZE] = targetTemp[i + halfHeight];
	}
}


DEVICE void IncBucketCounter(uint bucket, volatile uint* counters, 
	uint& counter0, uint& counter1, uint numBits) {

	// For 4-, 5-, and 6-bit keys, use 8-bit counters in indexable shared
	// memory. This requires a read-modify-write to update the previous
	// count.

	// We can find the array index by dividing bucket by 4 (the number of
	// counters packed into each uint) and multiplying by 32 (the stride
	// between consecutive counters for the thread).
	// uint index = 32 * (bucket / 4);
	// It's likely more efficient to use a mask rather than a shift (the
	// NVIDIA docs claim shift is 2-cycles, but it is likely just one for
	// constant shift, so use a mask to be safe).

	uint index = (32 / 4) * (~3 & bucket);
	uint counter = counters[index];
	counter = shl_add(1, bfi(0, bucket, 3, 2), counter);
	counters[index] = counter;
}

/**
 * this kernel uses more than 16 Kb shared memory, make sure cache configuration 
 * is correct
 *
 */
 __global__ 
void single_block_radixsort(uint* keys_global, uint* values_global, Partition *par, uint num_interval, uint bit, uint num_par) {
	
	uint tid = threadIdx.x;
	uint lane = (WARP_SIZE - 1) & tid;
	uint warp = tid / WARP_SIZE;
	uint block = blockIdx.x;
	uint interval_start = block * num_interval;
	uint interval_end = interval_start + num_interval;
	
	if (interval_end > num_par)interval_end = num_par;

	volatile __shared__ uint16 counts_shared[NUM_BUCKETS*NUM_THREADS];
	volatile __shared__ uint shared1[NUM_ELEMENT_SB];
	volatile __shared__ uint shared2[NUM_ELEMENT_SB];
	const int ScanStride = WARP_SIZE + WARP_SIZE / 2 + 1;
//	const int ScanSize = NUM_WARPS * ScanStride;
	
	volatile uint16* warpCounters = counts_shared + warp * WARP_SIZE;
	volatile uint16* counters = warpCounters + lane;
	volatile uint* prefix1 = shared1;
	volatile uint* prefix2 = shared1 + NUM_THREADS + NUM_THREADS/2+1;
	volatile uint* s = shared1 + 3*NUM_THREADS + 3 +  ScanStride * warp + lane + WARP_SIZE/2;
	volatile uint* prefix_ptr1 = prefix1 + NUM_THREADS/2;
	volatile uint* prefix_ptr2 = prefix2 + NUM_THREADS/2;

	for (uint p = interval_start; p < interval_end; p++)
	{	
		
		uint start = par[p].start;
		uint end = par[p].end;
		uint valPerThread = NUM_PER_THREAD;
		uint threadStart = start + tid * valPerThread;
		uint* key_start = keys_global + start;
		uint* value_start = values_global + start;
	
		// clear all the counters
		#pragma unroll
		for(int i = 0; i < NUM_COUNTERS; ++i)
			counters[NUM_THREADS * i] = 0;
			
		if (tid < NUM_THREADS/2)
		{
			prefix1[tid] = 0;
			prefix2[tid] = 0;
		}
		s[-16] = 0;

		if (threadStart < end)
		{
			if (threadStart + valPerThread > end)
				valPerThread = end - threadStart;

			uint *threadKeyData = keys_global + threadStart;
			for (int j = 0; j < valPerThread; ++j)
			{	
				uint key_data = threadKeyData[j];
				uint bucket = bfe(key_data, bit, NUM_BITS);
				counters[bucket * NUM_THREADS]++;
			}
				
		}
		__syncthreads();
		
		//prefix sum
		for (uint index = tid; index < NUM_BUCKETS*NUM_THREADS; index += NUM_THREADS)
		{
			s[0] = counts_shared[index];
			uint sum = s[0];
			#pragma unroll 
			for (uint i = 0; i < LOG_WARP_SIZE; i++)
			{
				int offset = 1 << i;
				sum += s[-offset];
				s[0] = sum;
			}
			counts_shared[index] = s[0];
		}
		
		__syncthreads();
				
		prefix_ptr1[tid] = counts_shared[(tid+1)*WARP_SIZE-1];

		__syncthreads();

		//inclusive scan
		#pragma unroll
		for (uint i = 0; i < 8; i++)
		{
			uint offset = 1 << i;
			prefix_ptr2[tid] = prefix_ptr1[tid] + prefix_ptr1[tid-offset];
			__syncthreads();
			_swap(prefix_ptr1, prefix_ptr2);
		}

		#pragma unroll
		for (uint i = 0; i < NUM_BUCKETS; i++)
		{
			uint offset = prefix_ptr1[i + warp*WARP_SIZE-1];
			counts_shared[lane + i*WARP_SIZE + warp*1024] += offset;
		}
		__syncthreads();

		//scatter
		//
		// there's an alternative here, store bucket or compute bucket
		if (threadStart < end)
		{	
			uint *threadKeyData = keys_global + threadStart;
			uint *threadValueData = values_global + threadStart;
			#pragma unroll
			for (int i = valPerThread-1; i >=0; i--)
			{
				uint key_data = threadKeyData[i];
				uint value_data = threadValueData[i];
				uint bucket = bfe(key_data, bit, NUM_BITS);
				uint index = --counters[bucket*NUM_THREADS];
				shared1[index] = key_data;
				shared2[index] = value_data;
			}
		}
		__syncthreads();

		#pragma unroll
		for (uint index = tid; index < end-start; index += NUM_THREADS)
		{
			key_start[index] = shared1[index];
			value_start[index] = shared2[index];
		}
		__syncthreads();
		
	}
}

 __global__ 
void multiblock_radixsort_pass1(uint* keys_global, uint* counts_global, Partition *par, uint num_interval, uint bit, uint num_par) {
	
	uint tid = threadIdx.x;
	uint lane = (WARP_SIZE - 1) & tid;
	uint warp = tid / WARP_SIZE;
	uint block = blockIdx.x;
	
	uint interval_start = block * num_interval;
	uint interval_end = interval_start + num_interval;
	
	if (interval_end > num_par)interval_end = num_par;

	volatile __shared__ uint counts_shared[NUM_COUNTERS_MGPU*WARP_SIZE*NUM_WARPS];

	volatile uint* warpCounters = counts_shared + warp * SHARED_WARP_MEM;

	volatile uint* counters = warpCounters + lane;
	
	for (uint p = interval_start; p < interval_end; ++p)
	{
		uint start = par[p].start;
		uint end = par[p].end;
		uint *write_pos = counts_global + par[p].dig_pos;
		uint threadStart = warp*WARP_SIZE + lane + start;
		const uint* threadData = keys_global + threadStart;
		uint valPerThread = ((end-threadStart)>>8) + ((end-threadStart)&NUM_THREADS?1:0);
		
		// Define the counters so we can pass them to IncBucketCounter. They don't
		// actually get used unless NUM_BITS <= 3 however.
		uint counter0 = 0;
		uint counter1 = 0;
		// clear all the counters
		#pragma unroll
		for(int i = 0; i < NUM_COUNTERS_MGPU; ++i)
			counters[WARP_SIZE * i] = 0;

		uint keys[INNER_LOOP];
		
		#pragma unroll
		for(int j = 0; j < valPerThread; ++j) 
			keys[j] = threadData[j * NUM_THREADS];

		#pragma unroll
		for(int j = 0; j < valPerThread; ++j) {
			uint bucket = bfe(keys[j], bit, NUM_BITS);
			IncBucketCounter(bucket, counters, counter0, counter1, 
				NUM_BITS);
		}	
		
		GatherSums<NUM_COUNTERS_MGPU>(lane, GATHER_SUM_MODE, warpCounters);
		GatherSums<NUM_COUNTERS_MGPU>(lane, 0, warpCounters);
		GatherSums<NUM_COUNTERS_MGPU / 2>(lane, 0, warpCounters);
		GatherSums<NUM_COUNTERS_MGPU / 4>(lane, 0, warpCounters);

		// There are probably still multiple copies of each sum. Perform a parallel
		// scan to add them all up.
		volatile uint* reduction = warpCounters + lane;
		reduction[WARP_SIZE] = 0;
		uint x = reduction[0];
		uint offset = NUM_CHANNELS;
		uint y = reduction[offset];
		x += y;
		reduction[0] = x;
		
		__syncthreads();
		//write to global memory
		if (tid < NUM_CHANNELS)
		{
			uint sum = 0;
			volatile uint *ptr = counts_shared + tid;
			for (uint i = 0; i < 8; i++)
				sum += ptr[i*SHARED_WARP_MEM];
			write_pos[tid] = sum;
		}
		__syncthreads();
	}
}

void __global__ multiblock_radixsort_pass2(uint *counts_global, uint *d_block_len, uint num_interval, uint size)
{
	uint tid = threadIdx.x;
	uint lane = (WARP_SIZE - 1) & tid;
	uint warp = tid / WARP_SIZE;
	uint block = blockIdx.x;
	uint warp_start = (NUM_WARPS*block+warp) * num_interval;
	uint warp_end = warp_start + num_interval;
	uint scan_stride = WARP_SIZE + WARP_SIZE/2 + 1;
	uint data_offset = scan_stride*warp + WARP_SIZE/2+1;
	volatile __shared__ uint shared[NUM_THREADS+NUM_THREADS/2 + 32];
	volatile uint* s = shared + data_offset + lane;

	s[-16] = 0;
	
	if (warp_end > size)warp_end = size;

	for (uint p = warp_start; p < warp_end; p++)
	{
		uint block_len = d_block_len[p];
		uint num_element = block_len/NUM_ELEMENT_SB + (block_len%NUM_ELEMENT_SB?1:0);
		uint log_value = (uint)(__log2f(num_element));
		if ((1<<log_value) < num_element)
			log_value++;
		uint *counts_start = counts_global + p*32*NUM_CHANNELS;	
		//unroll later 
		for (uint value = 0; value < NUM_CHANNELS; value++)
		{
			uint *count_value_start = counts_start + value;
			
			if (lane < num_element)
				 s[0] =  count_value_start[lane*NUM_CHANNELS];

			uint sum = s[0];
			
			#pragma unroll	
			for (uint i = 0; i < log_value; i++)
			{
				int offset = 1 << i;
				sum += s[-offset];
				s[0] = sum;	
			}
			
			if (lane < num_element)
				count_value_start[lane*NUM_CHANNELS] = s[0];
		}
		if (lane < NUM_CHANNELS)
		{
			shared[data_offset + lane*2] = counts_start[(num_element-1)*NUM_CHANNELS+lane] &0xffff;	
			shared[data_offset + lane*2+1] = counts_start[(num_element-1)*NUM_CHANNELS+lane] >> 16;	
		}

		uint sum = s[0];
		
		#pragma unroll
		for (uint i = 0; i < LOG_WARP_SIZE; i++)
		{
			int offset = 1 << i;
			sum += s[-offset];
			s[0] = sum;
		}

		if (lane < NUM_CHANNELS)
		{
			#pragma unroll
			for (uint i = 0; i < num_element; i++)
			{
				uint *count_value_start = counts_start + i*NUM_CHANNELS;
				count_value_start[lane] += (shared[data_offset + lane*2-1] | (shared[data_offset + lane*2]<<16));
			}
		}
	}
}

/*

__global__
void multiblock_radixsort_pass3(uint *counts_global, uint *keys_global, uint *values_global, uint *d_block_start, 
				uint *d_block_len, uint *d_tmp_store, uint bit, uint block_count)
{
	uint tid = threadIdx.x;
	uint lane = (WARP_SIZE - 1) & tid;
	uint warp = tid / WARP_SIZE;
	uint block = blockIdx.x;
	volatile __shared__ uint counts_shared[NUM_BUCKETS*NUM_THREADS];
	volatile __shared__ uint shared1[NUM_ELEMENT_SB];
	volatile __shared__ uint shared2[NUM_ELEMENT_SB];
	const int ScanStride = WARP_SIZE + WARP_SIZE / 2 + 1;
	const int ScanStride1 = NUM_WARPS + NUM_WARPS / 2 + 1;
	
	volatile uint* warpCounters = counts_shared + warp * WARP_SIZE;
	volatile uint* counters = warpCounters + lane;
	volatile uint* s = shared2 + ScanStride*warp + lane + WARP_SIZE/2;
	volatile uint* s2 = shared1 + ScanStride1*(tid/8) + tid%8 + NUM_WARPS/2;
	volatile uint* global_counters = shared1 + 512;
	uint keys[INNER_LOOP];
	uint values[INNER_LOOP];
	uint *key_scatter_start = d_tmp_store + 2*block*MAX_SEG_NUM;
	uint *value_scatter_start = d_tmp_store + (2*block+1)*MAX_SEG_NUM;
	
	//there're two options: adjacent or stride. Firstly I choose stride manner
	for (uint p = block; p < block_count; p += NUM_BLOCK)
	{	
		uint block_len = d_block_len[p];
		uint block_start = d_block_start[p];
		uint num_element = block_len/NUM_ELEMENT_SB + (block_len%NUM_ELEMENT_SB?1:0);

		for (int l = 0; l < num_element; l++)
		{
			uint start = block_start + l*NUM_ELEMENT_SB;
			uint end = start + NUM_ELEMENT_SB;
			uint *dig_pos = counts_global + (p*32+l)*NUM_CHANNELS;
			uint valPerThread = NUM_PER_THREAD;
			uint threadStart = start + tid*valPerThread;
	
			// clear all the counters
			#pragma unroll
			for(int i = 0; i < NUM_COUNTERS; ++i)
				counters[NUM_THREADS * i] = 0;
			
			s[-16] = 0;
			s2[-4] = 0;
		
			__syncthreads();

			if (threadStart < end)
			{
				if (threadStart + valPerThread > end)
					valPerThread = end - threadStart;

				uint *threadKeyData = keys_global + threadStart;
				uint *threadValueData = values_global + threadStart;
				for (int j = 0; j < valPerThread; ++j)
				{	
					keys[j] = threadKeyData[j];
					uint bucket = bfe(keys[j], bit, NUM_BITS);
					counters[bucket * NUM_THREADS]++;
					values[j] = threadValueData[j];
				}
			}
			__syncthreads();
		
			//prefix sum
			for (uint index = tid; index < NUM_BUCKETS*NUM_THREADS; index += NUM_THREADS)
			{
				s[0] = counts_shared[index];
				uint sum = s[0];
				#pragma unroll 
				for (uint i = 0; i < LOG_WARP_SIZE; i++)
				{
					int offset = 1 << i;
					sum += s[-offset];
					s[0] = sum;
				}
				counts_shared[index] = s[0];
			}
		
			__syncthreads();
			
			//8-element inclusive scan
			uint sum = s2[0] = counts_shared[(tid+1)*WARP_SIZE-1];
			#pragma unroll
			for (uint i = 0; i < LOG_NUM_WARPS; i++)
			{
				uint offset = 1 << i;
				sum += s2[-offset];
				s2[0] = sum;
			}
			
			//load global scatter offset
			if (tid < NUM_CHANNELS)
			{
				global_counters[2*tid] = dig_pos[tid]&0xffff;
				global_counters[2*tid+1] = dig_pos[tid]>>16;
			}

			__syncthreads();

			#pragma unroll
			for (uint i = 0; i < NUM_BUCKETS; i++)
			{
				uint bucket = warp*4 + i/8;
				uint global_offset = global_counters[bucket] - shared1[ScanStride1*bucket + NUM_WARPS-1 + NUM_WARPS/2];
				uint offset = shared1[ScanStride1*bucket + (i%8) -1 + NUM_WARPS/2];
				counts_shared[lane + i*WARP_SIZE + warp*1024] += (global_offset+offset);
			}

			__syncthreads();

			//scatter to temporary global memory
			//
			// there's an alternative here, store bucket or compute bucket
			
			if (threadStart < end)
			{	
				#pragma unroll
				for (int i = valPerThread-1; i >= 0; i--)
				{
					uint bucket = bfe(keys[i], bit, NUM_BITS);
					uint index = --counters[bucket*NUM_THREADS];
					key_scatter_start[index] = keys[i];
					value_scatter_start[index] = values[i];
				}
			}
		}
		
		__syncthreads();
		//copy segment data from temporary storage to destination
		uint *key_global_start = keys_global + block_start;
		uint *value_global_start = values_global + block_start;
		for (uint i = tid; i < block_len; i += NUM_THREADS)
		{
			key_global_start[i] = key_scatter_start[i];
			value_global_start[i] = value_scatter_start[i];
		}
		__syncthreads();
	}
}
*/

#undef NUM_BITS
#undef NUM_BUCKETS
#undef COUNT_FUNC
#undef SHARED_WARP_MEM
#undef COUNT_SHARED_MEM
#undef PACKED_SPACING
#undef INNER_LOOP
