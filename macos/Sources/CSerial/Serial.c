#include "CSerial.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <IOKit/serial/ioss.h>
#endif

int motor_serial_open(const char *path, int baud, char *error, size_t capacity) {
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) goto fail;
    if (ioctl(fd, TIOCEXCL) < 0) goto fail;
    struct termios settings;
    if (tcgetattr(fd, &settings) < 0) goto fail;
    cfmakeraw(&settings);
    settings.c_cflag |= CLOCAL | CREAD;
    settings.c_cflag &= ~(PARENB | CSTOPB | CSIZE);
#ifdef CRTSCTS
    settings.c_cflag &= ~CRTSCTS;
#endif
    settings.c_cflag |= CS8;
    settings.c_cc[VMIN] = 0; settings.c_cc[VTIME] = 0;
    cfsetispeed(&settings, B9600); cfsetospeed(&settings, B9600);
    if (tcsetattr(fd, TCSANOW, &settings) < 0) goto fail;
#ifdef __APPLE__
    // Standard termios constants cannot express 6 Mbps on Darwin.
    speed_t custom = (speed_t)baud;
    if (ioctl(fd, IOSSIOSPEED, &custom) < 0) goto fail;
#else
    // Linux builds are for protocol tests; never pretend 9600 is 6 Mbps.
    (void)baud;
    errno = ENOTSUP; goto fail;
#endif
    tcflush(fd, TCIOFLUSH);
    return fd;
fail:
    snprintf(error, capacity, "%s", strerror(errno));
    if (fd >= 0) close(fd);
    return -1;
}

static int wait_fd(int fd, short events, int timeout_ms) {
    struct pollfd p = {fd, events, 0};
    int result = poll(&p, 1, timeout_ms);
    if (result < 0) return errno == EINTR ? 0 : -1;
    if (result == 0) return 0;
    if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) { errno = EIO; return -1; }
    return (p.revents & events) ? 1 : 0;
}
int motor_serial_read(int fd, uint8_t *bytes, size_t capacity, int timeout_ms) {
    int ready = wait_fd(fd, POLLIN, timeout_ms);
    if (ready <= 0) return ready;
    ssize_t n = read(fd, bytes, capacity);
    if (n < 0 && (errno == EAGAIN || errno == EINTR)) return 0;
    return (int)n;
}
int motor_serial_write(int fd, const uint8_t *bytes, size_t count, int timeout_ms) {
    // Each control packet is 20 bytes; a partial write is an explicit failure.
    int ready = wait_fd(fd, POLLOUT, timeout_ms);
    if (ready <= 0) return -1;
    ssize_t n = write(fd, bytes, count);
    return n == (ssize_t)count ? (int)n : -1;
}
int motor_serial_flush_input(int fd) { return tcflush(fd, TCIFLUSH); }
int motor_serial_set_baud(int fd, int baud) {
#ifdef __APPLE__
    speed_t custom = (speed_t)baud;
    return ioctl(fd, IOSSIOSPEED, &custom);
#else
    (void)fd; (void)baud; errno = ENOTSUP; return -1;
#endif
}
void motor_serial_close(int fd) { if (fd >= 0) close(fd); }
