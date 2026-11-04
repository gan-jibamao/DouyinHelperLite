/*
 * 验证 DHLScanBalancedJSON 的括号配平逻辑，对比原版非贪婪正则的失败场景
 */
#include <stdio.h>
#include <string.h>

/* ---- 原版做法：等价于 "stream_data":\s*(\{.*?\}) 的非贪婪匹配 ---- */
static void orig_extract(const char *html, char *out, size_t cap) {
    const char *k = strstr(html, "\"stream_data\"");
    out[0] = 0;
    if (!k) return;
    const char *b = strchr(k, '{');
    if (!b) return;
    /* 非贪婪：到第一个 } 就停 */
    const char *e = strchr(b, '}');
    if (!e) return;
    size_t n = (size_t)(e - b + 1);
    if (n >= cap) n = cap - 1;
    memcpy(out, b, n);
    out[n] = 0;
}

/* ---- 新做法：括号配平，跳过字符串内的括号 ---- */
static int balanced_extract(const char *html, char *out, size_t cap) {
    const char *k = strstr(html, "\"stream_data\"");
    out[0] = 0;
    if (!k) return 0;
    const char *b = strchr(k, '{');
    if (!b) return 0;

    int depth = 0, inStr = 0, esc = 0;
    const char *p = b;
    for (; *p; p++) {
        char c = *p;
        if (inStr) {
            if (esc) esc = 0;
            else if (c == '\\') esc = 1;
            else if (c == '"') inStr = 0;
            continue;
        }
        if (c == '"') inStr = 1;
        else if (c == '{') depth++;
        else if (c == '}') {
            depth--;
            if (depth == 0) {
                size_t n = (size_t)(p - b + 1);
                if (n >= cap) n = cap - 1;
                memcpy(out, b, n);
                out[n] = 0;
                return 1;
            }
        }
    }
    return 0;
}

int main(void) {
    /* 真实结构：stream_data 里嵌 stream_url，stream_url 里再嵌 flv_pull_url */
    const char *html =
        "<html><script>window.__DATA__={\"stream_data\":"
        "{\"data\":[{\"id\":\"7400000000000000001\","
        "\"stream_info\":{\"flv_pull_url\":{\"FULL_HD\":\"https://x/a_uhd.flv\",\"HD\":\"https://x/a_hd.flv\"}},"
        "\"status\":4}],\"extra\":{\"k\":\"v\"}},"
        "\"other\":1}</script></html>";

    char a[2048], b[2048];
    orig_extract(html, a, sizeof(a));
    int ok = balanced_extract(html, b, sizeof(b));

    printf("原版非贪婪正则取出：\n  %s\n\n", a);
    printf("括号配平取出：\n  %s\n\n", b);
    printf("配平成功=%d\n", ok);

    size_t la = strlen(a), lb = strlen(b);
    printf("\n长度对比：原版 %zu 字节 / 配平 %zu 字节\n", la, lb);

    if (lb > la) {
        printf("✅ 配平版取到了完整嵌套结构\n");
    }
    if (strstr(b, "flv_pull_url")) {
        printf("✅ 配平版包含 flv_pull_url（原版 %s）\n",
               strstr(a, "flv_pull_url") ? "也有" : "没有 -> 会漏掉流地址");
    } else {
        printf("❌ 配平版也没取到\n");
        return 1;
    }

    if (strstr(a, "flv_pull_url")) {
        printf("（注：本例原版恰好也能取到）\n");
    } else {
        printf("✅ 证实原版正则会截断，拿不到真实流地址\n");
    }
    return 0;
}
