/* SPDX-License-Identifier: GPL-2.0 */
#ifndef NTDMA_H
#define NTDMA_H
#ifdef __KERNEL__
#include <linux/types.h>
#include <linux/ioctl.h>
#else
#include <stdint.h>
#include <sys/ioctl.h>
typedef uint32_t __u32;
typedef uint64_t __u64;
#endif

#define NTDMA_PRE_GUARD  4096u
#define NTDMA_MAX_LEN    (16u * 1024 * 1024)
#define NTDMA_POST_GUARD (64u * 1024)

struct ntdma_info {
	__u64 bus_addr;
	__u64 size;
	__u32 pre_guard;
	__u32 max_len;
	__u32 mps;
	__u32 hw_maxlen;
	__u32 hw_runs;
	__u32 pad;
};

struct ntdma_run {
	/* in */
	__u32 offset;		/* from buffer start; data window = [offset, offset+len) */
	__u32 len;
	__u32 payload;
	__u32 seed;
	__u32 mode;		/* 0 increment, 1 xorshift */
	__u32 poll_gap_ns;
	/* out */
	__u64 bus_addr;
	__u64 pi_ns;
	__u32 status;
	__u32 cycles;
	__u32 bytes;
	__u32 tlps;
	__u32 wait_cycles;
	__u32 credit_cycles;
	__u32 polls;
	__u32 mps;
};

#define NTDMA_IOC_INFO _IOR('N', 1, struct ntdma_info)
#define NTDMA_IOC_RUN  _IOWR('N', 2, struct ntdma_run)
#endif
