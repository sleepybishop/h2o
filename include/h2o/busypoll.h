#ifndef h2o__busypoll_h
#define h2o__busypoll_h

#if !H2O_USE_EPOLL_BUSYPOLL
#error "this file requires Linux epoll busy-poll support"
#endif

#include "h2o/socket.h"

enum en_h2o_bp_mode_t { BP_MODE_OFF, BP_MODE_SUSPEND, BP_MODE_BUSYPOLL, BP_MODE_NUM };

struct busypoll_epoll_params {
    uint32_t usecs;
    uint16_t budget;
    int prefer;
    int nonblock;
};

struct busypoll_napi_options {
    uint64_t gro_flush_timeout;
    uint32_t defer_hard_irqs;
    uint64_t suspend_timeout;
    unsigned has_gro_flush_timeout : 1;
    unsigned has_defer_hard_irqs : 1;
    unsigned has_suspend_timeout : 1;
};

struct busypoll_nic_t {
    h2o_iovec_t iface;
    unsigned ifindex;
    enum en_h2o_bp_mode_t mode;
    H2O_VECTOR(unsigned) cpus;
    H2O_VECTOR(uint32_t) napi_ids;
    struct busypoll_napi_options options;
    H2O_VECTOR(struct busypoll_napi_options) saved_options;
};

typedef H2O_VECTOR(struct busypoll_nic_t) h2o_busypoll_nic_vector_t;

/* returns diagnostic on failure with errno set */
const char *h2o_evloop_validate_busypoll(enum en_h2o_bp_mode_t mode, const struct busypoll_epoll_params *params);
int h2o_evloop_set_busypoll(h2o_loop_t *loop, enum en_h2o_bp_mode_t mode, const struct busypoll_epoll_params *params);
int h2o_busypoll_attach_cbpf(int fd, unsigned group_size);
int h2o_busypoll_attach_partial_map(int fd, const h2o_busypoll_nic_vector_t *nics, size_t num_workers);
int h2o_busypoll_discover_queues(struct busypoll_nic_t *nic);
int h2o_busypoll_apply_options(h2o_busypoll_nic_vector_t *nics);
void h2o_busypoll_restore_options(h2o_busypoll_nic_vector_t *nics);
int h2o_busypoll_init_worker(h2o_loop_t *loop, const struct busypoll_nic_t *nic, size_t queue,
                             const struct busypoll_epoll_params *params);
int h2o_busypoll_disable_worker(h2o_loop_t *loop, const char *reason);
int h2o_busypoll_check_socket(h2o_socket_t *sock);

const char *h2o_busypoll_get_iface(void);
uint32_t h2o_busypoll_get_napi_id(void);
int h2o_busypoll_get_cpu_idx(void);

#endif
