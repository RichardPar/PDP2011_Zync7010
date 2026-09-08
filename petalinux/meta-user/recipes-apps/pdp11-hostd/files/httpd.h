/*
 * httpd.h - libhttpd: a small embedded HTTP/1.1 + WebSocket server.
 *
 * Written for pdp11-hostd (the PDP-11 front-panel web UI needs live push,
 * static asset serving and the pre-existing REST API from one port), but
 * deliberately kept free of anything PDP-11: it knows nothing about disks,
 * UIO or the daemon's state. Built as libhttpd.a and linked in.
 *
 * Properties that matter here:
 *   - no external dependencies (its own SHA-1 and base64, for the RFC 6455
 *     handshake) - it has to cross-compile into a PetaLinux rootfs where
 *     pulling in libwebsockets/openssl for one page would be absurd
 *   - one detached thread per connection, capped (HTTPD_MAX_CONNS), so a
 *     long-lived WebSocket never blocks a plain GET, and a wedged browser
 *     never blocks the broadcaster (send timeout + drop)
 *   - HTTP/1.1 keep-alive, so loading a page of several assets is one
 *     connection, not one per file
 *
 * Threading contract: handlers run on the connection's own thread and must
 * send exactly one reply. httpd_ws_broadcast() may be called from any
 * thread. A client that can't absorb a broadcast within the send timeout is
 * closed rather than allowed to stall the caller.
 *
 * Usage:
 *     httpd_t *h = httpd_new(8080);
 *     httpd_route(h, "/status", status_handler, NULL);
 *     httpd_ws_route(h, "/ws", on_open, on_text, NULL);
 *     httpd_default(h, static_file_handler, NULL);
 *     httpd_start(h);
 *     ... httpd_ws_broadcast(h, json, strlen(json)) from anywhere ...
 */
#ifndef HTTPD_H
#define HTTPD_H

#include <stddef.h>

typedef struct httpd      httpd_t;
typedef struct httpd_conn httpd_conn_t;

/* A parsed request. Every pointer is owned by the connection and is valid
 * only for the duration of the handler call. */
typedef struct {
    const char   *method;      /* "GET", "POST", ...                        */
    const char   *path;        /* "/load"  - query string already split off */
    const char   *query;       /* "unit=1&path=x", "" when there is none    */
    const char   *body;        /* request body, "" when there is none       */
    size_t        body_len;
    httpd_conn_t *conn;
} httpd_req_t;

/* A request handler must send exactly one reply (httpd_reply*). */
typedef void (*httpd_handler)(const httpd_req_t *req, void *user);

/* WebSocket callbacks. on_open fires once the handshake has completed (a
 * good place to push an initial snapshot); on_text for each text frame the
 * client sends. Both run on the connection's thread. */
typedef void (*httpd_ws_open_fn)(httpd_conn_t *c, void *user);
typedef void (*httpd_ws_text_fn)(httpd_conn_t *c, const char *msg, size_t len, void *user);

/* Optional log sink - one already-formatted line, no trailing newline. */
typedef void (*httpd_log_fn)(const char *line);

httpd_t *httpd_new(int port);
void     httpd_set_log(httpd_t *h, httpd_log_fn fn);
/* Bind to loopback only (default: all interfaces). Call before httpd_start. */
void     httpd_set_loopback(httpd_t *h, int loopback_only);

/* Exact-path routes, checked in registration order; then the default
 * handler (typically static assets + 404). Returns 0, or -1 if full. */
int      httpd_route(httpd_t *h, const char *path, httpd_handler fn, void *user);
void     httpd_default(httpd_t *h, httpd_handler fn, void *user);
int      httpd_ws_route(httpd_t *h, const char *path,
                        httpd_ws_open_fn on_open, httpd_ws_text_fn on_text, void *user);

/* Bind + spawn the accept thread. 0 = ok, -1 = the port could not be bound
 * (already logged). Retries briefly on EADDRINUSE. */
int      httpd_start(httpd_t *h);
void     httpd_stop(httpd_t *h);

/* Replies. Exactly one per request. */
void     httpd_reply(const httpd_req_t *r, int code, const char *ctype,
                     const void *body, size_t len);
void     httpd_reply_str(const httpd_req_t *r, int code, const char *ctype,
                         const char *body);
/* extra_hdrs, if non-NULL, is inserted verbatim and must end with "\r\n". */
void     httpd_reply_full(const httpd_req_t *r, int code, const char *ctype,
                          const char *extra_hdrs, const void *body, size_t len);
/* 304, for a conditional GET whose validator matched. Carries no body and
 * no Content-Length, as a 304 must not. */
void     httpd_reply_notmodified(const httpd_req_t *r, const char *extra_hdrs);

/* URL-decoded query parameter. 0 = found and copied, -1 = absent. */
int      httpd_param(const httpd_req_t *r, const char *key, char *out, size_t outn);
/* Case-insensitive request header lookup ("Host"), NULL if absent. */
const char *httpd_header(const httpd_req_t *r, const char *name);

/* Send one text frame to one client / to every connected client. Returns
 * the number of clients written to (0 or 1 for the single-client form). */
int      httpd_ws_send(httpd_conn_t *c, const char *text, size_t len);
int      httpd_ws_broadcast(httpd_t *h, const char *text, size_t len);
int      httpd_ws_clients(httpd_t *h);

#endif /* HTTPD_H */
