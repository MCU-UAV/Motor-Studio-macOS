#ifndef MOTOR_SERIAL_H
#define MOTOR_SERIAL_H
#include <stddef.h>
#include <stdint.h>
int motor_serial_open(const char *path, int baud, char *error, size_t capacity);
int motor_serial_read(int fd, uint8_t *bytes, size_t capacity, int timeout_ms);
int motor_serial_write(int fd, const uint8_t *bytes, size_t count, int timeout_ms);
int motor_serial_flush_input(int fd);
int motor_serial_set_baud(int fd, int baud);
void motor_serial_close(int fd);
#endif
