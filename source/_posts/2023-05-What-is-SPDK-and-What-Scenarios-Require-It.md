---
title: What is SPDK, and What Scenarios Require It
date: 2023-05-14 12:39:50
tags:
---

## 1. Introduction

There are already many articles about SPDK benifits. This article will not delve deeply into specific technical details; regarding specific technical implementations, I will place them in the reference links at the end.

## 2. What is SPDK

First, it must be clear that SPDK is a framework, not a distributed system. The foundation of SPDK (the official website uses the word 'bedrock') is a user space, polled-mode, asynchronous, lockless NVMe driver that provides zero-copy, high concurrency direct access to SSDs from user space. Its initial purpose was to optimize block storage write operations. However, with the continuous evolution of SPDK, people discovered that SPDK can optimize various aspects of the storage software stack.

Many distributed storage systems are considering how to incorporate the SPDK framework, or adopt the high-performance storage technology represented by SPDK to optimize the entire IO path.

## 3. SPDK Design Philosophy

SPDK mainly achieves its high-performance solution by introducing the following technologies:

1. Moving storage-related drivers to user space to avoid performance loss caused by system calls, and incidentally enabling zero-copy by directly using user space memory for write operations.
2. Using polling mode
   1. Polling hardware queues, unlike the previous interrupt mode which brought unstable performance and latency increases.
   2. Any business can register a polling function as a poller in the SPDK thread. After registration, this function will be executed periodically in SPDK, avoiding the overhead caused by event notification mechanisms like `epoll`.
3. Avoiding the use of locks in the IO path. Using lock-free queues to pass messages/IO.
   - One of the main design goals of SPDK is to achieve linear performance improvement as hardware (e.g. SSD, NIC, CPU) increases. To achieve this goal, SPDK designers must eliminate the overhead caused by using more system resources, such as: more threads, inter-process communication, accessing more storage hardware, and network cards.
   - To reduce this performance overhead, SPDK introduced lock-free queues, using lock-free programming to avoid the performance loss caused by locks.
   - SPDK's lock-free queues mainly rely on DPDK's implementation, which essentially uses CAS (Compare and Swap) to implement a multi-producer multi-consumer FIFO queue. For the implementation of lock-free queues, you can refer to [this article](https://blog.csdn.net/chen98765432101/article/details/69367633).

In simple terms, the SPDK runtime occupies specified CPU cores fully; its essence is a large while infinite loop that occupies a CPU core completely. It continuously runs user-specified pollers, polling queues, network interfaces, etc. Therefore, the most basic principle of SPDK programming is to avoid process context switches on SPDK cores. This would break SPDK's high-performance framework, causing performance degradation or even failure to work.

Process context switches can occur for many reasons, roughly listed as follows. We must avoid them when programming with SPDK. I once encountered a situation where an inconspicuous system call `mmap` in the SPDK thread entered the kernel, causing the entire SPDK process to become unserviceable until it crashed.

- CPU time slice exhaustion.
- When a process has insufficient system resources (such as insufficient memory), it must wait until resources are met before it can run. During this time, the process will also be suspended, and the system will schedule other processes to run.
- When a higher priority process needs to run, to ensure the operation of the high-priority process, the current process will be suspended, and the high-priority process will run.
- Hardware interrupts will cause the process on the CPU to be suspended, switching to execute the kernel's interrupt service routine.

## 4. Using SPDK to Accelerate NVMe Storage

SPDK aims to directly access `NVMe SSD` from user space, bypassing the kernel NVMe driver.

SPDK unbinds the `NVMe SSD` from the kernel driver and binds it to the VFIO or UIO driver. Although these two drivers themselves do not perform any initialization operations on the NVMe device, they give SPDK the ability to directly access the NVMe device. Subsequent initialization and command issuance are all handled by SPDK. Therefore, SPDK's access to `NVMe SSD` calls are basically corresponding to NVMe commands, such as admin cmd `spdk_nvme_ctrlr_cmd_set_feature`, `spdk_nvme_ctrlr_cmd_get_log_page`, and io cmd `spdk_nvme_ctrlr_alloc_io_qpair`, `spdk_nvme_ns_cmd_read`, etc. Of course, io_uring is already somewhat similar to the io cmd mentioned here :)

## 5. SPDK Bdev

Based on the above accelerated access to NVMe storage, SPDK provides a block device (bdev) software stack. This block device is not the block device in the Linux system; the block device in SPDK is just an interface layer abstracted by software.

SPDK has already provided various bdevs to meet different backend storage methods and testing requirements. Such as NVMe (NVMe bdev includes both NVMe physical disks and NVMe-oF), memory (malloc bdev), no write operation directly returns (null bdev), etc. Users can also customize their own bdev. &zwnj;**A very common way to use SPDK is**&zwnj; for users to define their own bdev to access their distributed storage cluster.

Through the bdev interface layer, SPDK unifies the calling methods of block devices. Users can use various bdevs by adding different block devices to the SPDK process through different RPCs without modifying the code. Moreover, it is very simple for users to add their own bdev, which greatly expands the applicable scenarios of SPDK.

At this point, students should understand that SPDK's current application scenarios are mainly targeted at block storage. It can be said that block storage is the foundation of the entire storage system. On top of it, we have built various file storage, object storage, table storage, databases, etc. We can, like various cloud-native databases, build upper-layer distributed systems directly on distributed block storage and object storage. We can also push down metadata and indexes that other storage needs to manage to the block layer, directly using SPDK to optimize upper-layer storage. For example, current block storage uses LBA as the index granularity for management. We can change the index to files/objects and build file/object storage systems on top of them.

## 6. SPDK Applications

The most direct way to use SPDK is as a storage engine to accelerate access to `NVMe SSD`. On top of this, SPDK has abstracted the bdev layer. Various businesses can expose block storage devices to users in some way by binding to bdev. This is what we will discuss next regarding various application scenarios.

The purpose of enterprises using block storage is to expose backend storage (which can be local disks or distributed storage clusters) to users. Its implementation forms, such as public clouds, private clouds, etc., we will not discuss for now. In terms of presentation methods alone, we have many ways to expose this block device to users. I have mainly encountered the following types:

1. Using network storage protocols such as iSCSI/NBD/NVMe-oF, establishing a client (called initiator in iscsi/nvmeof protocols) on the user's host machine to access the block device.
2. Through virtio virtualization, providing some type of block device on the host OS to virtual machines. Among these, different device types correspond to different drivers, and their IO paths also vary, such as vhost-user-blk, vfio-pci, virtio-blk, etc.
3. Bare-metal/smart-NIC/DPU by establishing PF/VF, simulating NVMe/virtio block devices.

For the first two methods, SPDK provides corresponding backend drivers, such as `iSCSI target`, `NVMe-oF target`, `vhost target`, etc. The third method varies in specific implementation details among different vendors and may not be open source. We use SPDK as the backend driver for these methods to receive IO from clients and process it. The advantage is that we can leverage SPDK's high-performance storage framework, which is the previously mentioned `user space`, `polled-mode`, `asynchronous`, `lockless`. The SPDK official website has many test documents comparing the performance of SPDK with other open-source implementations, which is still quite considerable.

## 7. Summary

I'm using SPDK for two years and is generally quite satisfied. The SPDK community provides various means for everyone to communicate. The SPDK China team also frequently publishes technical articles, technical videos, etc. Moreover, SPDK has been continuously evolving, absorbing and supporting various software and hardware new features. By learning SPDK, we can be exposed to various aspects of the storage technology stack. Therefore, I believe that as a storage professional, whether or not you use SPDK in your work, you must understand the various high-performance storage technologies behind SPDK.

## Network Stack

SPDK covers the entire path from front-end to network transmission to back-end write operations.

## 8. Reference Links

1. [Storage Performance Development Kits](https://spdk.io/doc/index.html) SPDK official documentation
2. [Virtualization Technology - Overview [Part 1]](https://zhuanlan.zhihu.com/p/69629212)
3. [20.01 SPDK NVMe-oF RDMA Performance Report](https://ci.spdk.io/download/performance-reports/SPDK_rdma_perf_report_2001.pdf)