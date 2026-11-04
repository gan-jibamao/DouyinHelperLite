/*
 * 离线验证 DHLFLVParser 的解析逻辑（用 C 重实现同一算法，跑真实构造的 FLV 字节流）
 * 编译：clang -o flvtest flvtest.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef struct {
    uint8_t  type;
    uint32_t timestamp;
    uint32_t size;
    uint8_t *payload;
} Tag;

typedef struct {
    uint8_t *buf;
    size_t   len;
    size_t   cap;
    int      validated;
    int      sawPrev;
    int      rejected;
    unsigned long long consumed;
} Parser;

static void pinit(Parser *p) {
    p->buf = malloc(256 * 1024);
    p->len = 0;
    p->cap = 256 * 1024;
    p->validated = 0;
    p->sawPrev = 0;
    p->rejected = 0;
    p->consumed = 0;
}

static void pappend(Parser *p, const uint8_t *d, size_t n) {
    if (p->len + n > p->cap) {
        while (p->len + n > p->cap) p->cap *= 2;
        p->buf = realloc(p->buf, p->cap);
    }
    memcpy(p->buf + p->len, d, n);
    p->len += n;
}

static void pdrop(Parser *p, size_t n) {
    if (n >= p->len) { p->len = 0; return; }
    memmove(p->buf, p->buf + n, p->len - n);
    p->len -= n;
}

/* 返回解析出的 tag 数；out 最多 cap 个 */
static int parse(Parser *p, Tag *out, int cap) {
    int n = 0;
    if (p->rejected) return 0;

    if (!p->validated) {
        if (p->len < 9) return 0;
        if (memcmp(p->buf, "FLV", 3) != 0) { p->rejected = 1; return 0; }
        uint32_t hs = ((uint32_t)p->buf[5] << 24) | ((uint32_t)p->buf[6] << 16) |
                      ((uint32_t)p->buf[7] << 8) | p->buf[8];
        if (hs < 9 || hs > 1024) hs = 9;
        if (p->len < hs) return 0;
        pdrop(p, hs);
        p->consumed += hs;
        p->validated = 1;
    }

    if (!p->sawPrev) {
        if (p->len < 4) return 0;
        pdrop(p, 4);
        p->consumed += 4;
        p->sawPrev = 1;
    }

    while (p->len >= 11) {
        const uint8_t *b = p->buf;
        uint8_t  type = b[0] & 0x1F;
        uint32_t ds = ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
        uint32_t tl = ((uint32_t)b[4] << 16) | ((uint32_t)b[5] << 8) | b[6];
        uint32_t te = b[7];
        uint32_t ts = (te << 24) | tl;

        if (ds > 16u * 1024u * 1024u) { p->rejected = 1; return n; }

        size_t need = 11 + ds + 4;
        if (p->len < need) break;

        if (n < cap && (type == 8 || type == 9 || type == 18)) {
            out[n].type = type;
            out[n].timestamp = ts;
            out[n].size = ds;
            out[n].payload = malloc(ds ? ds : 1);
            memcpy(out[n].payload, b + 11, ds);
            n++;
        }
        pdrop(p, need);
        p->consumed += need;
    }
    return n;
}

/* ---- 构造一个真实结构的 FLV 流 ---- */
static size_t build_flv(uint8_t *o) {
    size_t i = 0;
    /* header */
    memcpy(o, "FLV\x01\x05\x00\x00\x00\x09", 9); i = 9;
    /* PreviousTagSize0 = 0 */
    o[i++] = 0; o[i++] = 0; o[i++] = 0; o[i++] = 0;

    /* tag 1: 视频 AVCDecoderConfigurationRecord, ts=0 */
    {
        uint8_t pl[32];
        int k = 0;
        pl[k++] = 0x17;          /* keyframe + AVC */
        pl[k++] = 0x00;          /* AVCPacketType=0 (seq header) */
        pl[k++] = 0; pl[k++] = 0; pl[k++] = 0;   /* CTS */
        pl[k++] = 0x01;          /* configurationVersion */
        pl[k++] = 0x42;          /* AVCProfileIndication */
        pl[k++] = 0x00;          /* profile_compat */
        pl[k++] = 0x1E;          /* AVCLevelIndication */
        pl[k++] = 0xFF;          /* lengthSizeMinusOne = 3 */
        pl[k++] = 0xE1;          /* numOfSPS = 1 */
        pl[k++] = 0x00; pl[k++] = 0x04;   /* sps len = 4 */
        pl[k++] = 0x67; pl[k++] = 0x42; pl[k++] = 0x00; pl[k++] = 0x1E;
        pl[k++] = 0x01;          /* numOfPPS = 1 */
        pl[k++] = 0x00; pl[k++] = 0x02;
        pl[k++] = 0x68; pl[k++] = 0xCE;

        o[i++] = 0x09;
        uint32_t ds = 5 + 22;
        o[i++] = (uint8_t)(ds >> 16);
        o[i++] = (uint8_t)(ds >> 8);
        o[i++] = (uint8_t)ds;
        uint32_t ts = 0;
        o[i++] = (ts >> 16) & 0xFF;
        o[i++] = (ts >> 8) & 0xFF;
        o[i++] = ts & 0xFF;
        o[i++] = (ts >> 24) & 0xFF;
        o[i++] = 0; o[i++] = 0; o[i++] = 0;   /* streamID */
        memcpy(o + i, pl, 5 + 22); i += 5 + 22;
        /* prevTagSize */
        uint32_t pv = 11 + 5 + 22;
        o[i++] = pv >> 24; o[i++] = (pv >> 16) & 0xFF; o[i++] = (pv >> 8) & 0xFF; o[i++] = pv & 0xFF;
    }

    /* tag 2: 音频 AAC sequence header, ts=0 */
    {
        o[i++] = 0x08;
        uint32_t ds = 4;
        o[i++] = ds >> 16; o[i++] = (ds >> 8) & 0xFF; o[i++] = ds & 0xFF;
        o[i++] = 0; o[i++] = 0; o[i++] = 0;
        o[i++] = 0;
        o[i++] = 0; o[i++] = 0; o[i++] = 0;
        o[i++] = 0xAF;   /* AAC 44k stereo */
        o[i++] = 0x00;   /* AAC sequence header */
        o[i++] = 0x12;   /* ASC: 44100, 2ch */
        o[i++] = 0x10;
        uint32_t pv = 11 + 4;
        o[i++] = pv >> 24; o[i++] = (pv >> 16) & 0xFF; o[i++] = (pv >> 8) & 0xFF; o[i++] = pv & 0xFF;
    }

    /* tag 3: 视频 NALU, ts=40 */
    {
        uint8_t pl[16];
        int k = 0;
        pl[k++] = 0x27;  /* inter frame + AVC */
        pl[k++] = 0x01;  /* AVCPacketType=1 NALU */
        pl[k++] = 0; pl[k++] = 0; pl[k++] = 0;
        /* AVCC length-prefixed NAL */
        pl[k++] = 0x00; pl[k++] = 0x00; pl[k++] = 0x00; pl[k++] = 0x02;
        pl[k++] = 0x41; pl[k++] = 0x9A;
        pl[k++] = 0x00; pl[k++] = 0x00; pl[k++] = 0x00; pl[k++] = 0x01;
        pl[k++] = 0x65;

        o[i++] = 0x09;
        uint32_t ds = k;
        o[i++] = ds >> 16; o[i++] = (ds >> 8) & 0xFF; o[i++] = ds & 0xFF;
        uint32_t ts = 40;
        o[i++] = (ts >> 16) & 0xFF; o[i++] = (ts >> 8) & 0xFF; o[i++] = ts & 0xFF;
        o[i++] = (ts >> 24) & 0xFF;
        o[i++] = 0; o[i++] = 0; o[i++] = 0;
        memcpy(o + i, pl, k); i += k;
        uint32_t pv = 11 + ds;
        o[i++] = pv >> 24; o[i++] = (pv >> 16) & 0xFF; o[i++] = (pv >> 8) & 0xFF; o[i++] = pv & 0xFF;
    }

    /* tag 4: 音频 AAC raw, ts=64 */
    {
        o[i++] = 0x08;
        uint32_t ds = 4;
        o[i++] = ds >> 16; o[i++] = (ds >> 8) & 0xFF; o[i++] = ds & 0xFF;
        uint32_t ts = 64;
        o[i++] = (ts >> 16) & 0xFF; o[i++] = (ts >> 8) & 0xFF; o[i++] = ts & 0xFF;
        o[i++] = (ts >> 24) & 0xFF;
        o[i++] = 0; o[i++] = 0; o[i++] = 0;
        o[i++] = 0xAF; o[i++] = 0x01; o[i++] = 0xAA; o[i++] = 0xBB;
        uint32_t pv = 11 + 4;
        o[i++] = pv >> 24; o[i++] = (pv >> 16) & 0xFF; o[i++] = (pv >> 8) & 0xFF; o[i++] = pv & 0xFF;
    }

    return i;
}

int main(void) {
    uint8_t stream[4096];
    size_t n = build_flv(stream);
    printf("构造 FLV 总长 %zu 字节\n", n);

    /* --- 场景 A：一次性喂完 --- */
    {
        Parser p; pinit(&p);
        pappend(&p, stream, n);
        Tag tags[16];
        int t = parse(&p, tags, 16);
        printf("\n[A] 一次性喂入 → 解析出 %d 个 tag\n", t);
        for (int i = 0; i < t; i++)
            printf("    type=%u ts=%u size=%u\n", tags[i].type, tags[i].timestamp, tags[i].size);
        printf("    headerValidated=%d consumed=%llu\n", p.validated, p.consumed);
        if (t != 4) { printf("    !! 期望 4 个 tag\n"); return 1; }
        if (tags[0].type != 9 || tags[0].timestamp != 0) { printf("    !! tag0 不对\n"); return 1; }
        if (tags[1].type != 8) { printf("    !! tag1 不对\n"); return 1; }
        if (tags[2].type != 9 || tags[2].timestamp != 40) { printf("    !! tag2 ts 不对\n"); return 1; }
        if (tags[3].type != 8 || tags[3].timestamp != 64) { printf("    !! tag3 ts 不对\n"); return 1; }
        printf("    ✅ 场景 A 通过\n");
        for (int i = 0; i < t; i++) free(tags[i].payload);
        free(p.buf);
    }

    /* --- 场景 B：分片喂入（模拟网络分包） --- */
    {
        Parser p; pinit(&p);
        Tag all[16]; int total = 0;
        size_t chunk = 7;
        for (size_t off = 0; off < n; off += chunk) {
            size_t take = (off + chunk <= n) ? chunk : (n - off);
            pappend(&p, stream + off, take);
            Tag t[16];
            int got = parse(&p, t, 16);
            for (int i = 0; i < got && total < 16; i++) all[total++] = t[i];
        }
        printf("\n[B] 每 %zu 字节喂一次 → 解析出 %d 个 tag\n", chunk, total);
        for (int i = 0; i < total; i++)
            printf("    type=%u ts=%u size=%u\n", all[i].type, all[i].timestamp, all[i].size);
        if (total != 4) { printf("    !! 分片解析丢包\n"); return 1; }
        int ok = 1;
        static const uint8_t expect[4] = {9, 8, 9, 8};
        for (int i = 0; i < 4; i++)
            if (all[i].type != expect[i]) ok = 0;
        if (!ok) { printf("    !! tag 序列不对\n"); return 1; }
        printf("    ✅ 场景 B 通过（分片无丢失）\n");
        free(p.buf);
    }

    /* --- 场景 C：非 FLV 流应被拒绝 --- */
    {
        Parser p; pinit(&p);
        const char *html = "<!doctype html><html>error</html>";
        pappend(&p, (const uint8_t *)html, strlen(html));
        Tag t[4];
        int got = parse(&p, t, 4);
        printf("\n[C] 喂入 HTML → 解析 %d 个 tag, rejected=%d\n", got, p.rejected);
        if (!p.rejected) { printf("    !! 应拒绝\n"); return 1; }
        printf("    ✅ 场景 C 通过（正确拒绝非 FLV）\n");
        free(p.buf);
    }

    printf("\n全部通过\n");
    return 0;
}
