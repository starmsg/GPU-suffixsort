#include "sufsort_kernel.h"
#include "../Timer.h"
#include "globalscan.cu"
/*
 * thrust header
 */
#include <thrust/scan.h>
#include <thrust/device_ptr.h>
#include <thrust/sort.h>
#include <thrust/scatter.h>
#include <thrust/gather.h>

/**
 * GPU sort header
 *
 */
//#include <b40c/util/error_utils.cuh>
//#include <b40c/util/multiple_buffering.cuh>
//#include <b40c/radix_sort/enactor.cuh>
//#include <b40c_test_util.h>

/*
__global__ void bitonic_sort_kernel(uint32 *d_len, uint32 *d_value, uint32 *d_sa, uint32 *d_isa, uint32 size)
{
	uint32 interval_start = blockIdx.x*num_interval;
	uint32 interval_end = interval_start=num_interval;

	if (interval_end > size)interval_end = size;

	__shared__ volatile uint32 shared_key[];
	__shared__ volatile uint32 shared_value[];
	
	#pragma unroll
	for (uint32 i = interval_start; i < interval_end; i++)
	{
		uint32 len = d_len[i];
		uint32 
	}
}
*/

__global__ void scatter_small_group_kernel(uint32 *d_block_len, uint32 *d_block_start, uint32 *d_sa,
	 uint32 *d_isa, uint32 num_interval, uint32 size)
{
	uint32 interval_start = blockIdx.x * num_interval;
	uint32 interval_end = interval_start + num_interval;
	uint32 tid = threadIdx.x + interval_start;

	if (interval_end > size)interval_end = size;
	
	uint32 start, end, i, j;
	
	#pragma unroll
	for (i = tid; i < interval_end; i += THREADS_PER_BLOCK)
	{
		start = d_block_start[i];
		end = d_block_len[i]+start;
		for (j = start; j < end; j++)
			d_isa[d_sa[j]] = j+1;
	}
}

__global__ void scatter_large_group_kernel(uint32 *d_block_len, uint32 *d_block_start, uint32 *d_sa, 
	uint32 *d_isa, uint32 num_interval, uint32 size)
{
	uint32 interval_start = blockIdx.x * num_interval;
	uint32 interval_end = interval_start + num_interval;
	uint32 tid = threadIdx.x + interval_start;

	if (interval_end > size)interval_end = size;

	uint32 start, end, i, j, value;

	#pragma unroll
	for (i = tid; i < interval_end; i += THREADS_PER_BLOCK)
	{
		value = start = d_block_start[i];
		end = d_block_len[i]+start;
		value++;
		for (j = start; j < end; j++)
			d_isa[d_sa[j]] = value;
	}
}

__global__ void update_block_kernel1(uint32 *ps_array, uint32 *d_value, 
	Partition *d_par, uint32 num_interval, uint32 par_count)
{	
	uint32 interval_start = blockIdx.x*num_interval;
	uint32 interval_end = interval_start + num_interval;
	uint32 tid = threadIdx.x;
	
	__shared__ volatile uint32 shared[NUM_ELEMENT_SB+32];
	
	if (interval_end > par_count)interval_end = par_count;
	
	#pragma unroll
	for (uint i = interval_start; i < interval_end; i++)
	{
		uint32 start = d_par[i].start;
		uint32 end = d_par[i].end;
		uint32 bid = d_par[i].bid;

		#pragma unroll
		for (uint32 index = start + tid; index < end; index += THREADS_PER_BLOCK)
			shared[index-start] = ps_array[index];
	
		__syncthreads();	

		if (tid == 0)
		{	
			
			//	the last element of previous interval
			if (bid || ps_array[d_par[i-1].end-1] != shared[0])
				d_value[shared[0]] = start;
			
			#pragma unroll
			for (uint32 index = start + THREADS_PER_BLOCK; index < end; index += THREADS_PER_BLOCK)
			{
				uint32 index1 = index - start;
			//	if (shared[index1] != shared[index1-1])
				if (ps_array[index] != ps_array[index-1])
					d_value[shared[index1]] = index;
			}
			
		}
		else
		{
						
			#pragma unroll
			for (uint32 index = start + tid; index < end; index += THREADS_PER_BLOCK)
			{
				uint32 index1 = index - start;
				if (shared[index1] != shared[index1-1])
					d_value[shared[index1]] = index;
			}
		}
	}
}
/*
__global__ void update_block_kernel2(uint32 *d_keys, uint32 *d_values, uint32 size)
{
	uint32 start = (blockIdx.x*blockDim.x)<<2;
	uint32 tid = start + threadIdx.x;
	uint32 bound = (blockIdx.x+1)*(blockDim.x<<2);
	if (bound > size)
		bound = size+1;

	__shared__ volatile uint32 shared[NUM_ELEMENT_SB];
	
	#pragma unroll
	for (uint32 index = tid; index < bound; index += THREADS_PER_BLOCK)
		shared[index-start] = d_values[index];
	

	if (threadIdx.x == THREADS_PER_BLOCK-1)
		shared[bound-start] = d_values[bound];
	__syncthreads();

	#pragma unroll
	for (uint32 index = tid; index < bound; index += THREADS_PER_BLOCK)
	{	
		if (shared[index+1-start] < shared[index-start])
			printf("error: %u %u\n", shared[index+1-start], shared[index-start]);
		d_keys[index] = shared[index+1-start] - shared[index-start];
	}
}
*/

__global__ void update_block_kernel2(uint32 *d_keys, uint32 *d_values, uint32 size)
{
	uint32 start = (blockIdx.x*blockDim.x)<<2;
	uint32 tid = start + threadIdx.x;
	uint32 bound = (blockIdx.x+1)*(blockDim.x<<2);
	if (bound > size)
		bound = size+1;

	__shared__ volatile uint32 shared[NUM_ELEMENT_SB+32];
	
	#pragma unroll
	for (uint32 index = tid; index < bound; index += THREADS_PER_BLOCK)
		shared[index-start] = d_values[index];
	

	if (threadIdx.x == THREADS_PER_BLOCK-1)
		shared[bound-start] = d_values[bound];
	__syncthreads();

	#pragma unroll
	for (uint32 index = tid; index < bound; index += THREADS_PER_BLOCK)
	{	
		if (shared[index+1-start] < shared[index-start])
			printf("error: %u %u (%u %u), index: %u\n", shared[index+1-start], shared[index-start], d_values[index+1], d_values[index], index);
		d_keys[index] = shared[index+1-start] - shared[index-start];
	}
}

__global__ void find_boundary_kernel(uint32 *d_len, uint32 size)
{
	uint32 start = (blockIdx.x*blockDim.x) << 2;
	uint32 tid = start + threadIdx.x;
	uint32 bound = (blockIdx.x+1)*(blockDim.x<<2);
	
	if (blockIdx.x == 0 && threadIdx.x == 0)
		d_len[size+1] = 0;

	if (bound >= size)
		bound = size-1;

	__shared__ volatile uint32 shared[NUM_ELEMENT_SB + 32];

	for (uint32 index = tid; index < bound; index += THREADS_PER_BLOCK)
		shared[index-start] = d_len[index];

	if (threadIdx.x == THREADS_PER_BLOCK-1)
		shared[bound-start] = d_len[bound];

	__syncthreads();
	
	for (uint32 index = tid-start; index < bound-start; index += THREADS_PER_BLOCK)
	{	
		if (shared[index] <= MIN_UNSORTED_GROUP_SIZE && shared[index+1] > MIN_UNSORTED_GROUP_SIZE)
				d_len[size+1] = index+start+1;
		else if (shared[index] == 1 && shared[index+1] > 1)
				d_len[size+2] = index+start+1;
		else if (shared[index] <= MAX_SEG_NUM && shared[index+1] > MAX_SEG_NUM)
				d_len[size+3] = index+start+1;
	}	
}

__global__ void scatter_kernel(uint32 *d_L, uint32 *d_R_in, uint32 *d_R_out, Partition *d_par)
{
	/*
	 * use shift instead of multiplication(times 4)
	 */
	uint32 start = d_par[blockIdx.x].start;
	uint32 end = d_par[blockIdx.x].end;
	uint32 tid = start + (threadIdx.x<<2);
	
	if (tid >= end-start)
		return;
	
	extern __shared__ uint4 shared_memory[];

	uint4 *R_in = shared_memory;
	uint4 *L = shared_memory + THREADS_PER_BLOCK;

	R_in[threadIdx.x] = *((uint4*)(d_R_in+tid));
	L[threadIdx.x] = *((uint4*)(d_L+tid));

	d_R_out[L[threadIdx.x].x] = R_in[threadIdx.x].x;
	d_R_out[L[threadIdx.x].y] = R_in[threadIdx.x].y;
	d_R_out[L[threadIdx.x].z] = R_in[threadIdx.x].z;
	d_R_out[L[threadIdx.x].w] = R_in[threadIdx.x].w;
}

__global__ void generate_bucket_with_shift(uint32 *d_sa, uint32 *d_ref, uint32 *d_isa, uint32 string_size)
{
	uint32 tid = (blockIdx.x*blockDim.x + threadIdx.x);
	uint32 tid4 = tid*4;
	uint32 cur_block, next_block;
	
	//boundary check 
	if (tid4 >= string_size)
		return;
	
	extern __shared__ uint32 segment_ref[];
	
	d_sa[tid4] = tid4;
	d_sa[tid4+1] = tid4+1;
	d_sa[tid4+2] = tid4+2;
	d_sa[tid4+3] = tid4+3;
	
	cur_block = d_ref[tid];

	//change from little-endian to big-endian
	cur_block = ((cur_block<<24)|((cur_block&0xff00)<<8)|((cur_block&0xff0000)>>8)|(cur_block>>24));

	segment_ref[threadIdx.x] = cur_block;

	if (threadIdx.x == THREADS_PER_BLOCK-1)
	{	
		next_block = d_ref[tid+1];
		
		//change from little-endian to big-endian
		next_block = ((next_block<<24)|((next_block&0xff00)<<8)|((next_block&0xff0000)>>8)|(next_block>>24));

		segment_ref[threadIdx.x+1] = next_block;
	}
	__syncthreads();
	
	next_block = segment_ref[threadIdx.x+1];

	/*
	 *  shift operation on little endian system
	 */
	d_isa[tid4] = cur_block;
	d_isa[tid4+1] = ((cur_block << 8) | (next_block >> 24));
	d_isa[tid4+2] = ((cur_block << 16) | (next_block >> 16));
	d_isa[tid4+3] = ((cur_block << 24) | (next_block >> 8));
}

__global__ void generate_bucket_without_shift(uint32 *d_sa, uint8 *d_ref, uint32 *d_isa, uint32 string_size)
{
	uint32 tid = (blockIdx.x*blockDim.x + threadIdx.x);
	uint32 tid4 = tid*4;
	
	//boundary check 
	if (tid4 >= string_size)
		return;
	
	d_sa[tid4] = tid4;
	d_sa[tid4+1] = tid4+1;
	d_sa[tid4+2] = tid4+2;
	d_sa[tid4+3] = tid4+3;
	
	uint8* local_d_ref = d_ref+tid4;

	d_isa[tid4] = ((uint32*)local_d_ref)[tid];
	d_isa[tid4+1] = ((uint32*)(local_d_ref+1))[tid];
	d_isa[tid4+2] = ((uint32*)(local_d_ref+2))[tid];
	d_isa[tid4+3] = ((uint32*)(local_d_ref+3))[tid];
}

__global__ void get_second_keys(uint32 *d_sa, uint32 *d_isa_in, uint32 *d_isa_out, Partition *d_par, uint32 num_interval, uint32 par_count)
{
	uint32 interval_start = blockIdx.x * num_interval;
	uint32 interval_end = interval_start + num_interval;
	uint32 tid = threadIdx.x;
	uint32 start, end;
	
	if (interval_end > par_count)interval_end = par_count;
	
	#pragma unroll
	for (uint32 i = interval_start; i < interval_end; i++)
	{
		start = d_par[i].start;
		end = d_par[i].end;
		for (uint32 index = tid+start; index < end; index += THREADS_PER_BLOCK)
			d_isa_out[index] = d_isa_in[d_sa[index]];
	}
/*
	extern __shared__ uint4 shared_memory[];

	uint4* segment_sa = shared_memory;
	uint4* out = shared_memory + THREADS_PER_BLOCK;
	uint4* d_out_ptr = (uint4*)(d_isa_out+tid);

	segment_sa[threadIdx.x] = *((uint4*)(d_sa+tid));
	
	if (segment_sa[threadIdx.x].x < h_boundary)
		out[threadIdx.x].x = d_isa_in[segment_sa[threadIdx.x].x];

	if (segment_sa[threadIdx.x].y < h_boundary)
		out[threadIdx.x].y = d_isa_in[segment_sa[threadIdx.x].y];

	if (segment_sa[threadIdx.x].z < h_boundary)
		out[threadIdx.x].z = d_isa_in[segment_sa[threadIdx.x].z];

	if (segment_sa[threadIdx.x].w < h_boundary)
		out[threadIdx.x].w = d_isa_in[segment_sa[threadIdx.x].w];

	*d_out_ptr = out[threadIdx.x];	
*/
		
}

__global__ void get_first_keys(uint32 *d_sa, uint32 *d_isa_in, uint32 *d_isa_out, uint32 size)
{
	/*
	 * use shift instead of multiplication (multiply by 4)
	 */
	uint32 tid = ((blockIdx.x*blockDim.x + threadIdx.x) << 2);

	if (tid >= size)
		return;

	extern __shared__ uint4 shared_memory[];
	
	uint4* out = shared_memory;
	uint4* segment_sa4 = shared_memory + THREADS_PER_BLOCK;
	uint4* d_isa_out_ptr = (uint4*)(d_isa_out+tid);
	
	segment_sa4[threadIdx.x] = *((uint4*)(d_sa+tid));

	
	out[threadIdx.x].x = d_isa_in[segment_sa4[threadIdx.x].x];
	out[threadIdx.x].y = d_isa_in[segment_sa4[threadIdx.x].y];
	out[threadIdx.x].z = d_isa_in[segment_sa4[threadIdx.x].z];
	out[threadIdx.x].w = d_isa_in[segment_sa4[threadIdx.x].w];

	*d_isa_out_ptr = out[threadIdx.x];
}


/**
 * TODO:There're two ways to handle memory access, try another one later
 * TODO:need to use templete to allocate register files, a bug of nvcc reported by moderngpu 
 */
__global__ void neighbour_comparison_kernel(uint32 *d_keys, uint32 *d_output, 
		Partition *d_par, uint32 num_interval, uint32 size)
{

	uint32 interval_start = blockIdx.x*num_interval;
	uint32 interval_end = interval_start + num_interval;
	uint32 tid = threadIdx.x;
	
	__shared__ volatile uint32 shared[NUM_ELEMENT_SB+32];
	
	if (interval_end > size)interval_end = size;
	
	#pragma unroll
	for (uint i = interval_start; i < interval_end; i++)
	{
		uint32 start = d_par[i].start;
		uint32 end = d_par[i].end;
		uint32 bid = d_par[i].bid;

		#pragma unroll
		for (uint32 index = start + tid; index < end; index += THREADS_PER_BLOCK)
			shared[index-start] = d_keys[index];
	
		__syncthreads();	

		if (tid == 0)
		{	
			//	the last element of previous interval
			if (bid || d_keys[d_par[i-1].end-1] != shared[0])
				d_output[start] = 1;
			else
				d_output[start] = 0;
			
			#pragma unroll
			for (uint32 index = start + THREADS_PER_BLOCK; index < end; index += THREADS_PER_BLOCK)
			{
				uint32 index1 = index - start;
			//	if (shared[index1] != shared[index1-1])
				if (d_keys[index] == d_keys[index-1])
					d_output[index] = 0;
				else
					d_output[index] = 1;
			}
		}
		else
		{
						
			#pragma unroll
			for (uint32 index = start + tid; index < end; index += THREADS_PER_BLOCK)
			{
				uint32 index1 = index - start;
				if (shared[index1] == shared[index1-1])
					d_output[index] = 0;
				else
					d_output[index] = 1;
			}
		}
	}

	if (blockIdx.x == 0 && tid == 0)
		d_output[d_par[0].start] = 0;
}

/**
 * wrapper function of thrust key-value sort utility
 *
 * sort entries according to d_keys
 *
 */
void gpu_sort(uint32 *d_keys, uint32 *d_values, uint32 size)
{
/*
	b40c::radix_sort::Enactor enactor;
	b40c::util::DoubleBuffer<uint32, uint32> sort_storage(d_keys, d_values);
	enactor.Sort(sort_storage, size);
*/
	
	thrust::device_ptr<uint32> d_key_ptr = thrust::device_pointer_cast(d_keys);
	thrust::device_ptr<uint32> d_value_ptr = thrust::device_pointer_cast(d_values);

	thrust::sort_by_key(d_key_ptr, d_key_ptr+size, d_value_ptr);

	HANDLE_ERROR(cudaDeviceSynchronize());
}

void gpu_block_sort(uint32 *d_keys, uint32 *d_values, uint32 start, uint32 len)
{
	thrust::device_ptr<uint32> d_key_ptr = thrust::device_pointer_cast(d_keys+start);
	thrust::device_ptr<uint32> d_value_ptr = thrust::device_pointer_cast(d_values+start);
	
	thrust::sort_by_key(d_key_ptr, d_key_ptr+len, d_value_ptr);
}


/**
 * the function update_block takes prefix sum result as input
 * d_wp should store the last element of each group
 */
void update_block(uint32 *d_sa, uint32 *d_isa, uint32 *d_input, uint32 *d_wp, uint32 *d_value, 
	uint32 *d_len, Partition *d_par, Partition *h_par, uint32 *h_block_start, 
	uint32 *h_block_len, uint32 par_count, uint32 &acc_unique, uint32 num_unique, 
	uint32& boundary, uint32 &sort_bound, uint32 &s_type_bound, uint32 &l_type_bound, uint32 string_size, uint32 h)
{
	dim3 blocks_per_grid(1, 1, 1);
	dim3 threads_per_block(THREADS_PER_BLOCK, 1, 1);
	uint32 last = h_par[par_count-1].end;
	uint32 num_interval = par_count/BLOCK_NUM + (par_count%BLOCK_NUM?1:0);
	uint32 bound[4];

	update_block_kernel1<<<BLOCK_NUM, threads_per_block>>>(d_input, d_value, d_par, num_interval, par_count);
	CHECK_KERNEL_ERROR("update_block_kernel1");
	
//for debug
	
	HANDLE_ERROR(cudaThreadSynchronize());
	uint32 *h_value = (uint32*)allocate_pageable_memory(sizeof(uint32) * num_unique);
	mem_device2host(d_value, h_value, sizeof(uint32) * num_unique);
//	for (uint32 i = 0; i < num_unique; i++)
//		printf("d_value[%u]: %u\n", i, h_value[i]);
	free_pageable_memory(h_value);

//----------------------------------	

	blocks_per_grid.x = num_unique/(THREADS_PER_BLOCK*NUM_ELEMENT_ST) + (num_unique%(THREADS_PER_BLOCK*NUM_ELEMENT_ST) ? 1 : 0);
	mem_host2device(&last, d_value+num_unique+1, sizeof(uint32));
	update_block_kernel2<<<blocks_per_grid, threads_per_block>>>(d_len, d_value, num_unique);		
	CHECK_KERNEL_ERROR("update_block_kernel2");
	
	gpu_sort(d_len, d_value, num_unique+1);

//for debug	
	printf("inside update_block\n");
	uint32 _par_count = num_unique+1;
	uint32 split_bound = boundary;
	uint32 *block_len = (uint32*)allocate_pageable_memory(sizeof(uint32) * (_par_count));
	uint32 *block_start = (uint32*)allocate_pageable_memory(sizeof(uint32) * (_par_count));
	mem_device2host(d_len, block_len, sizeof(uint32)*(_par_count));
	mem_device2host(d_value, block_start, sizeof(uint32)*(_par_count));
//	for (uint32 i = 0; i < _par_count; i++)
//		printf("%u: (%u, %u, %u)\n", i, block_len[i], block_start[i], block_len[i]+block_start[i]);
	free_pageable_memory(block_len);
	free_pageable_memory(block_start);
//------------------------------

	/*
	 * boundary info is stored in d_value[num_unique]
	 */
	find_boundary_kernel<<<blocks_per_grid, threads_per_block>>>(d_len, num_unique);
	CHECK_KERNEL_ERROR("find_boundary_kernel");

	mem_device2host(d_len+num_unique+1, bound, sizeof(uint32)*4);
	boundary = bound[0];
	printf("boundary: %u\n", boundary);
	
	sort_bound = bound[1];
	printf("sort boundary: %u\n", sort_bound);
	
	s_type_bound = bound[2];
	printf("S type upperbound: %u\n", s_type_bound);

	l_type_bound = bound[3];
	printf("L type upperbound: %u\n", l_type_bound);

	blocks_per_grid.x = 256;
	threads_per_block.x = 256;
	num_interval = (boundary-sort_bound)/blocks_per_grid.x + ((boundary-sort_bound)%blocks_per_grid.x?1:0);
//	bitonic_sort_kernel<<<blocks_per_grid, threads_per_block>>>(d_len+sort_bound, d_value+sort_bound, boundary);
	
	cpu_small_group_sort(d_sa, d_isa, d_len+sort_bound, d_value+sort_bound, boundary-sort_bound, string_size, h);
	check_small_group_sort(d_sa, d_isa, d_len+sort_bound, d_value+sort_bound, boundary-sort_bound, string_size, h);
		
	mem_device2host(d_value + boundary, h_block_start, sizeof(uint32)*(num_unique+1-boundary));
	mem_device2host(d_len + boundary, h_block_len, sizeof(uint32)*(num_unique+1-boundary));
	

	
	/*
	 * for testing, copy all elements to host,  
	 * 
	 */
//	mem_device2host(d_value, h_block_start, sizeof(uint32)*num_unique);
//	mem_device2host(d_len, h_block_len, sizeof(uint32)*num_unique);
}

void scatter_rank_value(uint32 *d_block_len, uint32 *d_block_start, uint32 *d_sa, uint32 *d_isa, uint32 split_bound, uint32 par_count, uint32 string_size)
{
	dim3 blocks_per_grid(BLOCK_NUM, 1, 1);
	dim3 threads_per_block(THREADS_PER_BLOCK, 1, 1);

//	check_block_complete(d_block_len, d_block_start, d_sa, par_count, string_size);

	uint32 num_interval = split_bound/blocks_per_grid.x + (split_bound%blocks_per_grid.x?1:0);
	scatter_small_group_kernel<<<blocks_per_grid, threads_per_block>>>(d_block_len, d_block_start, d_sa, d_isa, num_interval, split_bound);
	CHECK_KERNEL_ERROR("scatter_small_group_kernel");
	

	blocks_per_grid.x = BLOCK_NUM/4;
	num_interval = (par_count-split_bound)/blocks_per_grid.x + ((par_count-split_bound)%blocks_per_grid.x?1:0);

//-------------------for debug
	printf("scatter: num_interval: %u\nsplit_bound: %u\npar_count: %u\n", num_interval, split_bound, par_count);
	
	printf("--------------------------");
	uint32 *h_block_len = (uint32*)allocate_pageable_memory(sizeof(uint32) * (par_count-split_bound));
	uint32 *h_block_start = (uint32*)allocate_pageable_memory(sizeof(uint32) * (par_count-split_bound));
	mem_device2host(d_block_len+split_bound, h_block_len, sizeof(uint32)*(par_count-split_bound));
	mem_device2host(d_block_start+split_bound, h_block_start, sizeof(uint32)*(par_count-split_bound));
//	for (uint32 i = 0; i < par_count-split_bound; i++)
//		printf("%u: (%u, %u, %u)\n", i, h_block_len[i], h_block_start[i], h_block_len[i]+h_block_start[i]);
	free_pageable_memory(h_block_len);
	free_pageable_memory(h_block_start);
//-----------------------------
	
	scatter_large_group_kernel<<<blocks_per_grid, threads_per_block>>>(d_block_len+split_bound, d_block_start+split_bound, 
		d_sa, d_isa, num_interval, par_count-split_bound);
	CHECK_KERNEL_ERROR("scatter_large_group_kernel");

	printf("sync scatter_large_group_kernel\n");
	HANDLE_ERROR(cudaThreadSynchronize());
}

void bucket_result(uint32 *d_sa, uint32 *d_isa, uint8* h_ref, uint32 string_size)
{
	uint32 *h_sa = (uint32*)allocate_pageable_memory(sizeof(uint32) * string_size);
	uint32 *h_isa = (uint32*)allocate_pageable_memory(sizeof(uint32) * string_size);
	mem_device2host(d_sa, h_sa, sizeof(uint32) * string_size);
	mem_device2host(d_isa, h_isa, sizeof(uint32) * string_size);
	
	uint32 start_pos;

	for (uint32 i = 0; i < string_size; i++)
	{
		start_pos = h_sa[i];
		printf("bucket val: %#x, ref val: %#x%x%x%x\n", h_isa[i], h_ref[start_pos], h_ref[start_pos+1], h_ref[start_pos+2], h_ref[start_pos+3]);
	}

	free_pageable_memory(h_sa);
	free_pageable_memory(h_isa);
}


void scatter(uint32 *d_L, uint32 *d_R_in, uint32 *d_R_out, Partition *d_par, uint32 par_count)
{
	
	/* 
	 * my implementation of scatter
	 */
	
	dim3 threads_per_block(THREADS_PER_BLOCK, 1, 1);
	dim3 blocks_per_grid(1, 1, 1);
	
	uint32 shared_size = THREADS_PER_BLOCK * sizeof(uint32) * 8;
	blocks_per_grid.x = par_count;
	
	
	scatter_kernel<<<blocks_per_grid, threads_per_block, shared_size>>>(d_L, d_R_in, d_R_out, d_par);
	CHECK_KERNEL_ERROR("scatter_kernel");
	HANDLE_ERROR(cudaDeviceSynchronize());
	

	/*thurst scatter operation*/
/*		
	thrust::device_ptr<uint32> d_input_ptr = thrust::device_pointer_cast(d_R_in);
	thrust::device_ptr<uint32> d_output_ptr = thrust::device_pointer_cast(d_R_out);
	thrust::device_ptr<uint32> d_map_ptr = thrust::device_pointer_cast(d_L);

	thrust::scatter(d_input_ptr, d_input_ptr+size, d_map_ptr, d_output_ptr);
	cudaDeviceSynchronize();
*/	
}

uint32 prefix_sum(uint32 *d_input, uint32 *d_output, uint32 size)
{
	uint32 sum = 0;
	uint32 first_rank = 1;

	mem_host2device(&first_rank, d_input, sizeof(uint32));

	thrust::device_ptr<uint32> d_input_ptr = thrust::device_pointer_cast(d_input);
	thrust::device_ptr<uint32> d_output_ptr = thrust::device_pointer_cast(d_output);

	thrust::inclusive_scan(d_input_ptr, d_input_ptr+size, d_output_ptr);
	
	mem_device2host(d_output+size-1, &sum, sizeof(uint32));
	
	return sum;
}

uint32 block_prefix_sum(uint32 *d_input, uint32 *d_block_totals, Partition *d_par, Partition *h_par, uint32 par_count)
{
	uint32 inclusive = 1;
	uint32 total = 0;
	uint32 num_interval = par_count/BLOCK_NUM + (par_count%BLOCK_NUM?1:0); 

	BlockScanPass1<<<BLOCK_NUM, NUM_THREADS>>>(d_input, d_par, d_block_totals, num_interval, par_count);
	BlockScanPass2<<<1, NUM_THREADS>>>(d_block_totals, BLOCK_NUM);
	BlockScanPass3<<<BLOCK_NUM, NUM_THREADS>>>(d_input, d_par, d_block_totals, num_interval, par_count, inclusive);
	HANDLE_ERROR(cudaThreadSynchronize());

	mem_device2host(d_input+h_par[par_count-1].end-1, &total, sizeof(uint32));
	
	return total;
}

/**
 * Update isa and unsorted groups
 * the function update_isa() can handle at most 65536*2048 elements
 */
bool update_isa_block(uint32 *d_sa, uint32 *d_isa_out, uint32 *d_isa_in, uint32 &acc_unique, 
	uint32 h_order, uint32 *d_block_start, uint32 *d_block_len, uint32 *h_block_start, 
	uint32 *h_block_len, Partition *d_par, Partition *h_par, 
	uint32 par_count, uint32 string_size, uint32 &new_par_count, uint32 &seg_sort_lower_bound, 
	uint32 &s_type_bound, uint32 &l_type_bound)
{
	dim3 threads_per_block(THREADS_PER_BLOCK, 1, 1);
	dim3 blocks_per_grid(1, 1, 1);
	
	uint32 num_unique = 0;
	uint32 split_boundary;
	uint32 sort_bound;
	uint32 shared_size = (THREADS_PER_BLOCK) * sizeof(uint32) * 16;
	uint32 num_interval = par_count/BLOCK_NUM + (par_count%BLOCK_NUM ? 1:0);
	blocks_per_grid.x = BLOCK_NUM;

#ifdef __MEASURE_TIME__
	Start(NEIG_COM);
#endif	
	printf("number of thread blocks: %d\n", par_count);

	/*
	 * input:  d_isa_out
	 * output: d_block_len
	 */
	neighbour_comparison_kernel<<<blocks_per_grid, threads_per_block, shared_size>>>(d_isa_out, d_block_len, d_par, num_interval, par_count);
	CHECK_KERNEL_ERROR("neighbour_comparision_kernel");
	
//	neighbour_comparison_kernel2<<<blocks_per_grid, threads_per_block, shared_size>>>(d_isa_out, d_block_len, d_par, num_interval);
//	CHECK_KERNEL_ERROR("neighbour_comparision_kernel2");
	
	HANDLE_ERROR(cudaDeviceSynchronize());
	
	check_neighbour_comparison(d_isa_out, d_block_len, h_par, par_count, string_size);

#ifdef __MEASURE_TIME__
	Stop(NEIG_COM);
	Start(PREFIX_SUM);
#endif	
#ifdef __DEBUG__
	/*
	 * test prefix sum result
	 */
	uint32 *h_input = (uint32*)allocate_pageable_memory(sizeof(uint32)*string_size);
	mem_device2host(d_block_len, h_input, sizeof(uint32)*string_size);
#endif
	num_unique = block_prefix_sum(d_block_len, d_block_start, d_par, h_par, par_count);

	printf("number of unique : %d\n", num_unique);
	
	check_prefix_sum(h_input, d_block_len, h_par, par_count, string_size);

#ifdef __MEASURE_TIME__
	Stop(PREFIX_SUM);
#endif

	if (num_unique + acc_unique == string_size)
		return true;
	
	//to be modified
	update_block(d_sa, d_isa_in, d_block_len, d_block_len, d_block_start, d_block_len, 
	d_par, h_par, h_block_start, h_block_len, par_count, acc_unique, num_unique, 
	split_boundary, sort_bound, s_type_bound, l_type_bound, string_size, h_order);
	
//	check_update_block(d_block_len, d_block_start, h_input, par_count, h_par, string_size, split_boundary, sort_bound);

#ifdef __DEBUG__
	free_pageable_memory(h_input);
#endif	

#ifdef __MEASURE_TIME__
	Start(SCATTER);
#endif
	scatter_rank_value(d_block_len, d_block_start, d_sa, d_isa_in, split_boundary, num_unique+1, string_size);
	new_par_count = (num_unique+1)-split_boundary;
#ifdef __MEASURE_TIME__
	Stop(SCATTER);
#endif	
	seg_sort_lower_bound = split_boundary;
	printf("synchronize after scatter\n");
	HANDLE_ERROR(cudaThreadSynchronize());
	return false;
}

//to be modified later
void derive_2h_order(uint32 *d_sa, uint32 *d_isa_in, uint32 *d_isa_out, uint32 h_order, Partition *h_par, Partition *d_par,
		uint32 *d_block_start, uint32 *d_block_len, uint32 *h_block_start, uint32 *h_block_len, uint32 *d_digits, uint32 *d_tmp_store, uint32 par_count, 
		uint32 block_count, uint32 seg_sort_lower_bound, uint32 s_type_bound, uint32 l_type_bound, uint32 s_type_par_bound, uint32 l_type_par_bound, uint32 digit_count)
{
	dim3 threads_per_block(THREADS_PER_BLOCK, 1, 1);
	dim3 blocks_per_grid(BLOCK_NUM, 1, 1);
	
	uint32 shared_size = (THREADS_PER_BLOCK) * sizeof(uint32) * 8; 
	uint32 num_interval = par_count/BLOCK_NUM + (par_count%BLOCK_NUM?1:0);
	
	//gather operation
	//to be modified later
	get_second_keys<<<blocks_per_grid, threads_per_block, shared_size>>>(d_sa, d_isa_in+h_order, d_isa_out, d_par, num_interval, par_count);
	CHECK_KERNEL_ERROR("get_second_keys");

#ifdef __MEASURE_TIME__
	Start(R_SORT);
#endif

#ifdef __DEBUG__

	printf("par_count: %u\n", par_count);
	printf("block_count: %u\n", block_count);
	printf("s_type_bound: %u\n", s_type_bound);
	printf("l_type_bound: %u\n", l_type_bound);
//	printf("s_type_par_bound: %u %u %u\n", s_type_par_bound, h_block_len[h_par[s_type_par_bound-1].bid-1], h_block_len[h_par[s_type_par_bound].bid-1]);
//	printf("l_type_par_bound: %u %u %u\n", l_type_par_bound, h_block_len[h_par[l_type_par_bound-1].bid-1], h_block_len[h_par[l_type_par_bound].bid-1]);
//	printf("l_type_par_bound: %u %u\n", l_type_par_bound, h_par[l_type_par_bound-1].bid);
	
#endif	
	//L-type segment key-value sort
	uint32 *d_block_start_ptr = d_block_start + s_type_bound + seg_sort_lower_bound;
	uint32 *d_block_len_ptr = d_block_len + s_type_bound + seg_sort_lower_bound;
	Partition *d_par_ptr = d_par + s_type_par_bound;
	uint32 l_par_count = l_type_par_bound - s_type_par_bound;
	uint32 l_block_count = l_type_bound - s_type_bound;
	uint32 num_thread = NUM_THREAD_SEG_SORT;
	uint32 num_block_for_pass2 = l_block_count < NUM_BLOCK_SEG_SORT ? l_block_count : NUM_BLOCK_SEG_SORT;
	uint32 num_block_for_pass13 = l_block_count < NUM_BLOCK_SEG_SORT ? l_block_count : NUM_BLOCK_SEG_SORT;
	uint32 work_per_block = l_block_count/num_block_for_pass2 + (l_block_count%num_block_for_pass2?1:0);
	uint32 num_interval_for_pass2 = work_per_block/NUM_WARPS + (work_per_block%NUM_WARPS?1:0);

//	for (uint32 i = 0; i < block_count; i++)
//		gpu_block_sort(d_isa_out, d_sa, h_block_start[i], h_block_len[i]);
/*	
	uint32 *block_start = (uint32*)allocate_pageable_memory(sizeof(uint32)*block_count);
	uint32 *block_len = (uint32*)allocate_pageable_memory(sizeof(uint32)*block_count);
	mem_device2host(d_block_start_ptr, block_start, sizeof(uint32)*l_block_count);
	mem_device2host(d_block_len_ptr, block_len, sizeof(uint32)*l_block_count);
	printf("l_block_count: %u\n", l_block_count);
	for (uint32 i = 0; i < l_block_count; i++)
		printf("(%u, %u)\n", block_len[i], block_start[i]);
	free_pageable_memory(block_start);
	free_pageable_memory(block_len);
	return;
*/	
	for (uint32 bit = 0; bit < 30; bit += 5)
	{
		HANDLE_ERROR(cudaMemset(d_digits, 0, digit_count));
		multiblock_radixsort_pass1<<<num_block_for_pass13, num_thread>>>(d_isa_out, d_digits+32, d_block_start_ptr, d_block_len_ptr, bit, l_block_count);
		multiblock_radixsort_pass2<<<num_block_for_pass2, num_thread>>>(d_digits+32, d_block_len_ptr, num_interval_for_pass2, l_block_count);
		multiblock_radixsort_pass3<<<num_block_for_pass13, num_thread>>>(d_digits+32, d_isa_out, d_sa, d_block_start_ptr, d_block_len_ptr, d_tmp_store, bit, l_block_count);
	}

	//S-type segment key-value sort
	uint s_par_count = s_type_par_bound;
	uint num_block = s_par_count < NUM_BLOCK_SEG_SORT ? s_par_count: NUM_BLOCK_SEG_SORT;
	num_interval = s_par_count/num_block + (s_par_count%num_block?1:0);

	for (uint32 bit = 0; bit < 30; bit +=5)
		single_block_radixsort<<<num_block, num_thread>>>(d_isa_out, d_sa, d_par, num_interval, bit, s_par_count);

	HANDLE_ERROR(cudaDeviceSynchronize());

	//For segmenets longer than 65535, we call thrust at current stage
	for (uint32 i = l_type_bound; i < block_count; i++)
		gpu_block_sort(d_isa_out, d_sa, h_block_start[i], h_block_len[i]);

#ifdef __MEASURE_TIME__
	Stop(R_SORT);
#endif
}

void assign_thread_blocks(Partition *h_par, Partition *d_par, uint32 *h_block_start, uint32 *h_block_len, uint32 block_count, uint32 &par_count, uint32 &s_type_bound, uint32 &l_type_bound,
			uint32 &s_type_par_bound, uint32 &l_type_par_bound)
{
	par_count = 0;
	uint32 start, end;
	uint32 pre_parcount;
	
	s_type_bound = 0;
	l_type_bound = 0;
	s_type_par_bound = 0;
	l_type_par_bound = 0;

	for (uint32 i = 0; i < block_count; i++)
	{
		if (h_block_len[i] < NUM_ELEMENT_SB)
		{
			h_par[par_count].bid = i+1;
			h_par[par_count].start = h_block_start[i];
			h_par[par_count].end = h_block_start[i] + h_block_len[i];
			par_count++;
		}
		else
		{
			start = h_block_start[i];
			end = start + h_block_len[i];
			pre_parcount = par_count;
			for (uint32 j = start; j < end; j += NUM_ELEMENT_SB)
			{
				h_par[par_count].bid = 0;
				h_par[par_count].start = j;
				h_par[par_count].end = j+NUM_ELEMENT_SB;
				par_count++;
			}
			h_par[pre_parcount].bid = i+1;
			h_par[par_count-1].end = end;
		}

		if (h_block_len[i] <= NUM_ELEMENT_SB && (i == block_count-1 || h_block_len[i+1] > NUM_ELEMENT_SB))
		{	
			s_type_bound = i+1;
			s_type_par_bound = par_count;
		}
		else if (h_block_len[i] <= MAX_SEG_NUM && (i == block_count-1 || h_block_len[i+1] > MAX_SEG_NUM))
		{	
			l_type_bound = i+1;
			l_type_par_bound = par_count;
		}
			
	}
	mem_host2device(h_par, d_par, sizeof(Partition)*par_count);
}

/*
 * release version
 */

/*
 * debug version
 * include correctness checking function
 */
void gpu_suffix_sorting_debug(uint32* h_sa, uint32* h_ref, uint32 string_size)
{
	dim3 threads_per_block(THREADS_PER_BLOCK, 1, 1);
	dim3 blocks_per_grid(1, 1, 1);
	
	uint32 ch_per_uint32 = 4;
	uint32 shared_size = (THREADS_PER_BLOCK+4) *4; 
	uint32 size_d_ref = CEIL(string_size, ch_per_uint32);
	uint32 h_order = ch_per_uint32;
	uint32 block_count;
	uint32 par_count;
	uint32 acc_unique = 0;
	uint32 seg_sort_lower_bound;
	uint32 s_type_bound;
	uint32 l_type_bound;
	uint32 s_type_par_bound;
	uint32 l_type_par_bound;

	uint32* h_isa = (uint32*)allocate_pageable_memory(sizeof(uint32) * string_size);
	uint32* d_ref = (uint32*)allocate_device_memory(sizeof(uint32) * size_d_ref);
	uint32* d_sa = (uint32*)allocate_device_memory(sizeof(uint32) * string_size);
	uint32* d_isa_in = (uint32*)allocate_device_memory(sizeof(uint32) * string_size);
	uint32* d_isa_out = (uint32*)allocate_device_memory(sizeof(uint32) * string_size);
	blocks_per_grid.x = CEIL(CEIL(string_size, ch_per_uint32), threads_per_block.x);
		
	uint32* h_block_start = (uint32*)allocate_pageable_memory(sizeof(uint32) * (string_size));
	uint32* h_block_len = (uint32*)allocate_pageable_memory(sizeof(uint32) * (string_size));
	uint32* d_block_start = (uint32*)allocate_device_memory(sizeof(uint32) * (string_size));
	uint32* d_block_len = (uint32*)allocate_device_memory(sizeof(uint32) * (string_size));

// 	Partition* h_par = (Partition*)allocate_pageable_memory(sizeof(Partition) * (string_size/NUM_ELEMENT_SB+32));
//	Partition* d_par = (Partition*)allocate_device_memory(sizeof(Partition) * (string_size/NUM_ELEMENT_SB+32));

 	Partition* h_par = (Partition*)allocate_pageable_memory(sizeof(Partition) * (string_size/MIN_UNSORTED_GROUP_SIZE+32));
	Partition* d_par = (Partition*)allocate_device_memory(sizeof(Partition) * (string_size/MIN_UNSORTED_GROUP_SIZE+32));

	//allocate memory for segmented sort
	uint32 digit_count = sizeof(uint32)*16*NUM_LIMIT*32;
	uint32 *d_digits = (uint32*)allocate_device_memory(digit_count);
	uint32 *d_tmp_store = (uint32*)allocate_device_memory(sizeof(uint32) * NUM_BLOCK_SEG_SORT * MAX_SEG_NUM *2);

	/* shared memory configuration*/
	enum cudaFuncCache pCacheConfig;
	HANDLE_ERROR(cudaDeviceSetCacheConfig(cudaFuncCachePreferShared));
	HANDLE_ERROR(cudaDeviceGetCacheConfig(&pCacheConfig));

	if (pCacheConfig == cudaFuncCachePreferNone)
		printf("cache perference: none \n");
	else if (pCacheConfig == cudaFuncCachePreferShared)
		printf("cache perference: shared memory \n");
	else if (pCacheConfig == cudaFuncCachePreferL1)
		printf("cache perference: L1 cache \n");
	else
		printf("cache perference: error\n");
	
	gpu_mem_usage();

	mem_host2device(h_ref, d_ref, sizeof(uint32) * size_d_ref);
	
	generate_bucket_with_shift<<<blocks_per_grid, threads_per_block, shared_size >>>(d_sa, d_ref, d_isa_in, string_size);
	CHECK_KERNEL_ERROR("generate_bucket_with_shift");
	HANDLE_ERROR(cudaDeviceSynchronize());

	/* initialize block information*/
	h_block_start[0] = 0;
	h_block_len[0] = string_size;
	block_count = 1;

	assign_thread_blocks(h_par, d_par, h_block_start, h_block_len, block_count, par_count, s_type_bound, l_type_bound, s_type_par_bound, l_type_par_bound);
	
	mem_device2device(d_isa_in, d_isa_out, sizeof(uint32) * string_size);
	::swap(d_isa_in, d_isa_out);

	/* sort bucket index stored in d_isa_in*/
	gpu_block_sort(d_isa_out, d_sa, h_block_start[0], h_block_len[0]);

	update_isa_block(d_sa, d_isa_out, d_isa_in, acc_unique, h_order, d_block_start, d_block_len, h_block_start, h_block_len, d_par, h_par, par_count, string_size, block_count, seg_sort_lower_bound, s_type_bound, l_type_bound);

	check_h_order_correctness(d_sa, (uint8*)h_ref, string_size, h_order);
	check_isa(d_sa, d_isa_in, (uint8*)h_ref, string_size, h_order);
	
	for (; h_order < string_size; h_order *= 2)
	{
		printf("%u-order calculation...\n", h_order*2);
		
		/* besides assigning thread blocks, 
		 * the following function will copy partition information to the device
		 */
		assign_thread_blocks(h_par, d_par, h_block_start, h_block_len, block_count, par_count, s_type_bound, l_type_bound, s_type_par_bound, l_type_par_bound);
		
		derive_2h_order(d_sa, d_isa_in, d_isa_out, h_order, h_par, d_par, d_block_start, d_block_len, h_block_start, h_block_len, d_digits, d_tmp_store, par_count, block_count, seg_sort_lower_bound, s_type_bound, l_type_bound, s_type_par_bound, l_type_par_bound, digit_count);

		check_h_order_correctness(d_sa, (uint8*)h_ref, string_size, h_order*2);

		//update isa and unsorted group
		if(update_isa_block(d_sa, d_isa_out, d_isa_in, acc_unique, 2*h_order, d_block_start, d_block_len, h_block_start, h_block_len, d_par, h_par, par_count, string_size, block_count, seg_sort_lower_bound, s_type_bound, l_type_bound))
			break;
		return;
		check_isa(d_sa, d_isa_in, (uint8*)h_ref, string_size, 2*h_order);
	}

	check_h_order_correctness(d_sa, (uint8*)h_ref, string_size, string_size);

	//transfer output to host memory
	mem_device2host(d_sa, h_sa, sizeof(uint32) * string_size);

	//free dvice memory
	free_device_memory(d_ref);
	free_device_memory(d_sa);
	free_device_memory(d_isa_in);
	free_device_memory(d_isa_out);
	free_device_memory(d_block_start);
	free_device_memory(d_block_len);
	free_device_memory(d_par);
	free_device_memory(d_digits);
	free_device_memory(d_tmp_store);

	//free host memory
	free_pageable_memory(h_isa);
	free_pageable_memory(h_block_start);
	free_pageable_memory(h_block_len);
	free_pageable_memory(h_par);
	
	HANDLE_ERROR(cudaDeviceReset());
}
