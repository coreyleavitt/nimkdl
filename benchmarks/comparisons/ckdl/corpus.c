// Real-trace replay: parse every file in the kdl-org conformance
// corpus (338 community-curated KDL files, ~7 KB total) and report
// aggregate throughput.
//
// The corpus is maintained by kdl-org for spec testing, NOT by us.
// A perf claim on this corpus defends against "your fixtures are
// cherry-picked" — these are the same files every spec-compliant
// parser is held against.
//
// Some files are intentionally-malformed (`*_fail.kdl`) and should
// reject. Time is measured regardless of outcome; rejection speed is
// part of real-world throughput.
//
// Usage:  ckdl-corpus <corpus-dir>
// Output: ckdl  corpus  files=<N>  bytes=<B>  iters=<N>  us/file=<X>  files/s=<X>K  KB/s=<X>  ok=<acc>/<all>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dirent.h>
#include <kdl/parser.h>
#include <kdl/common.h>

typedef struct {
    char *name;
    char *data;
    size_t len;
} corpus_file;

static int cmp_files(const void *a, const void *b) {
    return strcmp(((const corpus_file *)a)->name, ((const corpus_file *)b)->name);
}

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static char *read_file(const char *path, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)len + 1);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)len, f) != (size_t)len) { free(buf); fclose(f); return NULL; }
    buf[len] = '\0';
    fclose(f);
    *len_out = (size_t)len;
    return buf;
}

// Returns 1 if the parser reached EOF without a parse-error event, 0 otherwise.
static int parse_once(const char *src, size_t len) {
    kdl_str input = { .data = src, .len = len };
    kdl_parser *p = kdl_create_string_parser(input, KDL_READ_VERSION_2);
    if (!p) return 0;
    int ok = 0;
    for (;;) {
        kdl_event_data *ev = kdl_parser_next_event(p);
        if (!ev) break;
        if (ev->event == KDL_EVENT_PARSE_ERROR) { ok = 0; break; }
        if (ev->event == KDL_EVENT_EOF) { ok = 1; break; }
    }
    kdl_destroy_parser(p);
    return ok;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: ckdl-corpus <corpus-dir>\n"); return 2; }
    const char *dir_path = argv[1];

    DIR *d = opendir(dir_path);
    if (!d) { fprintf(stderr, "missing corpus dir: %s\n", dir_path); return 2; }

    size_t cap = 64, n = 0;
    corpus_file *files = malloc(cap * sizeof(corpus_file));
    size_t total_bytes = 0;

    struct dirent *ent;
    char path[4096];
    while ((ent = readdir(d)) != NULL) {
        const char *name = ent->d_name;
        size_t nl = strlen(name);
        if (nl < 4 || strcmp(name + nl - 4, ".kdl") != 0) continue;
        snprintf(path, sizeof path, "%s/%s", dir_path, name);
        size_t len;
        char *buf = read_file(path, &len);
        if (!buf) continue;
        if (n == cap) { cap *= 2; files = realloc(files, cap * sizeof(corpus_file)); }
        files[n].name = strdup(name);
        files[n].data = buf;
        files[n].len = len;
        total_bytes += len;
        n++;
    }
    closedir(d);
    qsort(files, n, sizeof(corpus_file), cmp_files);

    const int iters = 50;
    int ok_count = 0;
    double start = now_seconds();
    for (int it = 0; it < iters; it++) {
        ok_count = 0;
        for (size_t i = 0; i < n; i++) {
            if (parse_once(files[i].data, files[i].len)) ok_count++;
        }
    }
    double elapsed = now_seconds() - start;

    double total_parses = (double)n * (double)iters;
    double us_per_file = elapsed * 1e6 / total_parses;
    double files_per_sec = total_parses / elapsed;
    double kb_per_sec = ((double)total_bytes * (double)iters) / (elapsed * 1024.0);
    printf("  ckdl    corpus  files=%zu  bytes=%zu  iters=%d  us/file=%.2f  files/s=%.1fK  KB/s=%.0f  ok=%d/%zu\n",
        n, total_bytes, iters, us_per_file, files_per_sec / 1000.0, kb_per_sec, ok_count, n);

    for (size_t i = 0; i < n; i++) { free(files[i].name); free(files[i].data); }
    free(files);
    return 0;
}
