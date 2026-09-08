/*
 * httpd.c - libhttpd implementation. See httpd.h for the contract.
 *
 * Layout: SHA-1 + base64 (for the WebSocket handshake) -> connection
 * bookkeeping -> WebSocket framing -> HTTP request parse/serve -> the
 * per-connection thread -> the accept thread and public API.
 */
#include "httpd.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <ctype.h>
#include <pthread.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#define HTTPD_MAX_ROUTES   16
#define HTTPD_MAX_CONNS    24         /* browsers open several; WS ones stay */
#define HTTPD_HDR_MAX      8192       /* request line + headers             */
#define HTTPD_BODY_MAX     65536
#define HTTPD_WS_MAX       65536      /* largest client frame we will take  */
#define HTTPD_IDLE_SEC     30         /* keep-alive idle timeout            */
#define HTTPD_SEND_SEC     5          /* a client this slow gets dropped    */

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

/* ------------------------------------------------------------------ *
 * SHA-1 and base64 - only ever used on the 60-byte WebSocket accept
 * string, so clarity beats speed.
 * ------------------------------------------------------------------ */
typedef struct {
    uint32_t h[5];
    uint64_t len;
    uint8_t  buf[64];
    size_t   n;
} sha1_t;

static uint32_t rol32(uint32_t v, int s) { return (v << s) | (v >> (32 - s)); }

static void sha1_block(sha1_t *s, const uint8_t *p)
{
    uint32_t w[80], a, b, c, d, e, f, k, t;
    int i;
    for (i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[i*4] << 24) | ((uint32_t)p[i*4+1] << 16) |
               ((uint32_t)p[i*4+2] << 8) | (uint32_t)p[i*4+3];
    for (i = 16; i < 80; i++)
        w[i] = rol32(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3]; e = s->h[4];
    for (i = 0; i < 80; i++) {
        if      (i < 20) { f = (b & c) | (~b & d);          k = 0x5a827999; }
        else if (i < 40) { f = b ^ c ^ d;                   k = 0x6ed9eba1; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
        else             { f = b ^ c ^ d;                   k = 0xca62c1d6; }
        t = rol32(a, 5) + f + e + k + w[i];
        e = d; d = c; c = rol32(b, 30); b = a; a = t;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e;
}

static void sha1_init(sha1_t *s)
{
    s->h[0] = 0x67452301; s->h[1] = 0xefcdab89; s->h[2] = 0x98badcfe;
    s->h[3] = 0x10325476; s->h[4] = 0xc3d2e1f0;
    s->len = 0; s->n = 0;
}

static void sha1_update(sha1_t *s, const void *data, size_t n)
{
    const uint8_t *p = (const uint8_t *)data;
    s->len += n;
    while (n) {
        size_t take = 64 - s->n;
        if (take > n) take = n;
        memcpy(s->buf + s->n, p, take);
        s->n += take; p += take; n -= take;
        if (s->n == 64) { sha1_block(s, s->buf); s->n = 0; }
    }
}

static void sha1_final(sha1_t *s, uint8_t out[20])
{
    uint64_t bits = s->len * 8;
    uint8_t pad = 0x80;
    uint8_t lenbe[8];
    int i;
    sha1_update(s, &pad, 1);
    pad = 0;
    while (s->n != 56) sha1_update(s, &pad, 1);
    for (i = 0; i < 8; i++) lenbe[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha1_update(s, lenbe, 8);
    for (i = 0; i < 5; i++) {
        out[i*4+0] = (uint8_t)(s->h[i] >> 24);
        out[i*4+1] = (uint8_t)(s->h[i] >> 16);
        out[i*4+2] = (uint8_t)(s->h[i] >> 8);
        out[i*4+3] = (uint8_t)(s->h[i]);
    }
}

static void b64(const uint8_t *in, size_t n, char *out)
{
    static const char t[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t i, o = 0;
    for (i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16;
        if (i + 1 < n) v |= (uint32_t)in[i+1] << 8;
        if (i + 2 < n) v |= in[i+2];
        out[o++] = t[(v >> 18) & 63];
        out[o++] = t[(v >> 12) & 63];
        out[o++] = (i + 1 < n) ? t[(v >> 6) & 63] : '=';
        out[o++] = (i + 2 < n) ? t[v & 63]        : '=';
    }
    out[o] = 0;
}

/* ------------------------------------------------------------------ *
 * Server / connection state
 * ------------------------------------------------------------------ */
typedef struct {
    char          path[64];
    httpd_handler fn;
    void         *user;
} route_t;

struct httpd_conn {
    int                fd;
    httpd_t           *h;
    int                is_ws;
    pthread_mutex_t    wlock;      /* serializes writes to fd                */
    struct httpd_conn *next;       /* WebSocket client list                  */

    /* current request (valid only inside a handler) */
    char   hdr[HTTPD_HDR_MAX];     /* NUL-terminated header block            */
    char  *body;
    size_t body_len;
};

struct httpd {
    int              port;
    int              loopback_only;
    int              lfd;
    volatile int     stop;
    pthread_t        acc_tid;
    int              acc_started;
    httpd_log_fn     log;

    route_t          routes[HTTPD_MAX_ROUTES];
    int              nroutes;
    httpd_handler    def_fn;
    void            *def_user;

    char             ws_path[64];
    httpd_ws_open_fn ws_open;
    httpd_ws_text_fn ws_text;
    void            *ws_user;

    pthread_mutex_t  list_lock;    /* guards ws_list + nconns               */
    httpd_conn_t    *ws_list;
    int              nconns;
};

static void hlog(httpd_t *h, const char *fmt, ...)
{
    char line[512];
    va_list ap;
    if (!h->log) return;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    h->log(line);
}

/* write all n bytes, honouring the socket send timeout. -1 on error. */
static int write_all(httpd_conn_t *c, const void *p, size_t n)
{
    const uint8_t *b = (const uint8_t *)p;
    while (n) {
        ssize_t w = send(c->fd, b, n, MSG_NOSIGNAL);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (w == 0) return -1;
        b += w; n -= (size_t)w;
    }
    return 0;
}

/* ------------------------------------------------------------------ *
 * WebSocket framing (RFC 6455). Server->client frames are never masked;
 * client->server frames always are.
 * ------------------------------------------------------------------ */
#define WS_CONT  0x0
#define WS_TEXT  0x1
#define WS_BIN   0x2
#define WS_CLOSE 0x8
#define WS_PING  0x9
#define WS_PONG  0xa

static int ws_send_frame(httpd_conn_t *c, int opcode, const void *p, size_t n)
{
    uint8_t hdr[10];
    size_t hn = 0;
    int rc;

    hdr[hn++] = (uint8_t)(0x80 | opcode);       /* FIN + opcode */
    if (n < 126) {
        hdr[hn++] = (uint8_t)n;
    } else if (n <= 0xffff) {
        hdr[hn++] = 126;
        hdr[hn++] = (uint8_t)(n >> 8);
        hdr[hn++] = (uint8_t)n;
    } else {
        int i;
        hdr[hn++] = 127;
        for (i = 7; i >= 0; i--) hdr[hn++] = (uint8_t)((uint64_t)n >> (8 * i));
    }

    pthread_mutex_lock(&c->wlock);
    rc = write_all(c, hdr, hn);
    if (rc == 0 && n) rc = write_all(c, p, n);
    pthread_mutex_unlock(&c->wlock);
    return rc;
}

/* Read exactly n bytes. 0 = ok, -1 = closed/error/timeout. */
static int read_all(int fd, void *p, size_t n)
{
    uint8_t *b = (uint8_t *)p;
    while (n) {
        ssize_t r = recv(fd, b, n, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) return -1;
        b += r; n -= (size_t)r;
    }
    return 0;
}

/*
 * Read one frame. Payload goes into buf (cap bytes); frames larger than cap
 * are drained and reported as too-big (-2) rather than desynchronising the
 * stream. Returns the payload length, -1 on close/error, -2 on oversize.
 */
static long ws_read_frame(httpd_conn_t *c, int *opcode, uint8_t *buf, size_t cap)
{
    uint8_t h2[2], ext[8], mask[4];
    uint64_t len;
    int masked;
    size_t i;

    if (read_all(c->fd, h2, 2) < 0) return -1;
    *opcode = h2[0] & 0x0f;
    masked  = (h2[1] & 0x80) != 0;
    len     = h2[1] & 0x7f;

    if (len == 126) {
        if (read_all(c->fd, ext, 2) < 0) return -1;
        len = ((uint64_t)ext[0] << 8) | ext[1];
    } else if (len == 127) {
        if (read_all(c->fd, ext, 8) < 0) return -1;
        len = 0;
        for (i = 0; i < 8; i++) len = (len << 8) | ext[i];
    }
    if (masked && read_all(c->fd, mask, 4) < 0) return -1;

    if (len > cap) {
        uint8_t sink[512];
        while (len) {
            size_t take = len > sizeof(sink) ? sizeof(sink) : (size_t)len;
            if (read_all(c->fd, sink, take) < 0) return -1;
            len -= take;
        }
        return -2;
    }
    if (len && read_all(c->fd, buf, (size_t)len) < 0) return -1;
    if (masked)
        for (i = 0; i < (size_t)len; i++) buf[i] ^= mask[i & 3];
    return (long)len;
}

/* ------------------------------------------------------------------ *
 * HTTP request parsing
 * ------------------------------------------------------------------ */

/* Case-insensitive header lookup over the NUL-terminated header block. The
 * returned pointer is into c->hdr and is valid until the next request. */
static const char *hdr_find(const char *block, const char *name, char *out, size_t outn)
{
    size_t nl = strlen(name);
    const char *p = strchr(block, '\n');   /* skip the request line */
    if (!p) return NULL;
    p++;
    while (*p) {
        const char *eol = strchr(p, '\n');
        size_t linelen = eol ? (size_t)(eol - p) : strlen(p);
        if (linelen && p[linelen - 1] == '\r') linelen--;
        if (linelen > nl && strncasecmp(p, name, nl) == 0 && p[nl] == ':') {
            const char *v = p + nl + 1;
            size_t vl;
            while (*v == ' ' || *v == '\t') v++;
            vl = linelen - (size_t)(v - p);
            if (vl >= outn) vl = outn - 1;
            memcpy(out, v, vl);
            out[vl] = 0;
            return out;
        }
        if (!eol) break;
        p = eol + 1;
    }
    return NULL;
}

const char *httpd_header(const httpd_req_t *r, const char *name)
{
    /* Small per-call scratch: callers use the value immediately (this is a
     * convenience for handlers, the server itself uses hdr_find directly). */
    static __thread char scratch[512];
    return hdr_find(r->conn->hdr, name, scratch, sizeof(scratch));
}

static int hexval(int ch)
{
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

/* percent-decode src[0..n) into out (NUL-terminated, truncated to fit) */
static void url_decode(const char *src, size_t n, char *out, size_t outn)
{
    size_t i, o = 0;
    for (i = 0; i < n && o + 1 < outn; i++) {
        if (src[i] == '%' && i + 2 < n) {
            int hi = hexval((unsigned char)src[i+1]), lo = hexval((unsigned char)src[i+2]);
            if (hi >= 0 && lo >= 0) { out[o++] = (char)((hi << 4) | lo); i += 2; continue; }
        }
        out[o++] = (src[i] == '+') ? ' ' : src[i];
    }
    out[o] = 0;
}

int httpd_param(const httpd_req_t *r, const char *key, char *out, size_t outn)
{
    const char *q = r->query;
    size_t kl = strlen(key);
    while (q && *q) {
        if (strncmp(q, key, kl) == 0 && q[kl] == '=') {
            const char *v = q + kl + 1;
            const char *end = strchr(v, '&');
            url_decode(v, end ? (size_t)(end - v) : strlen(v), out, outn);
            return 0;
        }
        q = strchr(q, '&');
        if (q) q++;
    }
    return -1;
}

/* ------------------------------------------------------------------ *
 * Replies
 * ------------------------------------------------------------------ */
static const char *status_text(int code)
{
    switch (code) {
    case 200: return "OK";
    case 400: return "Bad Request";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 500: return "Internal Server Error";
    case 503: return "Service Unavailable";
    default:  return "OK";
    }
}

void httpd_reply_full(const httpd_req_t *r, int code, const char *ctype,
                      const char *extra, const void *body, size_t len)
{
    char hdr[512];
    int hn = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "%s"
        "Connection: keep-alive\r\n\r\n",
        code, status_text(code), ctype, len, extra ? extra : "");
    pthread_mutex_lock(&r->conn->wlock);
    if (write_all(r->conn, hdr, (size_t)hn) == 0 && len)
        write_all(r->conn, body, len);
    pthread_mutex_unlock(&r->conn->wlock);
}

void httpd_reply(const httpd_req_t *r, int code, const char *ctype,
                 const void *body, size_t len)
{
    httpd_reply_full(r, code, ctype, NULL, body, len);
}

void httpd_reply_str(const httpd_req_t *r, int code, const char *ctype, const char *body)
{
    httpd_reply_full(r, code, ctype, NULL, body, strlen(body));
}

void httpd_reply_notmodified(const httpd_req_t *r, const char *extra)
{
    char hdr[512];
    int hn = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 304 Not Modified\r\n%sConnection: keep-alive\r\n\r\n",
        extra ? extra : "");
    pthread_mutex_lock(&r->conn->wlock);
    write_all(r->conn, hdr, (size_t)hn);
    pthread_mutex_unlock(&r->conn->wlock);
}

/* ------------------------------------------------------------------ *
 * WebSocket client registry
 * ------------------------------------------------------------------ */
static void ws_register(httpd_t *h, httpd_conn_t *c)
{
    pthread_mutex_lock(&h->list_lock);
    c->next = h->ws_list;
    h->ws_list = c;
    c->is_ws = 1;
    pthread_mutex_unlock(&h->list_lock);
}

static void ws_unregister(httpd_t *h, httpd_conn_t *c)
{
    httpd_conn_t **pp;
    pthread_mutex_lock(&h->list_lock);
    for (pp = &h->ws_list; *pp; pp = &(*pp)->next) {
        if (*pp == c) { *pp = c->next; break; }
    }
    c->is_ws = 0;
    pthread_mutex_unlock(&h->list_lock);
}

int httpd_ws_send(httpd_conn_t *c, const char *text, size_t len)
{
    return ws_send_frame(c, WS_TEXT, text, len) == 0 ? 1 : 0;
}

/*
 * Broadcast under list_lock, so a client thread cannot free a connection
 * mid-send. A client that errors (or hits the send timeout) is shut down
 * here; its own thread notices the dead socket and cleans up. The lock
 * ordering is always list_lock -> conn->wlock, never the reverse.
 */
int httpd_ws_broadcast(httpd_t *h, const char *text, size_t len)
{
    httpd_conn_t *c;
    int n = 0;
    if (!h) return 0;
    pthread_mutex_lock(&h->list_lock);
    for (c = h->ws_list; c; c = c->next) {
        if (ws_send_frame(c, WS_TEXT, text, len) == 0) n++;
        else shutdown(c->fd, SHUT_RDWR);
    }
    pthread_mutex_unlock(&h->list_lock);
    return n;
}

int httpd_ws_clients(httpd_t *h)
{
    httpd_conn_t *c;
    int n = 0;
    if (!h) return 0;
    pthread_mutex_lock(&h->list_lock);
    for (c = h->ws_list; c; c = c->next) n++;
    pthread_mutex_unlock(&h->list_lock);
    return n;
}

/* ------------------------------------------------------------------ *
 * Per-connection thread
 * ------------------------------------------------------------------ */

/* Complete the RFC 6455 handshake and run the read loop until close. */
static void serve_websocket(httpd_conn_t *c, const char *key)
{
    static const char guid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    httpd_t *h = c->h;
    sha1_t s;
    uint8_t digest[20];
    char accept[32], resp[256];
    uint8_t *payload;
    int rn;

    sha1_init(&s);
    sha1_update(&s, key, strlen(key));
    sha1_update(&s, guid, sizeof(guid) - 1);
    sha1_final(&s, digest);
    b64(digest, sizeof(digest), accept);

    rn = snprintf(resp, sizeof(resp),
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n\r\n", accept);
    if (write_all(c, resp, (size_t)rn) < 0) return;

    payload = (uint8_t *)malloc(HTTPD_WS_MAX + 1);
    if (!payload) return;

    ws_register(h, c);
    hlog(h, "httpd: websocket client connected (%d total)", httpd_ws_clients(h));
    if (h->ws_open) h->ws_open(c, h->ws_user);

    for (;;) {
        int op;
        long n = ws_read_frame(c, &op, payload, HTTPD_WS_MAX);
        if (n == -1) break;
        if (n == -2) continue;                   /* oversize, already drained */
        if (op == WS_CLOSE) { ws_send_frame(c, WS_CLOSE, NULL, 0); break; }
        if (op == WS_PING)  { ws_send_frame(c, WS_PONG, payload, (size_t)n); continue; }
        if (op == WS_PONG)  continue;
        if (op == WS_TEXT && h->ws_text) {
            payload[n] = 0;
            h->ws_text(c, (const char *)payload, (size_t)n, h->ws_user);
        }
    }

    ws_unregister(h, c);
    free(payload);
    hlog(h, "httpd: websocket client gone (%d left)", httpd_ws_clients(h));
}

/*
 * Read one request's headers into c->hdr. Returns the header length, 0 if
 * the peer closed cleanly, -1 on error/oversize. Any bytes of the body that
 * arrived in the same read are left in c->hdr past the terminator and
 * reported through *pre_body / *pre_len.
 */
static int read_request(httpd_conn_t *c, char **pre_body, size_t *pre_len)
{
    size_t got = 0;
    char *end = NULL;

    for (;;) {
        ssize_t r;
        if (got) {
            c->hdr[got] = 0;
            end = strstr(c->hdr, "\r\n\r\n");
            if (end) break;
        }
        if (got + 1 >= sizeof(c->hdr)) return -1;
        r = recv(c->fd, c->hdr + got, sizeof(c->hdr) - 1 - got, 0);
        if (r < 0) { if (errno == EINTR) continue; return got ? -1 : 0; }
        if (r == 0) return got ? -1 : 0;
        got += (size_t)r;
    }

    *end = 0;                                  /* terminate the header block */
    *pre_body = end + 4;
    *pre_len  = got - (size_t)(*pre_body - c->hdr);
    return 1;
}

static void dispatch(httpd_t *h, httpd_req_t *req)
{
    int i;
    for (i = 0; i < h->nroutes; i++) {
        if (strcmp(req->path, h->routes[i].path) == 0) {
            h->routes[i].fn(req, h->routes[i].user);
            return;
        }
    }
    if (h->def_fn) { h->def_fn(req, h->def_user); return; }
    httpd_reply_str(req, 404, "text/plain", "not found\n");
}

static void *conn_thread(void *arg)
{
    httpd_conn_t *c = (httpd_conn_t *)arg;
    httpd_t *h = c->h;
    struct timeval tv;
    int one = 1;

    tv.tv_sec = HTTPD_IDLE_SEC; tv.tv_usec = 0;
    setsockopt(c->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    tv.tv_sec = HTTPD_SEND_SEC; tv.tv_usec = 0;
    setsockopt(c->fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(c->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    while (!h->stop) {
        httpd_req_t req;
        char method[16] = {0}, uri[1024] = {0}, pathbuf[1024];
        char clbuf[32], upg[64], wskey[128];
        char *pre_body, *q;
        size_t pre_len, clen = 0;
        int rc, http10 = 0;

        rc = read_request(c, &pre_body, &pre_len);
        if (rc <= 0) break;

        /* request line: METHOD SP URI SP VERSION */
        if (sscanf(c->hdr, "%15s %1023s", method, uri) != 2) {
            memset(&req, 0, sizeof(req));
            req.method = ""; req.path = ""; req.query = ""; req.body = "";
            req.conn = c;
            httpd_reply_str(&req, 400, "text/plain", "bad request\n");
            break;
        }
        /* HTTP/1.0 clients get one request per connection unless they ask
         * otherwise; note it now, while the request line is still intact. */
        {
            const char *eol = strchr(c->hdr, '\n');
            const char *v10 = strstr(c->hdr, "HTTP/1.0");
            http10 = v10 && (!eol || v10 < eol);
        }
        /* the raw URI keeps %xx for the query (httpd_param decodes); the
         * path itself is decoded here so "/a%20b" matches a route */
        q = strchr(uri, '?');
        if (q) *q++ = 0; else q = (char *)"";
        url_decode(uri, strlen(uri), pathbuf, sizeof(pathbuf));

        /* body, if any */
        c->body = NULL; c->body_len = 0;
        if (hdr_find(c->hdr, "Content-Length", clbuf, sizeof(clbuf))) {
            long v = strtol(clbuf, NULL, 10);
            if (v > 0 && v <= HTTPD_BODY_MAX) clen = (size_t)v;
        }
        if (clen) {
            c->body = (char *)malloc(clen + 1);
            if (!c->body) break;
            if (pre_len > clen) pre_len = clen;
            memcpy(c->body, pre_body, pre_len);
            if (pre_len < clen && read_all(c->fd, c->body + pre_len, clen - pre_len) < 0) {
                free(c->body); c->body = NULL; break;
            }
            c->body[clen] = 0;
            c->body_len = clen;
        }

        req.method   = method;
        req.path     = pathbuf;
        req.query    = q;
        req.body     = c->body ? c->body : "";
        req.body_len = c->body_len;
        req.conn     = c;

        /* WebSocket upgrade on the registered path */
        if (h->ws_path[0] && strcmp(pathbuf, h->ws_path) == 0 &&
            hdr_find(c->hdr, "Upgrade", upg, sizeof(upg)) &&
            strcasecmp(upg, "websocket") == 0 &&
            hdr_find(c->hdr, "Sec-WebSocket-Key", wskey, sizeof(wskey))) {
            free(c->body); c->body = NULL;
            serve_websocket(c, wskey);
            break;                              /* connection is spent */
        }

        dispatch(h, &req);

        free(c->body);
        c->body = NULL;

        /* honour an explicit close request; otherwise keep the connection.
         * (No pipelining: any bytes read past this request's body are
         * dropped. Browsers don't pipeline, and the alternative is carrying
         * a residual buffer through every path above for no gain here.) */
        if (hdr_find(c->hdr, "Connection", upg, sizeof(upg))) {
            if (strcasecmp(upg, "close") == 0) break;
            if (http10 && strcasecmp(upg, "keep-alive") != 0) break;
        } else if (http10) {
            break;
        }
    }

    close(c->fd);
    pthread_mutex_destroy(&c->wlock);
    pthread_mutex_lock(&h->list_lock);
    h->nconns--;
    pthread_mutex_unlock(&h->list_lock);
    free(c);
    return NULL;
}

/* ------------------------------------------------------------------ *
 * Accept thread + public API
 * ------------------------------------------------------------------ */
static void *accept_thread(void *arg)
{
    httpd_t *h = (httpd_t *)arg;

    while (!h->stop) {
        pthread_t tid;
        httpd_conn_t *c;
        int cfd = accept(h->lfd, NULL, NULL);
        int busy;

        if (cfd < 0) {
            if (errno == EINTR) continue;
            if (h->stop) break;
            hlog(h, "httpd: accept: %s", strerror(errno));
            break;
        }

        pthread_mutex_lock(&h->list_lock);
        busy = h->nconns >= HTTPD_MAX_CONNS;
        if (!busy) h->nconns++;
        pthread_mutex_unlock(&h->list_lock);
        if (busy) {
            static const char msg[] =
                "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n"
                "Connection: close\r\n\r\n";
            if (send(cfd, msg, sizeof(msg) - 1, MSG_NOSIGNAL) < 0) { /* going away anyway */ }
            close(cfd);
            hlog(h, "httpd: refusing connection - %d already open", HTTPD_MAX_CONNS);
            continue;
        }

        c = (httpd_conn_t *)calloc(1, sizeof(*c));
        if (!c) { close(cfd); continue; }
        c->fd = cfd;
        c->h  = h;
        pthread_mutex_init(&c->wlock, NULL);

        if (pthread_create(&tid, NULL, conn_thread, c) != 0) {
            hlog(h, "httpd: pthread_create: %s", strerror(errno));
            pthread_mutex_destroy(&c->wlock);
            close(cfd);
            free(c);
            pthread_mutex_lock(&h->list_lock);
            h->nconns--;
            pthread_mutex_unlock(&h->list_lock);
            continue;
        }
        pthread_detach(tid);
    }
    return NULL;
}

httpd_t *httpd_new(int port)
{
    httpd_t *h = (httpd_t *)calloc(1, sizeof(*h));
    if (!h) return NULL;
    h->port = port;
    h->lfd  = -1;
    pthread_mutex_init(&h->list_lock, NULL);
    return h;
}

void httpd_set_log(httpd_t *h, httpd_log_fn fn) { if (h) h->log = fn; }
void httpd_set_loopback(httpd_t *h, int lo)     { if (h) h->loopback_only = lo; }

int httpd_route(httpd_t *h, const char *path, httpd_handler fn, void *user)
{
    if (!h || h->nroutes >= HTTPD_MAX_ROUTES) return -1;
    snprintf(h->routes[h->nroutes].path, sizeof(h->routes[0].path), "%s", path);
    h->routes[h->nroutes].fn   = fn;
    h->routes[h->nroutes].user = user;
    h->nroutes++;
    return 0;
}

void httpd_default(httpd_t *h, httpd_handler fn, void *user)
{
    if (!h) return;
    h->def_fn = fn;
    h->def_user = user;
}

int httpd_ws_route(httpd_t *h, const char *path, httpd_ws_open_fn on_open,
                   httpd_ws_text_fn on_text, void *user)
{
    if (!h) return -1;
    snprintf(h->ws_path, sizeof(h->ws_path), "%s", path);
    h->ws_open = on_open;
    h->ws_text = on_text;
    h->ws_user = user;
    return 0;
}

int httpd_start(httpd_t *h)
{
    struct sockaddr_in sa;
    int one = 1, attempt;

    if (!h) return -1;
    /* A dead peer must give us EPIPE from send(), not a fatal signal. */
    signal(SIGPIPE, SIG_IGN);

    h->lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (h->lfd < 0) { hlog(h, "httpd: socket: %s", strerror(errno)); return -1; }
    setsockopt(h->lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    /* FD_CLOEXEC: this daemon shells out (udhcpc -b backgrounds itself), and
     * a child inheriting the listening socket pins the port for its whole
     * life - observed for real before this was set. */
    if (fcntl(h->lfd, F_SETFD, FD_CLOEXEC) < 0)
        hlog(h, "httpd: warning: fcntl(FD_CLOEXEC) failed: %s", strerror(errno));

    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = h->loopback_only ? htonl(INADDR_LOOPBACK) : INADDR_ANY;
    sa.sin_port = htons((uint16_t)h->port);

    /* Restarting right after a kill can race the old socket's teardown;
     * losing the UI + REST API for the whole run over 4ms is not useful. */
    for (attempt = 0; ; attempt++) {
        if (bind(h->lfd, (struct sockaddr *)&sa, sizeof(sa)) == 0) break;
        if (errno != EADDRINUSE || attempt >= 10) {
            hlog(h, "httpd: bind :%d failed (%s) - server disabled",
                 h->port, strerror(errno));
            close(h->lfd); h->lfd = -1;
            return -1;
        }
        if (attempt == 0) hlog(h, "httpd: :%d busy, retrying for up to 5s", h->port);
        usleep(500000);
    }

    if (listen(h->lfd, 8) < 0) {
        hlog(h, "httpd: listen: %s", strerror(errno));
        close(h->lfd); h->lfd = -1;
        return -1;
    }
    if (pthread_create(&h->acc_tid, NULL, accept_thread, h) != 0) {
        hlog(h, "httpd: pthread_create(accept): %s", strerror(errno));
        close(h->lfd); h->lfd = -1;
        return -1;
    }
    h->acc_started = 1;
    hlog(h, "httpd: listening on http://%s:%d/",
         h->loopback_only ? "127.0.0.1" : "0.0.0.0", h->port);
    return 0;
}

void httpd_stop(httpd_t *h)
{
    httpd_conn_t *c;
    if (!h) return;
    h->stop = 1;
    if (h->lfd >= 0) { shutdown(h->lfd, SHUT_RDWR); close(h->lfd); h->lfd = -1; }
    /* wake every websocket reader; each connection thread frees itself */
    pthread_mutex_lock(&h->list_lock);
    for (c = h->ws_list; c; c = c->next) shutdown(c->fd, SHUT_RDWR);
    pthread_mutex_unlock(&h->list_lock);
}
