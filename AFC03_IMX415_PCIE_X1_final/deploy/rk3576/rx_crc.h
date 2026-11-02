/* Reflected IEEE CRC32. Each backend takes/returns the uncomplemented
 * running state; the frame footer still uses exactly one final complement. */
static uint32_t crc_table[8][256];
typedef uint32_t (*crc_fn_t)(uint32_t,const uint8_t *,size_t);
static crc_fn_t selected_crc;
static const char *crc_backend;
static void crc32_init(void)
{
    for (unsigned i=0;i<256;++i) {
        uint32_t c=i;
        for (int k=0;k<8;++k) c=(c>>1)^((c&1)?0xedb88320u:0);
        crc_table[0][i]=c;
    }
    for (unsigned k=1;k<8;++k)
        for (unsigned i=0;i<256;++i) {
            uint32_t c=crc_table[k-1][i];
            crc_table[k][i]=(c>>8)^crc_table[0][c&255u];
        }
}
static uint32_t crc32_table(uint32_t c,const uint8_t *p,size_t n)
{
    while(n--) c=(c>>8)^crc_table[0][(c^*p++)&255u];
    return c;
}
static uint32_t crc32_slice8(uint32_t c,const uint8_t *p,size_t n)
{
    while(n>=8) {
        uint32_t a=c^(uint32_t)p[0]^((uint32_t)p[1]<<8)^
                     ((uint32_t)p[2]<<16)^((uint32_t)p[3]<<24);
        c=crc_table[7][a&255u]^crc_table[6][(a>>8)&255u]^
          crc_table[5][(a>>16)&255u]^crc_table[4][a>>24]^
          crc_table[3][p[4]]^crc_table[2][p[5]]^
          crc_table[1][p[6]]^crc_table[0][p[7]];
        p+=8;n-=8;
    }
    return crc32_table(c,p,n);
}
#if defined(__aarch64__) && defined(__linux__) && defined(__BYTE_ORDER__) && \
    __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define RX_HAVE_ARM_CRC32 1
#include <sys/auxv.h>
#include <asm/hwcap.h>
__attribute__((target("arch=armv8-a+crc")))
static uint32_t crc32_arm(uint32_t c,const uint8_t *p,size_t n)
{
    while(n>=8) {
        uint64_t word;
        memcpy(&word,p,8);
        __asm__("crc32x %w0, %w0, %1" : "+r"(c) : "r"(word));
        p+=8;n-=8;
    }
    while(n--) {
        uint32_t byte=*p++;
        __asm__("crc32b %w0, %w0, %w1" : "+r"(c) : "r"(byte));
    }
    return c;
}
static int arm_crc_available(void)
{ return (getauxval(AT_HWCAP)&HWCAP_CRC32)!=0; }
#endif
static int crc_select(const char *name)
{
    if(!strcmp(name,"table")) { selected_crc=crc32_table;crc_backend="table";return 0; }
    if(!strcmp(name,"slice8")) { selected_crc=crc32_slice8;crc_backend="slice8";return 0; }
#if defined(RX_HAVE_ARM_CRC32)
    if((!strcmp(name,"auto") || !strcmp(name,"arm")) && arm_crc_available()) {
        selected_crc=crc32_arm;crc_backend="arm";return 0;
    }
#endif
    if(!strcmp(name,"auto")) { selected_crc=crc32_slice8;crc_backend="slice8";return 0; }
    fprintf(stderr,"CRC backend '%s' unavailable; choose auto, table, slice8 or supported arm\n",name);
    return -1;
}
static uint32_t crc32_update(uint32_t c,const uint8_t *p,size_t n)
{ return selected_crc(c,p,n); }

static int crc_self_test(void)
{
    uint8_t data[1040];uint32_t random=0x35762816u;
    crc_fn_t backends[3]={crc32_table,crc32_slice8,NULL};
    const char *names[3]={"table","slice8","arm"};
#if defined(RX_HAVE_ARM_CRC32)
    if(arm_crc_available()) backends[2]=crc32_arm;
#endif
    for(size_t i=0;i<sizeof(data);++i) {
        random=random*1664525u+1013904223u;data[i]=(uint8_t)(random>>24);
    }
    for(unsigned b=0;b<3;++b) if(backends[b]) {
        if(~backends[b](0xffffffffu,(const uint8_t *)"123456789",9)!=0xcbf43926u)
            return -1;
        for(size_t off=0;off<8;++off) for(size_t n=0;n<=1024;++n) {
            random=random*1664525u+1013904223u;
            uint32_t expected=crc32_table(random,data+off,n);
            uint32_t got=backends[b](random,data+off,n);
            size_t split=n/3;
            uint32_t incremental=backends[b](random,data+off,split);
            incremental=backends[b](incremental,data+off+split,n-split);
            if(got!=expected || incremental!=expected) return -1;
        }
        printf("PASS CRC %s: IEEE vector, offsets, lengths 0..1024, random initial state and split updates\n",names[b]);
    }
    return 0;
}
