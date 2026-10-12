/*
 * sslwrap - TLS wrapper for a tcpserver service (ucspi-ssl style).
 *
 * Usage:
 *   tcpserver ... 0 465 sslwrap -c servercert.pem [-k key.pem] [-v] \
 *     program [args...]
 *
 * tcpserver accepts the TCP connection, drops privileges, and execs
 * sslwrap with the client socket on fd 0 and fd 1. sslwrap does the
 * TLS handshake on that socket, then runs program with plaintext on
 * its stdin/stdout.
 *
 * Cert file may contain the key as well (qmail servercert.pem style).
 * Program sees the usual tcpserver environment (TCPLOCALPORT,
 * TCPREMOTEIP, ...), so vchkpw can tell smtps/pop3s from plain ports.
 *
 * Exit codes: 0 ok, 100 usage, 111 error.
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <openssl/ssl.h>
#include <openssl/err.h>

#define BUFSIZE 16384

static int verbose = 0;

static void
oops(const char *msg)
{
  fprintf(stderr, "sslwrap: %s: %s\n", msg, strerror(errno));
  exit(111);
}

static void
oops_ssl(const char *msg)
{
  fprintf(stderr, "sslwrap: %s\n", msg);
  ERR_print_errors_fp(stderr);
  exit(111);
}

static void
usage(void)
{
  fprintf(stderr,
    "usage: sslwrap -c certfile [-k keyfile] [-v] program [args]\n"
    "  -c certfile   server certificate (PEM; may include private key)\n"
    "  -k keyfile    private key (PEM), if not inside certfile\n"
    "  -v            verbose logging to stderr\n");
  exit(100);
}

static void
logmsg(const char *msg)
{
  if (verbose)
    fprintf(stderr, "sslwrap: %s\n", msg);
}

/* write all of buf, handling short writes and EINTR */
static int
write_all(int fd, const char *buf, int len)
{
  int n;
  int off = 0;

  while (off < len) {
    n = write(fd, buf + off, len - off);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (n == 0)
      return -1;
    off += n;
  }
  return off;
}

/*
 * SSL_write can return WANT_READ / WANT_WRITE (renegotiation or
 * non-blocking socket). Loop until all bytes are written.
 */
static int
ssl_write_all(SSL *ssl, const char *buf, int len)
{
  int n;
  int off = 0;

  while (off < len) {
    n = SSL_write(ssl, buf + off, len - off);
    if (n <= 0) {
      int err = SSL_get_error(ssl, n);
      if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE)
        continue;
      return -1;
    }
    off += n;
  }
  return off;
}

/*
 * Pump data between the TLS socket (fd 0 / SSL) and the child pipe.
 *
 * tls_eof:   client sent close_notify (or hard error); stop reading TLS
 * child_eof: child closed stdout; stop reading child
 *
 * When the TLS side ends first we half-close the child's stdin so a
 * protocol QUIT still runs. When the child ends first we SSL_shutdown.
 */
static void
relay(SSL *ssl, int cfd)
{
  char buf[BUFSIZE];
  int tls_eof = 0;
  int child_eof = 0;
  int flags;

  flags = fcntl(0, F_GETFL, 0);
  if (flags >= 0)
    fcntl(0, F_SETFL, flags | O_NONBLOCK);
  flags = fcntl(cfd, F_GETFL, 0);
  if (flags >= 0)
    fcntl(cfd, F_SETFL, flags | O_NONBLOCK);

  while (!tls_eof || !child_eof) {
    fd_set rfds;
    int maxfd = -1;
    int do_ssl_read = 0;
    int do_child_read = 0;
    int n;

    FD_ZERO(&rfds);

    if (!tls_eof) {
      if (SSL_pending(ssl) > 0) {
        do_ssl_read = 1;
      } else {
        FD_SET(0, &rfds);
        if (0 > maxfd)
          maxfd = 0;
      }
    }
    if (!child_eof) {
      FD_SET(cfd, &rfds);
      if (cfd > maxfd)
        maxfd = cfd;
    }

    if (!do_ssl_read) {
      struct timeval tv;
      tv.tv_sec = 300;
      tv.tv_usec = 0;
      if (select(maxfd + 1, &rfds, NULL, NULL, &tv) <= 0) {
        if (errno == EINTR)
          continue;
        /* timeout or fatal select error: drop the session */
        logmsg("select timeout/error, closing");
        break;
      }
      if (!tls_eof && FD_ISSET(0, &rfds))
        do_ssl_read = 1;
      if (!child_eof && FD_ISSET(cfd, &rfds))
        do_child_read = 1;
    }

    /* TLS -> child */
    if (do_ssl_read) {
      n = SSL_read(ssl, buf, sizeof(buf));
      if (n > 0) {
        if (write_all(cfd, buf, n) < 0) {
          logmsg("child stdin write failed");
          break;
        }
      } else {
        int err = SSL_get_error(ssl, n);
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
          /* try again */
        } else {
          logmsg("TLS read end");
          tls_eof = 1;
          shutdown(cfd, SHUT_WR);
        }
      }
    }

    /* child -> TLS */
    if (do_child_read) {
      n = read(cfd, buf, sizeof(buf));
      if (n > 0) {
        if (ssl_write_all(ssl, buf, n) < 0) {
          logmsg("TLS write failed");
          break;
        }
      } else if (n == 0) {
        logmsg("child stdout EOF");
        child_eof = 1;
      } else {
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
          continue;
        logmsg("child stdout read failed");
        break;
      }
    }
  }

  /* send close_notify (call twice for the bidirectional shutdown) */
  SSL_shutdown(ssl);
  SSL_shutdown(ssl);
}

int
main(int argc, char **argv)
{
  const char *certfile = NULL;
  const char *keyfile = NULL;
  SSL_CTX *ctx;
  SSL *ssl;
  int sv[2];
  pid_t pid;
  int i;

  if (argc < 2)
    usage();

  for (i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-c") == 0) {
      if (++i >= argc)
        usage();
      certfile = argv[i];
    } else if (strcmp(argv[i], "-k") == 0) {
      if (++i >= argc)
        usage();
      keyfile = argv[i];
    } else if (strcmp(argv[i], "-v") == 0) {
      verbose = 1;
    } else if (strcmp(argv[i], "--") == 0) {
      i++;
      break;
    } else if (argv[i][0] == '-') {
      usage();
    } else {
      break;
    }
  }

  if (certfile == NULL || i >= argc)
    usage();
  if (keyfile == NULL)
    keyfile = certfile;

  signal(SIGPIPE, SIG_IGN);

  SSL_library_init();
  SSL_load_error_strings();

  ctx = SSL_CTX_new(TLS_server_method());
  if (ctx == NULL)
    oops_ssl("SSL_CTX_new failed");

  /* mail needs TLS 1.2+; no compression (CRIME) */
  if (SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) != 1)
    oops_ssl("cannot set min TLS version");
  SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION);

  if (SSL_CTX_use_certificate_chain_file(ctx, certfile) != 1)
    oops_ssl("cannot load certificate");
  if (SSL_CTX_use_PrivateKey_file(ctx, keyfile, SSL_FILETYPE_PEM) != 1)
    oops_ssl("cannot load private key");
  if (SSL_CTX_check_private_key(ctx) != 1)
    oops_ssl("private key does not match certificate");

  ssl = SSL_new(ctx);
  if (ssl == NULL)
    oops_ssl("SSL_new failed");

  /* tcpserver puts the client socket on fd 0 (and fd 1) */
  if (SSL_set_fd(ssl, 0) != 1)
    oops_ssl("SSL_set_fd failed");

  if (SSL_accept(ssl) != 1) {
    fprintf(stderr, "sslwrap: TLS handshake failed\n");
    ERR_print_errors_fp(stderr);
    exit(111);
  }
  logmsg("TLS handshake ok");

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0)
    oops("socketpair");

  pid = fork();
  if (pid < 0)
    oops("fork");

  if (pid == 0) {
    /* child: plaintext protocol on stdin/stdout */
    close(sv[0]);
    if (dup2(sv[1], 0) < 0)
      oops("dup2 stdin");
    if (dup2(sv[1], 1) < 0)
      oops("dup2 stdout");
    close(sv[1]);
    execvp(argv[i], argv + i);
    fprintf(stderr, "sslwrap: exec %s: %s\n", argv[i], strerror(errno));
    _exit(111);
  }

  close(sv[1]);
  relay(ssl, sv[0]);
  close(sv[0]);
  waitpid(pid, NULL, 0);

  SSL_free(ssl);
  SSL_CTX_free(ctx);
  logmsg("done");
  return 0;
}
