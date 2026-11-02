KDIR := /lib/modules/$(shell uname -r)/build
SGDMA_DIR ?= $(shell dirname $(CURDIR))/sgdma_drv
EXTRA_SYMBOLS := $(SGDMA_DIR)/Module.symvers

obj-m := milianke_v4l2.o
milianke_v4l2-objs := milianke_v4l2_zerocopy.o

all:
	make -C $(KDIR) M=$(CURDIR) KBUILD_EXTRA_SYMBOLS=$(EXTRA_SYMBOLS) modules

clean:
	make -C $(KDIR) M=$(CURDIR) clean
