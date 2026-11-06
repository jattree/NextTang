// SPDX-License-Identifier: GPL-2.0
/*
 * ntdma: minimal test driver for the NextTang Tang Console 138K PCIe DMA
 * writer (22c2:1100, BAR2 register window at 0x40-0x7F).
 *
 * One coherent buffer (pre-guard + up to 16 MiB + post-guard) is mmap-able
 * through /dev/ntdma. The bus address the FPGA writes to is always derived
 * here from the buffer handle; user space only chooses an offset and a
 * length, both checked against the buffer, so the FPGA is never pointed
 * outside memory this module owns. The FPGA clamps again in hardware.
 * Only 32-bit MMIO accesses are made: the BAR2 completer answers 1-DW reads
 * only.
 */
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/dma-mapping.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/ktime.h>
#include <linux/mutex.h>
#include <linux/uaccess.h>
#include "ntdma.h"

#define R_ID		0x40
#define R_CTRL		0x44
#define R_ADDR_LO	0x48
#define R_ADDR_HI	0x4c
#define R_LEN		0x50
#define R_PAYLOAD	0x54
#define R_SEED		0x58
#define R_STATUS	0x5c
#define R_CYCLES	0x60
#define R_BYTES		0x64
#define R_TLPS		0x68
#define R_MAXLEN	0x6c
#define R_WAITCYC	0x70
#define R_CREDCYC	0x74
#define R_RUNS		0x78
#define R_LASTADDR	0x7c

#define CTRL_GO		BIT(0)
#define CTRL_CLEAR	BIT(1)
#define CTRL_ABORT	BIT(2)
#define ST_DONE		BIT(0)
#define ST_BUSY		BIT(1)
#define ST_ERROR	BIT(2)
#define NTDMA_ID	0x4E54444D

struct ntdma {
	struct pci_dev *pdev;
	void __iomem *regs;
	void *cpu;
	dma_addr_t bus;
	size_t size;
	struct miscdevice misc;
	struct mutex lock;
};

static struct ntdma *the_dev;

static u32 rd(struct ntdma *d, u32 off) { return ioread32(d->regs + off); }
static void wr(struct ntdma *d, u32 off, u32 v) { iowrite32(v, d->regs + off); }

/* Stop a running transfer; returns 0 once the engine is idle. */
static int ntdma_quiesce(struct ntdma *d)
{
	int i;

	if (!(rd(d, R_STATUS) & ST_BUSY))
		return 0;
	wr(d, R_CTRL, CTRL_ABORT);
	for (i = 0; i < 100000; i++) {
		if (!(rd(d, R_STATUS) & ST_BUSY))
			return 0;
		udelay(1);
	}
	return -ETIMEDOUT;
}

static long ntdma_run(struct ntdma *d, struct ntdma_run __user *uarg)
{
	struct ntdma_run r;
	u64 addr, t0, t1;
	u32 st, mps;
	unsigned long polls = 0;
	int ret = 0;

	if (copy_from_user(&r, uarg, sizeof(r)))
		return -EFAULT;
	mps = pcie_get_mps(d->pdev);
	if (r.len == 0 || r.len > NTDMA_MAX_LEN || (r.len & 3) || (r.offset & 3))
		return -EINVAL;
	if (r.offset > d->size || r.len > d->size - r.offset)
		return -EINVAL;
	if (r.payload != 64 && r.payload != 128 && r.payload != 256 &&
	    r.payload != 512)
		return -EINVAL;
	if (r.payload > mps)
		return -EINVAL;

	addr = (u64)d->bus + r.offset;
	if (rd(d, R_STATUS) & ST_BUSY)
		return -EBUSY;
	wr(d, R_CTRL, CTRL_CLEAR);
	wr(d, R_ADDR_LO, lower_32_bits(addr));
	wr(d, R_ADDR_HI, upper_32_bits(addr));
	wr(d, R_LEN, r.len);
	wr(d, R_PAYLOAD, r.payload);
	wr(d, R_SEED, r.seed);
	/* Read back before GO: the window must be exactly what we computed. */
	if (rd(d, R_ADDR_LO) != lower_32_bits(addr) ||
	    rd(d, R_ADDR_HI) != upper_32_bits(addr) ||
	    rd(d, R_LEN) != r.len || rd(d, R_PAYLOAD) != r.payload ||
	    rd(d, R_SEED) != r.seed) {
		dev_err(&d->pdev->dev, "register readback mismatch, not starting\n");
		return -EIO;
	}
	r.bus_addr = addr;

	/* iowrite32 orders prior normal-memory writes (the canary fill). */
	t0 = ktime_get_ns();
	wr(d, R_CTRL, CTRL_GO | (r.mode ? BIT(8) : 0));
	for (;;) {
		if (r.poll_gap_ns)
			ndelay(r.poll_gap_ns);
		st = rd(d, R_STATUS);
		polls++;
		if (!(st & ST_BUSY))
			break;
		if (ktime_get_ns() - t0 > 2000000000ULL) {
			ret = -ETIMEDOUT;
			break;
		}
	}
	t1 = ktime_get_ns();
	if (ret) {
		ntdma_quiesce(d);
		st = rd(d, R_STATUS);
	}
	r.status = st;
	r.pi_ns = t1 - t0;
	r.cycles = rd(d, R_CYCLES);
	r.bytes = rd(d, R_BYTES);
	r.tlps = rd(d, R_TLPS);
	r.wait_cycles = rd(d, R_WAITCYC);
	r.credit_cycles = rd(d, R_CREDCYC);
	r.polls = polls;
	r.mps = mps;
	if (copy_to_user(uarg, &r, sizeof(r)))
		return -EFAULT;
	return ret;
}

static long ntdma_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct ntdma *d = the_dev;
	long ret;

	if (!d)
		return -ENODEV;
	mutex_lock(&d->lock);
	switch (cmd) {
	case NTDMA_IOC_INFO: {
		struct ntdma_info i = {
			.bus_addr = d->bus,
			.size = d->size,
			.pre_guard = NTDMA_PRE_GUARD,
			.max_len = NTDMA_MAX_LEN,
			.mps = pcie_get_mps(d->pdev),
			.hw_maxlen = rd(d, R_MAXLEN),
			.hw_runs = rd(d, R_RUNS),
		};
		ret = copy_to_user((void __user *)arg, &i, sizeof(i)) ? -EFAULT : 0;
		break;
	}
	case NTDMA_IOC_RUN:
		ret = ntdma_run(d, (struct ntdma_run __user *)arg);
		break;
	default:
		ret = -ENOTTY;
	}
	mutex_unlock(&d->lock);
	return ret;
}

static int ntdma_mmap(struct file *f, struct vm_area_struct *vma)
{
	struct ntdma *d = the_dev;
	size_t len = vma->vm_end - vma->vm_start;

	if (!d || vma->vm_pgoff || len > PAGE_ALIGN(d->size))
		return -EINVAL;
	return dma_mmap_coherent(&d->pdev->dev, vma, d->cpu, d->bus, len);
}

static const struct file_operations ntdma_fops = {
	.owner = THIS_MODULE,
	.unlocked_ioctl = ntdma_ioctl,
	.mmap = ntdma_mmap,
};

static int ntdma_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct ntdma *d;
	u32 ident;
	int ret;

	if (the_dev)
		return -EBUSY;
	d = devm_kzalloc(&pdev->dev, sizeof(*d), GFP_KERNEL);
	if (!d)
		return -ENOMEM;
	d->pdev = pdev;
	mutex_init(&d->lock);

	ret = pci_enable_device(pdev);
	if (ret)
		return ret;
	ret = pci_request_region(pdev, 2, "ntdma");
	if (ret)
		goto err_disable;
	d->regs = pci_iomap(pdev, 2, 0x100);
	if (!d->regs) {
		ret = -ENOMEM;
		goto err_region;
	}
	ident = rd(d, R_ID);
	if (ident != NTDMA_ID) {
		dev_err(&pdev->dev, "BAR2+0x40 reads %08x, not the DMA bitstream\n", ident);
		ret = -ENODEV;
		goto err_unmap;
	}
	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
	if (ret)
		goto err_unmap;
	d->size = NTDMA_PRE_GUARD + NTDMA_MAX_LEN + NTDMA_POST_GUARD;
	d->cpu = dma_alloc_coherent(&pdev->dev, d->size, &d->bus, GFP_KERNEL);
	if (!d->cpu) {
		ret = -ENOMEM;
		goto err_unmap;
	}
	pci_set_master(pdev);

	d->misc.minor = MISC_DYNAMIC_MINOR;
	d->misc.name = "ntdma";
	d->misc.fops = &ntdma_fops;
	d->misc.mode = 0600;
	ret = misc_register(&d->misc);
	if (ret)
		goto err_free;
	pci_set_drvdata(pdev, d);
	the_dev = d;
	dev_info(&pdev->dev, "ntdma: buffer %zu bytes at bus %pad, MPS %d\n",
		 d->size, &d->bus, pcie_get_mps(pdev));
	return 0;

err_free:
	pci_clear_master(pdev);
	dma_free_coherent(&pdev->dev, d->size, d->cpu, d->bus);
err_unmap:
	pci_iounmap(pdev, d->regs);
err_region:
	pci_release_region(pdev, 2);
err_disable:
	pci_disable_device(pdev);
	return ret;
}

static void ntdma_remove(struct pci_dev *pdev)
{
	struct ntdma *d = pci_get_drvdata(pdev);

	misc_deregister(&d->misc);
	the_dev = NULL;
	if (ntdma_quiesce(d))
		dev_err(&pdev->dev, "engine still busy; leaking the buffer\n");
	pci_clear_master(pdev);
	if (!(rd(d, R_STATUS) & ST_BUSY))
		dma_free_coherent(&pdev->dev, d->size, d->cpu, d->bus);
	pci_iounmap(pdev, d->regs);
	pci_release_region(pdev, 2);
	pci_disable_device(pdev);
	dev_info(&pdev->dev, "ntdma: removed\n");
}

static const struct pci_device_id ntdma_ids[] = {
	{ PCI_DEVICE(0x22c2, 0x1100) },
	{ }
};
MODULE_DEVICE_TABLE(pci, ntdma_ids);

static struct pci_driver ntdma_driver = {
	.name = "ntdma",
	.id_table = ntdma_ids,
	.probe = ntdma_probe,
	.remove = ntdma_remove,
};
module_pci_driver(ntdma_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("NextTang PCIe DMA writer test driver");
