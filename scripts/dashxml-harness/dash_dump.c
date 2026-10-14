/*
 * dashxml harness driver: runs libavformat/dashdec.c's REAL parse_manifest()
 * on one MPD and prints everything it extracted, so two builds can be diffed.
 *
 * Built twice by run.sh:
 *  - against libxml2, from vanilla dashdec.c;
 *  - with -DFDXML_VARIANT, from dashdec.c as apply-firedown-patches.sh leaves
 *    it, plus fdxml.c. ff_fdxml_read_memory (the JNI call in the app) is
 *    replaced below by a stand-in that hands the SAME bytes to the REAL
 *    FFmpegXml.parse() in a JVM and feeds its answer to
 *    ff_fdxml_doc_from_blob() — the same function the JNI path ends in.
 *
 * Usage: dash_dump <file.mpd> <manifest-url>
 * Environment (FDXML variant): FDXML_CP (classpath holding FdxmlCli,
 * FFmpegXml and kxml2), FDXML_BLOB_DIR (cache of Java answers keyed by the
 * manifest bytes, so repeated runs over a corpus start one JVM per manifest).
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef FDXML_VARIANT
#include "fdxml.h"
static xmlDocPtr harness_read_memory(void *log_ctx, const char *buf, int len);
#define ff_fdxml_read_memory harness_read_memory
#endif

#include "dashdec.c"

#ifdef FDXML_VARIANT

/* FFmpegXml.parse() returned null: FdxmlCli exits with this. */
#define FDXML_CLI_NULL 3

static uint64_t fnv1a(const char *buf, int len)
{
    uint64_t h = 0xcbf29ce484222325ULL;
    int i;

    for (i = 0; i < len; i++) {
        h ^= (uint8_t)buf[i];
        h *= 0x100000001b3ULL;
    }
    return h ^ (uint64_t)len;
}

static int file_exists(const char *path)
{
    struct stat st;

    return stat(path, &st) == 0;
}

static int write_file(const char *path, const char *buf, int len)
{
    FILE *f;
    size_t written;

    f = fopen(path, "wb");
    if (!f) {
        return -1;
    }
    written = fwrite(buf, 1, len, f);
    if (fclose(f) != 0 || written != (size_t)len) {
        return -1;
    }
    return 0;
}

static uint8_t *read_file(const char *path, size_t *len)
{
    FILE *f;
    uint8_t *data;
    long size;

    f = fopen(path, "rb");
    if (!f) {
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    data = malloc(size > 0 ? size : 1);
    if (!data || fread(data, 1, size, f) != (size_t)size) {
        free(data);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *len = size;
    return data;
}

/* Runs FdxmlCli in a JVM; returns its exit status, or -1. */
static int run_java(const char *in_path, const char *out_path)
{
    const char *cp = getenv("FDXML_CP");
    pid_t pid;
    int status;

    pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        execlp("java", "java", "-cp", cp, "FdxmlCli", in_path, out_path, (char *)NULL);
        _exit(127);
    }
    if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status)) {
        return -1;
    }
    return WEXITSTATUS(status);
}

static xmlDocPtr harness_read_memory(void *log_ctx, const char *buf, int len)
{
    const char *dir = getenv("FDXML_BLOB_DIR");
    char key[17];
    char in_path[4096];
    char blob_path[4096];
    char null_path[4096];
    uint8_t *blob;
    size_t blob_len;
    xmlDocPtr doc;
    int status;

    if (!dir || !getenv("FDXML_CP")) {
        fprintf(stderr, "FDXML-HARNESS: FDXML_CP and FDXML_BLOB_DIR must be set\n");
        exit(70);
    }
    snprintf(key, sizeof(key), "%016llx", (unsigned long long)fnv1a(buf, len));
    snprintf(in_path, sizeof(in_path), "%s/%s.%d.mpd", dir, key, (int)getpid());
    snprintf(blob_path, sizeof(blob_path), "%s/%s.blob", dir, key);
    snprintf(null_path, sizeof(null_path), "%s/%s.null", dir, key);

    if (file_exists(null_path)) {
        return NULL;
    }
    if (!file_exists(blob_path)) {
        if (write_file(in_path, buf, len) < 0) {
            fprintf(stderr, "FDXML-HARNESS: cannot write %s\n", in_path);
            exit(70);
        }
        status = run_java(in_path, blob_path);
        unlink(in_path);
        if (status == FDXML_CLI_NULL) {
            write_file(null_path, "", 0);
            return NULL;
        }
        if (status != 0) {
            /* Not an answer from FFmpegXml: the JVM or the classpath is broken. */
            fprintf(stderr, "FDXML-HARNESS: FdxmlCli failed (status %d)\n", status);
            exit(70);
        }
    }
    blob = read_file(blob_path, &blob_len);
    if (!blob) {
        fprintf(stderr, "FDXML-HARNESS: cannot read %s\n", blob_path);
        exit(70);
    }
    doc = ff_fdxml_doc_from_blob(log_ctx, blob, blob_len);
    free(blob);
    return doc;
}

#endif /* FDXML_VARIANT */

static const char *nz(const char *s)
{
    return s ? s : "(null)";
}

static void dump_fragment(const char *what, const struct fragment *f)
{
    if (!f) {
        printf("    %s: none\n", what);
        return;
    }
    printf("    %s: url=%s off=%"PRId64" size=%"PRId64"\n", what, nz(f->url), f->url_offset, f->size);
}

static void dump_representation(const char *kind, int i, const struct representation *r)
{
    int j;

    printf("  %s[%d] id=%s lang=%s bw=%d codecs=%s dep=%s fr=%d/%d\n", kind, i,
           nz(r->id), nz(r->lang), r->bandwidth, nz(r->codecs), nz(r->dependencyid),
           r->framerate.num, r->framerate.den);
    printf("    template=%s\n", nz(r->url_template));
    printf("    seq first=%"PRId64" last=%"PRId64" start=%"PRId64" dur=%"PRId64" ts=%"PRId64" pto=%"PRId64"\n",
           r->first_seq_no, r->last_seq_no, r->start_number, r->fragment_duration,
           r->fragment_timescale, r->presentation_timeoffset);
    dump_fragment("init", r->init_section);
    printf("    fragments=%d timelines=%d\n", r->n_fragments, r->n_timelines);
    for (j = 0; j < r->n_fragments; j++) {
        dump_fragment("frag", r->fragments[j]);
    }
    for (j = 0; j < r->n_timelines; j++) {
        printf("    S t=%"PRId64" r=%"PRId64" d=%"PRId64"\n", r->timelines[j]->starttime,
               r->timelines[j]->repeat, r->timelines[j]->duration);
    }
}

int main(int argc, char **argv)
{
    AVFormatContext *s;
    DASHContext *c;
    AVIOContext *in = NULL;
    const AVDictionaryEntry *e = NULL;
    int ret;
    int i;

    if (argc < 3) {
        fprintf(stderr, "usage: %s file.mpd manifest-url\n", argv[0]);
        return 2;
    }
    av_log_set_level(getenv("DASHXML_LOG") ? AV_LOG_TRACE : AV_LOG_QUIET);

    s = avformat_alloc_context();
    c = av_mallocz(sizeof(*c));
    if (!s || !c) {
        return 2;
    }
    c->class = &dash_class;
    av_opt_set_defaults(c);
    s->priv_data = c;

    /* Read through the file protocol, whose AVIOContext has no "location":
     * parse_manifest then takes the manifest URL from argv[2], as it takes
     * the URL the app opened. */
    ret = avio_open(&in, argv[1], AVIO_FLAG_READ);
    if (ret < 0) {
        fprintf(stderr, "cannot open %s\n", argv[1]);
        return 2;
    }

    ret = parse_manifest(s, argv[2], in);
    printf("ret=%d live=%d\n", ret, c->is_live);
    printf("mpd dur=%"PRId64" spd=%"PRId64" ast=%"PRId64" aet=%"PRId64" pub=%"PRId64" mup=%"PRId64" tsbd=%"PRId64" mbt=%"PRId64"\n",
           c->media_presentation_duration, c->suggested_presentation_delay, c->availability_start_time,
           c->availability_end_time, c->publish_time, c->minimum_update_period,
           c->time_shift_buffer_depth, c->min_buffer_time);
    printf("period dur=%"PRIu64" start=%"PRIu64" max_url_size=%d\n", c->period_duration, c->period_start, c->max_url_size);
    printf("base_url=%s\n", nz(c->base_url));
    e = av_dict_iterate(s->metadata, e);
    while (e) {
        printf("meta %s=%s\n", e->key, e->value);
        e = av_dict_iterate(s->metadata, e);
    }
    for (i = 0; i < c->n_videos; i++) {
        dump_representation("video", i, c->videos[i]);
    }
    for (i = 0; i < c->n_audios; i++) {
        dump_representation("audio", i, c->audios[i]);
    }
    for (i = 0; i < c->n_subtitles; i++) {
        dump_representation("subtitle", i, c->subtitles[i]);
    }

    printf("end\n");
    /* Before returning: LeakSanitizer reports from an exit handler and leaves
     * with _exit(), so anything still buffered would be lost — and two empty
     * outputs would compare "identical". run.sh requires the end line. */
    fflush(stdout);

    dash_close(s);
    avio_closep(&in);
    av_opt_free(c);
    av_freep(&s->priv_data);
    avformat_free_context(s);
    return 0;
}
