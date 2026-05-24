/* SPDX-License-Identifier: BSD-3-Clause */
/* Copyright (c) 2023, Unikraft GmbH and The Unikraft Authors.
 * Licensed under the BSD-3-Clause License (the "License").
 * You may not use this file except in compliance with the License.
 */
#ifndef __VIRTIO_VSOCK_H__
#define __VIRTIO_VSOCK_H__

#include <virtio/virtio_ids.h>
#include <virtio/virtio_config.h>
#include <virtio/virtio_types.h>

/* virtio-vsock specific feature flags */

/* Stream socket type is supported */
#define VIRTIO_VSOCK_F_STREAM			0
/* Stream socket type is supported */
#define VIRTIO_VSOCK_F_SEQPACKET		1
/* Stream socket is not implied */
#define VIRTIO_VSOCK_F_NO_IMPLIED_STREAM	2

struct virtio_vsock_config {
	__u64 guest_cid;
} __packed;

/* Communication was interrupted */
#define VIRTIO_VSOCK_EVENT_TRANSPORT_RESET	0

struct virtio_vsock_event {
	__u32 id;
};

struct virtio_vsock_hdr {
	__u64	src_cid;
	__u64	dst_cid;
	__u32	src_port;
	__u32	dst_port;
	__u32	len;
	__u16	type;
	__u16	op;
	__u32	flags;
	__u32	buf_alloc;
	__u32	fwd_cnt;
} __packed;

/* stream sockets: OP_SHUTDOWN packet flags */
#define VIRTIO_VSOCK_SHUTDOWN_F_RECEIVE	UK_BIT(0)
#define VIRTIO_VSOCK_SHUTDOWN_F_SEND    UK_BIT(1)

/* seqpacket sockets: general packet flags */
#define VIRTIO_VSOCK_SEQ_EOM		UK_BIT(0)
#define VIRTIO_VSOCK_SEQ_EOR		UK_BIT(1)

#define VIRTIO_VSOCK_TYPE_STREAM	1
#define VIRTIO_VSOCK_TYPE_SEQPACKET	2

enum virtio_vsock_op {
	VIRTIO_VSOCK_OP_INVALID = 0,

	/* Connect operations */
	VIRTIO_VSOCK_OP_REQUEST = 1,
	VIRTIO_VSOCK_OP_RESPONSE = 2,
	VIRTIO_VSOCK_OP_RST = 3,
	VIRTIO_VSOCK_OP_SHUTDOWN = 4,

	/* TX/RX operations */
	VIRTIO_VSOCK_OP_RW = 5,

	/* Tell the peer our credit info */
	VIRTIO_VSOCK_OP_CREDIT_UPDATE = 6,
	/* Request the peer to send the credit info to us */
	VIRTIO_VSOCK_OP_CREDIT_REQUEST = 7,
};

#endif /* __VIRTIO_VSOCK_H__ */
