/* Exactly two reusable raw frame buffers. The producer may fill one while
 * the writer owns the other; a buffer stays owned until its entire frame is
 * written. No frame is displayed or counted before CRC/decode validation. */
#define OUTPUT_SLOTS 2
typedef struct {
    uint8_t *raw;
    size_t cap,n;
    lz77_meta_t meta;
} output_frame_t;
typedef struct {
    output_frame_t slots[OUTPUT_SLOTS];
    size_t head,tail,used,high_water;
    int finish,abort,done,stdout_rgb24,verbose;
    const char *prefix;
    FILE *log_output;
    rx_stats_t *stats;
    double output_seconds;
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t changed;
} output_queue_t;

static int output_frame_write(output_queue_t *q,output_frame_t *f)
{
    if(q->stdout_rgb24) {
        size_t sent=0;
        while(sent<f->n && !stop_signal) {
            pthread_setcancelstate(PTHREAD_CANCEL_ENABLE,NULL);
            ssize_t n=write(STDOUT_FILENO,f->raw+sent,f->n-sent);
            int code=errno;
            pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,NULL);
            errno=code;
            if(n<0 && errno==EINTR) continue;
            if(n<=0) { perror("RGB24 output");return -1; }
            sent+=(size_t)n;
        }
        if(sent!=f->n) return -1;
    }
    if(write_frame(q->prefix,f->meta.frame_id,f->raw,f->n)<0) return -1;
    if(q->verbose)
        fprintf(q->log_output,"frame=%" PRIu32 " %ux%u raw=%" PRIu32
                " compressed=%" PRIu32 " tokens=%" PRIu32 " crc=%08" PRIx32 "\n",
                f->meta.frame_id,f->meta.width,f->meta.height,f->meta.raw_len,
                f->meta.comp_len,f->meta.tokens,f->meta.crc32);
    return 0;
}
static void *output_thread(void *arg)
{
    output_queue_t *q=arg;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,NULL);
    for(;;) {
        pthread_mutex_lock(&q->lock);
        while(!q->used && !q->finish && !q->abort && !stop_signal)
            queue_wait(&q->changed,&q->lock);
        if(q->abort || stop_signal || (!q->used && q->finish)) {
            q->done=1;pthread_cond_broadcast(&q->changed);
            pthread_mutex_unlock(&q->lock);return NULL;
        }
        output_frame_t *f=&q->slots[q->tail];
        pthread_mutex_unlock(&q->lock);
        double start=monotonic_s();
        int rc=output_frame_write(q,f);
        pthread_mutex_lock(&q->lock);
        q->output_seconds+=monotonic_s()-start;
        if(rc<0) {
            atomic_store(&pipeline_failed,1);
            q->abort=1;q->done=1;
        } else {
            ++q->stats->frames;
            q->stats->raw_bytes+=f->n;
            q->stats->compressed_bytes+=f->meta.comp_len;
            q->tail=(q->tail+1)%OUTPUT_SLOTS;--q->used;
        }
        pthread_cond_broadcast(&q->changed);
        pthread_mutex_unlock(&q->lock);
        if(rc<0) return NULL;
    }
}
static int output_start(output_queue_t *q,rx_stats_t *stats,int stdout_rgb24,
                        const char *prefix,int verbose,FILE *log_output)
{
    int rc;
    memset(q,0,sizeof(*q));q->stats=stats;q->stdout_rgb24=stdout_rgb24;
    q->prefix=prefix;q->verbose=verbose;q->log_output=log_output;
    if((rc=pthread_mutex_init(&q->lock,NULL))!=0) {errno=rc;return -1;}
    if((rc=pthread_cond_init(&q->changed,NULL))!=0) {
        pthread_mutex_destroy(&q->lock);errno=rc;return -1;
    }
    if((rc=pthread_create(&q->thread,NULL,output_thread,q))!=0) {
        pthread_cond_destroy(&q->changed);pthread_mutex_destroy(&q->lock);
        errno=rc;return -1;
    }
    return 0;
}
static output_frame_t *output_acquire(output_queue_t *q)
{
    pthread_mutex_lock(&q->lock);
    while(q->used==OUTPUT_SLOTS && !q->abort && !stop_signal)
        queue_wait(&q->changed,&q->lock);
    output_frame_t *f=(q->abort || stop_signal) ? NULL : &q->slots[q->head];
    pthread_mutex_unlock(&q->lock);
    return f;
}
static void output_submit(output_queue_t *q,output_frame_t *f,
                          const lz77_meta_t *m,size_t n)
{
    pthread_mutex_lock(&q->lock);
    f->meta=*m;f->n=n;
    q->head=(q->head+1)%OUTPUT_SLOTS;++q->used;
    if(q->used>q->high_water) q->high_water=q->used;
    pthread_cond_signal(&q->changed);
    pthread_mutex_unlock(&q->lock);
}
static void output_profile(output_queue_t *q,rx_stats_t *st,double started)
{
    pthread_mutex_lock(&q->lock);
    rx_stats_t copy=*st;
    copy.frames=q->stats->frames;copy.raw_bytes=q->stats->raw_bytes;
    copy.compressed_bytes=q->stats->compressed_bytes;
    output_seconds=q->output_seconds;
    pthread_mutex_unlock(&q->lock);
    report_profile(&copy,started);
}
static uint64_t output_frames(output_queue_t *q)
{
    pthread_mutex_lock(&q->lock);
    uint64_t n=q->stats->frames;
    pthread_mutex_unlock(&q->lock);return n;
}
static void output_stop(output_queue_t *q,int aborting)
{
    pthread_mutex_lock(&q->lock);q->finish=1;q->abort|=aborting;
    pthread_cond_broadcast(&q->changed);
    while(!q->done && !q->abort && !stop_signal)
        queue_wait(&q->changed,&q->lock);
    int cancel=!q->done;
    if(cancel) q->abort=1;
    pthread_cond_broadcast(&q->changed);pthread_mutex_unlock(&q->lock);
    if(cancel) pthread_cancel(q->thread);
    pthread_join(q->thread,NULL);
    output_seconds=q->output_seconds;
    fprintf(stderr,"PIPELINE_OUTPUT buffers=%u high_water=%zu raw_capacity=%zu,%zu\n",
            OUTPUT_SLOTS,q->high_water,q->slots[0].cap,q->slots[1].cap);
    for(size_t i=0;i<OUTPUT_SLOTS;++i) free(q->slots[i].raw);
    pthread_cond_destroy(&q->changed);pthread_mutex_destroy(&q->lock);
}
