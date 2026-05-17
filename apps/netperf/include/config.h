#ifndef NETPERF_CONFIG_H
#define NETPERF_CONFIG_H

/* Build identity */
#define PACKAGE_NAME    "netperf"
#define PACKAGE_VERSION "2.7.0"
#define PACKAGE_STRING  "netperf 2.7.0"

/* Standard C / POSIX bits musl provides */
#define STDC_HEADERS            1
#define HAVE_STRING_H           1
#define HAVE_STRINGS_H          1
#define HAVE_LIMITS_H           1
#define HAVE_STDINT_H           1
#define HAVE_INTTYPES_H         1
#define HAVE_UNISTD_H           1
#define HAVE_STDLIB_H           1
#define HAVE_ERRNO_H            1
#define HAVE_SIGNAL_H           1
#define HAVE_SYS_TYPES_H        1
#define HAVE_SYS_STAT_H         1
#define HAVE_SYS_IPC_H          1
#define HAVE_SYS_IOCTL_H        1
#define HAVE_SYS_TIME_H         1
#define HAVE_SYS_TIMES_H        1
#define HAVE_SYS_WAIT_H         1
#define HAVE_SYS_SOCKET_H       1
#define HAVE_SYS_PARAM_H        1
#define HAVE_FCNTL_H            1
#define HAVE_MALLOC_H           1

/* Network headers from lwIP + musl */
#define HAVE_NETINET_IN_H       1
#define HAVE_NETINET_TCP_H      1
#define HAVE_ARPA_INET_H        1
#define HAVE_NETDB_H            1
#define HAVE_SYS_SELECT_H       1

/* Network functions */
#define HAVE_GETHOSTBYNAME      1
#define HAVE_GETADDRINFO        1
#define HAVE_GETNAMEINFO        1
#define HAVE_INET_NTOP          1
#define HAVE_STRUCT_SOCKADDR_IN6 1
#define HAVE_STRUCT_SOCKADDR_STORAGE 1
#define HAVE_GETTIMEOFDAY       1
#define HAVE_STRTOL             1
#define HAVE_STRDUP             1

/* setsid: claim we have it so the #if !HAVE_SETSID blocks are skipped
   (they pull in sys/wait.h + waitpid which we don't need) */
#define HAVE_SETSID             1

/* uname for system identification */
#define HAVE_SYS_UTSNAME_H      1

/* socklen_t equivalent — normally set by autoconf */
#define netperf_socklen_t socklen_t

/* Things intentionally absent on a unikernel */
/* #undef HAVE_FORK            */
/* #undef HAVE_DAEMON          */
/* #undef HAVE_SYSLOG_H        */
/* #undef HAVE_GETPWUID        */
/* #undef HAVE_SYS_RESOURCE_H  */
/* #undef HAVE_GETRUSAGE       */
/* #undef HAVE_KSTAT_H         */
/* #undef HAVE_SENDFILE        */
/* #undef HAVE_LINUX_TCP_H     */
/* #undef HAVE_SYSCALL_H       */
/* #undef HAVE_BIND_TO_CPU_ID  */
/* #undef USE_PROC_STAT        */

#endif /* NETPERF_CONFIG_H */
