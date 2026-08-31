#include "PortSocketSupport.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int unix_address(const char *path, struct sockaddr_un *address) {
    if (strlen(path) >= sizeof(address->sun_path)) { errno = ENAMETOOLONG; return -1; }
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    address->sun_len = sizeof(*address);
    strlcpy(address->sun_path, path, sizeof(address->sun_path));
    return 0;
}

int stm_create_receiver(const char *path) {
    struct sockaddr_un address;
    if (unix_address(path, &address) < 0) return -1;
    int receiver = socket(AF_UNIX, SOCK_STREAM, 0);
    if (receiver < 0) return -1;
    if (bind(receiver, (struct sockaddr *)&address, sizeof(address)) < 0 ||
        chmod(path, 0600) < 0 || listen(receiver, 1) < 0) {
        int saved = errno; close(receiver); errno = saved; return -1;
    }
    fcntl(receiver, F_SETFD, FD_CLOEXEC);
    return receiver;
}

int stm_send_listener(int connection, int listener) {
    char byte = 'L';
    struct iovec vector = { .iov_base = &byte, .iov_len = 1 };
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof(control));
    struct msghdr message = { .msg_iov = &vector, .msg_iovlen = 1,
                             .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &listener, sizeof(listener));
    return sendmsg(connection, &message, 0) == 1 ? 0 : -1;
}

static int accept_peer(int receiver, uid_t expected_sender, int timeout_ms) {
    struct pollfd ready = { .fd = receiver, .events = POLLIN };
    if (poll(&ready, 1, timeout_ms) <= 0) { errno = ETIMEDOUT; return -1; }
    int connection = accept(receiver, NULL, NULL);
    if (connection < 0) return -1;
    uid_t user; gid_t group;
    if (getpeereid(connection, &user, &group) < 0 || user != expected_sender) {
        close(connection); errno = EPERM; return -1;
    }
    struct timeval timeout = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int yes = 1;
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    return connection;
}

static int receive_descriptor(int connection) {
    char byte = 0;
    struct iovec vector = { .iov_base = &byte, .iov_len = 1 };
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof(control));
    struct msghdr message = { .msg_iov = &vector, .msg_iovlen = 1,
                             .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    ssize_t count = recvmsg(connection, &message, 0);
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (count != 1 || !header || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
        header->cmsg_len != CMSG_LEN(sizeof(int))) { errno = EPROTO; return -1; }
    int listener;
    memcpy(&listener, CMSG_DATA(header), sizeof(listener));
    if (byte != 'L' || (message.msg_flags & MSG_CTRUNC)) { close(listener); errno = EPROTO; return -1; }
    fcntl(listener, F_SETFD, FD_CLOEXEC);
    return listener;
}

static int validate_listener(int listener, uid_t expected_sender) {
    struct sockaddr_in address;
    socklen_t size = sizeof(address);
    int type = 0;
    socklen_t option_size = sizeof(type);
    if (getsockname(listener, (struct sockaddr *)&address, &size) < 0 || address.sin_family != AF_INET ||
        address.sin_addr.s_addr != htonl(INADDR_LOOPBACK) ||
        getsockopt(listener, SOL_SOCKET, SO_TYPE, &type, &option_size) < 0 || type != SOCK_STREAM) {
        errno = EPROTO; return -1;
    }
    // Production descriptors must be port 80; unprivileged fixture senders use an ephemeral port.
    if (expected_sender == 0 && ntohs(address.sin_port) != 80) { errno = EPROTO; return -1; }
    // SO_ACCEPTCONN is not queryable on every macOS version. Re-listening is
    // safe for an existing listener and rejects connected/non-listenable sockets.
    return listen(listener, SOMAXCONN);
}

int stm_receive_listener(int receiver, uid_t expected_sender) {
    int connection = accept_peer(receiver, expected_sender, 5000);
    if (connection < 0) return -1;
    int listener = receive_descriptor(connection);
    int saved = errno;
    close(connection);
    if (listener < 0) { errno = saved; return -1; }
    if (validate_listener(listener, expected_sender) < 0) {
        saved = errno; close(listener); errno = saved; return -1;
    }
    return listener;
}

int stm_create_listener(void) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    int yes = 1;
    if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)) < 0 ||
        fcntl(listener, F_SETFD, FD_CLOEXEC) < 0) {
        int saved = errno; close(listener); errno = saved; return -1;
    }
    return listener;
}

int stm_authorize_listener(int receiver, int listener, uid_t expected_helper) {
    // Keep the socket creator alive: macOS can reset connections if the process
    // that created a listening socket exits, even after SCM_RIGHTS transfers it.
    // A connection from the app itself wakes this wait if authorization is
    // cancelled; accept_peer rejects it because it is not the root helper.
    int connection = accept_peer(receiver, expected_helper, -1);
    if (connection < 0) return -1;
    int result = stm_send_listener(connection, listener);
    if (result == 0) {
        char reply = 0;
        if (recv(connection, &reply, 1, 0) != 1 || reply != 'B') { errno = EPROTO; result = -1; }
    }
    int saved = errno;
    close(connection);
    if (result < 0) { errno = saved; return -1; }
    return validate_listener(listener, expected_helper);
}

int stm_cancel_authorization(const char *path) {
    struct sockaddr_un address;
    if (unix_address(path, &address) < 0) return -1;
    int connection = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connection < 0) return -1;
    struct timeval timeout = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int result = connect(connection, (struct sockaddr *)&address, sizeof(address));
    int saved = errno;
    close(connection);
    errno = saved;
    return result;
}

int stm_bind_for_app(const char *path, uid_t recipient) {
    if (geteuid() != 0 || recipient == 0) { errno = EPERM; return -1; }
    struct stat info;
    if (lstat(path, &info) < 0 || !S_ISSOCK(info.st_mode) || info.st_uid != recipient) { errno = EPERM; return -1; }
    struct sockaddr_un endpoint;
    if (unix_address(path, &endpoint) < 0) return -1;
    int connection = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connection < 0) return -1;
    if (connect(connection, (struct sockaddr *)&endpoint, sizeof(endpoint)) < 0) {
        int saved = errno; close(connection); errno = saved; return -1;
    }
    uid_t user; gid_t group;
    if (getpeereid(connection, &user, &group) < 0 || user != recipient) {
        close(connection); errno = EPERM; return -1;
    }
    struct timeval timeout = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int yes = 1;
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    int listener = receive_descriptor(connection);
    if (listener < 0) { int saved = errno; close(connection); errno = saved; return -1; }
    // Accept only an unbound IPv4 TCP socket. The only authorized destination
    // is fixed below; the app cannot request a public interface or another port.
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    socklen_t size = sizeof(address);
    int type = 0;
    socklen_t type_size = sizeof(type);
    if (getsockname(listener, (struct sockaddr *)&address, &size) < 0 ||
        address.sin_family != AF_INET || address.sin_port != 0 || address.sin_addr.s_addr != htonl(INADDR_ANY) ||
        getsockopt(listener, SOL_SOCKET, SO_TYPE, &type, &type_size) < 0 || type != SOCK_STREAM) {
        close(listener); close(connection); errno = EPROTO; return -1;
    }
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(80);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int result = bind(listener, (struct sockaddr *)&address, sizeof(address));
    if (result == 0) result = listen(listener, SOMAXCONN);
    if (result == 0 && send(connection, "B", 1, 0) != 1) result = -1;
    int saved = errno;
    close(listener);
    close(connection);
    errno = saved;
    return result;
}

#ifdef STM_BINDER_MAIN
int main(int argc, char **argv) {
    if (argc != 3) { fputs("Expected a private socket path and recipient UID.\n", stderr); return 1; }
    char *end;
    errno = 0;
    unsigned long uid = strtoul(argv[2], &end, 10);
    if (errno || *end || uid == 0 || uid > UINT_MAX) { fputs("Invalid recipient UID.\n", stderr); return 1; }
    if (stm_bind_for_app(argv[1], (uid_t)uid) < 0) { perror("Cannot authorize loopback HTTP port 80"); return 1; }
    return 0;
}
#endif
