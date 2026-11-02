/* Optional diagnostics only; no DMA ownership/descriptor changes. */
#ifndef ST_C2H_PROFILE_H
#define ST_C2H_PROFILE_H

#include <linux/types.h>
#include <linux/ktime.h>

enum st_profile_stage {
	ST_PROF_USER_MAP,
	ST_PROF_SUBMIT,
	ST_PROF_DMA_MAP,
	ST_PROF_REQUEST,
	ST_PROF_DESC_LOCK,
	ST_PROF_DESC_BUILD,
	ST_PROF_QUEUE,
	ST_PROF_KICK,
	ST_PROF_WAIT,
	ST_PROF_REAP,
	ST_PROF_SUBMIT_CLEANUP,
	ST_PROF_USER_UNMAP,
	ST_PROF_STAGES
};

struct st_profile_call {
	u64 epoch, start_ns;
	u64 ns[ST_PROF_STAGES];
	u64 wait_spin_calls, wait_spin_ready, wait_spin_ns;
};

bool st_profile_begin(struct st_profile_call *call);
void st_profile_end(struct st_profile_call *call, size_t requested, ssize_t result);
void st_profile_poll_empty(void);

/* Optional counters nested inside completion_wait, never extra DMA work. */
static inline void st_profile_wait_spin(struct st_profile_call *call,
				       u64 duration, bool ready)
{
	if (call) {
		++call->wait_spin_calls;
		call->wait_spin_ready += ready;
		call->wait_spin_ns += duration;
	}
}

static inline u64 st_profile_clock(struct st_profile_call *call)
{
	return call ? ktime_get_ns() : 0;
}

static inline void st_profile_add(struct st_profile_call *call,
				 enum st_profile_stage stage, u64 start)
{
	if (call)
		call->ns[stage] += ktime_get_ns() - start;
}

struct sg_table;
ssize_t sgdma_xfer_submit_profiled(void *dev_hndl, int channel, bool write,
		u64 ep_addr, struct sg_table *sgt, bool dma_mapped, int timeout_ms,
		u32 *controls, struct st_profile_call *profile);

#endif
