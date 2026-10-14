/*
 * fdxml — the slice of libxml2's tree API that libavformat/dashdec.c uses,
 * backed by the platform's XML parser through JNI instead of libxml2.
 *
 * Firedown fork only. dashdec.c includes this in place of <libxml/parser.h>
 * and keeps calling libxml2's names; the macros below route them here. The
 * tree is built from ONE Java call per manifest
 * (com.solarized.firedown.ffmpegutils.FFmpegXml.parse), which returns it
 * serialized; see that class for the wire format. Nothing in here is shared
 * between threads: every parse builds its own tree, so concurrent DASH
 * parses (capture probes, a download, a live refresh) cannot interfere —
 * the class of bug patch 0006 removed from libxml2 does not exist here.
 *
 * The SEMANTICS of each function are libxml2 2.13's, as far as dashdec.c can
 * observe them, and several are load-bearing there:
 *  - element and attribute names are LOCAL names (<mpd:MPD> is "MPD");
 *  - xmlGetProp matches the local name whatever its namespace, first wins;
 *  - xmlNodeGetContent of an element is the concatenation of its descendant
 *    text and CDATA, and "" — never NULL — when there is none
 *    (resolve_content_path compares the result with "" unguarded);
 *  - text, CDATA and comment/PI children stay distinct node types
 *    (get_content_url only reads a BaseURL whose FIRST child is text);
 *  - xmlNodeSetContent stores what xmlEncodeSpecialChars returned. libxml2
 *    escapes, then decodes entity references on set; here BOTH are identity,
 *    which yields the same stored text. They are a pair: keep them in step.
 */

#ifndef AVFORMAT_FDXML_H
#define AVFORMAT_FDXML_H

#include <stddef.h>
#include <stdint.h>

typedef char xmlChar;

typedef enum {
    XML_ELEMENT_NODE       = 1,
    XML_TEXT_NODE          = 3,
    XML_CDATA_SECTION_NODE = 4,
    XML_PI_NODE            = 7,
    XML_COMMENT_NODE       = 8,
} xmlElementType;

typedef struct _xmlAttr {
    char *name;
    char *value;
    struct _xmlAttr *next;
} xmlAttr, *xmlAttrPtr;

typedef struct _xmlNode {
    xmlElementType type;
    char *name;                 /* elements: local name; other nodes: NULL */
    char *content;              /* text and CDATA nodes only */
    struct _xmlNode *children;
    struct _xmlNode *last;
    struct _xmlNode *next;
    struct _xmlNode *parent;
    xmlAttr *properties;
} xmlNode, *xmlNodePtr;

typedef struct _xmlDoc {
    xmlNode *root;
} xmlDoc, *xmlDocPtr;

/* Parse a manifest through FFmpegXml.parse. NULL when it is not well-formed
 * XML, carries a DOCTYPE, or JNI is unavailable. */
xmlDocPtr ff_fdxml_read_memory(void *log_ctx, const char *buf, int len);

/* Rebuild a tree from FFmpegXml's wire format. Separate from the JNI call so
 * a host test can feed it bytes produced by the same Java code. */
xmlDocPtr ff_fdxml_doc_from_blob(void *log_ctx, const uint8_t *blob, size_t len);

void       ff_fdxml_free_doc(xmlDocPtr doc);
xmlNodePtr ff_fdxml_doc_get_root_element(const xmlDoc *doc);
xmlNodePtr ff_fdxml_first_element_child(const xmlNode *node);
xmlNodePtr ff_fdxml_next_element_sibling(const xmlNode *node);
char      *ff_fdxml_get_prop(const xmlNode *node, const char *name);
char      *ff_fdxml_node_get_content(const xmlNode *node);
int        ff_fdxml_node_set_content(xmlNodePtr node, const char *content);
char      *ff_fdxml_encode_special_chars(const void *doc, const char *input);
xmlNodePtr ff_fdxml_new_node(const void *ns, const char *name);
xmlNodePtr ff_fdxml_copy_node(const xmlNode *node, int extended);
void       ff_fdxml_free_node(xmlNodePtr node);
void       ff_fdxml_free(void *ptr);
void      *ff_fdxml_realloc(void *ptr, size_t size);
int        ff_fdxml_strlen(const char *str);

#define xmlFreeDoc              ff_fdxml_free_doc
#define xmlDocGetRootElement    ff_fdxml_doc_get_root_element
#define xmlFirstElementChild    ff_fdxml_first_element_child
#define xmlNextElementSibling   ff_fdxml_next_element_sibling
#define xmlGetProp              ff_fdxml_get_prop
#define xmlNodeGetContent       ff_fdxml_node_get_content
#define xmlNodeSetContent       ff_fdxml_node_set_content
#define xmlEncodeSpecialChars   ff_fdxml_encode_special_chars
#define xmlNewNode              ff_fdxml_new_node
#define xmlCopyNode             ff_fdxml_copy_node
#define xmlFreeNode             ff_fdxml_free_node
#define xmlFree                 ff_fdxml_free
#define xmlRealloc              ff_fdxml_realloc
#define xmlStrlen               ff_fdxml_strlen

/* libxml2 process-global setup/teardown: nothing to do here. */
#define LIBXML_TEST_VERSION
#define xmlCleanupParser()      do { } while (0)

#endif /* AVFORMAT_FDXML_H */
