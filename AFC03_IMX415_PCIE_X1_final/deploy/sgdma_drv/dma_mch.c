/*
 * This file is part of the Anlogic DMA IP Core driver tool for Linux
 *
 * Copyright (c) 2016-present,  Anlogic, Inc.
 * All rights reserved.
 *
 * This source code is licensed under BSD-style license (found in the
 * LICENSE file in the root directory of this source tree)
 */

#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 500
#include <assert.h>
#include <fcntl.h>
#include <getopt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>

#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include "../../sgdma_drv/cdev_ctrl.h"
#include "../../sgdma_drv/cdev_sgdma.h"

#include "dma_utils.c"

#define offsetof(TYPE, MEMBER)	__builtin_offsetof(TYPE, MEMBER)

#define DEVICE_PATH_MAX_LEN 256
#define DEVICE_NAME_DEFAULT "/dev/ANLOGIC-PCI0"
#define SIZE_DEFAULT (32)
#define COUNT_DEFAULT (1)
#define DESC_COUNT_DEFAULT (64)
#define CLK_FREQ_DEFAULT (250000000)
#define MAX_READ_CHNS 4
#define MAX_WRITE_CHNS 4

struct test_data {
	int index;
	int rdch;
	int readfd;
	int wtch;
	int writefd;
	int chkdata;
	uint8_t *wtbuf;
	uint8_t *rdbuf;
	uint64_t addr;
	uint64_t size;
	uint64_t count;
	pthread_t thread;
	uint64_t total_time;
	char *ifname;
	char *ofname;
	volatile int ret;
	int desccnt;
	int use_lens;
	int use_ctls;
	struct sgdma_desc_info *descs;
};

static struct option const long_opts[] = {
	{"device", required_argument, NULL, 'd'},
	{"loopback", no_argument, NULL, 'l'},
	{"check", no_argument, NULL, 'k'},
	{"rdchns", required_argument, NULL, 'r'},
	{"wtchns", required_argument, NULL, 'w'},
	{"address", required_argument, NULL, 'a'},
	{"size", required_argument, NULL, 's'},
	{"count", required_argument, NULL, 'c'},
	{"desccount", required_argument, NULL, 'C'},
	{"random", required_argument, NULL, 'R'},
	{"freq", required_argument, NULL, 'f'},
	{"perf", required_argument, NULL, 'p'},
	{"ifile", required_argument, NULL, 'i'},
	{"ofile", required_argument, NULL, 'o'},
	{"lenlist", required_argument, NULL, 128},
	{"ctllist", required_argument, NULL, 129},
	{"chkeop", no_argument, NULL, 130},
	{"help", no_argument, NULL, 'h'},
	{"verbose", no_argument, NULL, 'v'},
	{0, 0, 0, 0}
};

#define RTFLG_BUF_ADDR    0x01
#define RTFLG_BUF_LEN     0x02
#define RTFLG_EP_ADDR     0x04
#define RTFLG_COMPLETE_F  0x08
#define RTFLG_CANCEL      0x10
#define RTFLG_CHKDATA     0x20
#define RTFLG_LOOPBACK    0x40
#define RTFLG_HWPERF      0x80

static int test_dma(char *devname, uint64_t addr, uint64_t size,
		    uint64_t offset, uint64_t count, char *ofname);

static void usage(const char *name)
{
	int i = 0;
	fprintf(stdout, "%s\n\n", name);
	fprintf(stdout, "usage: %s [OPTIONS]\n\n", name);
	fprintf(stdout, "SGDMA multi channel test\n\n");

	fprintf(stdout, "  -%c (--%s) device name(defaults to %s)\n",
		long_opts[i].val, long_opts[i].name, DEVICE_NAME_DEFAULT);
	i++;

	fprintf(stdout, "  -%c (--%s) loopback test\n",
		long_opts[i].val, long_opts[i].name);
	i++;

	fprintf(stdout, "  -%c (--%s) check read data\n",
		long_opts[i].val, long_opts[i].name);
	i++;

	fprintf(stdout, "  -%c (--%s) read channel list: eg, 0,2\n",
		long_opts[i].val, long_opts[i].name);
	i++;

	fprintf(stdout, "  -%c (--%s) write channel list: eg, 0,2\n",
		long_opts[i].val, long_opts[i].name);
	i++;

	fprintf(stdout, "  -%c (--%s) the start address on the AXI bus\n",
	       long_opts[i].val, long_opts[i].name);
	i++;

	fprintf(stdout,
		"  -%c (--%s) size of a single transfer in bytes, default %d.\n",
		long_opts[i].val, long_opts[i].name, SIZE_DEFAULT);
	i++;

	fprintf(stdout, "  -%c (--%s) number of transfers, default is %d.\n",
	       long_opts[i].val, long_opts[i].name, COUNT_DEFAULT);
	i++;

	fprintf(stdout, "  -%c (--%s) number of descriptors, default is %d. Only for random test\n",
	       long_opts[i].val, long_opts[i].name, DESC_COUNT_DEFAULT);
	i++;

	fprintf(stdout, "  -%c (--%s) random options: 'a'-addr, 'e'-ep_addr, 'l'-len, 'c'-complete, 'C'-cancel, 'z'-nomeaning.\n",
	       long_opts[i].val, long_opts[i].name);
	i++;

	fprintf(stdout, "  -%c (--%s) clock frequency, default is %lu\n",
	       long_opts[i].val, long_opts[i].name, (unsigned long)CLK_FREQ_DEFAULT);
	i++;

	fprintf(stdout, "  -%c (--%s) hw performance: start, stop\n",
	       long_opts[i].val, long_opts[i].name);
	i++;

	fprintf(stdout, "  -%c (--%s) input file name\n",
	       long_opts[i].val, long_opts[i].name);
	i++;

	fprintf(stdout, "  -%c (--%s) output file name\n",
	       long_opts[i].val, long_opts[i].name);
	i++;

	fprintf(stdout, "     (--%s) length lists, like \"16, 32*3, 64\n",
	       long_opts[i].name);
	i++;

	fprintf(stdout, "     (--%s) descriptor control lists, like \"0, 2*3, 3\n",
	       long_opts[i].name);
	i++;

	fprintf(stdout, "     (--%s) check eop for stream c2h channel\n",
	       long_opts[i].name);
	i++;

	fprintf(stdout, "  -%c (--%s) print usage help and exit\n",
		long_opts[i].val, long_opts[i].name);
	i++;

	fprintf(stdout, "  -%c (--%s) verbose output\n",
		long_opts[i].val, long_opts[i].name);
	i++;
}

static inline void _print_hwperf(uint64_t cycle_cnt, uint64_t data_cnt,
			  uint64_t data_width, uint64_t freq)
{
	fprintf(stdout, "clock cycle count: %lu\n", cycle_cnt);
	fprintf(stdout, "data cycle count: %lu\n", data_cnt);
	fprintf(stdout, "data width: %lu bits\n", data_width);
	fprintf(stdout, "clock frequency: %lu\n", freq);
	if (cycle_cnt == 0)
		return;
	fprintf(stdout, "data rate: %lu\n", data_cnt * data_width * freq / (8 * cycle_cnt));
}

static void print_hwperf(int *h2c_chn_list, int h2c_cnt,
				      int *c2h_chn_list, int c2h_cnt,
				      struct anlogic_perf_cnt *perf,
				      uint64_t freq)
{
	int i;

	for (i = 0; i < h2c_cnt + c2h_cnt; i++) {
		fprintf(stdout, "%s channel %d hw perf:\n",
			(i < h2c_cnt) ? "h2c" : "c2h",
			(i < h2c_cnt) ? h2c_chn_list[i] : c2h_chn_list[i - h2c_cnt]);

		_print_hwperf(perf[i].clock_cycle_count,
			      perf[i].data_cycle_count,
			      perf[i].data_width, freq);
	}
}

static int parse_uint32_list(char *str, uint32_t *list, int max)
{
	char *token;
	char *mult;
	uint32_t cnt;
	uint32_t val;
	int i = 0, j = 0;

	token = strtok(str, ",");
	while (token != NULL && i < max) {
		mult = strchr(token, '*');
		if (mult) {
			*mult = '\0';
			cnt = strtoul(mult + 1, NULL, 0);
		} else
			cnt = 1;

		val = strtoul(token, NULL, 0);
		for (j = 0; j < cnt && i < max; j++) {
			list[i++] = val;
		}
		token = strtok(NULL, ",");
	}

	return i;
}

static int parse_chn_list(char *chns, int *chn_list, int max)
{
	char *token;
	int i = 0;

	token = strtok(chns, ",");
	while (token != NULL && i < max) {
		chn_list[i] = atoi(token);
		token = strtok(NULL, ",");
		i++;
	}

	return i;
}

static int open_chn_list(const char *name, char *dev, int *chn_list, int cnt, int *fds, int chkeop)
{
	int i;
	char dev_path[DEVICE_PATH_MAX_LEN];
	unsigned long flgs = O_RDWR;

	if (chkeop)
		flgs |= O_TRUNC;

	for (i = 0; i < cnt; i++) {
		snprintf(dev_path, DEVICE_PATH_MAX_LEN, "%s_%s_%d", dev, name, chn_list[i]);
		fds[i] = open(dev_path, flgs);
		if (fds[i] < 0) {
			fprintf(stderr, "unable to open device %s, %d.\n",
				dev_path, fds[i]);
			perror("open device");
			return -EINVAL;
		}
	}

	return 0;
}

static int do_cus_rw(int fd, uint8_t *buf, uint64_t size,
	      uint64_t ep_addr, int write, int desc_cnt,
	      struct sgdma_desc_info *descs, int use_ctls)
{
	struct sgdma_cus_rw_ioctl *io;
	int ret;
	int i;

	io = malloc(offsetof(struct sgdma_cus_rw_ioctl, desc) + sizeof(struct sgdma_desc_info) * desc_cnt);
	memset(io, 0, sizeof(*io));
	io->write = write;
	io->buffer = (uint64_t)buf;
	io->ep_addr = ep_addr;
	io->desc_cnt = desc_cnt;
	if (use_ctls)
		io->flags |= SGDMA_CUSRW_FLG_CTRL;
	memcpy(io->desc, descs, sizeof(struct sgdma_desc_info) * desc_cnt);

	ret = ioctl(fd, IOCTL_SGDMA_CUS_RW, io);
	if (ret < 0) {
		fprintf(stderr, "do_cus_rw failed %d\n", ret);
		goto exit;
	}

	if (io->error < 0) {
		fprintf(stderr, "do_cus_rw error %d\n", io->error);
		ret = io->error;
		goto exit;
	}

	ret = io->done;
exit:
	free(io);
	return ret;
}

void *test_thread(void *arg)
{
	struct test_data *data = (struct test_data *)arg;
	struct timespec ts_start;
	struct timespec ts_end;
	char fname[DEVICE_PATH_MAX_LEN];
	int ifd = -1;
	int ofd = -1;
	off_t off;
	int i, j;
	int ret = -1;
	int rdsz = 0;

	pthread_detach(pthread_self());
	data->total_time = 0;
	if (data->writefd > 0) {
		if (data->ifname) {
			snprintf(fname, DEVICE_PATH_MAX_LEN, "%s-h2c%d", data->ifname, data->wtch);
			ifd = open(fname, O_RDONLY);
			if (ifd < 0) {
				fprintf(stderr, "unable to open input file %s, %d.\n",
					fname, ifd);
				ret = -EINVAL;
				goto err_out;
			}
			ret = read_to_buffer(fname, ifd, data->wtbuf, data->size, 0);
			if (ret < 0) {
				fprintf(stderr, "read %s to buffer failed %d\n", fname, ret);
				goto err_out;
			}
			close(ifd);
			ifd = -1;
		} else {
			for (j = 0; j < data->size; j++)
				data->wtbuf[j] = (j & 0xff);
		}
	}

	if (data->readfd > 0 && data->ofname) {
		snprintf(fname, DEVICE_PATH_MAX_LEN, "%s-c2h%d", data->ofname, data->rdch);
		ofd = open(fname, O_RDWR | O_CREAT | O_TRUNC | O_SYNC, 0666);
		if (ofd < 0) {
			fprintf(stderr, "unable to open output file %s, %d.\n",
				fname, ofd);
			ret = -EINVAL;
			goto err_out;
		}

	}

	for (i = 0; i < data->count; i++) {
		if (data->readfd > 0)
			memset(data->rdbuf, 0, data->size);

		clock_gettime(CLOCK_MONOTONIC, &ts_start);
		if (data->writefd > 0) {
			off = lseek(data->writefd, data->addr, SEEK_SET);
			if (off != data->addr) {
				fprintf(stderr, "test %d write seek to 0x%lx fail.\n",
					data->index, (unsigned long)data->addr);
				ret = -EIO;
				goto err_out;
			}

			if (data->use_lens)
				ret = do_cus_rw(data->writefd, data->wtbuf,
						data->size, data->addr, 1,
						data->desccnt, data->descs,
						data->use_ctls);
			else
				ret = write(data->writefd, data->wtbuf, data->size);
			if (ret < 0) {
				fprintf(stderr, "test %d write failed %d\n", data->index, ret);
				goto err_out;
			}
		}

		if (data->readfd > 0) {
			off = lseek(data->readfd, data->addr, SEEK_SET);
			if (off != data->addr) {
				fprintf(stderr, "test %d read seek to 0x%lx fail.\n",
					data->index, (unsigned long)data->addr);
				ret = -EIO;
				goto err_out;
			}

			if (data->use_lens)
				ret = do_cus_rw(data->readfd, data->rdbuf,
						data->size, data->addr, 0,
						data->desccnt, data->descs,
						data->use_ctls);
			else
				ret = read(data->readfd, data->rdbuf, data->size);
			if (ret < 0) {
				fprintf(stderr, "test %d read failed %d\n", data->index, ret);
				goto err_out;
			}
			rdsz = ret;
		}
		clock_gettime(CLOCK_MONOTONIC, &ts_end);
		data->total_time += ((ts_end.tv_sec * (unsigned long)1e+9 + ts_end.tv_nsec) -
				(ts_start.tv_sec * (unsigned long)1e+9 + ts_start.tv_nsec));

		if (data->chkdata && data->readfd > 0) {
			if (data->writefd > 0) {
				if (memcmp(data->wtbuf, data->rdbuf, rdsz)) {
					fprintf(stderr, "test %d data mismatch\n",
						data->index);
					goto err_out;
				}
			} else {
				for (j = 0; j < rdsz; j++) {
					if (data->rdbuf[j] != (j & 0xff)) {
						fprintf(stderr, "test %d read data mismatch at %d\n",
							data->index, j);
						goto err_out;
					}
				}
			}
		}

		if (ofd > 0) {
			ret = write_from_buffer(fname, ofd, data->rdbuf, rdsz, i * data->size);
			if (ret < 0) {
				fprintf(stderr, "test %d write output file failed %d\n", data->index, ret);
				goto err_out;
			}
		}

		if (verbose) {
			fprintf(stdout, "test %d-%d finish\n", data->index, i);
		}
	}

	if (ofd > 0)
		close(ofd);

	data->ret = 1;
	return NULL;
err_out:
	if (ifd > 0)
		close(ifd);
	if (ofd > 0)
		close(ofd);
	data->ret = -1;
	return (void*)(long)ret;
}

int do_rtest(char *device, struct anlogic_ioc_rtest *rtest)
{
	int fd;
	int ret = 0;
	char dev_path[DEVICE_PATH_MAX_LEN];

	snprintf(dev_path, DEVICE_PATH_MAX_LEN, "%s_%s", device, "control");

	fd = open(dev_path, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "unable to open device %s\n", dev_path);
		return -1;
	}

	ret = ioctl(fd, ANLOGIC_IOCRTEST, rtest);
	if (ret < 0) {
		fprintf(stderr, "do anlogic rtest failed %d\n", ret);
	}

	close(fd);
	return ret;
}

int perf_ops(char *device, int start,
	     int *write_chn_list, int wtchn_cnt,
	     int *read_chn_list, int rdchn_cnt,
	     struct anlogic_perf_cnt *perf)
{
	struct anlogic_ioc_rtest rtest;
	char dev_path[DEVICE_PATH_MAX_LEN];
	int fd;
	int ret = 0;
	int i;

	if (rdchn_cnt >= MAX_READ_CHNS || wtchn_cnt >= MAX_WRITE_CHNS) {
		fprintf(stderr, "channel count too large\n");
		return -1;
	}

	memset(&rtest, 0, sizeof(rtest));
	rtest.flags = (RTFLG_HWPERF | (start ? 1 : 0));
	rtest.h2c_cnt = wtchn_cnt;
	rtest.c2h_cnt = rdchn_cnt;
	for (i = 0; i < wtchn_cnt; i++) {
		if (write_chn_list[i] >= IOCTL_CHANNEL_NUM_MAX) {
			fprintf(stderr, "invalid write channel %d\n", write_chn_list[i]);
			return -1;
		}
		rtest.chn_list[i] = write_chn_list[i];
	}

	for (i = 0; i < rdchn_cnt; i++) {
		if (read_chn_list[i] >= IOCTL_CHANNEL_NUM_MAX) {
			fprintf(stderr, "invalid read channel %d\n", read_chn_list[i]);
			return -1;
		}
		rtest.chn_list[wtchn_cnt + i] = read_chn_list[i];
	}

	snprintf(dev_path, DEVICE_PATH_MAX_LEN, "%s_%s", device, "control");

	fd = open(dev_path, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "unable to open device %s\n", dev_path);
		return -1;
	}

	ret = ioctl(fd, ANLOGIC_IOCRTEST, rtest);
	if (ret < 0) {
		fprintf(stderr, "do perf ops failed %d\n", ret);
		goto exit;
	}

	if (start)
		goto exit;

	for (i = 0; i < wtchn_cnt + rdchn_cnt; i++) {
		perf[i] = rtest.perf[i];
	}

exit:
	close(fd);
	return ret;
}

int main(int argc, char *argv[])
{
	int cmd_opt;
	char *device = DEVICE_NAME_DEFAULT;
	uint64_t address = 0;
	uint64_t size = SIZE_DEFAULT;
	uint64_t count = COUNT_DEFAULT;
	uint32_t desccount = DESC_COUNT_DEFAULT;
	uint64_t freq = CLK_FREQ_DEFAULT;
	char *read_chns = NULL;
	char *write_chns = NULL;
	int loopback = 0, checkdata = 0;
	int read_chn_list[MAX_READ_CHNS], rdchn_cnt = 0;
	int write_chn_list[MAX_WRITE_CHNS], wtchn_cnt = 0;
	int read_fds[MAX_READ_CHNS], write_fds[MAX_WRITE_CHNS];
	struct test_data *data;
	int test_cnt = 0;
	int buf_cnt = 0;
	char *buf = NULL;
	uint64_t aligned_size;
	uint64_t total_time, avg_bw;
	char *random = NULL;
	int perfops = -1;
	char *ifname = NULL;
	char *ofname = NULL;
	char *lenlist = NULL;
	char *ctllist = NULL;
	uint32_t *len_list = NULL;
	uint32_t *ctl_list = NULL;
	char *p;
	int len_cnt = 0;
	int chkeop = 0;
	int i;
	int ret;

	while ((cmd_opt = getopt_long(argc, argv, "vhd:lkr:w:a:s:c:C:R:f:p:i:o:", long_opts,
			    NULL)) != -1) {
		switch (cmd_opt) {
		case 0:
			/* long option */
			break;
		case 'd':
			/* device node name */
			device = strdup(optarg);
			break;
		case 'a':
			/* RAM address on the AXI bus in bytes */
			address = getopt_integer(optarg);
			break;
			/* RAM size in bytes */
		case 's':
			size = getopt_integer(optarg);
			break;
		case 'c':
			/* count */
			count = getopt_integer(optarg);
			break;
		case 'C':
			/* descriptor count */
			desccount = getopt_integer(optarg);
			break;
		case 'l':
			/* loopback */
			loopback = 1;
			break;
		case 'k':
			/* check */
			checkdata = 1;
			break;
		case 'r':
			/* read channels */
			read_chns = strdup(optarg);
			break;
		case 'w':
			/* write channels */
			write_chns = strdup(optarg);
			break;
		case 'R':
			/* random options */
			random = strdup(optarg);
			break;
		case 'f':
			/* clock frequency */
			freq = getopt_integer(optarg);
			if (freq == 0) {
				fprintf(stderr, "invalid frequency\n");
				exit(-EINVAL);
			}
			break;
		case 'p':
			/* performance ops */
			if (strcmp(optarg, "start") == 0)
				perfops = 1;
			else if (strcmp(optarg, "stop") == 0)
				perfops = 0;
			else {
				fprintf(stderr, "unknown perf option %s\n", optarg);
				exit(-EINVAL);
			}
			break;
		case 'i':
			/* input file name */
			ifname = strdup(optarg);
			break;
		case 'o':
			/* output file name */
			ofname = strdup(optarg);
			break;
		case 128:
			/* length list */
			lenlist = strdup(optarg);
			break;
		case 129:
			/* desc control list */
			ctllist = strdup(optarg);
			break;
		case 130:
			/* check eop */
			chkeop = 1;
			break;
		case 'v':
			verbose = 1;
			break;
		case 'h':
		default:
			usage(argv[0]);
			exit(0);
			break;
		}
	}

	if (read_chns)
		rdchn_cnt = parse_chn_list(read_chns, read_chn_list,
					   MAX_READ_CHNS);
	if (write_chns)
		wtchn_cnt = parse_chn_list(write_chns, write_chn_list,
					   MAX_WRITE_CHNS);
	if (!rdchn_cnt && !wtchn_cnt) {
		fprintf(stderr, "no channel specified\n");
		exit(-EINVAL);
	}

	if (perfops >= 0) {
		struct anlogic_perf_cnt perf[MAX_READ_CHNS + MAX_WRITE_CHNS];
		ret = perf_ops(device, perfops, write_chn_list, wtchn_cnt,
			       read_chn_list, rdchn_cnt, perf);
		if (ret < 0) {
			fprintf(stderr, "perf ops failed\n");
			exit(-EINVAL);
		}

		if (perfops == 0) {
			print_hwperf(write_chn_list, wtchn_cnt,
				     read_chn_list, rdchn_cnt,
				     perf, freq);
		}

		return 0;
	}

	if (loopback && rdchn_cnt != wtchn_cnt) {
		fprintf(stderr, "read and write channel count mismatch\n");
		exit(-EINVAL);
	}

	if (verbose) {
		fprintf(stdout,
			"dev %s, addr 0x%lx, size 0x%lx, count %lu, loopback=%d\n",
			device, address, size, count, loopback);

		fprintf(stdout, "read chns: ");
		for (i = 0; i < rdchn_cnt; i++)
			fprintf(stdout, "%d ", read_chn_list[i]);
		fprintf(stdout, "\n");

		fprintf(stdout, "write chns: ");
		for (i = 0; i < wtchn_cnt; i++)
			fprintf(stdout, "%d ", write_chn_list[i]);
		fprintf(stdout, "\n");
	}

	if (random) {
		struct anlogic_ioc_rtest rtest;
		char c;

		if ((wtchn_cnt + rdchn_cnt) > (IOCTL_CHANNEL_NUM_MAX * 2)) {
			fprintf(stderr, "channel count too large\n");
			exit(-EINVAL);
		}

		memset(&rtest, 0, sizeof(rtest));
		i = 0;
		while (random[i]) {
			c = random[i++];
			switch (c) {
			case 'a':
				rtest.flags |= RTFLG_BUF_ADDR;
				break;
			case 'e':
				rtest.flags |= RTFLG_EP_ADDR;
				break;
			case 'l':
				rtest.flags |= RTFLG_BUF_LEN;
				break;
			case 'c':
				rtest.flags |= RTFLG_COMPLETE_F;
				break;
			case 'C':
				rtest.flags |= RTFLG_CANCEL;
				break;
			case 'z':
				break;
			default:
				fprintf(stderr, "unknown random option %c\n", c);
				exit(-EINVAL);
			}
		}
		if (loopback)
			rtest.flags |= RTFLG_LOOPBACK;
		if (checkdata)
			rtest.flags |= RTFLG_CHKDATA;

		test_cnt = loopback ? rdchn_cnt : rdchn_cnt + wtchn_cnt;
		rtest.ep_addr = address;
		rtest.ep_len = size * test_cnt;
		rtest.count = count;
		rtest.desc_cnt = desccount;
		rtest.h2c_cnt = wtchn_cnt;
		rtest.c2h_cnt = rdchn_cnt;
		for (i = 0; i < wtchn_cnt; i++)
			rtest.chn_list[i] = write_chn_list[i];
		for (i = 0; i < rdchn_cnt; i++)
			rtest.chn_list[i + wtchn_cnt] = read_chn_list[i];

		ret = do_rtest(device, &rtest);
		if (ret)
			fprintf(stderr, "test failed, please check kernel log\n");
		else {
			printf("test pass\n");
			print_hwperf(&rtest.chn_list[0], rtest.h2c_cnt,
				     &rtest.chn_list[rtest.h2c_cnt], rtest.c2h_cnt,
				     rtest.perf, freq);
		}

		return ret;
	}

	if (open_chn_list("c2h", device, read_chn_list, rdchn_cnt, read_fds, chkeop) < 0)
		exit(-EINVAL);

	if (open_chn_list("h2c", device, write_chn_list, wtchn_cnt, write_fds, 0) < 0)
		exit(-EINVAL);

	if (lenlist) {
		len_list = calloc(desccount, sizeof(uint32_t));
		if (!len_list) {
			fprintf(stderr, "unable to allocate len list for %u descs\n",
				desccount);
			exit(-ENOMEM);
		}
		len_cnt = parse_uint32_list(lenlist, len_list, desccount);
		if (len_cnt <= 0) {
			fprintf(stderr, "invalid len list %s\n", lenlist);
			exit(-EINVAL);
		}

		if (ctllist) {
			ctl_list = calloc(desccount, sizeof(uint32_t));
			if (!ctl_list) {
				fprintf(stderr, "unable to allocate ctl list for %u descs\n",
					desccount);
				exit(-ENOMEM);
			}

			int ctl_cnt = parse_uint32_list(ctllist, ctl_list, desccount);
			if (ctl_cnt <= 0) {
				fprintf(stderr, "invalid ctl list %s\n", ctllist);
				exit(-EINVAL);
			}

			if (ctl_cnt != len_cnt) {
				fprintf(stderr, "error: ctl list count %d != len list count %d\n",
					ctl_cnt, len_cnt);
				exit(-EINVAL);
			}
		}

		for (i = 0, size = 0; i < len_cnt; i++) {
			if (len_list[i] == 0) {
				fprintf(stderr, "invalid length %u\n", len_list[i]);
				exit(-EINVAL);
			}
			size += len_list[i];
			if (verbose)
				printf("[%d](len, ctl) = (%u, %u)\n",
				       i, len_list[i], ctl_list ? ctl_list[i] : 0);
		}
		desccount = len_cnt;
	}

	aligned_size = (size + 4095) & ~4095;
	test_cnt = loopback ? rdchn_cnt : rdchn_cnt + wtchn_cnt;
	buf_cnt = rdchn_cnt + wtchn_cnt;

	ret = posix_memalign((void **)&buf, 4096, aligned_size * buf_cnt);
	if (ret) {
		fprintf(stderr, "unable to allocate buffer %lu\n",
			aligned_size * buf_cnt);
		exit(-ENOMEM);
	}

	p = calloc(test_cnt, sizeof(struct test_data) + desccount * sizeof(struct sgdma_desc_info));
	if (!p) {
		fprintf(stderr, "unable to allocate test data\n");
		exit(-ENOMEM);
	}
	data = (struct test_data *)p;
	p += sizeof(struct test_data) * test_cnt;

	for (i = 0; i < test_cnt; i++) {
		data[i].descs = (struct sgdma_desc_info *)(p + i * desccount * sizeof(struct sgdma_desc_info));
		address = ((address + 0xFF) & ~0xFFUL);
		if (loopback) {
			data[i].writefd = write_fds[i];
			data[i].readfd = read_fds[i];
			data[i].wtch = write_chn_list[i];
			data[i].rdch = read_chn_list[i];
			data[i].wtbuf = buf + i * 2 * aligned_size;
			data[i].rdbuf = data[i].wtbuf + aligned_size;
			data[i].ifname = ifname;
			data[i].ofname = ofname;
		} else if (i < rdchn_cnt) {
			data[i].writefd = -1;
			data[i].readfd = read_fds[i];
			data[i].wtch = -1;
			data[i].rdch = read_chn_list[i];
			data[i].wtbuf = NULL;
			data[i].rdbuf = buf + i * aligned_size;
			data[i].ifname = NULL;
			data[i].ofname = ofname;
		} else {
			data[i].writefd = write_fds[i - rdchn_cnt];
			data[i].readfd = -1;
			data[i].wtch = write_chn_list[i - rdchn_cnt];
			data[i].rdch = -1;
			data[i].wtbuf = buf + i * aligned_size;
			data[i].rdbuf = NULL;
			data[i].ifname = ifname;
			data[i].ofname = NULL;
		}

		if (len_list) {
			for (int j = 0; j < desccount; j++) {
				data[i].descs[j].len = len_list[j];
				data[i].descs[j].control = (ctl_list ? ctl_list[j] : 0);
			}
			data[i].use_lens = 1;

			if (ctl_list)
				data[i].use_ctls = 1;
		}
		data[i].desccnt = desccount;
		data[i].index = i;
		data[i].addr = address;
		data[i].size = size;
		data[i].count = count;
		data[i].ret = 0;
		data[i].chkdata = checkdata;
		address += size;

		ret = pthread_create(&data[i].thread, NULL, test_thread,
				     &data[i]);
		if (ret) {
			fprintf(stderr, "unable to create thread %d\n", i);
		}
	}

	while (1) {
		for (i = 0; i < test_cnt; i++) {
			if (data[i].thread && data[i].ret == 0)
				break;
		}

		if (i == test_cnt)
			break;

		usleep(100);
	}

	for (i = 0; i < test_cnt; i++) {
		if (data[i].ret > 0) {
			total_time = data[i].total_time;
			avg_bw = (loopback ? 2 : 1) * data[i].size * data[i].count * (unsigned long)1e+9 / total_time;
			fprintf(stdout, "test %d finish: total_time=%ldns, avg_time=%ldns, avg_bw=%ldB/s(%.6fGB/s)\n", data[i].index,
				(long)total_time, (long)total_time / data[i].count,
				(long)avg_bw, ((double)avg_bw) / (1024 * 1024 * 1024));
		} else {
			fprintf(stderr, "test %d failed\n", data[i].index);
		}
	}

	return 0;
}
