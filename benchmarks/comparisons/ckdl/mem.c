// Memory-footprint harness for ckdl. ONE fixture per invocation —
// VmPeak is monotonic per-process so each measurement gets a fresh
// baseline.
//
// Usage:  ckdl-mem <fixture-path>
// Output: ckdl  <fixture>  input=<KB> baseline=<KB> peak=<KB> delta=<KB>
//
// Asymmetry caveat: ckdl is SAX-style. There is NO AST built, so
// there is nothing structural to "hold" between iterations the way
// nimkdl/kdl-rs/knus/facet-kdl all hold a final parsed document.
// What this harness measures is therefore the high-water of the
// PARSE-STATE allocator across N parses — the transient peak that
// shows up while events are being drained. The "held" value here is
// just an event counter (so the parse can't be DCE'd) plus the
// parser pointer kept in scope until after vmPeak is sampled.
//
// In practice this means ckdl's delta is structurally smaller than
// the other parsers' deltas, because the others include held-doc
// cost AND transient-parse-peak, while ckdl includes only the
// latter. That asymmetry is honest and reflects the actual API
// difference: a streaming parser fundamentally has a smaller memory
// footprint than an AST builder.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <kdl/parser.h>
#include <kdl/common.h>

static long vm_peak_kb(void) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256];
    long peak = -1;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "VmPeak:", 7) == 0) {
            sscanf(line + 7, " %ld", &peak);
            break;
        }
    }
    fclose(f);
    return peak;
}

static char *read_file(const char *path, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)len + 1);
    if (!buf) { fclose(f); return NULL; }
    fread(buf, 1, (size_t)len, f);
    buf[len] = '\0';
    fclose(f);
    *len_out = (size_t)len;
    return buf;
}

// Drain all events from one parse, returning the event count so the
// optimizer can't DCE the work.
static unsigned long parse_once(const char *src, size_t len) {
    kdl_str input = { .data = src, .len = len };
    kdl_parser *p = kdl_create_string_parser(input, KDL_READ_VERSION_2);
    if (!p) return 0;
    unsigned long events = 0;
    for (;;) {
        kdl_event_data *ev = kdl_parser_next_event(p);
        if (!ev) break;
        events++;
        if (ev->event == KDL_EVENT_EOF) break;
        if (ev->event == KDL_EVENT_PARSE_ERROR) break;
    }
    kdl_destroy_parser(p);
    return events;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: ckdl-mem <fixture-path>\n"); return 2; }
    const char *path = argv[1];
    size_t len = 0;
    char *src = read_file(path, &len);
    if (!src) { fprintf(stderr, "missing fixture: %s\n", path); return 2; }

    int iters = (len > 200000) ? 20 : 200;
    long baseline = vm_peak_kb();

    // "Held" value: total event count across all parses. Keeping it
    // in scope past the vmPeak read is the closest analog to holding
    // a final parsed doc, given ckdl has no AST.
    volatile unsigned long held_events = 0;
    for (int i = 0; i < iters; i++) {
        held_events += parse_once(src, len);
    }
    long peak = vm_peak_kb();
    if (held_events == 42) fprintf(stderr, "(noop guard)\n"); // prevent DCE

    // Basename of the fixture path for the report column.
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;

    long input_kb = (long)((len + 1023) / 1024);
    printf("  ckdl    %-35s input %5ld KB   baseline %6ld KB   peak %6ld KB   delta %6ld KB\n",
        base, input_kb, baseline, peak, peak - baseline);

    free(src);
    return 0;
}
