#include <jni.h>
#include <string.h>
#include "libavcodec/ffjni.h"
#include "libavcodec/jni.h"
#include "libavutil/avstring.h"
#include "libavutil/error.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/attributes.h" // Required for av_used
#include "url.h"

#ifdef PROFILING
#include <time.h>
#endif

// Define error codes to match your Java FFmpegOkhttp class
#define OKHTTP_AVERROR_OK           0
#define OKHTTP_AVERROR_EOF         -1
#define OKHTTP_AVERROR_ENOSYS      -2
#define OKHTTP_AVERROR_EINVAL      -3
#define OKHTTP_AVERROR_BAD_REQUEST -4
#define OKHTTP_AVERROR_UNAUTHORIZED -5
#define OKHTTP_AVERROR_FORBIDDEN    -6
#define OKHTTP_AVERROR_NOT_FOUND    -7
#define OKHTTP_AVERROR_TOO_MANY_REQUESTS -8
#define OKHTTP_AVERROR_OTHER_4XX    -9
#define OKHTTP_AVERROR_SERVER_ERROR -10
#define OKHTTP_AVERROR_INTERRUPTED -11

#define SEGMENT_SIZE 8192

struct JNIOkhttpFields {
    jclass okhttp_class;
    jmethodID init_method;
    jmethodID okhttp_open_method;
    jmethodID okhttp_read_method;
    jmethodID okhttp_seek_method;
    jmethodID okhttp_close_method;
    jmethodID okhttp_get_mime_method;
    jclass hash_map_class;
    jmethodID hash_map_init_method;
    jmethodID hash_map_put_method;
    jclass bbuf_class;
    jmethodID bbuf_allocate_method;
};

typedef struct {
    const AVClass *class;
    char *headers;
    char *mime_type;
    struct JNIOkhttpFields jfields;
    jobject thiz;

    /* [OOM FIX] Cached DirectByteBuffer — reused across okhttp_read calls
     * instead of allocating a new one per call. For a given URLContext the
     * buf pointer and size are constant (FFmpeg allocates the protocol buffer
     * once), so the cached buffer is valid for the lifetime of the connection. */
    jobject cached_buf;
    unsigned char *cached_buf_ptr;
    int cached_buf_size;
} OkhttpContext;

#define OFFSET(x) offsetof(struct JNIOkhttpFields, x)
static const struct FFJniField jfields_okhttp_mapping[] = {
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", NULL, NULL, FF_JNI_CLASS, OFFSET(okhttp_class), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "<init>", "(Ljava/lang/String;Ljava/lang/String;)V", FF_JNI_METHOD, OFFSET(init_method), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpOpen", "(Ljava/util/Map;)I", FF_JNI_METHOD, OFFSET(okhttp_open_method), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpRead", "(Ljava/nio/ByteBuffer;I)I", FF_JNI_METHOD, OFFSET(okhttp_read_method), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpSeek", "(JI)J", FF_JNI_METHOD, OFFSET(okhttp_seek_method), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpClose", "()V", FF_JNI_METHOD, OFFSET(okhttp_close_method), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegOkhttp", "okhttpGetMime", "()Ljava/lang/String;", FF_JNI_METHOD, OFFSET(okhttp_get_mime_method), 1 },
    { "java/util/HashMap", NULL, NULL, FF_JNI_CLASS, OFFSET(hash_map_class), 1 },
    { "java/util/HashMap", "<init>", "()V", FF_JNI_METHOD, OFFSET(hash_map_init_method), 1 },
    { "java/util/HashMap", "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", FF_JNI_METHOD, OFFSET(hash_map_put_method), 1 },
    { "java/nio/ByteBuffer", NULL, NULL, FF_JNI_CLASS, OFFSET(bbuf_class), 1 },
    { "java/nio/ByteBuffer", "allocateDirect", "(I)Ljava/nio/ByteBuffer;", FF_JNI_STATIC_METHOD, OFFSET(bbuf_allocate_method), 1 },
    { NULL }
};
#undef OFFSET

#define OFFSET(x) offsetof(OkhttpContext, x)
#define D AV_OPT_FLAG_DECODING_PARAM
#define E AV_OPT_FLAG_ENCODING_PARAM
static const AVOption options[] = {
    { "headers", "set custom HTTP headers", OFFSET(headers), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, D | E },
    { "mime_type", "export the MIME type", OFFSET(mime_type), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY },
    { NULL }
};
#undef OFFSET

static jobject okhttp_get_options(OkhttpContext *c, JNIEnv *env, AVDictionary **options)
{
    jobject meta_map = (*env)->NewObject(env, c->jfields.hash_map_class, c->jfields.hash_map_init_method);
    AVDictionaryEntry *t = NULL;

    if((*env)->ExceptionCheck(env) || !meta_map)
        return NULL;

    while ((t = av_dict_iterate(*options, t))) {
        jstring key = ff_jni_utf_chars_to_jstring(env, t->key, c);
        jstring value = ff_jni_utf_chars_to_jstring(env, t->value, c);
        if(key && value) {
            jobject prev = (*env)->CallObjectMethod(env, meta_map, c->jfields.hash_map_put_method, key, value);
            if (ff_jni_exception_check(env, 1, c) < 0) {
                if (prev)
                    (*env)->DeleteLocalRef(env, prev);
                if (key)
                    (*env)->DeleteLocalRef(env, key);
                if (value)
                    (*env)->DeleteLocalRef(env, value);
                (*env)->DeleteLocalRef(env, meta_map);
                return NULL;
            }
            if (prev)
                (*env)->DeleteLocalRef(env, prev);
        }
        if(key)
            (*env)->DeleteLocalRef(env, key);
        if(value)
            (*env)->DeleteLocalRef(env, value);
    }
    return meta_map;
}

/* Forward declaration — okhttp_open() calls okhttp_seek(AVSEEK_SIZE) at end of
 * open to learn the total size, and okhttp_seek is defined further down. */
static int64_t okhttp_seek(URLContext *h, int64_t off, int whence);

static int okhttp_close(URLContext *h)
{
    OkhttpContext *c = h->priv_data;
    JNIEnv *env = ff_jni_get_env(h);

    av_log(h, AV_LOG_DEBUG, "okhttp_close\n");

    if (!env || !c->thiz) {
        av_log(h, AV_LOG_WARNING, "okhttp_close: no env or thiz\n");
        return 0;
    }

    (*env)->CallVoidMethod(env, c->thiz, c->jfields.okhttp_close_method);
    ff_jni_exception_check(env, 1, c->thiz);

    // FIX #3: free mime_type string
    av_freep(&c->mime_type);

    /* [OOM FIX] Free cached DirectByteBuffer */
    if (c->cached_buf != NULL) {
        (*env)->DeleteGlobalRef(env, c->cached_buf);
        c->cached_buf = NULL;
        c->cached_buf_ptr = NULL;
        c->cached_buf_size = 0;
        av_log(h, AV_LOG_TRACE, "okhttp_close: freed cached DirectByteBuffer\n");
    }

    if (c->thiz) {
        (*env)->DeleteGlobalRef(env, c->thiz);
        c->thiz = NULL;
    }

    ff_jni_reset_jfields(env, &c->jfields, jfields_okhttp_mapping, 1, c);

    av_log(h, AV_LOG_DEBUG, "okhttp_close finished\n");
    return 0;
}

static int okhttp_open(URLContext *h, const char *uri, int flags, AVDictionary **options)
{
    OkhttpContext *c = h->priv_data;
    JNIEnv *env = ff_jni_get_env(h);
    jobject object = NULL, url = NULL, headers = NULL, meta_map = NULL, mime_type = NULL;
    int ret = 0;

    av_log(h, AV_LOG_DEBUG, "okhttp_open: %s\n", uri);

    if (!env) {
        av_log(h, AV_LOG_ERROR, "okhttp_open: no JNIEnv\n");
        return AVERROR(EINVAL);
    }

    ret = ff_jni_init_jfields(env, &c->jfields, jfields_okhttp_mapping, 1, h);

    if (ret < 0) {
        av_log(h, AV_LOG_ERROR, "okhttp_open: jfields init failed: %d\n", ret);
        return ret;
    }

    url     = ff_jni_utf_chars_to_jstring(env, uri, c);
    headers = ff_jni_utf_chars_to_jstring(env, c->headers ? c->headers : "", c); // FIX #1

    object = (*env)->NewObject(env, c->jfields.okhttp_class, c->jfields.init_method, url, headers);

    if (ff_jni_exception_check(env, 1, h) < 0 || !object) {
        av_log(h, AV_LOG_ERROR, "okhttp_open: NewObject failed\n");
        ret = AVERROR_EXIT;
        goto done;
    }
    c->thiz = (*env)->NewGlobalRef(env, object);

    meta_map = okhttp_get_options(c, env, options);
    ret = (*env)->CallIntMethod(env, c->thiz, c->jfields.okhttp_open_method, meta_map);

    /* Java side may have thrown (e.g. InterruptedException when the worker
     * thread is cancelled mid-open). Clear before any further JNI call so
     * CheckJNI doesn't abort the process on the next callback. */
    if (ff_jni_exception_check(env, 1, h) < 0) {
        av_log(h, AV_LOG_ERROR, "okhttp_open: Java exception from okhttpOpen\n");
        ret = AVERROR_EXIT;
        goto done;
    }

    if (ret < 0) {
        av_log(h, AV_LOG_WARNING, "okhttp_open: Java okhttpOpen returned %d\n", ret);
        switch(ret) {
            case OKHTTP_AVERROR_EOF:           ret = AVERROR_EOF; break;
            case OKHTTP_AVERROR_UNAUTHORIZED:  ret = AVERROR_HTTP_UNAUTHORIZED; break;
            case OKHTTP_AVERROR_FORBIDDEN:     ret = AVERROR_HTTP_FORBIDDEN; break;
            case OKHTTP_AVERROR_NOT_FOUND:     ret = AVERROR_HTTP_NOT_FOUND; break;
            case OKHTTP_AVERROR_INTERRUPTED:   ret = AVERROR_EXIT; break;
            default:                           ret = AVERROR(EIO); break;
        }
        goto done;
    }

    mime_type = (*env)->CallObjectMethod(env, c->thiz, c->jfields.okhttp_get_mime_method);

    if (ff_jni_exception_check(env, 1, h) < 0) {
        av_log(h, AV_LOG_ERROR, "okhttp_open: Java exception from okhttpGetMime\n");
        ret = AVERROR_EXIT;
        goto done;
    }

    if (mime_type) {
        const char *m = (*env)->GetStringUTFChars(env, mime_type, NULL);
        if (m) {
            c->mime_type = av_strdup(m);
            av_log(h, AV_LOG_VERBOSE, "okhttp_open: mime=%s\n", m);
            (*env)->ReleaseStringUTFChars(env, mime_type, m);
        }
    }

    /* Advertise seekability honestly (native http.c does this; this port did
     * not). The protocol always exposes url_seek, so without this the
     * URLContext defaults to seekable even for a chunked segment whose total
     * length we never learned. A "seekable but unknown-size" stream defeats the
     * mov demuxer's read_header early-out ("stop after moov+first mdat" only
     * fires for non-seekable input, or when an atom ends exactly at avio_size),
     * so mov walks every moof/mdat to EOF and downloads the whole fragmented
     * HLS track during avformat_open_input. okhttp_seek(AVSEEK_SIZE) returns the
     * total size, or <0 when unknown. */
    {
        int64_t total = okhttp_seek(h, 0, AVSEEK_SIZE);
        h->is_streamed = (total <= 0);
        av_log(h, AV_LOG_VERBOSE, "okhttp_open: total=%"PRId64" is_streamed=%d\n",
               total, h->is_streamed);
    }

    av_log(h, AV_LOG_DEBUG, "okhttp_open: success\n");

done:

    if (meta_map)
        (*env)->DeleteLocalRef(env, meta_map);
    if (object)
        (*env)->DeleteLocalRef(env, object);
    if (mime_type)
        (*env)->DeleteLocalRef(env, mime_type);
    if (url)
        (*env)->DeleteLocalRef(env, url);
    if (headers)
        (*env)->DeleteLocalRef(env, headers);

    return ret;
}

static int okhttp_read(URLContext *h, unsigned char *buf, int size)
{
    OkhttpContext *c = h->priv_data;
    JNIEnv *env = ff_jni_get_env(h);
#ifdef PROFILING
    struct timespec start, end;

    // Start timer
    clock_gettime(CLOCK_MONOTONIC, &start);
#endif

    av_log(h, AV_LOG_TRACE, "okhttp_read: size=%d\n", size);

    if (!env) {
        av_log(h, AV_LOG_ERROR, "okhttp_read: no JNIEnv\n");
        return AVERROR(EIO);
    }

    /* [OOM FIX] Reuse a cached DirectByteBuffer instead of allocating one
     * per read call. The old approach created thousands of DirectByteBuffer
     * objects during HLS segment downloads, overwhelming the GC's Cleaner
     * thread and causing OOM under concurrent downloads.
     *
     * For a given URLContext, FFmpeg passes the same buf pointer and size
     * on every okhttp_read call, so we only need to create the wrapper once. */
    if (c->cached_buf == NULL || c->cached_buf_ptr != buf || c->cached_buf_size < size) {
        if (c->cached_buf != NULL) {
            (*env)->DeleteGlobalRef(env, c->cached_buf);
            c->cached_buf = NULL;
        }

        av_log(h, AV_LOG_VERBOSE, "okhttp_read: creating cached DirectByteBuffer size=%d\n", size);

        jobject local_buf = (*env)->NewDirectByteBuffer(env, buf, size);
        if (!local_buf) {
            av_log(h, AV_LOG_ERROR, "okhttp_read: NewDirectByteBuffer failed\n");
            return AVERROR(ENOMEM);
        }
        c->cached_buf = (*env)->NewGlobalRef(env, local_buf);
        (*env)->DeleteLocalRef(env, local_buf);

        if (!c->cached_buf) {
            av_log(h, AV_LOG_ERROR, "okhttp_read: NewGlobalRef failed\n");
            return AVERROR(ENOMEM);
        }

        c->cached_buf_ptr = buf;
        c->cached_buf_size = size;
    }

    int bytes_read = (*env)->CallIntMethod(env, c->thiz, c->jfields.okhttp_read_method, c->cached_buf, size);

#ifdef PROFILING
    // End timer
    clock_gettime(CLOCK_MONOTONIC, &end);

    // Calculate nanoseconds
    long diff_ns = (end.tv_sec - start.tv_sec) * 1000000000L + (end.tv_nsec - start.tv_nsec);

    // Log occasionally (e.g., every 100 reads) to avoid log spamming
    static int read_count = 0;
    if (++read_count % 100 == 0) {
        av_log(c, AV_LOG_ERROR, "Read %d bytes | JNI Latency: %ld ns", bytes_read, diff_ns);
    }
#endif

    /* On a pending exception (e.g. InterruptedException from Thread.interrupt
     * during cancel), return AVERROR_EXIT rather than EIO so the demuxer
     * unwinds cleanly instead of retrying into the same trap. */
    if (ff_jni_exception_check(env, 1, c->thiz) < 0) {
        av_log(h, AV_LOG_ERROR, "okhttp_read: Java exception\n");
        return AVERROR_EXIT;
    }

    if (bytes_read > 0) {
        av_log(h, AV_LOG_TRACE, "okhttp_read: %d bytes\n", bytes_read);
        return bytes_read;
    }
    if (bytes_read == 0) {
        av_log(h, AV_LOG_DEBUG, "okhttp_read: EAGAIN\n");
        return AVERROR(EAGAIN);
    }
    if (bytes_read == OKHTTP_AVERROR_INTERRUPTED) {
        av_log(h, AV_LOG_INFO, "okhttp_read: interrupted\n");
        return AVERROR_EXIT;
    }

    av_log(h, AV_LOG_VERBOSE, "okhttp_read: EOF\n");
    return AVERROR_EOF;
}


static int64_t okhttp_seek(URLContext *h, int64_t off, int whence)
{
    OkhttpContext *c = h->priv_data;
    JNIEnv *env = ff_jni_get_env(h);

    av_log(h, AV_LOG_DEBUG, "okhttp_seek: off=%"PRId64" whence=%d\n", off, whence);

    if (!env) {
        av_log(h, AV_LOG_ERROR, "okhttp_seek: no JNIEnv\n");
        return AVERROR(EINVAL);
    }

    int64_t result = (*env)->CallLongMethod(env, c->thiz, c->jfields.okhttp_seek_method, off, whence);

    if (ff_jni_exception_check(env, 1, c->thiz) < 0) {
        av_log(h, AV_LOG_ERROR, "okhttp_seek: Java exception\n");
        return AVERROR_EXIT;
    }

    if (result == OKHTTP_AVERROR_EOF) {
        av_log(h, AV_LOG_VERBOSE, "okhttp_seek: EOF\n");
        return AVERROR_EOF;
    } else if (result == OKHTTP_AVERROR_INTERRUPTED) {
        av_log(h, AV_LOG_INFO, "okhttp_seek: interrupted\n");
        return AVERROR_EXIT;
    } else if (result == OKHTTP_AVERROR_ENOSYS) {
        av_log(h, AV_LOG_VERBOSE, "okhttp_seek: ENOSYS\n");
        return AVERROR(ENOSYS);
    } else if (result == OKHTTP_AVERROR_EINVAL) {
        av_log(h, AV_LOG_WARNING, "okhttp_seek: EINVAL\n");
        return AVERROR(EINVAL);
    }

    av_log(h, AV_LOG_DEBUG, "okhttp_seek: result=%"PRId64"\n", result);
    return result;
}

#define HTTP_CLASS(flavor)                          \
static const AVClass flavor ## _context_class = {   \
    .class_name = # flavor,                         \
    .item_name  = av_default_item_name,             \
    .option     = options,                          \
    .version    = LIBAVUTIL_VERSION_INT,            \
}


HTTP_CLASS(http);
const URLProtocol ff_http_protocol = {
    .name                = "http",
    .url_open2           = okhttp_open,
    .url_read            = okhttp_read,
    .url_seek            = okhttp_seek,
    .url_close           = okhttp_close,
    .priv_data_size      = sizeof(OkhttpContext),
    .priv_data_class     = &http_context_class,
    .flags               = URL_PROTOCOL_FLAG_NETWORK,
    .default_whitelist   = "http,https,tls,tcp,udp,crypto,data"
};



HTTP_CLASS(https);
const URLProtocol ff_https_protocol = {
    .name                = "https",
    .url_open2           = okhttp_open,
    .url_read            = okhttp_read,
    .url_seek            = okhttp_seek,
    .url_close           = okhttp_close,
    .priv_data_size      = sizeof(OkhttpContext),
    .priv_data_class     = &https_context_class,
    .flags               = URL_PROTOCOL_FLAG_NETWORK,
    .default_whitelist   = "http,https,tls,tcp,udp,crypto,data"
};
