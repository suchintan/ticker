#!/usr/bin/env bash
# Install Ticker to /Applications.
#
# build-app.sh starts with `rm -rf Ticker.app`, so a login item pointing at the
# build directory breaks on the next rebuild. The installed copy in /Applications
# is the one that should ever be registered to open at login. Reinstalls exchange
# the verified staging directory with that installed copy atomically and keep the
# displaced bundle until every other transactional step has succeeded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_BUNDLE="${TICKER_INSTALL_SOURCE_BUNDLE:-${REPO_ROOT}/Ticker.app}"
INSTALL_BUNDLE="${TICKER_INSTALL_BUNDLE:-/Applications/Ticker.app}"
CLI_LINK="${TICKER_INSTALL_CLI_LINK:-/usr/local/bin/ticker}"
CODESIGN="${TICKER_INSTALL_CODESIGN:-codesign}"
CODESIGN_CHECK_ENABLED="${TICKER_INSTALL_CODESIGN_CHECK_ENABLED:-1}"
PLUTIL="${TICKER_INSTALL_PLUTIL:-/usr/bin/plutil}"
LAUNCHCTL="${TICKER_INSTALL_LAUNCHCTL:-/bin/launchctl}"
COPY_COMMAND="${TICKER_INSTALL_COPY:-cp}"
REMOVE_COMMAND="${TICKER_INSTALL_REMOVE:-rm}"
LINK_COMMAND="${TICKER_INSTALL_LINK:-/bin/ln}"
READLINK_COMMAND="${TICKER_INSTALL_READLINK:-/usr/bin/readlink}"
STAT_COMMAND="${TICKER_INSTALL_STAT:-/usr/bin/stat}"
CC_COMMAND="${TICKER_INSTALL_CC:-/usr/bin/clang}"
EXCHANGE_COMMAND_OVERRIDE="${TICKER_INSTALL_EXCHANGE:-}"
NO_REPLACE_COMMAND_OVERRIDE="${TICKER_INSTALL_NO_REPLACE:-}"
PGREP_COMMAND="${TICKER_INSTALL_PGREP:-pgrep}"
PKILL_COMMAND="${TICKER_INSTALL_PKILL:-pkill}"
OPEN_COMMAND="${TICKER_INSTALL_OPEN:-/usr/bin/open}"
SLEEP_COMMAND="${TICKER_INSTALL_SLEEP:-sleep}"
DATE_COMMAND="${TICKER_INSTALL_DATE:-/bin/date}"
LOCK_HOOK_COMMAND="${TICKER_INSTALL_LOCK_HOOK:-}"
STOP_CHECK_ATTEMPTS="${TICKER_INSTALL_STOP_CHECK_ATTEMPTS:-20}"
START_CHECK_ATTEMPTS="${TICKER_INSTALL_START_CHECK_ATTEMPTS:-20}"
PROCESS_CHECK_INTERVAL="${TICKER_INSTALL_PROCESS_CHECK_INTERVAL:-0.1}"
TICKER_INSTALL_TRANSACTION_PID="$$"
export TICKER_INSTALL_TRANSACTION_PID

INSTALL_PARENT=""
CLI_PARENT=""
INSTALL_LOCK=""
INSTALL_LOCK_IDENTITY=""
INSTALL_LOCK_PID=""
INSTALL_LOCK_TIMESTAMP=""
LOCK_HELPER_DIRECTORY=""
LOCK_HELPER=""
LOCK_PENDING_SIGNAL_STATUS=""
LOCK_PENDING_SIGNAL_NAME=""
LOCK_RELEASED_CUSTODY=""
APP_PROCESS_PATTERN=""
STAGING_BUNDLE=""
EXCHANGE_HELPER_DIRECTORY=""
EXCHANGE_HELPER=""
EXCHANGE_COMMAND=""
NO_REPLACE_COMMAND=""
EXCHANGE_PROBE_A=""
EXCHANGE_PROBE_B=""
CLI_STAGED_PATH=""

LOCK_OWNED=0
TRANSACTION_ACTIVE=0
FINAL_STATE_PROVEN=0
PRIOR_EXISTED=0
PRIOR_BUNDLE_IDENTITY=""
STAGING_CUSTODY_IDENTITY=""
STAGED_BUNDLE_IDENTITY=""
APP_MUTATION_STARTED=0
APP_EXCHANGED=0
FRESH_REPLACEMENT_INSTALLED=0
APP_UNEXPECTED_DESTINATION_IDENTITY=""

PRIOR_APP_WAS_RUNNING=0
PRIOR_APP_STOP_REQUESTED=0
PRIOR_APP_STOPPED=0
REINSTALL_APP_RESTART_CUSTODY=0

PRIOR_LOGIN_STATE=""
EXPECTED_LOGIN_STATE=""
FINAL_LOGIN_STATE=""
REQUIRES_APPROVAL_LOGIN_STATE="requires approval — approve Ticker in System Settings › General › Login Items"
LOGIN_AGENT_TARGET="gui/${UID}/com.suchintan.ticker.login"
LOGIN_MUTATION_STARTED=0
REPLACEMENT_KICKSTART_VERIFIED=0
REPLACEMENT_START_ATTEMPTED=0
START_ORIGIN_INSTALLER_REPLACEMENT="installer-replacement"
START_ORIGIN_ROLLBACK_RESTORATION="rollback-restoration"
STOP_PURPOSE_PRIOR_PROCESS="prior-process"
STOP_PURPOSE_INSTALLER_REPLACEMENT="installer-replacement"

CLI_PRIOR_EXISTED=0
CLI_PRIOR_IDENTITY=""
CLI_NEW_IDENTITY=""
CLI_PARENT_WRITABLE=0
CLI_MUTATION_STARTED=0
CLI_MUTATED=0
CLI_UNEXPECTED_DESTINATION_IDENTITY=""

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

path_identity() {
    "${STAT_COMMAND}" -f '%d:%i' "$1"
}

path_device() {
    local identity

    identity="$(path_identity "$1")" || return 1
    printf '%s\n' "${identity%%:*}"
}

# Bash can defer traps but cannot atomically change its signal mask around
# mkdir(2). This short-lived native helper owns the lock's signal mask, inode
# custody, durable metadata publication, and identity-bound release records.
build_installer_lock_helper() {
    local temporary_root="${TMPDIR:-/tmp}"

    if [[ ! -x "${CC_COMMAND}" ]]; then
        echo "installer: ERROR - installer lock helper is unavailable; system compiler not found: ${CC_COMMAND}" >&2
        return 1
    fi
    LOCK_HELPER_DIRECTORY="$(mktemp -d "${temporary_root%/}/ticker-install-lock.XXXXXX")" \
        || return 1
    LOCK_HELPER="${LOCK_HELPER_DIRECTORY}/installer-lock"
    if ! "${CC_COMMAND}" -Os -Wall -Wextra -x c -o "${LOCK_HELPER}" - <<'LOCK_HELPER_SOURCE'
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <sys/stdio.h>

static volatile sig_atomic_t pending_signal = 0;

static void remember_signal(int signal_number) {
    if (pending_signal == 0) {
        pending_signal = signal_number;
    }
}

static int signal_status(void) {
    switch (pending_signal) {
        case SIGHUP: return 129;
        case SIGINT: return 130;
        case SIGQUIT: return 131;
        case SIGTERM: return 143;
        default: return 0;
    }
}

static int begin_signal_block(sigset_t *prior_mask) {
    struct sigaction action;
    sigset_t blocked;

    memset(&action, 0, sizeof(action));
    action.sa_handler = remember_signal;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGHUP, &action, NULL) != 0
            || sigaction(SIGINT, &action, NULL) != 0
            || sigaction(SIGQUIT, &action, NULL) != 0
            || sigaction(SIGTERM, &action, NULL) != 0) {
        return -1;
    }
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGHUP);
    sigaddset(&blocked, SIGINT);
    sigaddset(&blocked, SIGQUIT);
    sigaddset(&blocked, SIGTERM);
    return sigprocmask(SIG_BLOCK, &blocked, prior_mask);
}

static int restore_signal_mask(const sigset_t *prior_mask) {
    return sigprocmask(SIG_SETMASK, prior_mask, NULL);
}

static int identity_for_stat(const struct stat *value, char *buffer, size_t size) {
    int count = snprintf(
        buffer,
        size,
        "%llu:%llu:%lu",
        (unsigned long long)value->st_dev,
        (unsigned long long)value->st_ino,
        (unsigned long)value->st_uid
    );
    return count > 0 && (size_t)count < size ? 0 : -1;
}

static int stat_matches_identity(const struct stat *value, const char *identity) {
    char observed[128];
    return identity_for_stat(value, observed, sizeof(observed)) == 0
        && strcmp(observed, identity) == 0;
}

static int path_matches_identity(const char *path, const char *identity) {
    struct stat value;
    return lstat(path, &value) == 0 && stat_matches_identity(&value, identity);
}

static int write_all(int fd, const char *value, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(fd, value + offset, length - offset);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        offset += (size_t)written;
    }
    return 0;
}

static int fsync_directory_if_supported(int fd) {
    if (fsync(fd) == 0) return 0;
    return errno == EINVAL || errno == ENOTSUP ? 0 : -1;
}

static int run_hook(const char *phase, const char *lock_path, const char *custody_path) {
    const char *hook = getenv("TICKER_INSTALL_LOCK_HOOK");
    pid_t child;
    int status;

    if (hook == NULL || hook[0] == '\0') return 0;
    child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        if (dup2(STDERR_FILENO, STDOUT_FILENO) < 0) _exit(127);
        execlp(hook, hook, phase, lock_path, custody_path == NULL ? "" : custody_path, NULL);
        _exit(127);
    }
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static int inject_signal_for_phase(const char *phase) {
    const char *configured_phase = getenv("TICKER_INSTALL_LOCK_SIGNAL_PHASE");
    const char *configured_signal = getenv("TICKER_INSTALL_LOCK_SIGNAL");
    const char *transaction_pid = getenv("TICKER_INSTALL_TRANSACTION_PID");
    char *end = NULL;
    long target;
    int signal_number = SIGTERM;

    if (configured_phase == NULL || strcmp(configured_phase, phase) != 0) return 0;
    if (configured_signal != NULL && configured_signal[0] != '\0') {
        if (strcmp(configured_signal, "HUP") == 0) signal_number = SIGHUP;
        else if (strcmp(configured_signal, "INT") == 0) signal_number = SIGINT;
        else if (strcmp(configured_signal, "QUIT") == 0) signal_number = SIGQUIT;
        else if (strcmp(configured_signal, "TERM") != 0) return -1;
    }
    if (transaction_pid == NULL || transaction_pid[0] == '\0') return -1;
    errno = 0;
    target = strtol(transaction_pid, &end, 10);
    if (errno != 0 || end == transaction_pid || *end != '\0' || target <= 0) return -1;
    return kill((pid_t)target, signal_number);
}

static int timestamp_from_command(const char *command, char *buffer, size_t size) {
    int descriptors[2];
    pid_t child;
    int status;
    size_t used = 0;

    if (pipe(descriptors) != 0) return -1;
    child = fork();
    if (child < 0) {
        close(descriptors[0]);
        close(descriptors[1]);
        return -1;
    }
    if (child == 0) {
        close(descriptors[0]);
        if (dup2(descriptors[1], STDOUT_FILENO) < 0) _exit(127);
        close(descriptors[1]);
        execlp(command, command, "-u", "+%Y-%m-%dT%H:%M:%SZ", NULL);
        _exit(127);
    }
    close(descriptors[1]);
    while (used + 1 < size) {
        ssize_t count = read(descriptors[0], buffer + used, size - used - 1);
        if (count < 0) {
            if (errno == EINTR) continue;
            close(descriptors[0]);
            return -1;
        }
        if (count == 0) break;
        used += (size_t)count;
    }
    close(descriptors[0]);
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return -1;
    while (used > 0 && (buffer[used - 1] == '\n' || buffer[used - 1] == '\r')) used--;
    if (used == 0 || used + 1 >= size) return -1;
    buffer[used] = '\0';
    return 0;
}

static int write_metadata(int directory_fd, const char *name, const char *value) {
    int fd;
    size_t length = strlen(value);
    int result = -1;

    fd = openat(directory_fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
    if (fd < 0) return -1;
    if (write_all(fd, value, length) == 0
            && write_all(fd, "\n", 1) == 0
            && fsync(fd) == 0) {
        result = 0;
    }
    if (close(fd) != 0) result = -1;
    return result;
}

static int read_metadata(int directory_fd, const char *name, const char *expected) {
    char buffer[512];
    char wanted[512];
    int fd;
    size_t used = 0;
    int count;

    count = snprintf(wanted, sizeof(wanted), "%s\n", expected);
    if (count <= 0 || (size_t)count >= sizeof(wanted)) return -1;
    fd = openat(directory_fd, name, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return errno == ENOENT ? 1 : -1;
    while (used < sizeof(buffer)) {
        ssize_t amount = read(fd, buffer + used, sizeof(buffer) - used);
        if (amount < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return -1;
        }
        if (amount == 0) break;
        used += (size_t)amount;
    }
    if (close(fd) != 0 || used != (size_t)count) return -1;
    return memcmp(buffer, wanted, used) == 0 ? 0 : -1;
}

static int validate_contents(
    int directory_fd,
    const char *pid,
    const char *timestamp,
    int metadata_required
) {
    DIR *directory;
    struct dirent *entry;
    struct stat value;
    int pid_result;
    int timestamp_result;
    int duplicate_fd = dup(directory_fd);

    if (duplicate_fd < 0) return -1;
    directory = fdopendir(duplicate_fd);
    if (directory == NULL) {
        close(duplicate_fd);
        return -1;
    }
    errno = 0;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (strcmp(entry->d_name, "pid") != 0
                && strcmp(entry->d_name, "timestamp") != 0
                && strcmp(entry->d_name, "released-custody") != 0) {
            closedir(directory);
            return -1;
        }
        if (fstatat(directory_fd, entry->d_name, &value, AT_SYMLINK_NOFOLLOW) != 0
                || !S_ISREG(value.st_mode)) {
            closedir(directory);
            return -1;
        }
    }
    if (errno != 0 || closedir(directory) != 0) return -1;
    pid_result = read_metadata(directory_fd, "pid", pid);
    timestamp_result = read_metadata(directory_fd, "timestamp", timestamp);
    if (pid_result < 0 || timestamp_result < 0) return -1;
    if (metadata_required && (pid_result != 0 || timestamp_result != 0)) return -1;
    return 0;
}

static char *parent_path(const char *path) {
    char *copy = strdup(path);
    char *slash;
    if (copy == NULL) return NULL;
    slash = strrchr(copy, '/');
    if (slash == NULL) {
        free(copy);
        return strdup(".");
    }
    if (slash == copy) slash[1] = '\0';
    else *slash = '\0';
    return copy;
}

static int release_owned_lock(
    const char *lock_path,
    const char *expected_identity,
    const char *pid,
    const char *timestamp,
    int metadata_required,
    int invoke_hook
) {
    /*
     * Darwin has no atomic compare-and-delete for a directory. Move the public
     * lock into a private unique namespace, mark the exact owned inode through
     * its descriptor, and retain that small record instead of deleting a path
     * that another actor can swap after an identity check.
     */
    char *custody = NULL;
    char *custody_namespace = NULL;
    char *parent = NULL;
    size_t custody_size = strlen(lock_path) + 64;
    struct stat moved;
    struct stat public_lock;
    struct stat namespace_stat;
    char namespace_identity[128];
    int directory_fd = -1;
    int namespace_fd = -1;
    int parent_fd = -1;
    int manual_cleanup = 0;
    int result = -1;

    custody_namespace = malloc(custody_size);
    parent = parent_path(lock_path);
    if (custody_namespace == NULL || parent == NULL) goto finished;
    snprintf(custody_namespace, custody_size, "%s.released.XXXXXX", lock_path);
    if (mkdtemp(custody_namespace) == NULL) {
        fprintf(stderr, "installer: ERROR - could not create unique released-custody namespace\n");
        goto finished;
    }
    namespace_fd = open(custody_namespace, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (namespace_fd < 0 || fstat(namespace_fd, &namespace_stat) != 0
            || identity_for_stat(
                &namespace_stat, namespace_identity, sizeof(namespace_identity)
            ) != 0) {
        fprintf(stderr, "installer: ERROR - released-custody namespace could not be identified; retained for manual cleanup: %s\n", custody_namespace);
        goto finished;
    }
    custody = malloc(strlen(custody_namespace) + 6);
    if (custody == NULL) goto finished;
    snprintf(custody, strlen(custody_namespace) + 6, "%s/lock", custody_namespace);
    if (renameatx_np(AT_FDCWD, lock_path, namespace_fd, "lock", RENAME_EXCL) != 0) {
        fprintf(stderr, "installer: ERROR - could not atomically move owned lock into released custody; foreign paths were preserved for manual cleanup: %s %s\n", lock_path, custody_namespace);
        goto finished;
    }
    parent_fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (parent_fd >= 0) (void)fsync_directory_if_supported(parent_fd);
    if (fsync_directory_if_supported(namespace_fd) != 0) {
        fprintf(stderr, "installer: ERROR - released-custody rename could not be made durable; retained for manual cleanup: %s\n", custody_namespace);
        goto finished;
    }
    directory_fd = openat(namespace_fd, "lock", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (directory_fd < 0 || fstat(directory_fd, &moved) != 0) {
        fprintf(stderr, "installer: ERROR - moved lock custody could not be identified; retained for manual cleanup: %s\n", custody_namespace);
        goto finished;
    }
    if (!stat_matches_identity(&moved, expected_identity)) {
        fprintf(stderr, "installer: ERROR - foreign inode moved into released custody and was preserved for manual cleanup: %s\n", custody);
        goto finished;
    }
    if (validate_contents(directory_fd, pid, timestamp, metadata_required) != 0) {
        fprintf(stderr, "installer: ERROR - owned lock custody has unexpected contents; retained for manual cleanup: %s\n", custody);
        goto finished;
    }
    if (fchmod(directory_fd, 0700) != 0
            || write_metadata(directory_fd, "released-custody", expected_identity) != 0
            || fsync_directory_if_supported(directory_fd) != 0) {
        fprintf(stderr, "installer: ERROR - could not mark proven released custody; retained for manual cleanup: %s\n", custody);
        goto finished;
    }
    if (invoke_hook && run_hook("during-custody-release", lock_path, custody) != 0) {
        fprintf(stderr, "installer: ERROR - installer lock custody-release hook failed\n");
        goto finished;
    }
    if (invoke_hook && run_hook("last-pre-delete", lock_path, custody) != 0) {
        fprintf(stderr, "installer: ERROR - installer lock last-pre-delete hook failed\n");
        goto finished;
    }
    /* Preserve the historical seam above; this is the exact former rmdir seam. */
    if (invoke_hook && run_hook("former-pre-rmdir", lock_path, custody) != 0) {
        fprintf(stderr, "installer: ERROR - installer lock former-pre-rmdir hook failed\n");
        goto finished;
    }
    if (fstat(directory_fd, &moved) != 0
            || !stat_matches_identity(&moved, expected_identity)
            || validate_contents(directory_fd, pid, timestamp, metadata_required) != 0
            || read_metadata(directory_fd, "released-custody", expected_identity) != 0) {
        fprintf(stderr, "installer: ERROR - owned released-custody descriptor changed; retained paths require manual cleanup\n");
        goto finished;
    }
    if (!path_matches_identity(custody_namespace, namespace_identity)) {
        fprintf(stderr, "installer: ERROR - foreign inode at released-custody namespace was preserved for manual cleanup: %s\n", custody_namespace);
        manual_cleanup = 1;
    }
    if (lstat(custody, &moved) != 0) {
        fprintf(stderr, "installer: ERROR - released-custody pathname disappeared; owned record was retained through its descriptor for manual cleanup: %s\n", custody);
        manual_cleanup = 1;
    } else if (!stat_matches_identity(&moved, expected_identity)) {
        fprintf(stderr, "installer: ERROR - foreign inode at released-custody path was preserved for manual cleanup: %s\n", custody);
        manual_cleanup = 1;
    }
    if (manual_cleanup != 0) goto finished;
    /*
     * The descriptor and custody pathname both prove that the rename moved our
     * expected inode. A different inode at the released public name therefore
     * belongs to a later lock owner. Observe it only; its release is not ours.
     */
    if (lstat(lock_path, &public_lock) == 0) {
        if (stat_matches_identity(&public_lock, expected_identity)) {
            fprintf(stderr, "installer: ERROR - public installer lock path did not contain a distinct successor; retained paths require manual cleanup: %s\n", lock_path);
            manual_cleanup = 1;
        }
    } else if (errno != ENOENT) {
        fprintf(stderr, "installer: ERROR - public installer lock absence is uncertain; retained paths require manual cleanup: %s\n", lock_path);
        manual_cleanup = 1;
    }
    if (manual_cleanup != 0) goto finished;
    if (parent_fd >= 0) (void)fsync_directory_if_supported(parent_fd);
    fprintf(stderr, "installer: released installer lock; retained proven released-custody record: %s\n", custody_namespace);
    if (invoke_hook
            && (printf("%s\n", custody_namespace) < 0 || fflush(stdout) != 0)) {
        goto finished;
    }
    result = 0;

finished:
    if (directory_fd >= 0) close(directory_fd);
    if (namespace_fd >= 0) close(namespace_fd);
    if (parent_fd >= 0) close(parent_fd);
    free(parent);
    free(custody);
    free(custody_namespace);
    return result;
}

static int acquire_lock(const char *lock_path, const char *pid, const char *date_command) {
    sigset_t prior_mask;
    struct stat owned;
    char identity[128] = "";
    char timestamp[128] = "";
    char *parent = NULL;
    int directory_fd = -1;
    int parent_fd = -1;
    int acquired = 0;
    int result = 74;
    int pending_status;
    int after_mkdir_signal_status;

    if (begin_signal_block(&prior_mask) != 0) return 74;
    if (mkdir(lock_path, 0755) != 0) {
        result = errno == EEXIST ? 73 : 74;
        goto finished;
    }
    acquired = 1;
    after_mkdir_signal_status = inject_signal_for_phase("after-mkdir");
    directory_fd = open(lock_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (directory_fd < 0 || fstat(directory_fd, &owned) != 0
            || identity_for_stat(&owned, identity, sizeof(identity)) != 0) {
        fprintf(stderr, "installer: ERROR - created installer lock inode could not be captured\n");
        goto failed;
    }
    if (after_mkdir_signal_status != 0
            || inject_signal_for_phase("after-inode-capture") != 0) goto failed;
    if (timestamp_from_command(date_command, timestamp, sizeof(timestamp)) != 0) {
        fprintf(stderr, "installer: ERROR - could not obtain the installer lock timestamp\n");
        goto failed;
    }
    if (write_metadata(directory_fd, "pid", pid) != 0) {
        fprintf(stderr, "installer: ERROR - could not record the installer lock PID\n");
        goto failed;
    }
    if (inject_signal_for_phase("between-metadata-writes") != 0
            || run_hook("between-metadata-writes", lock_path, NULL) != 0) goto failed;
    if (write_metadata(directory_fd, "timestamp", timestamp) != 0) {
        fprintf(stderr, "installer: ERROR - could not record the installer lock timestamp\n");
        goto failed;
    }
    parent = parent_path(lock_path);
    if (parent == NULL || fsync_directory_if_supported(directory_fd) != 0) goto failed;
    parent_fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (parent_fd < 0 || fsync_directory_if_supported(parent_fd) != 0
            || !path_matches_identity(lock_path, identity)) goto failed;
    if (printf("%s\t%s\n", identity, timestamp) < 0 || fflush(stdout) != 0) goto failed;
    result = 0;
    goto finished;

failed:
    /*
     * A metadata-write hook can remove write permission from the directory.
     * Restore it only through the descriptor whose captured identity proves
     * that this is the inode created above. Darwin can otherwise reject the
     * move into released custody and leave both an empty custody namespace and
     * the partial public lock behind.
     */
    if (directory_fd >= 0 && identity[0] != '\0'
            && fstat(directory_fd, &owned) == 0
            && stat_matches_identity(&owned, identity)) {
        (void)fchmod(directory_fd, 0700);
    }
    if (directory_fd >= 0) {
        close(directory_fd);
        directory_fd = -1;
    }
    if (acquired && identity[0] != '\0') {
        if (release_owned_lock(lock_path, identity, pid, timestamp, 0, 0) != 0) {
            fprintf(stderr, "installer: ERROR - partial installer lock cleanup was not proven; manual recovery required\n");
        }
    } else if (acquired) {
        fprintf(stderr, "installer: ERROR - unidentified partial installer lock retained for manual recovery: %s\n", lock_path);
    }

finished:
    if (directory_fd >= 0) close(directory_fd);
    if (parent_fd >= 0) close(parent_fd);
    free(parent);
    if (restore_signal_mask(&prior_mask) != 0) return 74;
    pending_status = signal_status();
    if (pending_status != 0) return pending_status;
    return result;
}

static int release_lock(
    const char *lock_path,
    const char *identity,
    const char *pid,
    const char *timestamp,
    int metadata_required
) {
    sigset_t prior_mask;
    int result;
    int pending_status;

    if (begin_signal_block(&prior_mask) != 0) return 74;
    result = release_owned_lock(
        lock_path, identity, pid, timestamp, metadata_required, 1
    );
    if (restore_signal_mask(&prior_mask) != 0) return 74;
    pending_status = signal_status();
    return pending_status != 0 ? pending_status : (result == 0 ? 0 : 74);
}

int main(int argc, char **argv) {
    if (argc == 5 && strcmp(argv[1], "acquire") == 0) {
        return acquire_lock(argv[2], argv[3], argv[4]);
    }
    if (argc == 7 && strcmp(argv[1], "release") == 0) {
        return release_lock(
            argv[2], argv[3], argv[4], argv[5], strcmp(argv[6], "full") == 0
        );
    }
    fprintf(stderr, "usage: installer-lock acquire PATH PID DATE | installer-lock release PATH ID PID TIMESTAMP full|partial\n");
    return 64;
}
LOCK_HELPER_SOURCE
    then
        echo "installer: ERROR - could not build the installer lock helper" >&2
        return 1
    fi
    if [[ ! -x "${LOCK_HELPER}" ]]; then
        echo "installer: ERROR - installer lock helper is not executable" >&2
        return 1
    fi
    return 0
}

defer_installer_lock_signal() {
    local status="$1"
    local name="$2"

    if [[ -z "${LOCK_PENDING_SIGNAL_STATUS}" ]]; then
        LOCK_PENDING_SIGNAL_STATUS="${status}"
        LOCK_PENDING_SIGNAL_NAME="${name}"
    fi
}

begin_installer_lock_signal_block() {
    trap 'defer_installer_lock_signal 129 HUP' HUP
    trap 'defer_installer_lock_signal 130 INT' INT
    trap 'defer_installer_lock_signal 131 QUIT' QUIT
    trap 'defer_installer_lock_signal 143 TERM' TERM
}

restore_installer_lock_signal_mask() {
    local status="${LOCK_PENDING_SIGNAL_STATUS}"
    local name="${LOCK_PENDING_SIGNAL_NAME}"

    trap 'handle_signal 129 HUP' HUP
    trap 'handle_signal 130 INT' INT
    trap 'handle_signal 131 QUIT' QUIT
    trap 'handle_signal 143 TERM' TERM
    LOCK_PENDING_SIGNAL_STATUS=""
    LOCK_PENDING_SIGNAL_NAME=""
    if [[ -n "${status}" ]]; then
        handle_signal "${status}" "${name}"
    fi
}

acquire_installer_lock() {
    local owner_pid="unknown"
    local acquired_at="unknown"
    local helper_output=""
    local helper_status=0

    INSTALL_LOCK="${INSTALL_BUNDLE}.install.lock"
    INSTALL_LOCK_PID="$$"
    begin_installer_lock_signal_block
    if helper_output="$(
        TICKER_INSTALL_LOCK_HOOK="${LOCK_HOOK_COMMAND}" \
            "${LOCK_HELPER}" acquire "${INSTALL_LOCK}" "${INSTALL_LOCK_PID}" "${DATE_COMMAND}"
    )"; then
        helper_status=0
    else
        helper_status=$?
    fi
    if [[ -n "${helper_output}" ]]; then
        INSTALL_LOCK_IDENTITY="${helper_output%%$'\t'*}"
        INSTALL_LOCK_TIMESTAMP="${helper_output#*$'\t'}"
        if [[ "${INSTALL_LOCK_IDENTITY}" == "${helper_output}" \
            || -z "${INSTALL_LOCK_IDENTITY}" || -z "${INSTALL_LOCK_TIMESTAMP}" ]]; then
            echo "installer: ERROR - installer lock helper returned an invalid ownership record" >&2
            helper_status=74
        else
            LOCK_OWNED=1
        fi
    fi
    case "${helper_status}" in
        129) defer_installer_lock_signal 129 HUP ;;
        130) defer_installer_lock_signal 130 INT ;;
        131) defer_installer_lock_signal 131 QUIT ;;
        143) defer_installer_lock_signal 143 TERM ;;
    esac
    restore_installer_lock_signal_mask

    if [[ "${helper_status}" -ne 0 ]]; then
        if [[ "${LOCK_OWNED}" -eq 1 ]]; then
            echo "installer: ERROR - installer lock publication completed while a signal was pending" >&2
            return 1
        fi
        if [[ -d "${INSTALL_LOCK}" && ! -L "${INSTALL_LOCK}" ]]; then
            if [[ -r "${INSTALL_LOCK}/pid" ]]; then
                owner_pid="$(<"${INSTALL_LOCK}/pid")"
            fi
            if [[ -r "${INSTALL_LOCK}/timestamp" ]]; then
                acquired_at="$(<"${INSTALL_LOCK}/timestamp")"
            fi
            echo "installer: ERROR - another installer owns ${INSTALL_LOCK}" >&2
            echo "installer: lock owner pid=${owner_pid}, acquired=${acquired_at}" >&2
            echo "installer: confirm that installer is finished, then remove the lock directory manually before retrying" >&2
        else
            echo "installer: ERROR - could not create exclusive installer lock: ${INSTALL_LOCK}" >&2
        fi
        return 1
    fi
    return 0
}

release_installer_lock() {
    local helper_output=""
    local helper_status=0
    local signal_name=""

    if [[ "${LOCK_OWNED}" -eq 0 ]]; then
        return 0
    fi
    if [[ ! -x "${LOCK_HELPER}" ]]; then
        echo "installer: ERROR - installer lock helper disappeared; retaining owned lock for manual recovery" >&2
        return 1
    fi
    if helper_output="$(
        TICKER_INSTALL_LOCK_HOOK="${LOCK_HOOK_COMMAND}" \
            "${LOCK_HELPER}" release \
            "${INSTALL_LOCK}" \
            "${INSTALL_LOCK_IDENTITY}" \
            "${INSTALL_LOCK_PID}" \
            "${INSTALL_LOCK_TIMESTAMP}" \
            full
    )"; then
        helper_status=0
    else
        helper_status=$?
    fi
    case "${helper_status}" in
        129) signal_name="HUP" ;;
        130) signal_name="INT" ;;
        131) signal_name="QUIT" ;;
        143) signal_name="TERM" ;;
    esac
    if [[ -n "${helper_output}" ]]; then
        if [[ "${helper_output}" != "${INSTALL_LOCK}.released."* ]]; then
            echo "installer: ERROR - installer lock helper returned an invalid released-custody record" >&2
            return 1
        fi
        LOCK_RELEASED_CUSTODY="${helper_output}"
        LOCK_OWNED=0
        INSTALL_LOCK_IDENTITY=""
        INSTALL_LOCK_PID=""
        INSTALL_LOCK_TIMESTAMP=""
    fi
    if [[ "${helper_status}" -ne 0 ]]; then
        if [[ -n "${signal_name}" ]]; then
            if [[ -n "${LOCK_RELEASED_CUSTODY}" ]]; then
                echo "installer: received ${signal_name} during installer lock release; released custody was reconciled" >&2
            else
                echo "installer: received ${signal_name} during installer lock release; custody requires manual cleanup" >&2
            fi
            return "${helper_status}"
        fi
        echo "installer: ERROR - could not release owned installer lock: ${INSTALL_LOCK}" >&2
        return 1
    fi
    if [[ -z "${LOCK_RELEASED_CUSTODY}" ]]; then
        echo "installer: ERROR - installer lock release was not accompanied by a custody record" >&2
        return 1
    fi
    return 0
}

cleanup_installer_lock_helper() {
    if [[ -z "${LOCK_HELPER_DIRECTORY}" ]]; then
        return 0
    fi
    if ! /bin/rm -rf -- "${LOCK_HELPER_DIRECTORY}"; then
        echo "installer: WARNING - installer lock helper retained at ${LOCK_HELPER_DIRECTORY}" >&2
        return 1
    fi
    LOCK_HELPER_DIRECTORY=""
    LOCK_HELPER=""
    return 0
}

escape_extended_regex() {
    local remaining="$1"
    local escaped=""
    local character

    while [[ -n "${remaining}" ]]; do
        character="${remaining%"${remaining#?}"}"
        remaining="${remaining#?}"
        case "${character}" in
            "."|"["|"]"|"("|")"|"{"|"}"|"*"|"+"|"?"|"^"|"$"|"|"|"\\")
                escaped="${escaped}\\${character}"
                ;;
            *)
                escaped="${escaped}${character}"
                ;;
        esac
    done
    printf '%s\n' "${escaped}"
}

installed_app_is_running() {
    "${PGREP_COMMAND}" -f -x "${APP_PROCESS_PATTERN}" >/dev/null 2>&1
}

capture_prior_app_state() {
    local status

    if installed_app_is_running; then
        PRIOR_APP_WAS_RUNNING=1
        echo "app: captured prior state: running"
        return 0
    else
        status=$?
    fi
    if [[ "${status}" -eq 1 ]]; then
        PRIOR_APP_WAS_RUNNING=0
        echo "app: captured prior state: not running"
        return 0
    fi
    echo "app: ERROR - could not capture the exact installed process state (pgrep status ${status})" >&2
    return 1
}

wait_for_installed_app_state() {
    local expected="$1"
    local attempts="$2"
    local description="$3"
    local attempt
    local status

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if installed_app_is_running; then
            status=0
        else
            status=$?
        fi
        if [[ "${expected}" == "running" && "${status}" -eq 0 ]]; then
            return 0
        fi
        if [[ "${expected}" == "stopped" && "${status}" -eq 1 ]]; then
            return 0
        fi
        if [[ "${status}" -ne 0 && "${status}" -ne 1 ]]; then
            echo "app: ERROR - ${description} process check failed (pgrep status ${status})" >&2
            return 1
        fi
        if [[ "${attempt}" -lt "${attempts}" ]] \
            && ! "${SLEEP_COMMAND}" "${PROCESS_CHECK_INTERVAL}"; then
            echo "app: ERROR - ${description} wait failed" >&2
            return 1
        fi
    done
    echo "app: ERROR - ${description} was not proven ${expected} after ${attempts} checks" >&2
    return 1
}

stop_installed_app() {
    local description="$1"
    local stop_purpose="$2"
    local status
    local kill_status

    case "${stop_purpose}" in
        "${STOP_PURPOSE_PRIOR_PROCESS}"|"${STOP_PURPOSE_INSTALLER_REPLACEMENT}")
            ;;
        *)
            echo "app: ERROR - invalid stop purpose for ${description}: ${stop_purpose}" >&2
            return 1
            ;;
    esac

    if installed_app_is_running; then
        status=0
    else
        status=$?
    fi
    if [[ "${status}" -eq 1 ]]; then
        return 0
    fi
    if [[ "${status}" -ne 0 ]]; then
        echo "app: ERROR - could not determine whether ${description} is running (pgrep status ${status})" >&2
        return 1
    fi

    echo "app: terminating ${description}"
    if [[ "${PRIOR_EXISTED}" -eq 1 \
        && "${stop_purpose}" == "${STOP_PURPOSE_PRIOR_PROCESS}" ]]; then
        # Any exact installed-path process stopped before the installer starts
        # the replacement becomes rollback restart custody. This includes a
        # displaced-image process that appeared after the pre-exchange proof.
        REINSTALL_APP_RESTART_CUSTODY=1
        PRIOR_APP_STOP_REQUESTED=1
    fi
    if "${PKILL_COMMAND}" -f -x "${APP_PROCESS_PATTERN}"; then
        kill_status=0
    else
        kill_status=$?
        if installed_app_is_running; then
            status=0
        else
            status=$?
        fi
        if [[ "${status}" -ne 1 ]]; then
            echo "app: ERROR - termination failed (pkill status ${kill_status}); exact process is not proven stopped" >&2
            return 1
        fi
    fi
    if ! wait_for_installed_app_state "stopped" "${STOP_CHECK_ATTEMPTS}" "${description}"; then
        return 1
    fi
    if [[ "${PRIOR_EXISTED}" -eq 1 \
        && "${stop_purpose}" == "${STOP_PURPOSE_PRIOR_PROCESS}" ]]; then
        PRIOR_APP_STOPPED=1
    fi
    return 0
}

stop_installed_app_for_rollback() {
    local description="$1"
    local stop_purpose

    case "${REPLACEMENT_START_ATTEMPTED}" in
        0)
            stop_purpose="${STOP_PURPOSE_PRIOR_PROCESS}"
            ;;
        1)
            stop_purpose="${STOP_PURPOSE_INSTALLER_REPLACEMENT}"
            ;;
        *)
            echo "app: ERROR - invalid replacement-start marker during rollback: ${REPLACEMENT_START_ATTEMPTED}" >&2
            return 1
            ;;
    esac

    stop_installed_app "${description}" "${stop_purpose}"
}

launch_and_verify_installed_app() {
    local description="$1"
    local start_origin="$2"

    case "${start_origin}" in
        "${START_ORIGIN_INSTALLER_REPLACEMENT}"|"${START_ORIGIN_ROLLBACK_RESTORATION}")
            ;;
        *)
            echo "app: ERROR - invalid start origin for ${description}: ${start_origin}" >&2
            return 1
            ;;
    esac

    if [[ "${start_origin}" == "${START_ORIGIN_INSTALLER_REPLACEMENT}" ]]; then
        REPLACEMENT_START_ATTEMPTED=1
    fi
    if ! "${OPEN_COMMAND}" "${INSTALL_BUNDLE}"; then
        echo "app: ERROR - ${description} launch command failed" >&2
        return 1
    fi
    if ! wait_for_installed_app_state \
        "running" "${START_CHECK_ATTEMPTS}" "${description} launch"; then
        echo "app: ERROR - ${description} launch verification failed" >&2
        return 1
    fi
    echo "app: ${description} launch verified"
    return 0
}

restart_captured_launch_agent() {
    local description="$1"
    local start_origin="$2"
    local launchctl_output
    local launchctl_status

    if [[ "${PRIOR_LOGIN_STATE}" != "enabled via LaunchAgent" ]]; then
        echo "app: ERROR - ${description} LaunchAgent restart was requested without a captured LaunchAgent state" >&2
        return 1
    fi
    case "${start_origin}" in
        "${START_ORIGIN_INSTALLER_REPLACEMENT}"|"${START_ORIGIN_ROLLBACK_RESTORATION}")
            ;;
        *)
            echo "app: ERROR - invalid start origin for ${description}: ${start_origin}" >&2
            return 1
            ;;
    esac

    if [[ "${start_origin}" == "${START_ORIGIN_INSTALLER_REPLACEMENT}" ]]; then
        REPLACEMENT_START_ATTEMPTED=1
    fi
    if launchctl_output="$("${LAUNCHCTL}" kickstart -k "${LOGIN_AGENT_TARGET}" 2>&1)"; then
        launchctl_status=0
    else
        launchctl_status=$?
    fi
    if [[ "${launchctl_status}" -ne 0 ]]; then
        echo "app: ERROR - ${description} exact LaunchAgent kickstart failed (launchctl status ${launchctl_status}): ${launchctl_output}" >&2
        return 1
    fi
    if ! wait_for_installed_app_state \
        "running" "${START_CHECK_ATTEMPTS}" "${description} LaunchAgent restart"; then
        echo "app: ERROR - ${description} exact LaunchAgent kickstart did not start the installed process" >&2
        return 1
    fi
    echo "app: ${description} exact LaunchAgent restart verified"
    return 0
}

validate_bundle() {
    local bundle="$1"
    local description="$2"
    local executable="${bundle}/Contents/MacOS/Ticker"
    local helper="${bundle}/Contents/Helpers/ticker"
    local plist="${bundle}/Contents/Info.plist"
    local bundle_identifier
    local bundle_executable
    local bundle_package_type

    if [[ ! -d "${bundle}" ]]; then
        echo "${description}: ERROR - bundle is missing" >&2
        return 1
    fi
    if [[ ! -x "${executable}" ]]; then
        echo "${description}: ERROR - executable is missing or not executable: ${executable}" >&2
        return 1
    fi
    if [[ ! -x "${helper}" ]]; then
        echo "${description}: ERROR - helper is missing or not executable: ${helper}" >&2
        return 1
    fi
    if [[ ! -f "${plist}" ]]; then
        echo "${description}: ERROR - Info.plist is missing: ${plist}" >&2
        return 1
    fi
    if ! "${PLUTIL}" -lint "${plist}" >/dev/null 2>&1; then
        echo "${description}: ERROR - Info.plist is invalid: ${plist}" >&2
        return 1
    fi
    if ! bundle_identifier="$("${PLUTIL}" -extract CFBundleIdentifier raw -o - "${plist}")"; then
        echo "${description}: ERROR - Info.plist CFBundleIdentifier is missing or not a string" >&2
        return 1
    fi
    if [[ "${bundle_identifier}" != "com.suchintan.ticker" ]]; then
        echo "${description}: ERROR - Info.plist CFBundleIdentifier must be exactly 'com.suchintan.ticker' (found '${bundle_identifier}')" >&2
        return 1
    fi
    if ! bundle_executable="$("${PLUTIL}" -extract CFBundleExecutable raw -o - "${plist}")"; then
        echo "${description}: ERROR - Info.plist CFBundleExecutable is missing or not a string" >&2
        return 1
    fi
    if [[ "${bundle_executable}" != "Ticker" ]]; then
        echo "${description}: ERROR - Info.plist CFBundleExecutable must be exactly 'Ticker' (found '${bundle_executable}')" >&2
        return 1
    fi
    if ! bundle_package_type="$("${PLUTIL}" -extract CFBundlePackageType raw -o - "${plist}")"; then
        echo "${description}: ERROR - Info.plist CFBundlePackageType is missing or not a string" >&2
        return 1
    fi
    if [[ "${bundle_package_type}" != "APPL" ]]; then
        echo "${description}: ERROR - Info.plist CFBundlePackageType must be exactly 'APPL' (found '${bundle_package_type}')" >&2
        return 1
    fi

    case "${CODESIGN_CHECK_ENABLED}" in
        0|false|FALSE|no|NO)
            ;;
        *)
            if ! "${CODESIGN}" --verify --deep --strict "${bundle}"; then
                echo "${description}: ERROR - signature verification failed" >&2
                return 1
            fi
            ;;
    esac

    return 0
}

remove_transaction_path() {
    local path="$1"
    local description="$2"

    if [[ -z "${path}" ]] || ! path_exists "${path}"; then
        return 0
    fi
    if ! "${REMOVE_COMMAND}" -rf -- "${path}"; then
        if ! path_exists "${path}"; then
            return 0
        fi
        echo "installer: ERROR - could not remove ${description}; retained at ${path}" >&2
        return 1
    fi
    if path_exists "${path}"; then
        echo "installer: ERROR - could not prove ${description} was removed; retained at ${path}" >&2
        return 1
    fi
    return 0
}

remove_staging_bundle() {
    local description="$1"
    local expected_identity="${2:-${STAGED_BUNDLE_IDENTITY:-${STAGING_CUSTODY_IDENTITY}}}"
    local observed_identity

    if [[ -z "${STAGING_BUNDLE}" ]] || ! path_exists "${STAGING_BUNDLE}"; then
        return 0
    fi
    if [[ -z "${expected_identity}" ]]; then
        echo "installer: ERROR - unidentified ${description} retained at ${STAGING_BUNDLE}" >&2
        return 1
    fi
    observed_identity="$(path_identity "${STAGING_BUNDLE}")" || {
        echo "installer: ERROR - could not identify ${description}; retained at ${STAGING_BUNDLE}" >&2
        return 1
    }
    if [[ "${observed_identity}" != "${expected_identity}" ]]; then
        echo "installer: ERROR - ${description} identity changed; retained at ${STAGING_BUNDLE}" >&2
        return 1
    fi
    remove_transaction_path "${STAGING_BUNDLE}" "${description}"
}

reserve_absent_sibling_path() {
    local base="$1"
    local suffix="$2"

    RESERVED_PATH="$(mktemp -d "${base}.${suffix}.XXXXXX")" || return 1
    if ! rmdir "${RESERVED_PATH}"; then
        echo "installer: ERROR - could not reserve transaction path: ${RESERVED_PATH}" >&2
        return 1
    fi
    return 0
}

validate_exchange_pair() {
    local first="$1"
    local second="$2"
    local description="$3"
    local first_parent
    local second_parent
    local first_device
    local second_device

    if ! path_exists "${first}" || ! path_exists "${second}"; then
        echo "installer: ERROR - ${description} requires two existing paths" >&2
        return 1
    fi
    first_parent="$(cd "$(dirname "${first}")" && pwd -P)" || return 1
    second_parent="$(cd "$(dirname "${second}")" && pwd -P)" || return 1
    if [[ "${first_parent}" != "${second_parent}" ]]; then
        echo "installer: ERROR - ${description} paths are not siblings" >&2
        return 1
    fi
    first_device="$(path_device "${first}")" || return 1
    second_device="$(path_device "${second}")" || return 1
    if [[ "${first_device}" != "${second_device}" ]]; then
        echo "installer: ERROR - ${description} paths are not on the same filesystem" >&2
        return 1
    fi
    return 0
}

validate_fresh_rename_pair() {
    local staged_parent
    local destination_parent
    local staged_device
    local parent_device

    staged_parent="$(cd "$(dirname "${STAGING_BUNDLE}")" && pwd -P)" || return 1
    destination_parent="$(cd "${INSTALL_PARENT}" && pwd -P)" || return 1
    if [[ "${staged_parent}" != "${destination_parent}" ]]; then
        echo "installer: ERROR - fresh-install staging and destination are not siblings" >&2
        return 1
    fi
    staged_device="$(path_device "${STAGING_BUNDLE}")" || return 1
    parent_device="$(path_device "${INSTALL_PARENT}")" || return 1
    if [[ "${staged_device}" != "${parent_device}" ]]; then
        echo "installer: ERROR - fresh-install staging and destination are not on the same filesystem" >&2
        return 1
    fi
    return 0
}

build_exchange_helper() {
    local temporary_root="${TMPDIR:-/tmp}"

    if [[ ! -x "${CC_COMMAND}" ]]; then
        echo "installer: ERROR - atomic exchange is unavailable; system compiler not found: ${CC_COMMAND}" >&2
        return 1
    fi
    EXCHANGE_HELPER_DIRECTORY="$(mktemp -d "${temporary_root%/}/ticker-install-exchange.XXXXXX")" \
        || return 1
    EXCHANGE_HELPER="${EXCHANGE_HELPER_DIRECTORY}/rename-swap"
    if ! "${CC_COMMAND}" -Os -Wall -Wextra -x c -o "${EXCHANGE_HELPER}" - <<'HELPER_SOURCE'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stdio.h>

int main(int argc, char **argv) {
    if (argc == 3) {
        if (renameatx_np(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_SWAP) != 0) {
            fprintf(stderr, "renameatx_np(%s, %s, RENAME_SWAP): %s\n",
                    argv[1], argv[2], strerror(errno));
            return 1;
        }
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "--no-replace") == 0) {
        if (renameatx_np(AT_FDCWD, argv[2], AT_FDCWD, argv[3], RENAME_EXCL) != 0) {
            fprintf(stderr, "renameatx_np(%s, %s, RENAME_EXCL): %s\n",
                    argv[2], argv[3], strerror(errno));
            return 1;
        }
        return 0;
    }
    fprintf(stderr, "usage: rename-swap FIRST SECOND | rename-swap --no-replace SOURCE DESTINATION\n");
    return 64;
}
HELPER_SOURCE
    then
        echo "installer: ERROR - could not build the atomic directory-exchange helper" >&2
        return 1
    fi
    if [[ ! -x "${EXCHANGE_HELPER}" ]]; then
        echo "installer: ERROR - atomic directory-exchange helper is not executable" >&2
        return 1
    fi

    if [[ -n "${EXCHANGE_COMMAND_OVERRIDE}" ]]; then
        if [[ ! -x "${EXCHANGE_COMMAND_OVERRIDE}" ]]; then
            echo "installer: ERROR - configured atomic exchange command is not executable" >&2
            return 1
        fi
        EXCHANGE_COMMAND="${EXCHANGE_COMMAND_OVERRIDE}"
    else
        EXCHANGE_COMMAND="${EXCHANGE_HELPER}"
    fi

    if [[ -n "${NO_REPLACE_COMMAND_OVERRIDE}" ]]; then
        if [[ ! -x "${NO_REPLACE_COMMAND_OVERRIDE}" ]]; then
            echo "installer: ERROR - configured no-replace command is not executable" >&2
            return 1
        fi
        NO_REPLACE_COMMAND="${NO_REPLACE_COMMAND_OVERRIDE}"
    else
        NO_REPLACE_COMMAND="${EXCHANGE_HELPER}"
    fi
    return 0
}

atomic_exchange() {
    TICKER_INSTALL_NATIVE_EXCHANGE_HELPER="${EXCHANGE_HELPER}" \
        "${EXCHANGE_COMMAND}" "$1" "$2"
}

native_atomic_exchange() {
    "${EXCHANGE_HELPER}" "$1" "$2"
}

atomic_publish_no_replace() {
    TICKER_INSTALL_NATIVE_RENAME_HELPER="${EXCHANGE_HELPER}" \
        "${NO_REPLACE_COMMAND}" --no-replace "$1" "$2"
}

cleanup_exchange_probes() {
    local cleanup_failed=0

    if ! remove_transaction_path "${EXCHANGE_PROBE_A}" "first atomic-exchange probe"; then
        cleanup_failed=1
    fi
    if ! remove_transaction_path "${EXCHANGE_PROBE_B}" "second atomic-exchange probe"; then
        cleanup_failed=1
    fi
    if [[ "${cleanup_failed}" -eq 0 ]]; then
        EXCHANGE_PROBE_A=""
        EXCHANGE_PROBE_B=""
    fi
    return "${cleanup_failed}"
}

preflight_atomic_exchange_in_parent() {
    local parent="$1"
    local description="$2"
    local first_before
    local second_before
    local first_after
    local second_after
    local first_restored
    local second_restored
    local first_status=0
    local restore_status=0
    local exchanged=0
    local preflight_failed=0

    EXCHANGE_PROBE_A="$(mktemp -d "${parent}/.ticker-rename-swap-a.XXXXXX")" || return 1
    EXCHANGE_PROBE_B="$(mktemp -d "${parent}/.ticker-rename-swap-b.XXXXXX")" || return 1
    if ! validate_exchange_pair "${EXCHANGE_PROBE_A}" "${EXCHANGE_PROBE_B}" \
        "${description} preflight"; then
        cleanup_exchange_probes || true
        return 1
    fi
    first_before="$(path_identity "${EXCHANGE_PROBE_A}")" || return 1
    second_before="$(path_identity "${EXCHANGE_PROBE_B}")" || return 1

    if ! atomic_exchange "${EXCHANGE_PROBE_A}" "${EXCHANGE_PROBE_B}"; then
        first_status=1
    fi
    first_after="$(path_identity "${EXCHANGE_PROBE_A}")" || preflight_failed=1
    second_after="$(path_identity "${EXCHANGE_PROBE_B}")" || preflight_failed=1
    if [[ "${preflight_failed}" -eq 0 \
        && "${first_after}" == "${second_before}" \
        && "${second_after}" == "${first_before}" ]]; then
        exchanged=1
        if ! atomic_exchange "${EXCHANGE_PROBE_A}" "${EXCHANGE_PROBE_B}"; then
            restore_status=1
        fi
        first_restored="$(path_identity "${EXCHANGE_PROBE_A}")" || preflight_failed=1
        second_restored="$(path_identity "${EXCHANGE_PROBE_B}")" || preflight_failed=1
        if [[ "${first_restored}" != "${first_before}" \
            || "${second_restored}" != "${second_before}" ]]; then
            restore_status=1
        fi
    elif [[ "${preflight_failed}" -eq 0 \
        && "${first_after}" == "${first_before}" \
        && "${second_after}" == "${second_before}" ]]; then
        exchanged=0
    else
        preflight_failed=1
    fi

    if ! cleanup_exchange_probes; then
        preflight_failed=1
    fi
    if [[ "${first_status}" -ne 0 || "${exchanged}" -ne 1 \
        || "${restore_status}" -ne 0 || "${preflight_failed}" -ne 0 ]]; then
        echo "installer: ERROR - atomic exchange preflight failed for ${description}" >&2
        return 1
    fi
    echo "atomic exchange verified for ${description}"
    return 0
}

prior_helper_explicitly_lacks_login_item_command() {
    local status="$1"
    local output="$2"

    if [[ "${status}" -ne 2 ]]; then
        return 1
    fi
    case "${output}" in
        "ticker: Unknown command 'login-item'. Run 'ticker --help' for usage."|\
        $'ticker: Unknown command \'login-item\'. Run \'ticker --help\' for usage.\nRun \'ticker --help\' for usage.')
            return 0
            ;;
    esac
    return 1
}

validate_legacy_login_plist_if_present() {
    local agent_plist="${HOME}/Library/LaunchAgents/com.suchintan.ticker.login.plist"
    local arguments_type
    local label
    local program_argument

    if [[ -L "${agent_plist}" ]]; then
        echo "login item: ERROR - legacy LaunchAgent plist must not be a symbolic link" >&2
        return 1
    fi
    if [[ ! -e "${agent_plist}" ]]; then
        return 0
    fi
    if [[ ! -f "${agent_plist}" ]]; then
        echo "login item: ERROR - legacy LaunchAgent plist must be a regular file" >&2
        return 1
    fi
    if ! "${PLUTIL}" -lint "${agent_plist}" >/dev/null 2>&1; then
        echo "login item: ERROR - legacy LaunchAgent plist is malformed" >&2
        return 1
    fi
    if ! label="$("${PLUTIL}" -extract Label raw -o - "${agent_plist}" 2>/dev/null)" \
        || [[ "${label}" != "com.suchintan.ticker.login" ]]; then
        echo "login item: ERROR - legacy LaunchAgent plist has the wrong label" >&2
        return 1
    fi
    if "${PLUTIL}" -extract Program raw -o - "${agent_plist}" >/dev/null 2>&1; then
        echo "login item: ERROR - legacy LaunchAgent plist contains unsupported Program" >&2
        return 1
    fi
    if ! arguments_type="$("${PLUTIL}" -type ProgramArguments "${agent_plist}" 2>/dev/null)" \
        || [[ "${arguments_type}" != "array" ]]; then
        echo "login item: ERROR - legacy LaunchAgent ProgramArguments is not an array" >&2
        return 1
    fi
    if ! program_argument="$("${PLUTIL}" \
        -extract ProgramArguments.0 raw -o - "${agent_plist}" 2>/dev/null)" \
        || [[ "${program_argument}" != "${INSTALL_BUNDLE}/Contents/MacOS/Ticker" ]]; then
        echo "login item: ERROR - legacy LaunchAgent plist has the wrong executable" >&2
        return 1
    fi
    if "${PLUTIL}" -extract ProgramArguments.1 raw -o - "${agent_plist}" \
        >/dev/null 2>&1; then
        echo "login item: ERROR - legacy LaunchAgent plist has extra arguments" >&2
        return 1
    fi
    return 0
}

legacy_login_state_was_provided() {
    [[ "${TICKER_INSTALL_LEGACY_LOGIN_STATE+x}" == "x" ]]
}

validate_explicit_legacy_login_state() {
    if ! legacy_login_state_was_provided; then
        return 0
    fi
    case "${TICKER_INSTALL_LEGACY_LOGIN_STATE}" in
        "disabled"|"system-settings"|"requires-approval")
            return 0
            ;;
        *)
            echo "login item: ERROR - TICKER_INSTALL_LEGACY_LOGIN_STATE must be disabled, system-settings, or requires-approval" >&2
            return 1
            ;;
    esac
}

capture_legacy_login_state() {
    local staged_helper="$1"
    local agent_target="gui/${UID}/com.suchintan.ticker.login"
    local launchctl_output
    local launchctl_status
    local state

    if launchctl_output="$("${LAUNCHCTL}" print "${agent_target}" 2>&1)"; then
        if ! state="$("${staged_helper}" login-item status 2>&1)"; then
            echo "login item: ERROR - legacy live LaunchAgent validation failed: ${state}" >&2
            return 1
        fi
        if [[ "${state}" != "enabled via LaunchAgent" ]]; then
            echo "login item: ERROR - legacy live LaunchAgent state is inconsistent: ${state}" >&2
            return 1
        fi
        if legacy_login_state_was_provided; then
            echo "login item: ERROR - TICKER_INSTALL_LEGACY_LOGIN_STATE is not valid when the exact legacy LaunchAgent is live" >&2
            return 1
        fi
        printf '%s\n' "${state}"
        return 0
    else
        launchctl_status=$?
    fi

    if [[ "${launchctl_status}" -ne 113 \
        || "${launchctl_output}" != *"Could not find service"* ]]; then
        echo "login item: ERROR - legacy LaunchAgent query failed (launchctl status ${launchctl_status}): ${launchctl_output}" >&2
        return 1
    fi
    if ! validate_legacy_login_plist_if_present; then
        return 1
    fi
    if ! legacy_login_state_was_provided; then
        echo "login item: ERROR - exact legacy LaunchAgent absence is ambiguous; set TICKER_INSTALL_LEGACY_LOGIN_STATE to disabled, system-settings, or requires-approval" >&2
        return 1
    fi
    case "${TICKER_INSTALL_LEGACY_LOGIN_STATE}" in
        "disabled")
            printf '%s\n' "disabled"
            ;;
        "system-settings")
            printf '%s\n' "enabled via System Settings login item"
            ;;
        "requires-approval")
            printf '%s\n' "${REQUIRES_APPROVAL_LOGIN_STATE}"
            ;;
    esac
    return 0
}

capture_prior_login_state() {
    local helper
    local helper_status
    local staged_helper="${STAGING_BUNDLE}/Contents/Helpers/ticker"
    local state

    if ! validate_explicit_legacy_login_state; then
        return 1
    fi
    if [[ "${PRIOR_EXISTED}" -eq 1 ]]; then
        helper="${INSTALL_BUNDLE}/Contents/Helpers/ticker"
    else
        helper="${staged_helper}"
    fi
    if [[ ! -x "${helper}" ]]; then
        echo "login item: ERROR - helper for prior-state capture is missing or not executable" >&2
        return 1
    fi
    if state="$("${helper}" login-item status 2>&1)"; then
        if legacy_login_state_was_provided; then
            echo "login item: ERROR - TICKER_INSTALL_LEGACY_LOGIN_STATE is only valid for an unsupported legacy helper with no live exact LaunchAgent" >&2
            return 1
        fi
    else
        helper_status=$?
        if [[ "${PRIOR_EXISTED}" -eq 1 ]] \
            && prior_helper_explicitly_lacks_login_item_command "${helper_status}" "${state}"; then
            if [[ ! -x "${staged_helper}" ]]; then
                echo "login item: ERROR - staged fallback helper is missing or not executable" >&2
                return 1
            fi
            echo "login item: prior helper lacks login-item; using the legacy launchctl/plist read contract"
            if ! state="$(capture_legacy_login_state "${staged_helper}")"; then
                return 1
            fi
        else
            if legacy_login_state_was_provided; then
                echo "login item: ERROR - TICKER_INSTALL_LEGACY_LOGIN_STATE is only valid for an unsupported legacy helper with no live exact LaunchAgent" >&2
                return 1
            fi
            echo "login item: ERROR - could not capture prior state (helper status ${helper_status}): ${state}" >&2
            return 1
        fi
    fi
    case "${state}" in
        "disabled"|"enabled via System Settings login item"|"enabled via LaunchAgent"|\
        "${REQUIRES_APPROVAL_LOGIN_STATE}")
            ;;
        *)
            echo "login item: ERROR - unsupported prior state: ${state}" >&2
            return 1
            ;;
    esac
    if [[ "${PRIOR_EXISTED}" -eq 0 && "${state}" != "disabled" ]]; then
        echo "login item: ERROR - a fresh install requires a disabled prior login item" >&2
        return 1
    fi
    PRIOR_LOGIN_STATE="${state}"
    echo "login item: captured prior state: ${PRIOR_LOGIN_STATE}"
    return 0
}

enable_and_verify_fresh_login_item() {
    local bundle="$1"
    local login_helper="${bundle}/Contents/Helpers/ticker"
    local enable_state
    local verified_state

    if [[ "${PRIOR_EXISTED}" -ne 0 ]]; then
        echo "login item: ERROR - fresh-install enable was requested during reinstall" >&2
        return 1
    fi

    if [[ ! -x "${login_helper}" ]]; then
        echo "login item: ERROR - installed helper is missing or not executable" >&2
        return 1
    fi

    # Mark the mutation before invoking the helper. A successful enable followed
    # by a failed status read still has to be compensated during rollback.
    LOGIN_MUTATION_STARTED=1
    if ! enable_state="$("${login_helper}" login-item enable 2>&1)"; then
        echo "login item: ERROR - enable failed: ${enable_state}" >&2
        return 1
    fi
    case "${enable_state}" in
        "enabled via System Settings login item"|"enabled via LaunchAgent")
            ;;
        *)
            echo "login item: ERROR - enable did not produce a live mechanism: ${enable_state}" >&2
            return 1
            ;;
    esac

    if ! verified_state="$("${login_helper}" login-item status 2>&1)"; then
        echo "login item: ERROR - live-state verification failed: ${verified_state}" >&2
        return 1
    fi
    if [[ "${verified_state}" != "${enable_state}" ]]; then
        echo "login item: ERROR - state changed after enable: ${verified_state}" >&2
        return 1
    fi

    EXPECTED_LOGIN_STATE="${verified_state}"
    echo "login item: ${verified_state}"
    return 0
}

verify_reinstalled_login_state() {
    local login_helper="${INSTALL_BUNDLE}/Contents/Helpers/ticker"
    local verified_state

    if [[ "${PRIOR_EXISTED}" -ne 1 ]]; then
        echo "login item: ERROR - reinstall state verification was requested during fresh install" >&2
        return 1
    fi

    if [[ ! -x "${login_helper}" ]]; then
        echo "login item: ERROR - installed helper is missing or not executable" >&2
        return 1
    fi
    if ! verified_state="$("${login_helper}" login-item status 2>&1)"; then
        echo "login item: ERROR - reinstall state verification failed: ${verified_state}" >&2
        return 1
    fi
    if [[ "${verified_state}" != "${PRIOR_LOGIN_STATE}" ]]; then
        echo "login item: ERROR - replacement changed the prior login state: ${verified_state}; expected ${PRIOR_LOGIN_STATE}" >&2
        return 1
    fi
    EXPECTED_LOGIN_STATE="${verified_state}"
    echo "login item: preserved prior state: ${verified_state}"
    return 0
}

verify_final_installed_login_state() {
    local login_helper="${INSTALL_BUNDLE}/Contents/Helpers/ticker"
    local verified_state

    if [[ -z "${EXPECTED_LOGIN_STATE}" ]]; then
        echo "login item: ERROR - no early expected login state was proven" >&2
        return 1
    fi
    if [[ ! -x "${login_helper}" ]]; then
        echo "login item: ERROR - installed helper is missing before final state verification" >&2
        return 1
    fi
    if ! verified_state="$("${login_helper}" login-item status 2>&1)"; then
        echo "login item: ERROR - final installed-helper state verification failed: ${verified_state}" >&2
        return 1
    fi
    if [[ "${verified_state}" != "${EXPECTED_LOGIN_STATE}" ]]; then
        echo "login item: ERROR - installed login state changed before commit: ${verified_state}; expected ${EXPECTED_LOGIN_STATE}" >&2
        return 1
    fi

    FINAL_LOGIN_STATE="${verified_state}"
    if [[ "${PRIOR_EXISTED}" -eq 1 ]]; then
        echo "login item: final preserved state: ${verified_state}"
    else
        echo "login item: final installed state: ${verified_state}"
    fi
    return 0
}

verify_restored_launch_agent_state() {
    local login_helper="${STAGING_BUNDLE}/Contents/Helpers/ticker"
    local verified_state

    if [[ "${PRIOR_LOGIN_STATE}" != "enabled via LaunchAgent" ]]; then
        echo "login item: ERROR - restored LaunchAgent verification was requested for a different prior state" >&2
        return 1
    fi
    if [[ ! -x "${login_helper}" ]]; then
        echo "login item: ERROR - trusted replacement helper is unavailable for restored LaunchAgent verification" >&2
        return 1
    fi
    if ! verified_state="$("${login_helper}" login-item status 2>&1)"; then
        echo "login item: ERROR - restored LaunchAgent state verification failed: ${verified_state}" >&2
        return 1
    fi
    if [[ "${verified_state}" != "${PRIOR_LOGIN_STATE}" ]]; then
        echo "login item: ERROR - rollback did not restore the exact prior LaunchAgent state: ${verified_state}; expected ${PRIOR_LOGIN_STATE}" >&2
        return 1
    fi
    echo "login item: restored exact prior state: ${verified_state}" >&2
    return 0
}

restore_fresh_login_state() {
    local bundle="$1"
    local login_helper="${bundle}/Contents/Helpers/ticker"
    local mutation_state
    local verified_state

    if [[ "${PRIOR_EXISTED}" -ne 0 ]]; then
        echo "login item: ERROR - refusing fresh-install login rollback during reinstall" >&2
        return 1
    fi

    if [[ "${LOGIN_MUTATION_STARTED}" -eq 0 ]]; then
        return 0
    fi
    if [[ ! -x "${login_helper}" ]]; then
        echo "login item: ERROR - rollback helper is missing or not executable" >&2
        return 1
    fi

    if [[ "${PRIOR_LOGIN_STATE}" != "disabled" ]]; then
        echo "login item: ERROR - fresh-install rollback requires a disabled prior state" >&2
        return 1
    fi
    if ! mutation_state="$("${login_helper}" login-item disable 2>&1)"; then
        echo "login item: ERROR - rollback disable failed: ${mutation_state}" >&2
        return 1
    fi
    if [[ "${mutation_state}" != "disabled" ]]; then
        echo "login item: ERROR - rollback disable returned: ${mutation_state}" >&2
        return 1
    fi

    if ! verified_state="$("${login_helper}" login-item status 2>&1)"; then
        echo "login item: ERROR - rollback state verification failed: ${verified_state}" >&2
        return 1
    fi
    if [[ "${verified_state}" != "${PRIOR_LOGIN_STATE}" ]]; then
        echo "login item: ERROR - rollback did not restore the exact prior state: ${verified_state}" >&2
        return 1
    fi
    echo "login item: restored prior state: ${verified_state}" >&2
    LOGIN_MUTATION_STARTED=0
    return 0
}

capture_cli_state() {
    CLI_PARENT="$(dirname "${CLI_LINK}")"
    if [[ -d "${CLI_PARENT}" && -w "${CLI_PARENT}" ]]; then
        CLI_PARENT_WRITABLE=1
    fi
    if path_exists "${CLI_LINK}"; then
        CLI_PRIOR_EXISTED=1
        CLI_PRIOR_IDENTITY="$(path_identity "${CLI_LINK}")" || {
            echo "cli: ERROR - could not capture prior path identity: ${CLI_LINK}" >&2
            return 1
        }
    fi
    return 0
}

verify_installed_cli_link() {
    local expected="${INSTALL_BUNDLE}/Contents/Helpers/ticker"
    local observed

    if [[ ! -L "${CLI_LINK}" ]]; then
        echo "cli: ERROR - installed CLI path is not a symbolic link: ${CLI_LINK}" >&2
        return 1
    fi
    if ! observed="$("${READLINK_COMMAND}" "${CLI_LINK}")"; then
        echo "cli: ERROR - could not read installed CLI link: ${CLI_LINK}" >&2
        return 1
    fi
    if [[ "${observed}" != "${expected}" ]]; then
        echo "cli: ERROR - installed CLI link targets ${observed}, expected ${expected}" >&2
        return 1
    fi
    if [[ ! -x "${CLI_LINK}" ]]; then
        echo "cli: ERROR - installed CLI link does not resolve to an executable helper" >&2
        return 1
    fi
    return 0
}

reconcile_cli_state() {
    local link_identity=""
    local staged_identity=""

    if path_exists "${CLI_LINK}"; then
        link_identity="$(path_identity "${CLI_LINK}")" || return 1
    fi
    if path_exists "${CLI_STAGED_PATH}"; then
        staged_identity="$(path_identity "${CLI_STAGED_PATH}")" || return 1
    fi

    if [[ "${CLI_PRIOR_EXISTED}" -eq 1 ]]; then
        if [[ "${link_identity}" == "${CLI_NEW_IDENTITY}" \
            && "${staged_identity}" == "${CLI_PRIOR_IDENTITY}" ]]; then
            CLI_MUTATED=1
            return 0
        fi
        if [[ "${link_identity}" == "${CLI_PRIOR_IDENTITY}" \
            && "${staged_identity}" == "${CLI_NEW_IDENTITY}" ]]; then
            CLI_MUTATED=0
            return 0
        fi
    else
        if [[ "${link_identity}" == "${CLI_NEW_IDENTITY}" && -z "${staged_identity}" ]]; then
            CLI_MUTATED=1
            return 0
        fi
        if [[ -z "${link_identity}" && "${staged_identity}" == "${CLI_NEW_IDENTITY}" ]]; then
            CLI_MUTATED=0
            return 0
        fi
    fi

    echo "cli: ERROR - CLI path state does not match either side of the transaction" >&2
    return 1
}

recover_unexpected_cli_exchange() {
    local link_identity
    local staged_identity
    local unexpected_identity

    if ! path_exists "${CLI_LINK}" || ! path_exists "${CLI_STAGED_PATH}"; then
        return 1
    fi
    link_identity="$(path_identity "${CLI_LINK}")" || return 1
    staged_identity="$(path_identity "${CLI_STAGED_PATH}")" || return 1
    if [[ "${link_identity}" != "${CLI_NEW_IDENTITY}" \
        || "${staged_identity}" == "${CLI_PRIOR_IDENTITY}" \
        || "${staged_identity}" == "${CLI_NEW_IDENTITY}" ]]; then
        return 1
    fi

    unexpected_identity="${staged_identity}"
    echo "cli: unexpected destination identity was displaced; atomically exchanging it back" >&2
    if ! native_atomic_exchange "${CLI_LINK}" "${CLI_STAGED_PATH}"; then
        echo "cli: ERROR - could not exchange the unexpected CLI identity back into place" >&2
        return 1
    fi
    link_identity="$(path_identity "${CLI_LINK}")" || return 1
    staged_identity="$(path_identity "${CLI_STAGED_PATH}")" || return 1
    if [[ "${link_identity}" != "${unexpected_identity}" \
        || "${staged_identity}" != "${CLI_NEW_IDENTITY}" ]]; then
        echo "cli: ERROR - could not prove the unexpected CLI identity was restored" >&2
        return 1
    fi
    CLI_UNEXPECTED_DESTINATION_IDENTITY="${unexpected_identity}"
    CLI_MUTATED=0
    echo "cli: preserved unexpected destination identity at ${CLI_LINK}" >&2
    return 0
}

record_unexpected_cli_destination() {
    local observed_identity

    if ! path_exists "${CLI_LINK}"; then
        return 1
    fi
    observed_identity="$(path_identity "${CLI_LINK}")" || return 1
    if [[ "${observed_identity}" == "${CLI_NEW_IDENTITY}" ]]; then
        return 1
    fi
    CLI_UNEXPECTED_DESTINATION_IDENTITY="${observed_identity}"
    echo "cli: preserved unexpected destination identity at ${CLI_LINK}" >&2
    return 0
}

install_cli_link() {
    local expected="${INSTALL_BUNDLE}/Contents/Helpers/ticker"
    local current_identity
    local exchange_status=0
    local publish_status=0

    if [[ "${CLI_PARENT_WRITABLE}" -eq 0 ]]; then
        echo "cli: ${CLI_PARENT} is not writable; skipped. To link it yourself:"
        echo "     sudo ln -sf ${expected} ${CLI_LINK}"
        return 0
    fi

    if ! reserve_absent_sibling_path "${CLI_LINK}" "staging"; then
        return 1
    fi
    CLI_STAGED_PATH="${RESERVED_PATH}"
    if ! "${LINK_COMMAND}" -s "${expected}" "${CLI_STAGED_PATH}"; then
        echo "cli: ERROR - could not create staged CLI link" >&2
        return 1
    fi
    CLI_NEW_IDENTITY="$(path_identity "${CLI_STAGED_PATH}")" || return 1
    if [[ ! -L "${CLI_STAGED_PATH}" \
        || "$("${READLINK_COMMAND}" "${CLI_STAGED_PATH}")" != "${expected}" ]]; then
        echo "cli: ERROR - staged CLI link could not be verified" >&2
        return 1
    fi

    if [[ "${CLI_PRIOR_EXISTED}" -eq 1 ]]; then
        if ! path_exists "${CLI_LINK}"; then
            echo "cli: ERROR - prior CLI path disappeared during the install" >&2
            return 1
        fi
        current_identity="$(path_identity "${CLI_LINK}")" || return 1
        if [[ "${current_identity}" != "${CLI_PRIOR_IDENTITY}" ]]; then
            CLI_UNEXPECTED_DESTINATION_IDENTITY="${current_identity}"
            echo "cli: ERROR - prior CLI path changed during the install" >&2
            return 1
        fi
        if ! validate_exchange_pair "${CLI_LINK}" "${CLI_STAGED_PATH}" "CLI path exchange"; then
            return 1
        fi
        CLI_MUTATION_STARTED=1
        if ! atomic_exchange "${CLI_LINK}" "${CLI_STAGED_PATH}"; then
            exchange_status=1
        fi
        if ! reconcile_cli_state; then
            if recover_unexpected_cli_exchange; then
                echo "cli: ERROR - CLI destination changed during the atomic exchange" >&2
            fi
            return 1
        fi
        if [[ "${exchange_status}" -ne 0 || "${CLI_MUTATED}" -ne 1 ]]; then
            echo "cli: ERROR - atomic CLI link exchange failed" >&2
            return 1
        fi
    else
        if path_exists "${CLI_LINK}"; then
            if ! record_unexpected_cli_destination; then
                echo "cli: ERROR - could not capture the appeared CLI path identity" >&2
            fi
            echo "cli: ERROR - CLI path appeared; publication refused to overwrite it" >&2
            return 1
        fi
        CLI_MUTATION_STARTED=1
        if ! atomic_publish_no_replace "${CLI_STAGED_PATH}" "${CLI_LINK}"; then
            publish_status=1
        fi
        if ! reconcile_cli_state; then
            if record_unexpected_cli_destination; then
                echo "cli: ERROR - CLI path appeared; no-replace publication refused to overwrite it" >&2
            fi
            return 1
        fi
        if [[ "${publish_status}" -ne 0 || "${CLI_MUTATED}" -ne 1 ]]; then
            echo "cli: ERROR - atomic no-replace CLI publication failed" >&2
            return 1
        fi
    fi

    if ! verify_installed_cli_link; then
        return 1
    fi
    echo "cli: linked ${CLI_LINK} -> ${expected}"
    return 0
}

restore_cli_state() {
    local exchange_status=0
    local restored_identity
    local restore_failed=0
    local staged_identity

    if [[ -n "${CLI_UNEXPECTED_DESTINATION_IDENTITY}" ]]; then
        if ! path_exists "${CLI_LINK}"; then
            echo "cli: ERROR - unexpected CLI destination disappeared during recovery" >&2
            return 1
        fi
        restored_identity="$(path_identity "${CLI_LINK}")" || return 1
        if [[ "${restored_identity}" != "${CLI_UNEXPECTED_DESTINATION_IDENTITY}" ]]; then
            echo "cli: ERROR - unexpected CLI destination changed during recovery" >&2
            return 1
        fi
        if ! path_exists "${CLI_STAGED_PATH}"; then
            echo "cli: ERROR - new CLI link is not retained at its staging identity" >&2
            return 1
        fi
        staged_identity="$(path_identity "${CLI_STAGED_PATH}")" || return 1
        if [[ "${staged_identity}" != "${CLI_NEW_IDENTITY}" ]]; then
            echo "cli: ERROR - new CLI link is not retained at its staging identity" >&2
            return 1
        fi
        if ! remove_transaction_path "${CLI_STAGED_PATH}" "unpublished new CLI link"; then
            return 1
        fi
        CLI_STAGED_PATH=""
        echo "cli: left the unexpected destination identity untouched" >&2
        return 0
    fi

    if [[ "${CLI_MUTATION_STARTED}" -eq 1 ]]; then
        if ! reconcile_cli_state; then
            return 1
        fi
        if [[ "${CLI_MUTATED}" -eq 1 && "${CLI_PRIOR_EXISTED}" -eq 1 ]]; then
            if ! validate_exchange_pair "${CLI_LINK}" "${CLI_STAGED_PATH}" \
                "CLI rollback exchange"; then
                return 1
            fi
            if ! atomic_exchange "${CLI_LINK}" "${CLI_STAGED_PATH}"; then
                exchange_status=1
            fi
            if ! reconcile_cli_state; then
                return 1
            fi
            if [[ "${CLI_MUTATED}" -ne 0 ]]; then
                echo "cli: ERROR - prior CLI path remains displaced at ${CLI_STAGED_PATH}" >&2
                return 1
            fi
            if [[ "${exchange_status}" -ne 0 ]]; then
                echo "cli: WARNING - rollback exchange reported failure after restoring path identities" >&2
            fi
        elif [[ "${CLI_MUTATED}" -eq 1 ]]; then
            if ! remove_transaction_path "${CLI_LINK}" "failed new CLI link"; then
                return 1
            fi
            CLI_MUTATED=0
        fi
    fi

    if [[ "${CLI_PRIOR_EXISTED}" -eq 1 ]]; then
        if ! path_exists "${CLI_LINK}"; then
            echo "cli: ERROR - prior CLI path was not restored" >&2
            return 1
        fi
        restored_identity="$(path_identity "${CLI_LINK}")" || return 1
        if [[ "${restored_identity}" != "${CLI_PRIOR_IDENTITY}" ]]; then
            echo "cli: ERROR - restored CLI path does not have its prior identity" >&2
            return 1
        fi
    elif path_exists "${CLI_LINK}"; then
        echo "cli: ERROR - rollback left a CLI path that did not previously exist" >&2
        return 1
    fi

    if ! remove_transaction_path "${CLI_STAGED_PATH}" "staged or displaced CLI path"; then
        restore_failed=1
    else
        CLI_STAGED_PATH=""
    fi
    if [[ "${CLI_MUTATION_STARTED}" -eq 1 ]]; then
        echo "cli: restored prior path state" >&2
    fi
    return "${restore_failed}"
}

reconcile_app_state() {
    local installed_identity=""
    local staged_identity=""
    local expected_staged_identity="${STAGED_BUNDLE_IDENTITY:-${STAGING_CUSTODY_IDENTITY}}"

    if [[ -z "${expected_staged_identity}" ]]; then
        echo "installer: ERROR - staged application identity was never captured" >&2
        return 1
    fi
    if path_exists "${INSTALL_BUNDLE}"; then
        installed_identity="$(path_identity "${INSTALL_BUNDLE}")" || return 1
    fi
    if path_exists "${STAGING_BUNDLE}"; then
        staged_identity="$(path_identity "${STAGING_BUNDLE}")" || return 1
    fi

    if [[ "${PRIOR_EXISTED}" -eq 1 ]]; then
        if [[ -n "${STAGED_BUNDLE_IDENTITY}" \
            && "${installed_identity}" == "${STAGED_BUNDLE_IDENTITY}" \
            && "${staged_identity}" == "${PRIOR_BUNDLE_IDENTITY}" ]]; then
            APP_EXCHANGED=1
            return 0
        fi
        if [[ "${installed_identity}" == "${PRIOR_BUNDLE_IDENTITY}" \
            && "${staged_identity}" == "${expected_staged_identity}" ]]; then
            APP_EXCHANGED=0
            return 0
        fi
    else
        if [[ -n "${STAGED_BUNDLE_IDENTITY}" \
            && "${installed_identity}" == "${STAGED_BUNDLE_IDENTITY}" \
            && -z "${staged_identity}" ]]; then
            FRESH_REPLACEMENT_INSTALLED=1
            return 0
        fi
        if [[ -z "${installed_identity}" \
            && "${staged_identity}" == "${expected_staged_identity}" ]]; then
            FRESH_REPLACEMENT_INSTALLED=0
            return 0
        fi
    fi

    echo "installer: ERROR - application paths do not match either transaction state" >&2
    return 1
}

record_unexpected_app_destination() {
    local observed_identity

    if ! path_exists "${INSTALL_BUNDLE}"; then
        return 1
    fi
    observed_identity="$(path_identity "${INSTALL_BUNDLE}")" || return 1
    if [[ "${observed_identity}" == "${STAGED_BUNDLE_IDENTITY}" ]]; then
        return 1
    fi
    APP_UNEXPECTED_DESTINATION_IDENTITY="${observed_identity}"
    echo "installer: preserved unexpected destination identity at ${INSTALL_BUNDLE}" >&2
    return 0
}

recover_unexpected_app_exchange() {
    local installed_identity
    local staged_identity
    local unexpected_identity

    if ! path_exists "${INSTALL_BUNDLE}" || ! path_exists "${STAGING_BUNDLE}"; then
        return 1
    fi
    installed_identity="$(path_identity "${INSTALL_BUNDLE}")" || return 1
    staged_identity="$(path_identity "${STAGING_BUNDLE}")" || return 1
    if [[ "${installed_identity}" != "${STAGED_BUNDLE_IDENTITY}" \
        || "${staged_identity}" == "${PRIOR_BUNDLE_IDENTITY}" \
        || "${staged_identity}" == "${STAGED_BUNDLE_IDENTITY}" ]]; then
        return 1
    fi

    unexpected_identity="${staged_identity}"
    echo "installer: unexpected bundle identity was displaced; atomically exchanging it back" >&2
    if ! native_atomic_exchange "${INSTALL_BUNDLE}" "${STAGING_BUNDLE}"; then
        echo "installer: ERROR - could not exchange the unexpected bundle back into place" >&2
        return 1
    fi
    installed_identity="$(path_identity "${INSTALL_BUNDLE}")" || return 1
    staged_identity="$(path_identity "${STAGING_BUNDLE}")" || return 1
    if [[ "${installed_identity}" != "${unexpected_identity}" \
        || "${staged_identity}" != "${STAGED_BUNDLE_IDENTITY}" ]]; then
        echo "installer: ERROR - could not prove the unexpected bundle was restored" >&2
        return 1
    fi
    APP_UNEXPECTED_DESTINATION_IDENTITY="${unexpected_identity}"
    APP_EXCHANGED=0
    echo "installer: preserved unexpected destination identity at ${INSTALL_BUNDLE}" >&2
    return 0
}

rollback_unexpected_app_destination() {
    local rollback_failed=0
    local installed_identity
    local staged_identity

    if ! path_exists "${INSTALL_BUNDLE}"; then
        echo "installer: ERROR - unexpected destination bundle disappeared during recovery" >&2
        return 1
    fi
    installed_identity="$(path_identity "${INSTALL_BUNDLE}")" || return 1
    if [[ "${installed_identity}" != "${APP_UNEXPECTED_DESTINATION_IDENTITY}" ]]; then
        echo "installer: ERROR - unexpected destination bundle changed during recovery" >&2
        return 1
    fi
    if ! path_exists "${STAGING_BUNDLE}"; then
        echo "installer: ERROR - staged replacement disappeared during recovery" >&2
        return 1
    fi
    staged_identity="$(path_identity "${STAGING_BUNDLE}")" || return 1
    if [[ "${staged_identity}" != "${STAGED_BUNDLE_IDENTITY}" ]]; then
        echo "installer: ERROR - staged replacement identity changed during recovery" >&2
        return 1
    fi

    if ! restore_cli_state; then
        rollback_failed=1
    fi
    if [[ "${rollback_failed}" -eq 0 ]]; then
        if ! remove_staging_bundle "unpublished staged replacement"; then
            rollback_failed=1
        else
            STAGING_BUNDLE=""
        fi
        if ! remove_support_paths; then
            rollback_failed=1
        fi
    fi
    if [[ "${rollback_failed}" -eq 0 ]]; then
        FINAL_STATE_PROVEN=1
        echo "installer: unexpected destination bundle was left untouched for manual recovery" >&2
    fi
    return "${rollback_failed}"
}

remove_support_paths() {
    local cleanup_failed=0

    if ! cleanup_exchange_probes; then
        cleanup_failed=1
    fi
    if ! remove_transaction_path "${EXCHANGE_HELPER_DIRECTORY}" \
        "atomic-exchange helper directory"; then
        cleanup_failed=1
    else
        EXCHANGE_HELPER_DIRECTORY=""
        EXCHANGE_HELPER=""
    fi
    return "${cleanup_failed}"
}

rollback_reinstall() {
    local rollback_failed=0
    local exchange_status=0
    local app_restored=0
    local process_status

    if [[ -n "${APP_UNEXPECTED_DESTINATION_IDENTITY}" ]]; then
        rollback_unexpected_app_destination
        return $?
    fi
    if ! reconcile_app_state; then
        return 1
    fi
    if [[ "${APP_EXCHANGED}" -eq 1 ]]; then
        if ! stop_installed_app_for_rollback "failed replacement"; then
            echo "installer: ERROR - refusing to mutate the bundle while its exact process may still be running" >&2
            return 1
        fi
        echo "installer: atomically exchanging the prior bundle back into place" >&2
        if ! validate_exchange_pair "${INSTALL_BUNDLE}" "${STAGING_BUNDLE}" \
            "application rollback exchange"; then
            return 1
        fi
        if ! atomic_exchange "${INSTALL_BUNDLE}" "${STAGING_BUNDLE}"; then
            exchange_status=1
        fi
        if ! reconcile_app_state; then
            return 1
        fi
        if [[ "${APP_EXCHANGED}" -ne 0 ]]; then
            echo "installer: ERROR - prior bundle remains available at ${STAGING_BUNDLE}" >&2
            return 1
        fi
        if [[ "${exchange_status}" -ne 0 ]]; then
            echo "installer: WARNING - rollback exchange reported failure after restoring path identities" >&2
        fi
    fi

    if [[ "${APP_MUTATION_STARTED}" -eq 0 && "${APP_EXCHANGED}" -eq 0 ]]; then
        app_restored=1
        echo "installer: prior bundle was never replaced and remains at the captured identity" >&2
    elif validate_bundle "${INSTALL_BUNDLE}" "restored installed bundle"; then
        app_restored=1
        echo "installer: restored and verified prior bundle" >&2
    else
        echo "installer: ERROR - restored prior bundle could not be verified; transaction artifacts retained" >&2
        rollback_failed=1
    fi

    # Reinstall never mutates login state, so rollback restores only the bundle
    # and CLI identities before any prior process is relaunched.
    if ! restore_cli_state; then
        rollback_failed=1
    fi

    if [[ "${REINSTALL_APP_RESTART_CUSTODY}" -eq 1 \
        && "${PRIOR_APP_STOP_REQUESTED}" -eq 1 \
        && "${PRIOR_APP_STOPPED}" -eq 0 ]]; then
        if installed_app_is_running; then
            process_status=0
        else
            process_status=$?
        fi
        if [[ "${process_status}" -eq 1 ]]; then
            PRIOR_APP_STOPPED=1
        elif [[ "${process_status}" -ne 0 ]]; then
            echo "app: ERROR - rollback could not classify the interrupted stop state" >&2
            rollback_failed=1
        fi
    fi

    # Restore a captured live LaunchAgent through its exact target on every
    # rollback. Its kickstart and status/process proof do not depend on the
    # earliest process snapshot. Other mechanisms restart only when that
    # snapshot was live or the forward pre-exchange stop took restart custody.
    if [[ "${app_restored}" -eq 1 \
        && "${PRIOR_LOGIN_STATE}" == "enabled via LaunchAgent" ]]; then
        if ! restart_captured_launch_agent \
            "restored app" "${START_ORIGIN_ROLLBACK_RESTORATION}"; then
            rollback_failed=1
        fi
        if ! verify_restored_launch_agent_state; then
            rollback_failed=1
        fi
    elif [[ "${app_restored}" -eq 1 \
        && ( "${PRIOR_APP_WAS_RUNNING}" -eq 1 \
            || "${REINSTALL_APP_RESTART_CUSTODY}" -eq 1 ) \
        && "${PRIOR_APP_STOPPED}" -eq 1 ]] \
        && ! launch_and_verify_installed_app \
            "restored app" "${START_ORIGIN_ROLLBACK_RESTORATION}"; then
        rollback_failed=1
    fi

    if [[ "${rollback_failed}" -eq 0 ]]; then
        if ! remove_staging_bundle "failed staged replacement"; then
            rollback_failed=1
        else
            STAGING_BUNDLE=""
        fi
        if ! remove_support_paths; then
            rollback_failed=1
        fi
    fi
    if [[ "${rollback_failed}" -eq 0 ]]; then
        FINAL_STATE_PROVEN=1
    fi
    return "${rollback_failed}"
}

rollback_fresh_install() {
    local rollback_failed=0
    local compensation_failed=0
    local replacement_stopped=1

    if [[ -n "${APP_UNEXPECTED_DESTINATION_IDENTITY}" ]]; then
        rollback_unexpected_app_destination
        return $?
    fi
    if ! reconcile_app_state; then
        return 1
    fi

    if [[ "${FRESH_REPLACEMENT_INSTALLED}" -eq 1 ]]; then
        if ! stop_installed_app_for_rollback "failed replacement"; then
            replacement_stopped=0
            rollback_failed=1
        fi
        # A partially successful enable must be disabled and verified while the
        # failed new helper is still present. Only then may the new app vanish.
        if ! restore_fresh_login_state "${INSTALL_BUNDLE}"; then
            compensation_failed=1
            rollback_failed=1
        fi
        if ! restore_cli_state; then
            compensation_failed=1
            rollback_failed=1
        fi
        if [[ "${compensation_failed}" -eq 0 && "${replacement_stopped}" -eq 1 ]]; then
            if ! remove_transaction_path "${INSTALL_BUNDLE}" "failed fresh install"; then
                rollback_failed=1
            else
                FRESH_REPLACEMENT_INSTALLED=0
            fi
        else
            echo "installer: ERROR - failed new app retained until process stop, login, and CLI compensation can be verified" >&2
        fi
    else
        if ! restore_cli_state; then
            rollback_failed=1
        fi
    fi

    if [[ "${rollback_failed}" -eq 0 ]]; then
        if ! remove_staging_bundle "failed staged replacement"; then
            rollback_failed=1
        else
            STAGING_BUNDLE=""
        fi
        if ! remove_support_paths; then
            rollback_failed=1
        fi
    fi
    if [[ "${rollback_failed}" -eq 0 ]]; then
        if path_exists "${INSTALL_BUNDLE}"; then
            echo "installer: ERROR - failed fresh install still occupies ${INSTALL_BUNDLE}" >&2
            rollback_failed=1
        else
            FINAL_STATE_PROVEN=1
        fi
    fi
    return "${rollback_failed}"
}

rollback_transaction() {
    local rollback_failed=0

    echo "installer: rolling back incomplete install" >&2
    if [[ "${PRIOR_EXISTED}" -eq 1 ]]; then
        if ! rollback_reinstall; then
            rollback_failed=1
        fi
    else
        if ! rollback_fresh_install; then
            rollback_failed=1
        fi
    fi
    TRANSACTION_ACTIVE=0
    return "${rollback_failed}"
}

handle_exit() {
    local status="$?"
    local rollback_status=0
    local lock_status=0

    trap - EXIT
    trap '' HUP INT QUIT TERM
    set +e
    if [[ "${TRANSACTION_ACTIVE}" -eq 1 && "${FINAL_STATE_PROVEN}" -eq 0 ]]; then
        rollback_transaction
        rollback_status=$?
    fi
    release_installer_lock
    lock_status=$?
    cleanup_installer_lock_helper || true
    if [[ "${rollback_status}" -ne 0 ]]; then
        status=1
    fi
    case "${lock_status}" in
        0)
            ;;
        129|130|131|143)
            case "${status}" in
                129|130|131|143) ;;
                *) status="${lock_status}" ;;
            esac
            ;;
        *)
            status=1
            ;;
    esac
    exit "${status}"
}

handle_signal() {
    local status="$1"
    local name="$2"

    echo "installer: received ${name}; restoring the last proven install state" >&2
    exit "${status}"
}

post_commit_cleanup() {
    local path="$1"
    local description="$2"
    local expected_identity="${3:-}"
    local cleanup_status=0

    if [[ -n "${expected_identity}" ]]; then
        remove_staging_bundle "${description}" "${expected_identity}" || cleanup_status=$?
    else
        remove_transaction_path "${path}" "${description}" || cleanup_status=$?
    fi
    if [[ "${cleanup_status}" -ne 0 ]]; then
        echo "installer: WARNING - install is committed; ${description} was retained at ${path}" >&2
    fi
}

trap handle_exit EXIT
trap 'handle_signal 129 HUP' HUP
trap 'handle_signal 130 INT' INT
trap 'handle_signal 131 QUIT' QUIT
trap 'handle_signal 143 TERM' TERM

cd "${REPO_ROOT}"

INSTALL_PARENT="$(dirname "${INSTALL_BUNDLE}")"
mkdir -p "${INSTALL_PARENT}"
if ! build_installer_lock_helper; then
    exit 1
fi
# The EXIT trap is the only release path, so this lock spans every state
# snapshot, application/login/CLI mutation, rollback, and post-commit cleanup.
if ! acquire_installer_lock; then
    exit 1
fi
if [[ ! -d "${SOURCE_BUNDLE}" ]]; then
    echo "no built bundle; running build-app.sh"
    bash Scripts/build-app.sh
fi
case "${STOP_CHECK_ATTEMPTS}" in
    ""|*[!0-9]*|0)
        echo "installer: ERROR - stop check attempts must be a positive integer" >&2
        exit 1
        ;;
esac
case "${START_CHECK_ATTEMPTS}" in
    ""|*[!0-9]*|0)
        echo "installer: ERROR - start check attempts must be a positive integer" >&2
        exit 1
        ;;
esac
APP_PROCESS_PATTERN="^$(escape_extended_regex "${INSTALL_BUNDLE}/Contents/MacOS/Ticker")([[:space:]].*)?$"
if path_exists "${INSTALL_BUNDLE}"; then
    PRIOR_EXISTED=1
    PRIOR_BUNDLE_IDENTITY="$(path_identity "${INSTALL_BUNDLE}")"
fi
if ! capture_prior_app_state; then
    exit 1
fi
if [[ "${PRIOR_EXISTED}" -eq 0 && "${PRIOR_APP_WAS_RUNNING}" -eq 1 ]]; then
    echo "app: ERROR - an exact installed process is running but no prior bundle exists to restore" >&2
    exit 1
fi
if ! capture_cli_state; then
    exit 1
fi

if ! STAGING_BUNDLE="$(mktemp -d "${INSTALL_BUNDLE}.staging.XXXXXX")"; then
    echo "installer: ERROR - could not create staging bundle" >&2
    exit 1
fi
TRANSACTION_ACTIVE=1
# Keep the mktemp inode as cleanup custody for an incomplete copy. A successful
# copy may replace the root inode, so exchange classification is captured later.
if ! STAGING_CUSTODY_IDENTITY="$(path_identity "${STAGING_BUNDLE}")"; then
    echo "installer: ERROR - could not capture staging custody identity; retained at ${STAGING_BUNDLE}" >&2
    TRANSACTION_ACTIVE=0
    exit 1
fi

echo "staging ${SOURCE_BUNDLE} -> ${STAGING_BUNDLE}"
if ! "${COPY_COMMAND}" -R "${SOURCE_BUNDLE}/." "${STAGING_BUNDLE}/"; then
    echo "installer: ERROR - copy to staged replacement failed" >&2
    exit 1
fi
if ! STAGED_BUNDLE_IDENTITY="$(path_identity "${STAGING_BUNDLE}")"; then
    echo "installer: ERROR - could not capture final copied staging identity" >&2
    exit 1
fi
if ! validate_bundle "${STAGING_BUNDLE}" "staged replacement"; then
    exit 1
fi
echo "staged replacement verified"

if ! capture_prior_login_state; then
    exit 1
fi

if [[ "${PRIOR_EXISTED}" -eq 1 ]]; then
    if ! validate_exchange_pair "${INSTALL_BUNDLE}" "${STAGING_BUNDLE}" \
        "application replacement exchange"; then
        exit 1
    fi
else
    if ! validate_fresh_rename_pair; then
        exit 1
    fi
fi

if ! build_exchange_helper; then
    exit 1
fi
if [[ "${PRIOR_EXISTED}" -eq 1 ]] \
    && ! preflight_atomic_exchange_in_parent "${INSTALL_PARENT}" "application filesystem"; then
    exit 1
fi
if [[ "${CLI_PRIOR_EXISTED}" -eq 1 && "${CLI_PARENT_WRITABLE}" -eq 1 ]] \
    && ! preflight_atomic_exchange_in_parent "${CLI_PARENT}" "CLI filesystem"; then
    exit 1
fi

# The running app is stopped only after the replacement, state snapshots, path
# checks, helper build, and real filesystem exchange preflight have succeeded.
if [[ "${PRIOR_APP_WAS_RUNNING}" -eq 1 ]]; then
    if ! stop_installed_app \
        "running installed copy" "${STOP_PURPOSE_PRIOR_PROCESS}"; then
        exit 1
    fi
    PRIOR_APP_STOPPED=1
else
    if ! stop_installed_app \
        "installed copy before replacement" "${STOP_PURPOSE_PRIOR_PROCESS}"; then
        exit 1
    fi
fi

echo "installing staged replacement -> ${INSTALL_BUNDLE}"
APP_MUTATION_STARTED=1
if [[ "${PRIOR_EXISTED}" -eq 1 ]]; then
    current_identity="$(path_identity "${INSTALL_BUNDLE}")" || exit 1
    if [[ "${current_identity}" != "${PRIOR_BUNDLE_IDENTITY}" ]]; then
        APP_UNEXPECTED_DESTINATION_IDENTITY="${current_identity}"
        echo "installer: ERROR - installed bundle changed before the atomic exchange" >&2
        exit 1
    fi
    exchange_status=0
    if ! atomic_exchange "${INSTALL_BUNDLE}" "${STAGING_BUNDLE}"; then
        exchange_status=1
    fi
    if ! reconcile_app_state; then
        if recover_unexpected_app_exchange; then
            echo "installer: ERROR - installed bundle changed during the atomic exchange" >&2
        fi
        exit 1
    fi
    if [[ "${exchange_status}" -ne 0 || "${APP_EXCHANGED}" -ne 1 ]]; then
        echo "installer: ERROR - atomic replacement exchange failed" >&2
        exit 1
    fi
    echo "application replacement exchanged atomically"
else
    publish_status=0
    if ! atomic_publish_no_replace "${STAGING_BUNDLE}" "${INSTALL_BUNDLE}"; then
        publish_status=1
    fi
    if ! reconcile_app_state; then
        if record_unexpected_app_destination; then
            echo "installer: ERROR - install destination appeared; no-replace publication refused to overwrite it" >&2
        fi
        exit 1
    fi
    if [[ "${publish_status}" -ne 0 || "${FRESH_REPLACEMENT_INSTALLED}" -ne 1 ]]; then
        echo "installer: ERROR - atomic fresh-install no-replace publication failed" >&2
        exit 1
    fi
fi

if ! validate_bundle "${INSTALL_BUNDLE}" "installed replacement"; then
    exit 1
fi
echo "installed replacement verified"

# Each replacement start is immediately preceded by an exact installed-path
# stop and absence proof. A process found here predates installer activation,
# so a reinstall takes rollback restart custody before it is terminated.
if [[ "${PRIOR_EXISTED}" -eq 1 \
    && "${PRIOR_LOGIN_STATE}" == "enabled via LaunchAgent" ]]; then
    if ! stop_installed_app \
        "installed copy before replacement LaunchAgent start" \
        "${STOP_PURPOSE_PRIOR_PROCESS}"; then
        exit 1
    fi
    if ! restart_captured_launch_agent \
        "replacement" "${START_ORIGIN_INSTALLER_REPLACEMENT}"; then
        exit 1
    fi
    REPLACEMENT_KICKSTART_VERIFIED=1
fi

# Fresh installs establish and verify a login target. Reinstalls preserve the
# captured state and verify it through the replacement at its installed path.
if [[ "${PRIOR_EXISTED}" -eq 1 ]]; then
    if ! verify_reinstalled_login_state; then
        exit 1
    fi
else
    if ! enable_and_verify_fresh_login_item "${INSTALL_BUNDLE}"; then
        exit 1
    fi
fi

# The CLI link remains inside the transaction. A prior link/path is held at the
# sibling staging path until this link and its executable target are verified.
if ! install_cli_link; then
    exit 1
fi

# Launch remains part of the transaction. An active LaunchAgent replacement was
# already started and verified by its exact kickstart. Every other path keeps
# the common open-and-verify behavior.
if [[ "${REPLACEMENT_KICKSTART_VERIFIED}" -eq 0 ]]; then
    if ! stop_installed_app \
        "installed copy before replacement launch" \
        "${STOP_PURPOSE_PRIOR_PROCESS}"; then
        exit 1
    fi
    if ! launch_and_verify_installed_app \
        "replacement" "${START_ORIGIN_INSTALLER_REPLACEMENT}"; then
        exit 1
    fi
fi

# CLI publication and replacement process start can race ordinary login-item
# transitions. Re-read the exact installed helper for both fresh installs and
# reinstalls after CLI publication, require equality with the early proof, and
# retain only this read for output.
FINAL_LOGIN_STATE=""
if ! verify_final_installed_login_state; then
    exit 1
fi
if [[ -z "${FINAL_LOGIN_STATE}" ]]; then
    echo "login item: ERROR - no final login state was proven before commit" >&2
    exit 1
fi

# All fallible install steps are now proven. Cleanup cannot invalidate or roll
# back this committed state; a cleanup failure only retains an artifact.
FINAL_STATE_PROVEN=1
TRANSACTION_ACTIVE=0

post_commit_cleanup "${STAGING_BUNDLE}" "displaced prior bundle" \
    "${PRIOR_BUNDLE_IDENTITY:-${STAGED_BUNDLE_IDENTITY}}"
post_commit_cleanup "${CLI_STAGED_PATH}" "displaced prior CLI path"
post_commit_cleanup "${EXCHANGE_HELPER_DIRECTORY}" "atomic-exchange helper directory"

echo
if [[ "${FINAL_LOGIN_STATE}" == "disabled" && "${PRIOR_EXISTED}" -eq 1 ]]; then
    echo "done. Ticker remains disabled at login."
elif [[ "${FINAL_LOGIN_STATE}" == "${REQUIRES_APPROVAL_LOGIN_STATE}" ]]; then
    echo "done. Approval remains required — approve Ticker in System Settings › General › Login Items."
else
    echo "done. Ticker will open automatically at login."
fi
