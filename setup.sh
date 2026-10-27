
#!/bin/bash

set -e

REGNO="IT23599918"
LAST4="9918"
PORT="15918"
NID="5999"

SERVER_FILE="server_${LAST4}.c"
CLIENT_FILE="client_${LAST4}.c"
MAKEFILE="Makefile_${LAST4}"
LOGFILE="netmsg_${REGNO}.log"

echo "=============================================="
echo " IE3010 NetMessenger Setup"
echo " Registration : $REGNO"
echo " Port         : $PORT"
echo " NID          : $NID"
echo "=============================================="

mkdir -p storage/$REGNO
mkdir -p test_files
mkdir -p docs
mkdir -p backups

# ------------------------------------------------
# SERVER
# ------------------------------------------------

cat > "$SERVER_FILE" <<'EOF'
#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define PORT 15918
#define NID "NID:5999"

#define MAX_CLIENTS 64
#define MAX_ROOMS 32
#define MAX_ROOM_MEMBERS 64

#define USERNAME_LEN 64
#define ROOM_LEN 64
#define LINE_SIZE 4096
#define FILE_BUFFER 8192

#define MAX_FILE_SIZE (10LL * 1024LL * 1024LL)

#define LOG_FILE "netmsg_IT23599918.log"
#define STORAGE_ROOT "./storage/IT23599918"

typedef struct {
    int fd;
    int active;
    int registered;
    char username[USERNAME_LEN];
} Client;

typedef struct {
    int active;
    char name[ROOM_LEN];
    char members[MAX_ROOM_MEMBERS][USERNAME_LEN];
    int member_count;
} Room;

static Client clients[MAX_CLIENTS];
static Room rooms[MAX_ROOMS];

static pthread_mutex_t state_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t send_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t log_mutex = PTHREAD_MUTEX_INITIALIZER;

static void log_event(const char *format, ...)
{
    FILE *fp;
    time_t now;
    struct tm tm_now;
    char timestamp[64];

    pthread_mutex_lock(&log_mutex);

    fp = fopen(LOG_FILE, "a");

    if (fp != NULL) {
        now = time(NULL);
        localtime_r(&now, &tm_now);

        strftime(
            timestamp,
            sizeof(timestamp),
            "%Y-%m-%d %H:%M:%S",
            &tm_now
        );

        fprintf(fp, "[%s] ", timestamp);

        va_list args;

        va_start(args, format);
        vfprintf(fp, format, args);
        va_end(args);

        fprintf(fp, "\n");

        fclose(fp);
    }

    pthread_mutex_unlock(&log_mutex);
}

static ssize_t send_all(int fd, const void *buffer, size_t length)
{
    const char *data = buffer;
    size_t total = 0;

    while (total < length) {
        ssize_t n = send(
            fd,
            data + total,
            length - total,
            0
        );

        if (n < 0) {
            if (errno == EINTR)
                continue;

            return -1;
        }

        if (n == 0)
            return -1;

        total += (size_t)n;
    }

    return (ssize_t)total;
}

static void send_text(int fd, const char *text)
{
    pthread_mutex_lock(&send_mutex);

    send_all(
        fd,
        text,
        strlen(text)
    );

    pthread_mutex_unlock(&send_mutex);
}

static void send_response(int fd, const char *response)
{
    char output[LINE_SIZE];

    snprintf(
        output,
        sizeof(output),
        "%s %s\n",
        response,
        NID
    );

    send_text(fd, output);
}

static ssize_t recv_line(int fd, char *buffer, size_t size)
{
    size_t pos = 0;

    while (pos < size - 1) {
        char c;

        ssize_t n = recv(
            fd,
            &c,
            1,
            0
        );

        if (n == 0) {
            if (pos == 0)
                return 0;

            break;
        }

        if (n < 0) {
            if (errno == EINTR)
                continue;

            return -1;
        }

        if (c == '\n')
            break;

        if (c != '\r')
            buffer[pos++] = c;
    }

    buffer[pos] = '\0';

    return (ssize_t)pos;
}

static int find_user_locked(const char *username)
{
    int i;

    for (i = 0; i < MAX_CLIENTS; i++) {
        if (
            clients[i].active &&
            clients[i].registered &&
            strcmp(clients[i].username, username) == 0
        ) {
            return i;
        }
    }

    return -1;
}

static int find_room_locked(const char *name)
{
    int i;

    for (i = 0; i < MAX_ROOMS; i++) {
        if (
            rooms[i].active &&
            strcmp(rooms[i].name, name) == 0
        ) {
            return i;
        }
    }

    return -1;
}

static int create_room_locked(const char *name)
{
    int i;

    for (i = 0; i < MAX_ROOMS; i++) {
        if (!rooms[i].active) {
            rooms[i].active = 1;

            strncpy(
                rooms[i].name,
                name,
                ROOM_LEN - 1
            );

            rooms[i].name[ROOM_LEN - 1] = '\0';
            rooms[i].member_count = 0;

            return i;
        }
    }

    return -1;
}

static int room_has_member(Room *room, const char *username)
{
    int i;

    for (i = 0; i < room->member_count; i++) {
        if (
            strcmp(
                room->members[i],
                username
            ) == 0
        ) {
            return 1;
        }
    }

    return 0;
}

static void room_add_member(Room *room, const char *username)
{
    if (room_has_member(room, username))
        return;

    if (room->member_count >= MAX_ROOM_MEMBERS)
        return;

    strncpy(
        room->members[room->member_count],
        username,
        USERNAME_LEN - 1
    );

    room->members[room->member_count][USERNAME_LEN - 1] = '\0';

    room->member_count++;
}

static void room_remove_member(Room *room, const char *username)
{
    int i;

    for (i = 0; i < room->member_count; i++) {
        if (
            strcmp(
                room->members[i],
                username
            ) == 0
        ) {
            int j;

            for (
                j = i;
                j < room->member_count - 1;
                j++
            ) {
                strcpy(
                    room->members[j],
                    room->members[j + 1]
                );
            }

            room->member_count--;

            break;
        }
    }

    if (room->member_count == 0) {
        room->active = 0;
    }
}

static void remove_user_rooms(const char *username)
{
    int i;

    for (i = 0; i < MAX_ROOMS; i++) {
        if (rooms[i].active) {
            room_remove_member(
                &rooms[i],
                username
            );
        }
    }
}

static void broadcast_except(int excluded_fd, const char *message)
{
    int fds[MAX_CLIENTS];
    int count = 0;
    int i;

    pthread_mutex_lock(&state_mutex);

    for (i = 0; i < MAX_CLIENTS; i++) {
        if (
            clients[i].active &&
            clients[i].registered &&
            clients[i].fd != excluded_fd
        ) {
            fds[count++] = clients[i].fd;
        }
    }

    pthread_mutex_unlock(&state_mutex);

    for (i = 0; i < count; i++) {
        send_text(
            fds[i],
            message
        );
    }
}

static void handle_register(int index, const char *username)
{
    int fd = clients[index].fd;

    if (
        username == NULL ||
        username[0] == '\0'
    ) {
        send_response(
            fd,
            "ERR 005 INVALID_USERNAME"
        );

        return;
    }

    pthread_mutex_lock(&state_mutex);

    if (find_user_locked(username) >= 0) {
        pthread_mutex_unlock(&state_mutex);

        send_response(
            fd,
            "ERR 001 USERNAME_TAKEN"
        );

        return;
    }

    strncpy(
        clients[index].username,
        username,
        USERNAME_LEN - 1
    );

    clients[index].username[USERNAME_LEN - 1] = '\0';

    clients[index].registered = 1;

    pthread_mutex_unlock(&state_mutex);

    {
        char response[LINE_SIZE];

        snprintf(
            response,
            sizeof(response),
            "OK REGISTERED %s",
            username
        );

        send_response(fd, response);
    }

    {
        char notification[LINE_SIZE];

        snprintf(
            notification,
            sizeof(notification),
            "MSG BCAST SERVER %s joined\n",
            username
        );

        broadcast_except(
            fd,
            notification
        );
    }

    log_event(
        "REGISTER user=%s",
        username
    );
}

static void handle_list(int fd)
{
    char response[LINE_SIZE] = "OK USERS ";
    int first = 1;
    int i;

    pthread_mutex_lock(&state_mutex);

    for (i = 0; i < MAX_CLIENTS; i++) {
        if (
            clients[i].active &&
            clients[i].registered
        ) {
            if (!first)
                strncat(
                    response,
                    ",",
                    sizeof(response) - strlen(response) - 1
                );

            strncat(
                response,
                clients[i].username,
                sizeof(response) - strlen(response) - 1
            );

            first = 0;
        }
    }

    pthread_mutex_unlock(&state_mutex);

    send_response(fd, response);
}

static void handle_bcast(
    int fd,
    const char *sender,
    const char *message
)
{
    char output[LINE_SIZE];

    snprintf(
        output,
        sizeof(output),
        "MSG BCAST %s %s\n",
        sender,
        message
    );

    broadcast_except(
        fd,
        output
    );

    send_response(
        fd,
        "OK SENT"
    );

    log_event(
        "BCAST sender=%s message=%s",
        sender,
        message
    );
}

static void handle_private(
    int fd,
    const char *sender,
    char *args
)
{
    char *space = strchr(args, ' ');

    if (space == NULL) {
        send_response(
            fd,
            "ERR 005 INVALID_COMMAND"
        );

        return;
    }

    *space = '\0';

    char *target = args;
    char *message = space + 1;

    pthread_mutex_lock(&state_mutex);

    int index = find_user_locked(target);

    if (index < 0) {
        pthread_mutex_unlock(&state_mutex);

        send_response(
            fd,
            "ERR 002 USER_NOT_FOUND"
        );

        return;
    }

    int target_fd = clients[index].fd;

    pthread_mutex_unlock(&state_mutex);

    char output[LINE_SIZE];

    snprintf(
        output,
        sizeof(output),
        "MSG PRIV %s %s\n",
        sender,
        message
    );

    send_text(
        target_fd,
        output
    );

    send_response(
        fd,
        "OK SENT"
    );

    log_event(
        "PMSG sender=%s target=%s message=%s",
        sender,
        target,
        message
    );
}

static void handle_join(
    int fd,
    const char *username,
    const char *room
)
{
    pthread_mutex_lock(&state_mutex);

    int index = find_room_locked(room);

    if (index < 0)
        index = create_room_locked(room);

    if (index < 0) {
        pthread_mutex_unlock(&state_mutex);

        send_response(
            fd,
            "ERR 007 ROOM_LIMIT_REACHED"
        );

        return;
    }

    room_add_member(
        &rooms[index],
        username
    );

    pthread_mutex_unlock(&state_mutex);

    char response[LINE_SIZE];

    snprintf(
        response,
        sizeof(response),
        "OK JOINED %s",
        room
    );

    send_response(
        fd,
        response
    );

    log_event(
        "JOIN user=%s room=%s",
        username,
        room
    );
}

static void handle_rooms(int fd)
{
    char response[LINE_SIZE] = "OK ROOMS ";
    int first = 1;
    int i;

    pthread_mutex_lock(&state_mutex);

    for (i = 0; i < MAX_ROOMS; i++) {
        if (rooms[i].active) {
            if (!first)
                strncat(
                    response,
                    ",",
                    sizeof(response) - strlen(response) - 1
                );

            strncat(
                response,
                rooms[i].name,
                sizeof(response) - strlen(response) - 1
            );

            first = 0;
        }
    }

    pthread_mutex_unlock(&state_mutex);

    send_response(
        fd,
        response
    );
}

static void handle_leave(
    int fd,
    const char *username,
    const char *room
)
{
    pthread_mutex_lock(&state_mutex);

    int index = find_room_locked(room);

    if (index < 0) {
        pthread_mutex_unlock(&state_mutex);

        send_response(
            fd,
            "ERR 003 ROOM_NOT_FOUND"
        );

        return;
    }

    room_remove_member(
        &rooms[index],
        username
    );

    pthread_mutex_unlock(&state_mutex);

    char response[LINE_SIZE];

    snprintf(
        response,
        sizeof(response),
        "OK LEFT %s",
        room
    );

    send_response(
        fd,
        response
    );
}

static void handle_rmsg(
    int fd,
    const char *sender,
    char *args
)
{
    char *space = strchr(args, ' ');

    if (space == NULL) {
        send_response(
            fd,
            "ERR 005 INVALID_COMMAND"
        );

        return;
    }

    *space = '\0';

    char *room = args;
    char *message = space + 1;

    int recipients[MAX_ROOM_MEMBERS];
    int recipient_count = 0;

    pthread_mutex_lock(&state_mutex);

    int room_index = find_room_locked(room);

    if (room_index < 0) {
        pthread_mutex_unlock(&state_mutex);

        send_response(
            fd,
            "ERR 003 ROOM_NOT_FOUND"
        );

        return;
    }

    if (
        !room_has_member(
            &rooms[room_index],
            sender
        )
    ) {
        pthread_mutex_unlock(&state_mutex);

        send_response(
            fd,
            "ERR 009 NOT_IN_ROOM"
        );

        return;
    }

    int i;

    for (
        i = 0;
        i < rooms[room_index].member_count;
        i++
    ) {
        int ci = find_user_locked(
            rooms[room_index].members[i]
        );

        if (ci >= 0)
            recipients[recipient_count++] =
                clients[ci].fd;
    }

    pthread_mutex_unlock(&state_mutex);

    char output[LINE_SIZE];

    snprintf(
        output,
        sizeof(output),
        "MSG ROOM %s %s %s\n",
        room,
        sender,
        message
    );

    for (i = 0; i < recipient_count; i++) {
        send_text(
            recipients[i],
            output
        );
    }

    send_response(
        fd,
        "OK SENT"
    );

    log_event(
        "RMSG sender=%s room=%s message=%s",
        sender,
        room,
        message
    );
}

static void disconnect_client(int index)
{
    int fd;
    int registered;

    char username[USERNAME_LEN];

    pthread_mutex_lock(&state_mutex);

    fd = clients[index].fd;

    registered =
        clients[index].registered;

    strncpy(
        username,
        clients[index].username,
        sizeof(username) - 1
    );

    username[sizeof(username) - 1] = '\0';

    if (registered)
        remove_user_rooms(username);

    clients[index].active = 0;
    clients[index].registered = 0;
    clients[index].fd = -1;

    pthread_mutex_unlock(&state_mutex);

    close(fd);

    if (registered) {
        char output[LINE_SIZE];

        snprintf(
            output,
            sizeof(output),
            "MSG BCAST SERVER %s left\n",
            username
        );

        broadcast_except(
            -1,
            output
        );

        log_event(
            "DISCONNECT user=%s",
            username
        );
    }
}

static void *client_thread(void *arg)
{
    int index = *(int *)arg;

    free(arg);

    int fd = clients[index].fd;

    char line[LINE_SIZE];

    while (1) {
        ssize_t n = recv_line(
            fd,
            line,
            sizeof(line)
        );

        if (n <= 0)
            break;

        if (
            strncmp(
                line,
                "REGISTER ",
                9
            ) == 0
        ) {
            handle_register(
                index,
                line + 9
            );

            continue;
        }

        pthread_mutex_lock(&state_mutex);

        int registered =
            clients[index].registered;

        char username[USERNAME_LEN];

        strncpy(
            username,
            clients[index].username,
            sizeof(username) - 1
        );

        username[sizeof(username) - 1] = '\0';

        pthread_mutex_unlock(&state_mutex);

        if (!registered) {
            send_response(
                fd,
                "ERR 012 REGISTER_REQUIRED"
            );

            continue;
        }

        if (strcmp(line, "LIST") == 0)
            handle_list(fd);

        else if (
            strncmp(
                line,
                "BCAST ",
                6
            ) == 0
        )
            handle_bcast(
                fd,
                username,
                line + 6
            );

        else if (
            strncmp(
                line,
                "PMSG ",
                5
            ) == 0
        )
            handle_private(
                fd,
                username,
                line + 5
            );

        else if (
            strncmp(
                line,
                "JOIN ",
                5
            ) == 0
        )
            handle_join(
                fd,
                username,
                line + 5
            );

        else if (
            strncmp(
                line,
                "LEAVE ",
                6
            ) == 0
        )
            handle_leave(
                fd,
                username,
                line + 6
            );

        else if (strcmp(line, "ROOMS") == 0)
            handle_rooms(fd);

        else if (
            strncmp(
                line,
                "RMSG ",
                5
            ) == 0
        )
            handle_rmsg(
                fd,
                username,
                line + 5
            );

        else if (strcmp(line, "QUIT") == 0) {
            send_response(
                fd,
                "OK BYE"
            );

            break;
        }

        else
            send_response(
                fd,
                "ERR 005 INVALID_COMMAND"
            );
    }

    disconnect_client(index);

    return NULL;
}

int main(void)
{
    signal(
        SIGPIPE,
        SIG_IGN
    );

    int i;

    for (i = 0; i < MAX_CLIENTS; i++) {
        clients[i].fd = -1;
    }

    int server_fd = socket(
        AF_INET,
        SOCK_STREAM,
        0
    );

    if (server_fd < 0) {
        perror("socket");
        return EXIT_FAILURE;
    }

    int option = 1;

    setsockopt(
        server_fd,
        SOL_SOCKET,
        SO_REUSEADDR,
        &option,
        sizeof(option)
    );

    struct sockaddr_in address;

    memset(
        &address,
        0,
        sizeof(address)
    );

    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(PORT);

    if (
        bind(
            server_fd,
            (struct sockaddr *)&address,
            sizeof(address)
        ) < 0
    ) {
        perror("bind");

        close(server_fd);

        return EXIT_FAILURE;
    }

    if (
        listen(
            server_fd,
            MAX_CLIENTS
        ) < 0
    ) {
        perror("listen");

        close(server_fd);

        return EXIT_FAILURE;
    }

    printf("============================================\n");
    printf(" NetMessenger Server\n");
    printf(" Registration : IT23599918\n");
    printf(" Port         : %d\n", PORT);
    printf(" Node ID      : %s\n", NID);
    printf(" Log          : %s\n", LOG_FILE);
    printf(" Storage      : %s\n", STORAGE_ROOT);
    printf("============================================\n");

    printf(
        "Server listening on port %d...\n",
        PORT
    );

    log_event(
        "SERVER START port=%d",
        PORT
    );

    while (1) {
        struct sockaddr_in client_address;

        socklen_t length =
            sizeof(client_address);

        int client_fd = accept(
            server_fd,
            (struct sockaddr *)&client_address,
            &length
        );

        if (client_fd < 0)
            continue;

        int slot = -1;

        pthread_mutex_lock(&state_mutex);

        for (i = 0; i < MAX_CLIENTS; i++) {
            if (!clients[i].active) {
                slot = i;

                clients[i].active = 1;
                clients[i].registered = 0;
                clients[i].fd = client_fd;
                clients[i].username[0] = '\0';

                break;
            }
        }

        pthread_mutex_unlock(&state_mutex);

        if (slot < 0) {
            close(client_fd);
            continue;
        }

        printf(
            "New client connected from %s\n",
            inet_ntoa(client_address.sin_addr)
        );

        log_event(
            "CONNECTION from=%s",
            inet_ntoa(client_address.sin_addr)
        );

        pthread_t thread;

        int *index = malloc(sizeof(int));

        if (index == NULL) {
            close(client_fd);
            continue;
        }

        *index = slot;

        pthread_create(
            &thread,
            NULL,
            client_thread,
            index
        );

        pthread_detach(thread);
    }

    close(server_fd);

    return EXIT_SUCCESS;
}
EOF

# ------------------------------------------------
# CLIENT
# ------------------------------------------------

cat > "$CLIENT_FILE" <<'EOF'
#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define SERVER_PORT 15918
#define LINE_SIZE 4096

static int socket_fd;
static volatile int running = 1;

static ssize_t send_all(
    int fd,
    const void *buffer,
    size_t length
)
{
    const char *data = buffer;

    size_t total = 0;

    while (total < length) {
        ssize_t n = send(
            fd,
            data + total,
            length - total,
            0
        );

        if (n <= 0)
            return -1;

        total += (size_t)n;
    }

    return (ssize_t)total;
}

static ssize_t recv_line(
    int fd,
    char *buffer,
    size_t size
)
{
    size_t pos = 0;

    while (pos < size - 1) {
        char c;

        ssize_t n = recv(
            fd,
            &c,
            1,
            0
        );

        if (n <= 0)
            return n;

        if (c == '\n')
            break;

        if (c != '\r')
            buffer[pos++] = c;
    }

    buffer[pos] = '\0';

    return (ssize_t)pos;
}

static void *receiver_thread(void *arg)
{
    (void)arg;

    char line[LINE_SIZE];

    while (running) {
        ssize_t n = recv_line(
            socket_fd,
            line,
            sizeof(line)
        );

        if (n <= 0)
            break;

        printf(
            "\n%s\n",
            line
        );

        fflush(stdout);
    }

    running = 0;

    return NULL;
}

int main(int argc, char *argv[])
{
    const char *server_ip =
        "127.0.0.1";

    if (argc >= 2)
        server_ip = argv[1];

    signal(
        SIGPIPE,
        SIG_IGN
    );

    socket_fd = socket(
        AF_INET,
        SOCK_STREAM,
        0
    );

    if (socket_fd < 0) {
        perror("socket");
        return EXIT_FAILURE;
    }

    struct sockaddr_in server;

    memset(
        &server,
        0,
        sizeof(server)
    );

    server.sin_family = AF_INET;
    server.sin_port =
        htons(SERVER_PORT);

    if (
        inet_pton(
            AF_INET,
            server_ip,
            &server.sin_addr
        ) <= 0
    ) {
        printf("Invalid IP address\n");

        return EXIT_FAILURE;
    }

    if (
        connect(
            socket_fd,
            (struct sockaddr *)&server,
            sizeof(server)
        ) < 0
    ) {
        perror("connect");

        return EXIT_FAILURE;
    }

    printf("============================================\n");
    printf(" NetMessenger Client\n");
    printf(" Registration : IT23599918\n");
    printf(" Server       : %s:%d\n",
           server_ip,
           SERVER_PORT);
    printf("============================================\n");

    printf("Connected successfully.\n\n");

    printf("Available commands:\n");
    printf(" REGISTER <username>\n");
    printf(" LIST\n");
    printf(" BCAST <message>\n");
    printf(" PMSG <username> <message>\n");
    printf(" JOIN <room>\n");
    printf(" LEAVE <room>\n");
    printf(" ROOMS\n");
    printf(" RMSG <room> <message>\n");
    printf(" QUIT\n\n");

    pthread_t receiver;

    if (
        pthread_create(
            &receiver,
            NULL,
            receiver_thread,
            NULL
        ) != 0
    ) {
        perror("pthread_create");

        return EXIT_FAILURE;
    }

    char input[LINE_SIZE];

    while (
        running &&
        fgets(
            input,
            sizeof(input),
            stdin
        ) != NULL
    ) {
        size_t length = strlen(input);

        if (
            length > 0 &&
            input[length - 1] == '\n'
        )
            input[length - 1] = '\0';

        if (input[0] == '\0')
            continue;

        char output[LINE_SIZE + 2];

        snprintf(
            output,
            sizeof(output),
            "%s\n",
            input
        );

        if (
            send_all(
                socket_fd,
                output,
                strlen(output)
            ) < 0
        ) {
            break;
        }

        if (
            strcmp(
                input,
                "QUIT"
            ) == 0
        ) {
            sleep(1);
            break;
        }
    }

    running = 0;

    shutdown(
        socket_fd,
        SHUT_RDWR
    );

    pthread_join(
        receiver,
        NULL
    );

    close(socket_fd);

    return EXIT_SUCCESS;
}
EOF

# ------------------------------------------------
# MAKEFILE
# ------------------------------------------------

cat > "$MAKEFILE" <<'EOF'
CC = gcc

CFLAGS = -std=c11 -Wall -Wextra -Wpedantic -pthread

SERVER = server_9918
CLIENT = client_9918

all: $(SERVER) $(CLIENT)

$(SERVER): server_9918.c
	$(CC) $(CFLAGS) server_9918.c -o $(SERVER)

$(CLIENT): client_9918.c
	$(CC) $(CFLAGS) client_9918.c -o $(CLIENT)

clean:
	rm -f $(SERVER) $(CLIENT)

.PHONY: all clean
EOF

# ------------------------------------------------
# OTHER REQUIRED FILES
# ------------------------------------------------

touch "$LOGFILE"

echo "IE3010 NetMessenger test file - IT23599918" \
> test_files/sample.txt

cat > TEST_COMMANDS.txt <<'EOF'
IT23599918 NetMessenger Testing

SERVER
------

./server_9918


CLIENT 1
--------

./client_9918

REGISTER seneth


CLIENT 2
--------

./client_9918

REGISTER suba


LIST USERS
----------

LIST


BROADCAST
---------

BCAST Hello everyone


PRIVATE MESSAGE
---------------

PMSG suba Hello Suba


CREATE / JOIN ROOM
------------------

JOIN History


LIST ROOMS
----------

ROOMS


ROOM MESSAGE
------------

RMSG History Hello History room


LEAVE ROOM
----------

LEAVE History


INVALID USER TEST
-----------------

PMSG nobody Hello


INVALID ROOM
------------

RMSG UnknownRoom Hello


QUIT
----

QUIT


PORT PROOF
----------

ss -tlnp | grep 15918


LOG
---

cat netmsg_IT23599918.log
EOF

echo
echo "Cleaning old binaries..."

make -f "$MAKEFILE" clean || true

echo
echo "Compiling..."

make -f "$MAKEFILE"

echo
echo "=============================================="
echo " BUILD SUCCESSFUL"
echo "=============================================="
echo
echo "Registration : $REGNO"
echo "Port         : $PORT"
echo "NID          : NID:$NID"
echo
echo "Run server:"
echo
echo "./server_9918"
echo
echo "Run client:"
echo
echo "./client_9918"
echo
echo "Testing commands:"
echo
echo "cat TEST_COMMANDS.txt"
echo
# Setup script for the IE3010 NetMessenger project
# Checks the personalized configuration and prepares the project files.
# Run this script from the project directory using: bash setup.sh

