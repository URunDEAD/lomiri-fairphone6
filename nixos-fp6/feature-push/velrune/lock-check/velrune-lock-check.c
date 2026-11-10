/*
 * velrune-lock-check: checks the Shell's lock-screen PIN for the person at the seat, as
 * root, so pam_faillock's root-owned tally counts every attempt.
 *
 * Started by systemd per connection (velrune-lock-check.socket, Accept=yes): the
 * connected socket is stdin and stdout. Protocol (one request per connection):
 *
 *   request:  the password, 1..256 bytes, no NUL or newline, ended by "\n" or by the
 *             client shutting down its write side
 *   reply:    one line
 *             "ok"                 the password is right
 *             "fail <remaining>"   wrong; <remaining> more failures before the lockout
 *                                  ("?" if the tally could not be read)
 *             "locked <seconds>"   pam_faillock locks the account; try again after
 *                                  <seconds> (the right password is refused too)
 *             "error <reason>"     not checked: caller, request or system problem
 *                                  (reasons: caller, request, system)
 *
 * The caller is never asked who to check: the peer's uid (SO_PEERCRED) must be at least
 * 1000 and own the active logind session on seat0, and that user's name is what PAM
 * checks, with service "velrune-lock". Attempts are serialized by an exclusive lock on
 * a root-owned file and a failed attempt takes at least --min-fail-ms (2 s), so
 * parallel connections cannot try faster. The password is kept in one buffer that is
 * zeroed before exit; nothing the client sends is ever logged.
 *
 * Options (set by the unit; the client cannot change them):
 *   --dir DIR --deny N --unlock-time S --fail-interval S   the pam_faillock settings
 *   --lock-file PATH --min-fail-ms MS --service NAME
 * Test builds (-DVELRUNE_LOCK_TESTING) also take --confdir DIR (pam_start_confdir) and
 * --active-uid UID (stands in for logind's active seat0 user).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifndef VELRUNE_LOCK_TESTING
#include <systemd/sd-login.h>
#endif

#define MAX_SECRET 256
#define MIN_UID 1000
#define READ_TIMEOUT_MS 10000

/* pam_faillock's tally record (modules/pam_faillock/faillock.h, linux-pam 1.7). */
struct tally {
	char source[52];
	uint16_t reserved;
	uint16_t status;
	uint64_t time;
};
#define TALLY_STATUS_VALID 0x1

struct config {
	const char *dir, *lock_file, *service;
	long deny, unlock_time, fail_interval, min_fail_ms;
#ifdef VELRUNE_LOCK_TESTING
	const char *confdir;
	long active_uid;
#endif
};

static char secret[MAX_SECRET + 2];
static size_t secret_len;

static void wipe(void) { explicit_bzero(secret, sizeof secret); secret_len = 0; }

static void reply(const char *line)
{
	size_t n = strlen(line);
	while (n > 0) {
		ssize_t w = write(STDOUT_FILENO, line, n);
		if (w < 0 && errno == EINTR)
			continue;
		if (w <= 0)
			return;
		line += w;
		n -= (size_t)w;
	}
}

static int64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void sleep_until(int64_t deadline_ms)
{
	int64_t left;
	while ((left = deadline_ms - now_ms()) > 0) {
		struct timespec ts = { left / 1000, (left % 1000) * 1000000 };
		nanosleep(&ts, NULL);
	}
}

/* Reads the request into `secret`. 0 on success, -1 for a bad or missing request. */
static int read_request(void)
{
	int64_t deadline = now_ms() + READ_TIMEOUT_MS;
	secret_len = 0;
	for (;;) {
		int64_t left = deadline - now_ms();
		struct pollfd p = { STDIN_FILENO, POLLIN, 0 };
		if (left <= 0)
			return -1;
		int r = poll(&p, 1, (int)left);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		ssize_t n = read(STDIN_FILENO, secret + secret_len, sizeof secret - 1 - secret_len);
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0)
			return -1;
		if (n == 0)
			break; /* the client shut down its side: length-framed */
		secret_len += (size_t)n;
		char *nl = memchr(secret, '\n', secret_len);
		if (nl) {
			if ((size_t)(nl - secret) + 1 != secret_len)
				return -1; /* bytes after the newline: one request only */
			secret_len = (size_t)(nl - secret);
			break;
		}
		if (secret_len > MAX_SECRET)
			return -1;
	}
	if (secret_len == 0 || secret_len > MAX_SECRET || memchr(secret, '\0', secret_len))
		return -1;
	secret[secret_len] = '\0';
	return 0;
}

static int caller_allowed(uid_t uid, const struct config *cfg)
{
	if (uid < MIN_UID)
		return 0;
#ifdef VELRUNE_LOCK_TESTING
	return cfg->active_uid >= 0 && (uid_t)cfg->active_uid == uid;
#else
	(void)cfg;
	char *session = NULL;
	uid_t active = (uid_t)-1;
	int ok = sd_seat_get_active("seat0", &session, &active) >= 0 && active == uid;
	free(session);
	return ok;
#endif
}

static int conversation(int n, const struct pam_message **msg, struct pam_response **resp, void *data)
{
	(void)data;
	struct pam_response *r = calloc((size_t)n, sizeof *r);
	if (r == NULL)
		return PAM_BUF_ERR;
	for (int i = 0; i < n; i++) {
		switch (msg[i]->msg_style) {
		case PAM_PROMPT_ECHO_OFF:
			/* PAM takes ownership of this copy; pam_unix and pam_exec overwrite it. */
			r[i].resp = strndup(secret, secret_len);
			if (r[i].resp == NULL)
				goto fail;
			break;
		case PAM_ERROR_MSG:
		case PAM_TEXT_INFO:
			break; /* the tally, not the text, decides the reply */
		default:
			goto fail; /* visible prompts and anything else: refuse */
		}
	}
	*resp = r;
	return PAM_SUCCESS;
fail:
	for (int i = 0; i < n; i++) {
		if (r[i].resp) {
			explicit_bzero(r[i].resp, strlen(r[i].resp));
			free(r[i].resp);
		}
	}
	free(r);
	return PAM_CONV_ERR;
}

/* Failures in the window and the time of the latest one, as pam_faillock counts them. */
static int read_tally(const struct config *cfg, const char *user, long *failures, uint64_t *latest)
{
	char path[4096];
	if (snprintf(path, sizeof path, "%s/%s", cfg->dir, user) >= (int)sizeof path)
		return -1;
	*failures = 0;
	*latest = 0;
	int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return errno == ENOENT ? 0 : -1;
	struct tally t[64];
	size_t count = 0, cap = 0;
	struct tally *all = NULL;
	ssize_t n;
	while ((n = read(fd, t, sizeof t)) > 0) {
		size_t got = (size_t)n / sizeof(struct tally);
		if (count + got > cap) {
			cap = (count + got) * 2;
			struct tally *grown = realloc(all, cap * sizeof *all);
			if (grown == NULL) {
				free(all);
				close(fd);
				return -1;
			}
			all = grown;
		}
		memcpy(all + count, t, got * sizeof *t);
		count += got;
	}
	close(fd);
	if (n < 0) {
		free(all);
		return -1;
	}
	for (size_t i = 0; i < count; i++)
		if ((all[i].status & TALLY_STATUS_VALID) && all[i].time > *latest)
			*latest = all[i].time;
	for (size_t i = 0; i < count; i++)
		if ((all[i].status & TALLY_STATUS_VALID) && *latest - all[i].time < (uint64_t)cfg->fail_interval)
			++*failures;
	free(all);
	return 0;
}

static int parse_long(const char *s, long *out)
{
	char *end;
	errno = 0;
	long v = strtol(s, &end, 10);
	if (errno || *s == '\0' || *end != '\0' || v < 0)
		return -1;
	*out = v;
	return 0;
}

static int parse_args(int argc, char **argv, struct config *cfg)
{
	*cfg = (struct config){ .dir = NULL, .lock_file = NULL, .service = "velrune-lock",
		.deny = 10, .unlock_time = 900, .fail_interval = 900, .min_fail_ms = 2000 };
#ifdef VELRUNE_LOCK_TESTING
	cfg->confdir = NULL;
	cfg->active_uid = -1;
#endif
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (v == NULL)
			return -1;
		if (!strcmp(a, "--dir")) cfg->dir = v;
		else if (!strcmp(a, "--lock-file")) cfg->lock_file = v;
		else if (!strcmp(a, "--service")) cfg->service = v;
		else if (!strcmp(a, "--deny")) { if (parse_long(v, &cfg->deny)) return -1; }
		else if (!strcmp(a, "--unlock-time")) { if (parse_long(v, &cfg->unlock_time)) return -1; }
		else if (!strcmp(a, "--fail-interval")) { if (parse_long(v, &cfg->fail_interval)) return -1; }
		else if (!strcmp(a, "--min-fail-ms")) { if (parse_long(v, &cfg->min_fail_ms)) return -1; }
#ifdef VELRUNE_LOCK_TESTING
		else if (!strcmp(a, "--confdir")) cfg->confdir = v;
		else if (!strcmp(a, "--active-uid")) { if (parse_long(v, &cfg->active_uid)) return -1; }
#endif
		else return -1;
		i++;
	}
	return cfg->dir && cfg->lock_file ? 0 : -1;
}

int main(int argc, char **argv)
{
	struct config cfg;
	if (parse_args(argc, argv, &cfg) != 0) {
		fputs("velrune-lock-check: bad arguments\n", stderr);
		return 2;
	}

	struct ucred cred;
	socklen_t len = sizeof cred;
	if (getsockopt(STDIN_FILENO, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) {
		reply("error caller\n");
		return 1;
	}
	if (!caller_allowed(cred.uid, &cfg)) {
		fprintf(stderr, "velrune-lock-check: refused uid %u (not the active seat0 user)\n", (unsigned)cred.uid);
		reply("error caller\n");
		return 1;
	}
	char pwbuf[4096];
	struct passwd pw, *found = NULL;
	if (getpwuid_r(cred.uid, &pw, pwbuf, sizeof pwbuf, &found) != 0 || found == NULL) {
		reply("error caller\n");
		return 1;
	}
	if (read_request() != 0) {
		wipe();
		reply("error request\n");
		return 1;
	}

	/* One attempt at a time, for every caller. */
	int lock = open(cfg.lock_file, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (lock < 0) {
		wipe();
		reply("error system\n");
		return 1;
	}
	while (flock(lock, LOCK_EX) != 0 && errno == EINTR)
		;
	int64_t started = now_ms();

	struct pam_conv conv = { conversation, NULL };
	pam_handle_t *pamh = NULL;
	int rc;
#ifdef VELRUNE_LOCK_TESTING
	if (cfg.confdir)
		rc = pam_start_confdir(cfg.service, found->pw_name, &conv, cfg.confdir, &pamh);
	else
#endif
		rc = pam_start(cfg.service, found->pw_name, &conv, &pamh);
	if (rc == PAM_SUCCESS)
		rc = pam_authenticate(pamh, 0);
	int ok = rc == PAM_SUCCESS;
	if (pamh)
		pam_end(pamh, rc);
	wipe();

	char line[64];
	if (ok) {
		snprintf(line, sizeof line, "ok\n");
	} else {
		long failures;
		uint64_t latest;
		uint64_t now = (uint64_t)time(NULL);
		if (read_tally(&cfg, found->pw_name, &failures, &latest) != 0)
			snprintf(line, sizeof line, "fail ?\n");
		else if (cfg.deny && failures >= cfg.deny && cfg.unlock_time && latest + (uint64_t)cfg.unlock_time >= now)
			snprintf(line, sizeof line, "locked %llu\n",
				 (unsigned long long)(latest + (uint64_t)cfg.unlock_time - now + 1));
		else
			snprintf(line, sizeof line, "fail %ld\n", cfg.deny > failures ? cfg.deny - failures : 0);
		sleep_until(started + cfg.min_fail_ms);
	}
	reply(line);
	flock(lock, LOCK_UN);
	close(lock);
	return ok ? 0 : 1;
}
