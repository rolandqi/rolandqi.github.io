---
title: Cloud Block Device Flow Control Strategies
date: 2023-05-11 12:39:50
tags:
- disributed system
- block device
---

## QoS Rate Limiting Algorithms Introduction

Rate limiting strategies mainly include token bucket and leaky bucket, which are introduced as follows.

### Token Bucket

Wiki's algorithm description of token bucket is as follows:

- A token is added to the bucket every `1/r` seconds.
- The bucket can hold at the most `b` tokens. If a token arrives when the bucket is full, **it is discarded**.
- When a packet (network layer PDU) of n bytes arrives,
  - if at least n tokens are in the bucket, n tokens are removed from the bucket, and the packet is sent to the network.
  - if fewer than n tokens are available, no tokens are removed from the bucket, and the packet is considered to be non-conformant.

A bucket with fixed capacity holds a certain number of tokens, where the bucket's capacity is the upper limit of token count. The number of tokens in the bucket is replenished at fixed intervals until the bucket is full. An IO request will consume one token; if there are tokens in the bucket, the IO request is allowed after consuming a token; otherwise, it cannot be allowed (the algorithm can choose whether to discard the IO request). If rate limiting is based on byte count, each IO will consume tokens equivalent to the iosize.

Based on the above description, we can understand that the token bucket algorithm can achieve the following effects:

1. The token bucket algorithm can control the rate of processing IO requests by controlling the token replenishment rate;
2. **The token bucket algorithm allows a certain degree of burst**—as long as the tokens in the bucket are not exhausted, IO requests can immediately consume tokens and be allowed through. During this period, the IO request processing rate will be greater than the token replenishment rate, where the token replenishment rate actually represents the average processing rate;
3. **The token bucket algorithm cannot control the upper limit of burst rate and burst duration. The burst duration is determined by the actual IO request rate. If the actual IO request rate is greater than the token replenishment rate and remains constant, then: Burst duration = Token bucket capacity / (Actual IO request rate - Token replenishment rate)

### Leaky Bucket

#### Leaky bucket as a meter

Wiki defines Leaky bucket as a meter as follows:

- A fixed capacity bucket, associated with each virtual connection or user, leaks at a fixed rate.
- If the bucket is empty, it stops leaking.
- For a packet to conform, it has to be possible to add a specific amount of water to the bucket: The specific amount added by a conforming packet can be the same for all packets, or can be proportional to the length of the packet.
- If this amount of water would cause the bucket to exceed its capacity then the packet does not conform and the water in the bucket is left unchanged.

We can understand it as follows:

A bucket leaks water at a fixed rate. Passing IO request packets add water to the bucket. The amount of water added is based on the aspect of flow control, which could be bytes or IOPS. If adding water causes overflow, the IO cannot pass; otherwise, it can be allowed through.

It can be seen that this algorithm description is basically similar to the token bucket. We can consider `Leaky bucket as a meter` and `Token Bucket` to be equivalent.

#### Leaky bucket as a queue

Wiki's description of this rate limiting strategy is: **The leaky bucket consists of a finite queue. When a packet arrives, if there is room on the queue it is appended to the queue; otherwise it is discarded. At every clock tick one packet is transmitted (unless the queue is empty)**

It can be considered that `Leaky bucket as a queue` is the scenario where the token bucket size equals 1.

## Mainstream Block Device Flow Control Solutions

The mainstream flow control strategies widely applied in engineering mainly include three types: qemu, librbd, and spdk, which are introduced respectively below.

### Qemu

Qemu supported block device IO rate limiting as early as version 1.1, providing 6 configuration items to set rate limits for IOPS and bandwidth in 6 different scenarios. Version 1.7 added support for bursts to block device IO rate limiting. Version 2.6 improved the burst support functionality, allowing control over burst rate and duration. The parameters are as follows:

| Scenario    | Basic Rate Limit Config | Burst Rate Config       | Burst Duration Config       |
|------------|-------------------------|-------------------------|------------------------------|
| Total IOPS | iops-total              | iops-total-max          | iops-total-max-length        |
| Read IOPS  | iops-read               | iops-read-max           | iops-read-max-length         |
| Write IOPS | iops-write              | iops-write-max          | iops-write-max-length        |
| Total BPS  | bps-total               | bps-total-max           | bps-total-max-length         |
| Read BPS   | bps-read                | bps-read-max            | bps-read-max-length          |
| Write BPS  | bps-write               | bps-write-max           | bps-write-max-length        |

The core data structure of its implementation is described as follows:

```c
typedef struct LeakyBucket {
    uint64_t avg;             /* IO limit target rate */
    uint64_t max;             /* IO burst limit rate */
    double  level;            /* bucket level in units */
    double  burst_level;      /* bucket level in units (for computing bursts) */
    uint64_t burst_length;    /* Burst duration, default unit is seconds */
} LeakyBucket
```

Qemu's flow control algorithm uses a leaky bucket implementation. The goal of the algorithm is that the user can have a burst rate of `bkt.max` for `bkt.burst_length` seconds, after which the rate drops to `bkt.avg`.

To achieve this goal, qemu implements two buckets:

1. Main bucket: Size `bucket_size` is `bkt.max * bkt.burst_length`, leaking at rate `bkt.avg`. Normal IOs are processed by the main bucket first.
2. Burst bucket: Size `burst_bucket_size` is set to one-tenth of the main bucket, leaking at rate `bkt.max`.

If the main bucket is full, then it needs to wait for the leaky bucket. If the main bucket is not full and a burst bucket is set, it needs to check whether the burst bucket can allow passage. This way, we ensure the IO burst rate through the burst bucket, and guarantee the burst duration through the size of the main bucket.

The key function controlling whether IO can be allowed is as follows:

```c
/* This function compute the wait time in ns that a leaky bucket should trigger
 *
 * @bkt: the leaky bucket we operate on
 * @ret: the resulting wait time in ns or 0 if the operation can go through
 */
int64_t throttle_compute_wait(LeakyBucket *bkt)
{
    double extra; /* the number of extra units blocking the io */
    double bucket_size;   /* I/O before throttling to bkt->avg */
    double burst_bucket_size; /* Before throttling to bkt->max */

    if (!bkt->avg) {
        return 0;
    }

    if (!bkt->max) {
        /* If bkt->max is 0 we still want to allow short bursts of I/O
         * from the guest, otherwise every other request will be throttled
         * and performance will suffer considerably. */
        bucket_size = (double) bkt->avg / 10;
        burst_bucket_size = 0;
    } else {
        /* If we have a burst limit then we have to wait until all I/O
         * at burst rate has finished before throttling to bkt->avg */
        bucket_size = bkt->max * bkt->burst_length;
        burst_bucket_size = (double) bkt->max / 10;
    }

    /* If the main bucket is full then we have to wait */
    extra = bkt->level - bucket_size;
    if (extra > 0) {
        return throttle_do_compute_wait(bkt->avg, extra);
    }

    /* If the main bucket is not full yet we still have to check the
     * burst bucket in order to enforce the burst limit */
    if (bkt->burst_length > 1) {
        assert(bkt->max > 0); /* see throttle_is_valid() */
        extra = bkt->burst_level - burst_bucket_size;
    if (extra > 0) {
        return throttle_do_compute_wait(bkt->max, extra);
        }
    }

    return 0;
}
```

### librbd

Ceph supported IO rate limiting for RBD images starting from version 13.2.0 (Mimic). This version only supported rate limiting for total IOPS scenario and supported bursts, allowing configuration of burst rate but not controlling burst duration (effectively equivalent to setting burst duration to 1 second and unmodifiable). Version 14.2.0 (Nautilus) added support for rate limiting in 5 additional scenarios: read IOPS, write IOPS, total BPS, read BPS, and write BPS, while maintaining the same burst support effects.

Librbd's rate limiting mechanism supports bursts and allows configuration of burst rates, but does not support controlling burst duration. It is implemented using a token bucket. The token bucket refill rate can be adjusted using the `rbd_qos_schedule_tick_min` parameter, defaulting to 50ms. Users can configure the base rate and burst rate through the following parameters:

| Scenario    | Basic Rate Limit Config           | Burst Rate Config           |
|------------|----------------------------------|------------------------------|
| Total IOPS | rbd_qos_iops_limit               | rbd_qos_iops_burst         |
| Read IOPS  | rbd_qos_iops_read_limit          | rbd_qos_iops_read_burst    |
| Write IOPS | rbd_qos_iops_write_limit         | rbd_qos_iops_write_burst   |
| Total BPS  | rbd_qos_bps_limit                | rbd_qos_bps_burst          |
| Read BPS   | rbd_qos_bps_read_limit            | rbd_qos_bps_read_burst     |
| Write BPS  | rbd_qos_bps_write_limit           | rbd_qos_bps_write_burst    |

### spdk

SPDK's QoS rate limiting is implemented at the bdev layer and uses a token bucket. It supports separate configuration for IOPS and BW but does not support burst rates. Configuration is done via the RPC request `bdev_set_qos_limit`. The configuration parameters are as follows:

| Parameter           | Explanation                     |
|---------------------|---------------------------------|
| rw_ios_per_sec      | IOPS limit                      |
| rw_mbytes_per_sec   | Read/Write bandwidth limit      |
| r_mbytes_per_sec    | Read bandwidth limit            |
| w_mbytes_per_sec    | Write bandwidth limit           |

SPDK refills the token bucket by registering a poller function `bdev_channel_poll_qos`, with a frequency hardcoded as `SPDK_BDEV_QOS_TIMESLICE_IN_USEC`, defaulting to 1ms. The amount of tokens added per refill is `Total rate / Timeslice`.

An IO must pass through all configured token buckets before it can be allowed. A token bucket can be decremented to a negative value in a single operation. Once it becomes negative, all IOs cannot be allowed until the function `bdev_channel_poll_qos` refills the token bucket to a positive value.

```c
static int
bdev_channel_poll_qos(void *arg)
{
    struct spdk_bdev_qos *qos = arg;
    uint64_t now = spdk_get_ticks();
    int i;

    if (now < (qos->last_timeslice + qos->timeslice_size)) {
        /* We received our callback earlier than expected - return
         *  immediately and wait to do accounting until at least one
         *  timeslice has actually expired.  This should never happen
         *  with a well-behaved timer implementation.
         */
        return SPDK_POLLER_IDLE;
    }

    /* Reset for next round of rate limiting */
    for (i = 0; i < SPDK_BDEV_QOS_NUM_RATE_LIMIT_TYPES; i++) {
        /* We may have allowed the IOs or bytes to slightly overrun in the last
         * timeslice. remaining_this_timeslice is signed, so if it's negative
         * here, we'll account for the overrun so that the next timeslice will
         * be appropriately reduced.
         */
        if (qos->rate_limits[i].remaining_this_timeslice > 0) {
            qos->rate_limits[i].remaining_this_timeslice = 0;
        }
    }

    while (now >= (qos->last_timeslice + qos->timeslice_size)) {
        qos->last_timeslice += qos->timeslice_size;
        for (i = 0; i < SPDK_BDEV_QOS_NUM_RATE_LIMIT_TYPES; i++) {
            qos->rate_limits[i].remaining_this_timeslice +=
                qos->rate_limits[i].max_per_timeslice;
        }
    }

    return bdev_qos_io_submit(qos->ch, qos);
}
```

## Impact of Rate Limiting Strategies on Block Devices

Different QoS strategies result in different experiences for the upper-layer block device, mainly reflected in IO latency and `%util`.

### Latency

Latency is determined by the burst performance and refill frequency of the QoS strategy.

- **Burst Performance**: Configuring a larger leaky bucket or token bucket, or setting up two buckets like Qemu, can enhance the burst performance of the block device, resulting in lower latency when the block device handles burst traffic.
  - This can be tested using the fio command: `fio --group_reporting --rw=randwrite --bs=1M --numjobs=1 --iodepth=64 --ioengine=libaio --direct=1 --name test --size=2000G  --filename=/dev/vdb  -iodepth_low=0 -iodepth_batch_submit=64 -thinktime=950ms -thinktime_blocks=64`. This issues 1M IOs with a queue depth of 64 each time, waits 950ms after completion, and repeats. If the block device's burst performance is poor, the observed phenomenon is high `iowait` latency and an inability to achieve high bandwidth. Furthermore, because we wait a long time between each IO issue, the io util is also low.
- **Refill Frequency**: A lower refill frequency can cause severe tail latency. For example, if the token bucket refills every 1 second, and if the IOs issued within that 1 second exceed the limit, then some IOs will inevitably experience latency exceeding 1 second, leading to high tail latency.

### IO util

Disk util value is defined as the proportion of time the disk spends processing IOs relative to the total time. It is the ratio of the time the disk queue has IOs to the total time. If the rate limiting algorithm causes the IO processing time to be very evenly distributed (like `Leaky bucket as a queue`, where IOs are processed one by one intermittently), and the disk queue always has IOs, then the util naturally is high.

For block devices configured with high burst performance, even very high queue depths can be processed quickly, resulting in naturally low Util.

### Impact on Database Applications

Here we take the database MySQL built on distributed block devices as an example to discuss the impact of rate limiting strategies on SQL performance.

In MySQL, there are mainly two parts of IO that significantly affect performance:

1. Flushing Dirty Pages
   1. To reduce the number of IOs and improve read/write performance, MySQL introduces the `buffer pool`. Modifications to data in MySQL are first made in the buffer pool and flushed at an appropriate time. When the memory data page and the disk data page content are inconsistent, we call this memory page a "dirty page". After the memory data is written to disk, the content of the memory and disk data pages becomes consistent, called a "clean page".
   2. From the usage scenario, we can infer that each dirty page flush must involve large IOs and high queues. If the block device's burst performance is poor, it will lead to slow dirty page flushing rates, and as mentioned above, this scenario is highly likely to have low ioutil. That is to say, this IO model does not leverage the performance of the rate limiting mechanism.
   3. The solutions are simple:
      1. Reduce the queue depth (the size of each dirty page flush) to offset the limitation of insufficient burst performance.
      2. Increase the flush frequency to thereby improve ioutil and enhance the utilization of the rate limiting strategy.
2. Flushing Redo-log. Bin-log is not discussed here because the official stance is that the performance loss from enabling bin-log is less than 1%.
   1. Redo-log, to ensure correctness, is written sequentially by a single thread. If the block device's burst performance is poor, it will cause high latency in issuing redo-log, dragging down the entire system's TPS.
   2. If redo-log shares the same disk with other IOs, its own priority cannot be reflected, potentially increasing redo-log latency due to dirty page flushing triggering rate limiting.
   3. The solutions include the following:
      1. Increase the block device's burst capability.
      2. Elevate the priority of redo-log so that it is issued first. If the block device system does not support IO priorities, you can apply for another disk to be used exclusively for redo-log.
      3. The upper-layer MySQL application supports concurrently and randomly written redo-log (PolarDB should have already implemented this).

## Reference Links

1. [Wiki Token bucket](https://en.wikipedia.org/wiki/Token_bucket)
2. [Wiki Leaky bucket](https://en.wikipedia.org/wiki/Leaky_bucket)
3. [Token Bucket Rate Limiting_Qemu and Librbd QoS Rate Limiting Mechanism Comparison and Algorithm Analysis](https://blog.csdn.net/weixin_28738021/article/details/112610541)
4. [Written on the 10th Anniversary of Work](https://zhuanlan.zhihu.com/p/352213790)
5. [qemu leaky bucket](https://github.com/qemu/qemu/blob/master/docs/throttle.txt)
6. [Huawei Cloud Disk EVS Burst Capability Introduction](https://support.huaweicloud.com/intl/zh-cn/productdesc-evs/zh-cn_topic_0044524691.html)
7. [How to Test Cloud Disk Performance](https://support.huaweicloud.com/intl/zh-cn/evs_faq/evs_faq_0019.html)
8. [Stress Testing ESSD Cloud Disk IOPS Performance](https://www.alibabacloud.com/help/zh/doc-detail/65077.htm)
9. [Rate Limiting Algorithm: Sliding Window Method](https://cloud.tencent.com/developer/news/626730)