#ifndef PORT_SOCKET_SUPPORT_H
#define PORT_SOCKET_SUPPORT_H
#include <sys/types.h>
int stm_create_receiver(const char *path);
int stm_receive_listener(int receiver, uid_t expected_sender);
int stm_send_listener(int connection, int listener);
int stm_create_listener(void);
int stm_authorize_listener(int receiver, int listener, uid_t expected_helper);
int stm_cancel_authorization(const char *path);
int stm_bind_for_app(const char *path, uid_t recipient);
#endif
