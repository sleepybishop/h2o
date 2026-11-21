#include "h2o.h"
#include "h2o/busypoll.h"
#include <linux/filter.h>
#include <ynl/ynl.h>
#include <ynl/netdev-user.h>

static __thread const char *worker_iface;
static __thread int worker_cpu = -1;
static __thread uint32_t worker_napi_id;

int h2o_busypoll_attach_cbpf(int fd, unsigned group_size)
{
    struct sock_filter code[] = {
        /* skb_record_rx_queue stores rx_queue + 1; zero falls back to default reuseport */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, SKF_AD_OFF + SKF_AD_QUEUE),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, UINT32_MAX),
        BPF_STMT(BPF_ALU | BPF_SUB | BPF_K, 1),
        BPF_STMT(BPF_ALU | BPF_MOD | BPF_K, group_size),
        BPF_STMT(BPF_RET | BPF_A, 0),
    };
    struct sock_fprog prog = {.len = sizeof(code) / sizeof(code[0]), .filter = code};
    return setsockopt(fd, SOL_SOCKET, SO_ATTACH_REUSEPORT_CBPF, &prog, sizeof(prog));
}

/* route mapped interfaces by queue and remaining traffic to ordinary workers */
int h2o_busypoll_attach_partial_map(int fd, const h2o_busypoll_nic_vector_t *nics, size_t num_workers)
{
    struct sock_filter group[] = {
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 0, 0), /* patched with ifindex and length below */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, SKF_AD_OFF + SKF_AD_QUEUE),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 2, 0),
        BPF_STMT(BPF_ALU | BPF_SUB | BPF_K, 1),
        BPF_STMT(BPF_JMP | BPF_JA, 3),
        /* unrecorded queues and unlisted interfaces use flow hash within their worker range */
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, SKF_AD_OFF + SKF_AD_RXHASH),
        BPF_JUMP(BPF_JMP | BPF_JGT | BPF_K, 0, 1, 0),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, SKF_AD_OFF + SKF_AD_RANDOM),
        BPF_STMT(BPF_ALU | BPF_MOD | BPF_K, 0), /* patched with number of workers */
        BPF_STMT(BPF_ALU | BPF_ADD | BPF_K, 0), /* patched with first worker index */
        BPF_STMT(BPF_RET | BPF_A, 0),
    };
    enum { group_len = sizeof(group) / sizeof(group[0]), hash_offset = 5 };
    if (num_workers > UINT32_MAX || nics->size > (BPF_MAXINSNS - 1 - (group_len - hash_offset)) / group_len) {
        errno = E2BIG;
        return -1;
    }
    struct sock_fprog prog = {.len = 1 + group_len * nics->size + group_len - hash_offset};
    prog.filter = h2o_mem_alloc(prog.len * sizeof(*prog.filter));
    prog.filter[0] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, SKF_AD_OFF + SKF_AD_IFINDEX);
    group[0].jf = group_len - 1;
    size_t pos = 1, first = 0;
    for (size_t i = 0; i <= nics->size; ++i) {
        size_t start, count;
        if (i != nics->size) {
            start = 0;
            count = nics->entries[i].cpus.size;
            group[0].k = nics->entries[i].ifindex;
        } else {
            start = hash_offset;
            count = num_workers - first;
        }
        assert(count != 0);
        group[group_len - 3].k = count;
        group[group_len - 2].k = first;
        memcpy(prog.filter + pos, group + start, (group_len - start) * sizeof(*group));
        pos += group_len - start;
        first += count;
    }
    assert(pos == prog.len);
    int ret = setsockopt(fd, SOL_SOCKET, SO_ATTACH_REUSEPORT_CBPF, &prog, sizeof(prog));
    free(prog.filter);
    return ret;
}

static struct ynl_sock *open_netdev(void)
{
    struct ynl_error err;
    struct ynl_sock *ys = ynl_sock_create(&ynl_netdev_family, &err);
    if (ys == NULL)
        fprintf(stderr, "busy-poll-map: failed to open netdev netlink socket: %s\n", err.msg);
    return ys;
}

static struct netdev_napi_get_rsp *get_napi_settings(struct ynl_sock *ys, uint32_t id)
{
    struct netdev_napi_get_req req = {0};
    netdev_napi_get_req_set_id(&req, id);
    struct netdev_napi_get_rsp *rsp = netdev_napi_get(ys, &req);
    if (rsp == NULL)
        fprintf(stderr, "busy-poll-map: cannot read settings for NAPI %u: %s\n", id, ys->err.msg);
    return rsp;
}

int h2o_busypoll_discover_queues(struct busypoll_nic_t *nic)
{
    if (nic->mode == BP_MODE_OFF)
        return 0;

    struct ynl_sock *ys = open_netdev();
    if (ys == NULL)
        return -1;
    int ret = -1;
    struct netdev_queue_get_req_dump req = {0};
    netdev_queue_get_req_dump_set_ifindex(&req, nic->ifindex);
    struct netdev_queue_get_list *queues = netdev_queue_get_dump(ys, &req);
    if (queues == NULL) {
        fprintf(stderr, "busy-poll-map: cannot query queues on %s: %s\n", nic->iface.base, ys->err.msg);
        goto Exit;
    }
    size_t count = 0;
    for (struct netdev_queue_get_list *entry = queues; !ynl_dump_empty(entry); entry = entry->next) {
        const struct netdev_queue_get_rsp *q = &entry->obj;
        if (q->ifindex != nic->ifindex || q->type != NETDEV_QUEUE_TYPE_RX)
            continue;
        if (!q->_present.napi_id || q->napi_id == 0) {
            fprintf(stderr, "busy-poll-map: %s RX queue %u has no NAPI ID\n", nic->iface.base, q->id);
            goto Exit;
        }
        if (q->id < nic->cpus.size)
            nic->napi_ids.entries[q->id] = q->napi_id;
        ++count;
    }
    if (count != nic->cpus.size) {
        fprintf(stderr, "busy-poll-map: %s has %zu RX queues and %zu mapped CPUs; active polling needs one CPU per RX queue\n",
                nic->iface.base, count, nic->cpus.size);
        goto Exit;
    }
    for (size_t q = 0; q != count; ++q) {
        if (nic->napi_ids.entries[q] == 0) {
            fprintf(stderr, "busy-poll-map: missing RX queue %zu on %s\n", q, nic->iface.base);
            goto Exit;
        }
        for (size_t prior = 0; prior < q; ++prior) {
            if (nic->napi_ids.entries[prior] == nic->napi_ids.entries[q]) {
                fprintf(stderr, "busy-poll-map: %s RX queues %zu and %zu share NAPI %u\n", nic->iface.base, prior, q,
                        nic->napi_ids.entries[q]);
                goto Exit;
            }
        }
        if (nic->mode == BP_MODE_SUSPEND && !nic->options.has_suspend_timeout) {
            struct netdev_napi_get_rsp *settings = get_napi_settings(ys, nic->napi_ids.entries[q]);
            if (settings == NULL)
                goto Exit;
            int enabled = settings->_present.irq_suspend_timeout && settings->irq_suspend_timeout != 0;
            netdev_napi_get_rsp_free(settings);
            if (!enabled) {
                fprintf(stderr, "busy-poll-map: SUSPEND requires a positive suspend-timeout for %s RX queue %zu\n", nic->iface.base,
                        q);
                goto Exit;
            }
        }
    }
    ret = 0;
Exit:
    if (queues != NULL)
        netdev_queue_get_list_free(queues);
    ynl_sock_destroy(ys);
    return ret;
}

static int has_options(const struct busypoll_napi_options *opts)
{
    return opts->has_gro_flush_timeout || opts->has_defer_hard_irqs || opts->has_suspend_timeout;
}

static int set_options(struct ynl_sock *ys, uint32_t id, const struct busypoll_napi_options *opts)
{
    if (!has_options(opts))
        return 0;
    struct netdev_napi_set_req req = {0};
    netdev_napi_set_req_set_id(&req, id);
    if (opts->has_gro_flush_timeout)
        netdev_napi_set_req_set_gro_flush_timeout(&req, opts->gro_flush_timeout);
    if (opts->has_defer_hard_irqs)
        netdev_napi_set_req_set_defer_hard_irqs(&req, opts->defer_hard_irqs);
    if (opts->has_suspend_timeout)
        netdev_napi_set_req_set_irq_suspend_timeout(&req, opts->suspend_timeout);
    int ret = netdev_napi_set(ys, &req);
    if (ret != 0)
        fprintf(stderr, "busy-poll-map: cannot set options for NAPI %u: %s\n", id, ys->err.msg);
    return ret;
}

static int save_and_set_options(struct ynl_sock *ys, struct busypoll_nic_t *nic, uint32_t id)
{
    struct netdev_napi_get_rsp *rsp = get_napi_settings(ys, id);
    if (rsp == NULL)
        return -1;
    struct busypoll_napi_options changes = nic->options;
    if ((changes.has_gro_flush_timeout && !rsp->_present.gro_flush_timeout) ||
        (changes.has_defer_hard_irqs && !rsp->_present.defer_hard_irqs) ||
        (changes.has_suspend_timeout && !rsp->_present.irq_suspend_timeout)) {
        fprintf(stderr, "busy-poll-map: kernel did not report previous settings for NAPI %u\n", id);
        netdev_napi_get_rsp_free(rsp);
        return -1;
    }
    /* write and restore only explicitly requested fields whose values changed */
    changes.has_gro_flush_timeout &= changes.gro_flush_timeout != rsp->gro_flush_timeout;
    changes.has_defer_hard_irqs &= changes.defer_hard_irqs != rsp->defer_hard_irqs;
    changes.has_suspend_timeout &= changes.suspend_timeout != rsp->irq_suspend_timeout;
    struct busypoll_napi_options saved = changes;
    saved.gro_flush_timeout = rsp->gro_flush_timeout;
    saved.defer_hard_irqs = rsp->defer_hard_irqs;
    saved.suspend_timeout = rsp->irq_suspend_timeout;
    netdev_napi_get_rsp_free(rsp);
    if (set_options(ys, id, &changes) != 0)
        return -1;
    nic->saved_options.entries[nic->saved_options.size++] = saved;
    return 0;
}

static void restore_options(struct ynl_sock *ys, h2o_busypoll_nic_vector_t *nics)
{
    /* roll back in reverse application order */
    for (size_t i = nics->size; i != 0; --i) {
        struct busypoll_nic_t *nic = nics->entries + i - 1;
        while (nic->saved_options.size != 0) {
            size_t q = --nic->saved_options.size;
            set_options(ys, nic->napi_ids.entries[q], nic->saved_options.entries + q);
        }
    }
}

int h2o_busypoll_apply_options(h2o_busypoll_nic_vector_t *nics)
{
    struct ynl_sock *ys = NULL;
    for (size_t i = 0; i != nics->size; ++i) {
        struct busypoll_nic_t *nic = nics->entries + i;
        if (nic->mode == BP_MODE_OFF || !has_options(&nic->options))
            continue;
        if (ys == NULL && (ys = open_netdev()) == NULL)
            return -1;
        h2o_vector_reserve(NULL, &nic->saved_options, nic->napi_ids.size);
        for (size_t q = 0; q != nic->napi_ids.size; ++q) {
            if (save_and_set_options(ys, nic, nic->napi_ids.entries[q]) != 0) {
                restore_options(ys, nics);
                ynl_sock_destroy(ys);
                return -1;
            }
        }
    }
    if (ys != NULL)
        ynl_sock_destroy(ys);
    return 0;
}

void h2o_busypoll_restore_options(h2o_busypoll_nic_vector_t *nics)
{
    for (size_t i = 0; i != nics->size; ++i) {
        if (nics->entries[i].saved_options.size != 0) {
            struct ynl_sock *ys = open_netdev();
            if (ys != NULL) {
                restore_options(ys, nics);
                ynl_sock_destroy(ys);
            }
            return;
        }
    }
}

int h2o_busypoll_init_worker(h2o_loop_t *loop, const struct busypoll_nic_t *nic, size_t queue,
                             const struct busypoll_epoll_params *params)
{
    worker_iface = nic->iface.base;
    worker_cpu = nic->cpus.entries[queue];
    if (nic->mode == BP_MODE_OFF)
        return 0;
    worker_napi_id = nic->napi_ids.entries[queue];
    return h2o_evloop_set_busypoll(loop, nic->mode, params);
}

int h2o_busypoll_disable_worker(h2o_loop_t *loop, const char *reason)
{
    if (worker_napi_id == 0)
        return 0;
    if (h2o_evloop_set_busypoll(loop, BP_MODE_OFF, NULL) != 0) {
        h2o_perror("busy-poll-map: cannot switch worker to ordinary epoll");
        return -1;
    }
    fprintf(stderr, "[warning] busy-poll-map: %s CPU %d NAPI %u: %s; switching worker to ordinary epoll\n", worker_iface,
            worker_cpu, worker_napi_id, reason);
    worker_napi_id = 0;
    return 0;
}

int h2o_busypoll_check_socket(h2o_socket_t *sock)
{
    if (worker_napi_id == 0)
        return 0;
    uint32_t id = 0;
    socklen_t len = sizeof(id);
    if (getsockopt(h2o_socket_get_fd(sock), SOL_SOCKET, SO_INCOMING_NAPI_ID, &id, &len) == 0 && id == worker_napi_id)
        return 0;
    /* driver may change queues at runtime; avoid mixing NAPI IDs on a polling epoll */
    char reason[96];
    snprintf(reason, sizeof(reason), "accepted connection has NAPI %u", id);
    return h2o_busypoll_disable_worker(h2o_socket_get_loop(sock), reason);
}

const char *h2o_busypoll_get_iface(void)
{
    return worker_iface;
}

uint32_t h2o_busypoll_get_napi_id(void)
{
    return worker_napi_id;
}

int h2o_busypoll_get_cpu_idx(void)
{
    return worker_cpu;
}
