// ntdma_test: run DMA transfers into the ntdma buffer and verify every byte.
// usage: ntdma_test LEN PAYLOAD [MODE] [SEED] [OFFSET] [REPEAT] [POLL_GAP_NS]
// Before each run the whole buffer (guards included) is filled with a canary;
// afterwards [OFFSET, OFFSET+LEN) must equal the pattern and everything else
// must still be canary.
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include "ntdma.h"

#define CANARY 0x5AA5C33Cu

static uint32_t pat(uint32_t mode, uint32_t seed, uint32_t i)
{
	uint32_t x = seed + i;
	if (mode) {
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
	}
	return x;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s LEN PAYLOAD [MODE] [SEED] [OFFSET] [REPEAT] [POLL_GAP_NS]\n", argv[0]);
		return 2;
	}
	uint32_t len = strtoul(argv[1], 0, 0), payload = strtoul(argv[2], 0, 0);
	uint32_t mode = argc > 3 ? strtoul(argv[3], 0, 0) : 1;
	uint32_t seed = argc > 4 ? strtoul(argv[4], 0, 0) : 0x12345678;
	uint32_t offset = argc > 5 ? strtoul(argv[5], 0, 0) : NTDMA_PRE_GUARD;
	int repeat = argc > 6 ? atoi(argv[6]) : 1;
	uint32_t gap = argc > 7 ? strtoul(argv[7], 0, 0) : (len > 65536 ? 10000 : 0);

	int fd = open("/dev/ntdma", O_RDWR);
	if (fd < 0) { perror("open /dev/ntdma"); return 1; }
	struct ntdma_info info;
	if (ioctl(fd, NTDMA_IOC_INFO, &info)) { perror("INFO"); return 1; }
	volatile uint32_t *buf = mmap(0, info.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (buf == MAP_FAILED) { perror("mmap"); return 1; }
	size_t words = info.size / 4;
	uint32_t *shadow = malloc(info.size);   /* cached copy for fast compare */
	if (!shadow) return 1;

	printf("info bus=0x%" PRIx64 " size=%" PRIu64 " mps=%u hw_maxlen=%u runs=%u\n",
	       info.bus_addr, info.size, info.mps, info.hw_maxlen, info.hw_runs);

	int failures = 0, done_runs = 0;
	double sum_tang = 0, sum_pi = 0, min_t = 1e30, max_t = 0;
	for (int rep = 0; rep < repeat; rep++) {
		uint32_t s = seed + rep * 0x01000193u;
		for (size_t i = 0; i < words; i++) buf[i] = CANARY;
		__sync_synchronize();
		struct ntdma_run r = { .offset = offset, .len = len, .payload = payload,
				       .seed = s, .mode = mode, .poll_gap_ns = gap };
		int rc = ioctl(fd, NTDMA_IOC_RUN, &r);
		if (rc) { printf("RUN ioctl failed: %s\n", strerror(errno)); failures++; break; }
		__sync_synchronize();
		memcpy(shadow, (const void *)buf, info.size);
		size_t first_w = offset / 4, last_w = first_w + len / 4;
		uint64_t bad_data = 0, bad_pre = 0, bad_post = 0;
		long first_bad = -1;
		for (size_t i = 0; i < words; i++) {
			uint32_t v = shadow[i];
			if (i >= first_w && i < last_w) {
				if (v != pat(mode, s, i - first_w)) {
					if (first_bad < 0) first_bad = i;
					bad_data++;
				}
			} else if (v != CANARY) {
				if (i < first_w) bad_pre++; else bad_post++;
				if (first_bad < 0) first_bad = i;
			}
		}
		double tang_s = r.cycles * 10e-9;           /* 100 MHz TL clock */
		double tang_mbs = tang_s > 0 ? r.bytes / tang_s / 1e6 : 0;
		double pi_mbs = r.pi_ns ? len / (r.pi_ns * 1e-9) / 1e6 : 0;
		int ok = (r.status & 7) == 1 && r.bytes == len && !bad_data && !bad_pre && !bad_post;
		if (!ok) failures++;
		done_runs++;
		sum_tang += tang_mbs; sum_pi += pi_mbs;
		if (tang_mbs < min_t) min_t = tang_mbs;
		if (tang_mbs > max_t) max_t = tang_mbs;
		if (repeat <= 10 || !ok || rep == 0 || rep == repeat - 1)
			printf("run %d len=%u pay=%u mode=%u bus=0x%" PRIx64 " status=%08x tlps=%u bytes=%u "
			       "cycles=%u waitcyc=%u credcyc=%u tang=%.1fMB/s pi_ns=%" PRIu64 " pi=%.1fMB/s polls=%u "
			       "bad_data=%" PRIu64 " bad_pre_guard=%" PRIu64 " bad_post_guard=%" PRIu64 " first_bad=%ld %s\n",
			       rep, len, payload, mode, r.bus_addr, r.status, r.tlps, r.bytes, r.cycles,
			       r.wait_cycles, r.credit_cycles, tang_mbs, r.pi_ns, pi_mbs, r.polls,
			       bad_data, bad_pre, bad_post, first_bad, ok ? "OK" : "FAIL");
		if (!ok && first_bad >= 0) {
			for (long i = first_bad; i < first_bad + 4 && i < (long)words; i++)
				printf("  word %ld: %08x (want %08x)\n", i, shadow[i],
				       (i >= (long)first_w && i < (long)last_w) ? pat(mode, s, i - first_w) : CANARY);
		}
		if (!ok) break;
	}
	printf("summary len=%u pay=%u runs=%d failures=%d tang_avg=%.1fMB/s tang_min=%.1f tang_max=%.1f pi_avg=%.1fMB/s\n",
	       len, payload, done_runs, failures, done_runs ? sum_tang / done_runs : 0, min_t, max_t, done_runs ? sum_pi / done_runs : 0);
	return failures ? 1 : 0;
}
