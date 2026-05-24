/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */

#ifndef __LINUX_VM_SOCKETS__
#define __LINUX_VM_SOCKETS__

#include <sys/socket.h>

#define VMADDR_CID_ANY		-1U
#define VMADDR_CID_HYPERVISOR	0
#define VMADDR_CID_LOCAL	1
#define VMADDR_CID_HOST		2

#define VMADDR_PORT_ANY		-1U

struct sockaddr_vm {
	sa_family_t svm_family;
	unsigned short svm_reserved1;
	unsigned int svm_port;
	unsigned int svm_cid;
	__u8 svm_flags;
	unsigned char svm_zero[sizeof(struct sockaddr) -
			       sizeof(sa_family_t) -
			       sizeof(unsigned short) -
			       sizeof(unsigned int) -
			       sizeof(unsigned int) -
			       sizeof(__u8)];
};

#endif /* __LINUX_VM_SOCKETS__ */
