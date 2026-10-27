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
