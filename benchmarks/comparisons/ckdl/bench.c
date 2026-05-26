// ckdl bench harness — event-drain, no AST construction.
// Reports parses/second for each fixture.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <kdl/parser.h>
#include <kdl/common.h>

static char *read_file(const char *path, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(len + 1);
    fread(buf, 1, len, f);
    buf[len] = '\0';
    fclose(f);
    *len_out = (size_t)len;
    return buf;
}

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static void parse_once(const char *src, size_t len) {
    kdl_str input = {.data = src, .len = len};
    kdl_parser *p = kdl_create_string_parser(input, KDL_READ_VERSION_2);
    if (!p) return;
    for (;;) {
        kdl_event_data *ev = kdl_parser_next_event(p);
        if (!ev) break;
        if (ev->event == KDL_EVENT_EOF) break;
        if (ev->event == KDL_EVENT_PARSE_ERROR) break;
    }
    kdl_destroy_parser(p);
}

static void bench(const char *name, const char *path, int iters) {
    size_t len;
    char *src = read_file(path, &len);
    if (!src) { printf("  %s: NOT FOUND\n", name); return; }
    for (int i = 0; i < (iters < 100 ? iters : 100); i++) parse_once(src, len);
    double start = now_seconds();
    for (int i = 0; i < iters; i++) parse_once(src, len);
    double elapsed = now_seconds() - start;
    double ops = iters / elapsed;
    double us = elapsed / iters * 1e6;
    printf("  %-40s %10.1fus avg   %10.1fK ops/s   %zu bytes\n",
        name, us, ops / 1000.0, len);
    free(src);
}

int main(void) {
    printf("=== ckdl (C, event-drain, -O3) ===\n\n");
    bench("realistic-config.kdl", "/fixtures/realistic-config.kdl",  5000);
    bench("Cargo.kdl",            "/fixtures/Cargo.kdl",            10000);
    bench("ci.kdl",               "/fixtures/ci.kdl",                5000);
    bench("website.kdl",          "/fixtures/website.kdl",           5000);
    bench("unicode-heavy.kdl",    "/fixtures/unicode-heavy.kdl",     5000);
    return 0;
}
