obj-m := ntdma.o
KDIR ?= /lib/modules/$(shell uname -r)/build

all: module ntdma_test

module:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

ntdma_test: ntdma_test.c ntdma.h
	$(CC) -O2 -Wall -o $@ ntdma_test.c

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
	rm -f ntdma_test
