/*
 * fdxml — libxml2's tree API as dashdec.c uses it, backed by the platform's
 * XML parser through JNI. Firedown fork only; see fdxml.h for the contract
 * and com.solarized.firedown.ffmpegutils.FFmpegXml for the wire format.
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "config.h"

#include <string.h>

#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"

#if CONFIG_JNI
#include <jni.h>
#include "libavcodec/ffjni.h"
#endif

#include "fdxml.h"

/* libxml2's nesting limit without XML_PARSE_HUGE; FFmpegXml enforces it too.
 * It also bounds every recursion below. */
#define FDXML_MAX_DEPTH 256

#define FDXML_MAGIC     "FDX1"
#define FDXML_MAGIC_LEN 4

enum {
    FDXML_TAG_ELEMENT = 1,
    FDXML_TAG_END     = 2,
    FDXML_TAG_TEXT    = 3,
    FDXML_TAG_CDATA   = 4,
    FDXML_TAG_OTHER   = 5,
};

typedef struct BlobReader {
    const uint8_t *p;
    const uint8_t *end;
} BlobReader;

static int read_varint(BlobReader *r, uint32_t *out)
{
    uint32_t value = 0;
    int shift;
    uint8_t byte;

    for (shift = 0; shift < 35; shift += 7) {
        if (r->p >= r->end) {
            return AVERROR_INVALIDDATA;
        }
        byte = *r->p;
        r->p++;
        value |= (uint32_t)(byte & 0x7f) << shift;
        if (!(byte & 0x80)) {
            *out = value;
            return 0;
        }
    }
    return AVERROR_INVALIDDATA;
}

static int read_string(BlobReader *r, char **out)
{
    uint32_t len;
    char *str;
    int ret;

    ret = read_varint(r, &len);
    if (ret < 0) {
        return ret;
    }
    if (len > (size_t)(r->end - r->p)) {
        return AVERROR_INVALIDDATA;
    }
    str = av_malloc((size_t)len + 1);
    if (!str) {
        return AVERROR(ENOMEM);
    }
    memcpy(str, r->p, len);
    str[len] = '\0';
    r->p += len;
    *out = str;
    return 0;
}

static void free_attrs(xmlAttr *attr)
{
    xmlAttr *next;

    while (attr) {
        next = attr->next;
        av_free(attr->name);
        av_free(attr->value);
        av_free(attr);
        attr = next;
    }
}

static void append_child(xmlNodePtr parent, xmlNodePtr child)
{
    child->parent = parent;
    child->next = NULL;
    if (parent->last) {
        parent->last->next = child;
    } else {
        parent->children = child;
    }
    parent->last = child;
}

static int read_element(BlobReader *r, xmlNodePtr *out)
{
    xmlNodePtr node;
    xmlAttr *attr;
    xmlAttr *tail = NULL;
    uint32_t count;
    uint32_t i;
    int ret;

    node = av_mallocz(sizeof(*node));
    if (!node) {
        return AVERROR(ENOMEM);
    }
    node->type = XML_ELEMENT_NODE;
    ret = read_string(r, &node->name);
    if (ret < 0) {
        goto fail;
    }
    ret = read_varint(r, &count);
    if (ret < 0) {
        goto fail;
    }
    /* Every attribute costs at least two bytes: refuse a count the
     * remaining blob cannot hold before looping on it. */
    if (count > (size_t)(r->end - r->p) / 2) {
        ret = AVERROR_INVALIDDATA;
        goto fail;
    }
    for (i = 0; i < count; i++) {
        attr = av_mallocz(sizeof(*attr));
        if (!attr) {
            ret = AVERROR(ENOMEM);
            goto fail;
        }
        if (tail) {
            tail->next = attr;
        } else {
            node->properties = attr;
        }
        tail = attr;
        ret = read_string(r, &attr->name);
        if (ret < 0) {
            goto fail;
        }
        ret = read_string(r, &attr->value);
        if (ret < 0) {
            goto fail;
        }
    }
    *out = node;
    return 0;

fail:
    ff_fdxml_free_node(node);
    return ret;
}

static int read_leaf(BlobReader *r, int tag, xmlNodePtr *out)
{
    xmlNodePtr node;
    int ret;

    node = av_mallocz(sizeof(*node));
    if (!node) {
        return AVERROR(ENOMEM);
    }
    if (tag == FDXML_TAG_OTHER) {
        node->type = XML_COMMENT_NODE;
        *out = node;
        return 0;
    }
    if (tag == FDXML_TAG_CDATA) {
        node->type = XML_CDATA_SECTION_NODE;
    } else {
        node->type = XML_TEXT_NODE;
    }
    ret = read_string(r, &node->content);
    if (ret < 0) {
        av_free(node);
        return ret;
    }
    *out = node;
    return 0;
}

xmlDocPtr ff_fdxml_doc_from_blob(void *log_ctx, const uint8_t *blob, size_t len)
{
    BlobReader r;
    xmlNodePtr stack[FDXML_MAX_DEPTH];
    xmlNodePtr root = NULL;
    xmlNodePtr node = NULL;
    xmlDocPtr doc;
    int depth = 0;
    int tag;
    int ret;

    if (!blob || len < FDXML_MAGIC_LEN) {
        goto fail;
    }
    if (memcmp(blob, FDXML_MAGIC, FDXML_MAGIC_LEN)) {
        goto fail;
    }
    r.p = blob + FDXML_MAGIC_LEN;
    r.end = blob + len;

    while (r.p < r.end) {
        tag = *r.p;
        r.p++;
        switch (tag) {
        case FDXML_TAG_ELEMENT:
            if (depth >= FDXML_MAX_DEPTH) {
                goto fail;
            }
            if (depth == 0 && root) {
                goto fail;
            }
            ret = read_element(&r, &node);
            if (ret < 0) {
                goto fail;
            }
            if (depth == 0) {
                root = node;
            } else {
                append_child(stack[depth - 1], node);
            }
            stack[depth] = node;
            depth++;
            break;
        case FDXML_TAG_END:
            if (depth == 0) {
                goto fail;
            }
            depth--;
            break;
        case FDXML_TAG_TEXT:
        case FDXML_TAG_CDATA:
        case FDXML_TAG_OTHER:
            if (depth == 0) {
                goto fail;
            }
            ret = read_leaf(&r, tag, &node);
            if (ret < 0) {
                goto fail;
            }
            append_child(stack[depth - 1], node);
            break;
        default:
            goto fail;
        }
    }
    if (depth != 0 || !root) {
        goto fail;
    }

    doc = av_mallocz(sizeof(*doc));
    if (!doc) {
        goto fail;
    }
    doc->root = root;
    return doc;

fail:
    av_log(log_ctx, AV_LOG_ERROR, "fdxml: malformed tree from FFmpegXml\n");
    ff_fdxml_free_node(root);
    return NULL;
}

void ff_fdxml_free_node(xmlNodePtr node)
{
    xmlNodePtr child;
    xmlNodePtr next;

    if (!node) {
        return;
    }
    child = node->children;
    while (child) {
        next = child->next;
        ff_fdxml_free_node(child);
        child = next;
    }
    free_attrs(node->properties);
    av_free(node->name);
    av_free(node->content);
    av_free(node);
}

void ff_fdxml_free_doc(xmlDocPtr doc)
{
    if (!doc) {
        return;
    }
    ff_fdxml_free_node(doc->root);
    av_free(doc);
}

xmlNodePtr ff_fdxml_doc_get_root_element(const xmlDoc *doc)
{
    if (!doc) {
        return NULL;
    }
    return doc->root;
}

static xmlNodePtr next_element(xmlNodePtr node)
{
    while (node && node->type != XML_ELEMENT_NODE) {
        node = node->next;
    }
    return node;
}

xmlNodePtr ff_fdxml_first_element_child(const xmlNode *node)
{
    if (!node) {
        return NULL;
    }
    return next_element(node->children);
}

xmlNodePtr ff_fdxml_next_element_sibling(const xmlNode *node)
{
    if (!node) {
        return NULL;
    }
    return next_element(node->next);
}

char *ff_fdxml_get_prop(const xmlNode *node, const char *name)
{
    const xmlAttr *attr;

    if (!node || !name) {
        return NULL;
    }
    for (attr = node->properties; attr; attr = attr->next) {
        if (!strcmp(attr->name, name)) {
            return av_strdup(attr->value);
        }
    }
    return NULL;
}

/* Length of the text and CDATA under an element, comments excluded —
 * what libxml2's xmlNodeGetContent concatenates. */
static size_t content_length(const xmlNode *node)
{
    const xmlNode *child;
    size_t len = 0;

    for (child = node->children; child; child = child->next) {
        if (child->type == XML_ELEMENT_NODE) {
            len += content_length(child);
        } else if (child->content) {
            len += strlen(child->content);
        }
    }
    return len;
}

static char *copy_content(const xmlNode *node, char *dst)
{
    const xmlNode *child;
    size_t len;

    for (child = node->children; child; child = child->next) {
        if (child->type == XML_ELEMENT_NODE) {
            dst = copy_content(child, dst);
        } else if (child->content) {
            len = strlen(child->content);
            memcpy(dst, child->content, len);
            dst += len;
        }
    }
    return dst;
}

char *ff_fdxml_node_get_content(const xmlNode *node)
{
    char *out;
    char *end;

    if (!node) {
        return NULL;
    }
    if (node->type != XML_ELEMENT_NODE) {
        /* Comments keep no text here; dashdec.c never reads one. */
        return av_strdup(node->content ? node->content : "");
    }
    out = av_malloc(content_length(node) + 1);
    if (!out) {
        return NULL;
    }
    end = copy_content(node, out);
    *end = '\0';
    return out;
}

int ff_fdxml_node_set_content(xmlNodePtr node, const char *content)
{
    xmlNodePtr child;
    xmlNodePtr next;
    xmlNodePtr text;
    char *copy;

    if (!node) {
        return -1;
    }
    copy = av_strdup(content ? content : "");
    if (!copy) {
        return -1;
    }
    if (node->type != XML_ELEMENT_NODE) {
        av_free(node->content);
        node->content = copy;
        return 0;
    }
    /* An element's children are replaced by one text node, or by none for
     * an empty string, as libxml2 does. */
    child = node->children;
    while (child) {
        next = child->next;
        ff_fdxml_free_node(child);
        child = next;
    }
    node->children = NULL;
    node->last = NULL;
    if (!copy[0]) {
        av_free(copy);
        return 0;
    }
    text = av_mallocz(sizeof(*text));
    if (!text) {
        av_free(copy);
        return -1;
    }
    text->type = XML_TEXT_NODE;
    text->content = copy;
    append_child(node, text);
    return 0;
}

char *ff_fdxml_encode_special_chars(const void *doc, const char *input)
{
    if (!input) {
        return NULL;
    }
    /* Identity, paired with ff_fdxml_node_set_content storing text as given:
     * see fdxml.h. */
    return av_strdup(input);
}

xmlNodePtr ff_fdxml_new_node(const void *ns, const char *name)
{
    xmlNodePtr node;

    if (!name) {
        return NULL;
    }
    node = av_mallocz(sizeof(*node));
    if (!node) {
        return NULL;
    }
    node->type = XML_ELEMENT_NODE;
    node->name = av_strdup(name);
    if (!node->name) {
        av_free(node);
        return NULL;
    }
    return node;
}

static int copy_attrs(const xmlAttr *src, xmlAttr **out)
{
    xmlAttr *head = NULL;
    xmlAttr *tail = NULL;
    xmlAttr *attr;

    for (; src; src = src->next) {
        attr = av_mallocz(sizeof(*attr));
        if (!attr) {
            goto fail;
        }
        if (tail) {
            tail->next = attr;
        } else {
            head = attr;
        }
        tail = attr;
        attr->name = av_strdup(src->name);
        attr->value = av_strdup(src->value);
        if (!attr->name || !attr->value) {
            goto fail;
        }
    }
    *out = head;
    return 0;

fail:
    free_attrs(head);
    return AVERROR(ENOMEM);
}

xmlNodePtr ff_fdxml_copy_node(const xmlNode *node, int extended)
{
    const xmlNode *child;
    xmlNodePtr copy;
    xmlNodePtr child_copy;
    int ret;

    if (!node) {
        return NULL;
    }
    copy = av_mallocz(sizeof(*copy));
    if (!copy) {
        return NULL;
    }
    copy->type = node->type;
    if (node->name) {
        copy->name = av_strdup(node->name);
        if (!copy->name) {
            goto fail;
        }
    }
    if (node->content) {
        copy->content = av_strdup(node->content);
        if (!copy->content) {
            goto fail;
        }
    }
    if (!extended) {
        return copy;
    }
    ret = copy_attrs(node->properties, &copy->properties);
    if (ret < 0) {
        goto fail;
    }
    /* libxml2: 1 copies the subtree, 2 the attributes only. */
    if (extended != 1) {
        return copy;
    }
    for (child = node->children; child; child = child->next) {
        child_copy = ff_fdxml_copy_node(child, 1);
        if (!child_copy) {
            goto fail;
        }
        append_child(copy, child_copy);
    }
    return copy;

fail:
    ff_fdxml_free_node(copy);
    return NULL;
}

void ff_fdxml_free(void *ptr)
{
    av_free(ptr);
}

void *ff_fdxml_realloc(void *ptr, size_t size)
{
    return av_realloc(ptr, size);
}

int ff_fdxml_strlen(const char *str)
{
    if (!str) {
        return 0;
    }
    return (int)strlen(str);
}

#if CONFIG_JNI

struct JNIFdxmlFields {
    jclass xml_class;
    jmethodID parse_method;
};

#define OFFSET(x) offsetof(struct JNIFdxmlFields, x)
static const struct FFJniField jfields_fdxml_mapping[] = {
    { "com/solarized/firedown/ffmpegutils/FFmpegXml", NULL, NULL, FF_JNI_CLASS, OFFSET(xml_class), 1 },
    { "com/solarized/firedown/ffmpegutils/FFmpegXml", "parse", "(Ljava/nio/ByteBuffer;)[B", FF_JNI_STATIC_METHOD, OFFSET(parse_method), 1 },
    { NULL }
};
#undef OFFSET

/*
 * One Java call per manifest. Everything JNI here is a LOCAL reference that
 * this function deletes before returning — including the class (jfields are
 * initialised with global = 0): it runs on the same long-lived attached
 * demuxer threads as the okhttp bridge, where nothing frees a local ref for
 * us (see the JNI rules in the fork's CLAUDE.md). FFmpegXml.parse never
 * throws by contract; ff_jni_exception_check still clears anything pending.
 */
xmlDocPtr ff_fdxml_read_memory(void *log_ctx, const char *buf, int len)
{
    struct JNIFdxmlFields jfields = { 0 };
    JNIEnv *env;
    jobject input = NULL;
    jbyteArray output = NULL;
    jbyte *bytes = NULL;
    jsize out_len;
    xmlDocPtr doc = NULL;
    int ret;

    if (!buf || len < 0) {
        return NULL;
    }
    env = ff_jni_get_env(log_ctx);
    if (!env) {
        av_log(log_ctx, AV_LOG_ERROR, "fdxml: no JNIEnv\n");
        return NULL;
    }
    ret = ff_jni_init_jfields(env, &jfields, jfields_fdxml_mapping, 0, log_ctx);
    if (ret < 0) {
        av_log(log_ctx, AV_LOG_ERROR, "fdxml: jfields init failed: %d\n", ret);
        return NULL;
    }

    /* The manifest's own memory, read in place: no copy, and none of JNI's
     * modified-UTF-8 string conversion near the document's bytes. */
    input = (*env)->NewDirectByteBuffer(env, (void *)buf, len);
    if (!input) {
        ff_jni_exception_check(env, 1, log_ctx);
        goto end;
    }
    output = (*env)->CallStaticObjectMethod(env, jfields.xml_class, jfields.parse_method, input);
    ret = ff_jni_exception_check(env, 1, log_ctx);
    if (ret < 0) {
        goto end;
    }
    if (!output) {
        /* Not well-formed XML: the caller reports AVERROR_INVALIDDATA. */
        goto end;
    }
    out_len = (*env)->GetArrayLength(env, output);
    bytes = (*env)->GetByteArrayElements(env, output, NULL);
    if (!bytes) {
        ff_jni_exception_check(env, 1, log_ctx);
        goto end;
    }
    doc = ff_fdxml_doc_from_blob(log_ctx, (const uint8_t *)bytes, (size_t)out_len);
    (*env)->ReleaseByteArrayElements(env, output, bytes, JNI_ABORT);

end:
    if (output) {
        (*env)->DeleteLocalRef(env, output);
    }
    if (input) {
        (*env)->DeleteLocalRef(env, input);
    }
    ff_jni_reset_jfields(env, &jfields, jfields_fdxml_mapping, 0, log_ctx);
    return doc;
}

#else

xmlDocPtr ff_fdxml_read_memory(void *log_ctx, const char *buf, int len)
{
    av_log(log_ctx, AV_LOG_ERROR, "fdxml: DASH manifests need JNI (FFmpegXml)\n");
    return NULL;
}

#endif /* CONFIG_JNI */
