/* Aggregate synchronous char-device 4096-byte ST C2H reads. Default OFF. */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/math64.h>
#include <linux/mm.h>
#include "st_c2h_profile.h"

static bool st_c2h_profile;
static DEFINE_SPINLOCK(profile_lock);
static u64 profile_epoch = 1;

struct profile_totals {
	u64 calls, errors, short_reads, zero_reads, requested_bytes, completed_bytes;
	u64 first_ns, last_ns, total_ns, max_total_ns, poll_empty;
	u64 ns[ST_PROF_STAGES];
	u64 wait_spin_calls, wait_spin_ready, wait_spin_ns;
};
static struct profile_totals totals;

static int profile_set(const char *value, const struct kernel_param *kp)
{
	bool enabled;
	unsigned long flags;
	int rc = kstrtobool(value, &enabled);
	(void)kp;
	if (rc)
		return rc;
	spin_lock_irqsave(&profile_lock, flags);
	if (enabled) {
		memset(&totals, 0, sizeof(totals));
		++profile_epoch;
	}
	WRITE_ONCE(st_c2h_profile, enabled);
	spin_unlock_irqrestore(&profile_lock, flags);
	return 0;
}

static const struct kernel_param_ops enable_ops = {
	.set = profile_set,
	.get = param_get_bool,
};
module_param_cb(st_c2h_profile, &enable_ops, &st_c2h_profile, 0644);
MODULE_PARM_DESC(st_c2h_profile,
	"Time synchronous 4096-byte char ST C2H reads; write 1 while idle to reset/start, 0 to stop");

bool st_profile_begin(struct st_profile_call *call)
{
	unsigned long flags;
	if (!READ_ONCE(st_c2h_profile))
		return false;
	memset(call, 0, sizeof(*call));
	spin_lock_irqsave(&profile_lock, flags);
	if (!st_c2h_profile) {
		spin_unlock_irqrestore(&profile_lock, flags);
		return false;
	}
	call->epoch = profile_epoch;
	spin_unlock_irqrestore(&profile_lock, flags);
	call->start_ns = ktime_get_ns();
	return true;
}

void st_profile_end(struct st_profile_call *call, size_t requested, ssize_t result)
{
	u64 end = ktime_get_ns();
	u64 duration = end - call->start_ns;
	unsigned long flags;
	unsigned int i;
	spin_lock_irqsave(&profile_lock, flags);
	/* A reset never mixes an old, still retiring read into a new epoch. */
	if (call->epoch == profile_epoch) {
		++totals.calls;
		if (result < 0)
			++totals.errors;
		else {
			totals.completed_bytes += result;
			if (!result)
				++totals.zero_reads;
			else if (result < requested)
				++totals.short_reads;
		}
		totals.requested_bytes += requested;
		if (!totals.first_ns || call->start_ns < totals.first_ns)
			totals.first_ns = call->start_ns;
		if (end > totals.last_ns)
			totals.last_ns = end;
		totals.total_ns += duration;
		if (duration > totals.max_total_ns)
			totals.max_total_ns = duration;
		for (i = 0; i < ST_PROF_STAGES; ++i)
			totals.ns[i] += call->ns[i];
		totals.wait_spin_calls += call->wait_spin_calls;
		totals.wait_spin_ready += call->wait_spin_ready;
		totals.wait_spin_ns += call->wait_spin_ns;
	}
	spin_unlock_irqrestore(&profile_lock, flags);
}

void st_profile_poll_empty(void)
{
	unsigned long flags;
	if (!READ_ONCE(st_c2h_profile))
		return;
	spin_lock_irqsave(&profile_lock, flags);
	if (st_c2h_profile)
		++totals.poll_empty;
	spin_unlock_irqrestore(&profile_lock, flags);
}

static int profile_stats_get(char *buffer, const struct kernel_param *kp)
{
	static const char * const names[ST_PROF_STAGES] = {
		"user_map", "submit", "dma_map", "request_build", "desc_lock",
		"desc_build", "queue_start", "poll_kick", "completion_wait",
		"completion_reap", "submit_cleanup", "user_unmap"
	};
	struct profile_totals snapshot;
	unsigned long flags;
	u64 epoch;
	bool enabled;
	unsigned int i;
	int used;
	(void)kp;
	spin_lock_irqsave(&profile_lock, flags);
	snapshot = totals;
	epoch = profile_epoch;
	enabled = st_c2h_profile;
	spin_unlock_irqrestore(&profile_lock, flags);
	used = scnprintf(buffer, PAGE_SIZE,
		"version=dma-profile-20261016\nenabled=%u\nepoch=%llu\n"
		"filter=char_st_c2h_read_4096\ncalls=%llu\nerrors=%llu\n"
		"short_reads=%llu\nzero_reads=%llu\nrequested_bytes=%llu\n"
		"completed_bytes=%llu\nelapsed_ns=%llu\ntotal_ns=%llu\n"
		"max_total_ns=%llu\npoll_empty=%llu\n",
		enabled, (unsigned long long)epoch,
		(unsigned long long)snapshot.calls, (unsigned long long)snapshot.errors,
		(unsigned long long)snapshot.short_reads, (unsigned long long)snapshot.zero_reads,
		(unsigned long long)snapshot.requested_bytes,
		(unsigned long long)snapshot.completed_bytes,
		(unsigned long long)(snapshot.last_ns - snapshot.first_ns),
		(unsigned long long)snapshot.total_ns,
		(unsigned long long)snapshot.max_total_ns,
		(unsigned long long)snapshot.poll_empty);
	for (i = 0; i < ST_PROF_STAGES; ++i)
		used += scnprintf(buffer + used, PAGE_SIZE - used, "%s_ns=%llu\n",
			names[i], (unsigned long long)snapshot.ns[i]);
	used += scnprintf(buffer + used, PAGE_SIZE - used,
		"wait_spin_calls=%llu\nwait_spin_ready=%llu\nwait_spin_ns=%llu\n",
		(unsigned long long)snapshot.wait_spin_calls,
		(unsigned long long)snapshot.wait_spin_ready,
		(unsigned long long)snapshot.wait_spin_ns);
	return used;
}

static const struct kernel_param_ops stats_ops = {
	.get = profile_stats_get,
};
module_param_cb(st_c2h_profile_stats, &stats_ops, NULL, 0444);
MODULE_PARM_DESC(st_c2h_profile_stats, "Read-only aggregate stage timings in nanoseconds");
