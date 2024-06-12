/*
GPT-2 Transformer Neural Net training loop. See README.md for usage.
*/

#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <sys/types.h>
// ----------- CPU utilities -----------
// defines: fopenCheck, freadCheck, fcloseCheck, fseekCheck, mallocCheck
// defines: create_dir_if_not_exists, find_max_step
#include "llmc/utils.h"
// defines: tokenizer_init, tokenizer_decode, tokenizer_free
#include "llmc/tokenizer.h"
// defines: dataloader_init, dataloader_reset, dataloader_next_batch, dataloader_free
// defines: evalloader_init, evalloader_reset, evalloader_next_batch, evalloader_free
#include "llmc/dataloader.h"
// defines: manual_seed, normal_ (same as torch.manual_seed and torch.normal)
#include "llmc/rand.h"
// defines: sample_softmax, random_f32
#include "llmc/sampler.h"
// defines: logger_init, logger_log_eval, logger_log_val, logger_log_train
#include "llmc/logger.h"
// defines: get_flops_promised
#include "llmc/mfu.h"
// ----------- GPU utilities -----------
// defines:
// WARP_SIZE, MAX_1024_THREADS_BLOCKS, CEIL_DIV, cudaCheck, PRECISION_MODE
// NVTX_RANGE_FN
#include "llmc/cuda_common.h"
// defines:
// Packed128, f128, x128
// warpReduceSum, warpReduceMax, blockReduce, copy_and_cast_kernel
#include "llmc/cuda_utils.cuh"
// defines: CUBLAS_LOWP, cublasCheck, cublaslt_workspace_size, cublaslt_workspace
// defines: cublas_compute, cublaslt_handle, cublas_handle
#include "llmc/cublas_common.h"
// ----------- Layer implementations in CUDA -----------
// defines: encoder_forward, encoder_backward
#include "llmc/encoder.cuh"
// defines: layernorm_forward, residual_forward, fused_residual_forward5, layernorm_backward
#include "llmc/layernorm.cuh"
// defines: gelu_forward, gelu_backward_inplace
#include "llmc/gelu.cuh"
#ifdef ENABLE_CUDNN
// defines: create_cudnn, destroy_cudnn, attention_forward_cudnn, attention_backward_cudnn
#include "llmc/cudnn_att.h"
#else
// defines: attention_forward, attention_backward
#include "llmc/attention.cuh"
#endif
// defines: matmul_forward, matmul_backward
#include "llmc/matmul.cuh"
// defines: fused_classifier
#include "llmc/fused_classifier.cuh"
// defines: adamw_kernel3
#include "llmc/adamw.cuh"
// defines: global_norm_squared
#include "llmc/global_norm.cuh"
// ----------- Multi-GPU support -----------
#ifdef MULTI_GPU
#include <mpi.h>
#include <nccl.h>
#endif

// ----------------------------------------------------------------------------
// global vars containing information about the GPU this process is running on
cudaDeviceProp deviceProp; // fills in common_start()
cudaStream_t main_stream;

// ----------------------------------------------------------------------------
// Multi-GPU related
#ifdef MULTI_GPU

#if defined(ENABLE_FP32)
const ncclDataType_t ncclFloatX = ncclFloat;
#elif defined(ENABLE_FP16)
const ncclDataType_t ncclFloatX = ncclHalf;
#else // Default to bfloat16
const ncclDataType_t ncclFloatX = ncclBfloat16;
#endif

void nccl_check(ncclResult_t status, const char *file, int line) {
    if (status != ncclSuccess) {
        printf("[NCCL ERROR] at file %s:%d:\n%s\n", file, line, ncclGetErrorString(status));
        exit(EXIT_FAILURE);
    }
}
#define ncclCheck(err) (nccl_check(err, __FILE__, __LINE__))

void mpi_check(int status, const char *file, int line) {
    if (status != MPI_SUCCESS) {
        char mpi_error[4096];
        int mpi_error_len = 0;
        assert(MPI_Error_string(status, &mpi_error[0], &mpi_error_len) == MPI_SUCCESS);
        printf("[MPI ERROR] at file %s:%d:\n%.*s\n", file, line, mpi_error_len, mpi_error);
        exit(EXIT_FAILURE);
    }
}
#define mpiCheck(err) (mpi_check(err, __FILE__, __LINE__))

#endif // MULTI_GPU

// ----------------------------------------------------------------------------
// MPI / multi-processing setup

// Parameters specific to training on multiple GPUs.
typedef struct {
    int process_rank;      // Rank of this process among all MPI processes. 0 if no multi-GPU.
    int num_processes;     // Total number of processes. 1 if no multi-GPU.
    int local_device_idx;  // This process GPU index on current machine. 0 if no multi-GPU.

    // Zero Redundancy Optimizer stage - https://fairscale.readthedocs.io/en/stable/deep_dive/oss_sdp_fsdp.html
    // 0-Disabled
    // 1-Optimizer State Sharding (OSS)
    // 2-Optimizer + Gradient State Sharding (SDP)
    // 3-Optimizer + Gradient + Horizontal Model Sharding (FSDP)
    int zero_stage;
    size_t shard_num_parameters;
    size_t shard_offset;
#ifdef MULTI_GPU
    ncclComm_t nccl_comm;  // NCCL communication primitive, used for collective multi-GPU work.
#endif
} MultiGpuConfig;

// one global variable to hold the multi-GPU configuration for this process
MultiGpuConfig multi_gpu_config;

#ifdef MULTI_GPU
// Determine which GPU this process should use.
// Processes on the same machines use different GPU indicies. Processes on other machines don't.
// Copied from NCCL examples: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/examples.html#example-2-one-device-per-process-or-thread
int multi_gpu_get_local_device_idx(int process_rank, int num_processes) {
  char hostname[1024];
  hostname[1023] = '\0';
  // All processes on the same machine will share the same hostname.
  gethostname(hostname, 1023);
  for (int i=0; i < 1024; i++) {
    if (hostname[i] == '.') {
        hostname[i] = '\0';
        break;
    }
  }
  uint64_t hostname_hash = 5381;
  for (int c = 0; hostname[c] != '\0'; c++){ hostname_hash = ((hostname_hash << 5) + hostname_hash) ^ hostname[c]; }

  // Distribute all hostname hashes to all processes.
  uint64_t* all_hostsname_hashes = (uint64_t*)malloc(num_processes * sizeof(uint64_t));
  all_hostsname_hashes[process_rank] = hostname_hash;
  mpiCheck(MPI_Allgather(MPI_IN_PLACE, 0, MPI_DATATYPE_NULL, all_hostsname_hashes, sizeof(uint64_t), MPI_BYTE, MPI_COMM_WORLD));

  // Identify which GPU we need to use.
  int local_device_idx = 0;
  for (int current_process = 0; current_process < num_processes; ++current_process) {
     if (current_process == process_rank) {
      // Found my gpu, local_device_idx now has my target GPU index.
      break;
     }
     if (all_hostsname_hashes[current_process] == all_hostsname_hashes[process_rank]) {
      // This process ID runs on the same machine, but it's not me, skip this GPU
      local_device_idx++;
     }
  }

  free(all_hostsname_hashes);
  return local_device_idx;
}
#endif

MultiGpuConfig multi_gpu_config_init(int *argc, char ***argv) {
#ifdef MULTI_GPU
    // Initialize MPI.
    MultiGpuConfig result;
    mpiCheck(MPI_Init(argc, argv));
    mpiCheck(MPI_Comm_rank(MPI_COMM_WORLD, &result.process_rank));
    mpiCheck(MPI_Comm_size(MPI_COMM_WORLD, &result.num_processes));
    result.local_device_idx = multi_gpu_get_local_device_idx(result.process_rank, result.num_processes);
    cudaCheck(cudaSetDevice(result.local_device_idx));
    ncclUniqueId nccl_id;
    if (result.process_rank == 0) {
        ncclCheck(ncclGetUniqueId(&nccl_id));
    }
    mpiCheck(MPI_Bcast((void *)&nccl_id, sizeof(nccl_id), MPI_BYTE, 0, MPI_COMM_WORLD));
    ncclCheck(ncclCommInitRank(&result.nccl_comm, result.num_processes, nccl_id, result.process_rank));
    return result;
#else
    printf("Multi-GPU support is disabled. Using a single GPU.\n");
    cudaCheck(cudaSetDevice(0));
    MultiGpuConfig result;
    result.process_rank = 0;
    result.num_processes = 1;
    result.local_device_idx = 0;
    return result;
#endif
}

void multi_gpu_config_free(const MultiGpuConfig* multi_gpu_config) {
#ifdef MULTI_GPU
    ncclCheck(ncclCommDestroy(multi_gpu_config->nccl_comm));
    mpiCheck(MPI_Finalize());
#endif
}

void multi_gpu_barrier(const MultiGpuConfig* multi_gpu_config) {
#ifdef MULTI_GPU
    if (multi_gpu_config->num_processes > 1) {
        mpiCheck(MPI_Barrier(MPI_COMM_WORLD));
    }
#endif
}

// convenience function that only prints if the rank of process is zero
void printf0(const char *format, ...) {
    if (multi_gpu_config.process_rank == 0) {
        va_list args;
        va_start(args, format);
        vprintf(format, args);
        va_end(args);
    }
}

void set_zero_configs(MultiGpuConfig* multi_gpu_config, int zero_stage, size_t total_parameters) {

    multi_gpu_config->zero_stage = 0;
    multi_gpu_config->shard_num_parameters = total_parameters;
    multi_gpu_config->shard_offset = 0;

    // Check the Zero Stage and define sharding parameters
    if (zero_stage == 0) {
        printf0("| Zero Optimization is disabled                                              |\n");
    }
    else if (zero_stage == 1) {
        if (total_parameters % multi_gpu_config->num_processes != 0) {
            printf0("| Zero Optimization is disabled, Can't equally partition parameters          |\n");
            multi_gpu_config->zero_stage = 0;
        }
        else {
            printf0("| Zero Stage1 is enabled                                                     |\n");
            multi_gpu_config->zero_stage = 1;
            multi_gpu_config->shard_num_parameters = total_parameters / multi_gpu_config->num_processes;
            multi_gpu_config->shard_offset = multi_gpu_config->process_rank * multi_gpu_config->shard_num_parameters;
        }
    }
    else{
        printf0("| Disabling Zero Optimization, Zero Stage2 and Stage3 are not yet supported  |\n");
        multi_gpu_config->zero_stage = 0;
    }
}

// ----------------------------------------------------------------------------
// GPT-2 model definition

typedef struct {
    int max_seq_len; // max sequence length, e.g. 1024
    int vocab_size; // vocab size, e.g. 50257
    int padded_vocab_size; // padded to e.g. %128==0, 50304
    int num_layers; // number of layers, e.g. 12
    int num_heads; // number of heads in attention, e.g. 12
    int channels; // number of channels, e.g. 768
} GPT2Config;

// the parameters of the model
constexpr const int NUM_PARAMETER_TENSORS = 16;
typedef struct {
    floatX* wte; // (V, C)
    floatX* wpe; // (maxT, C)
    floatX* ln1w; // (L, C)
    floatX* ln1b; // (L, C)
    floatX* qkvw; // (L, 3*C, C)
    floatX* qkvb; // (L, 3*C)
    floatX* attprojw; // (L, C, C)
    floatX* attprojb; // (L, C)
    floatX* ln2w; // (L, C)
    floatX* ln2b; // (L, C)
    floatX* fcw; // (L, 4*C, C)
    floatX* fcb; // (L, 4*C)
    floatX* fcprojw; // (L, C, 4*C)
    floatX* fcprojb; // (L, C)
    floatX* lnfw; // (C)
    floatX* lnfb; // (C)
} ParameterTensors;
static_assert(sizeof(ParameterTensors) == NUM_PARAMETER_TENSORS * sizeof(void*), "Inconsistent sizes!");

void fill_in_parameter_sizes(size_t* param_sizes, size_t* param_sizeof, GPT2Config config) {
    size_t Vp = config.padded_vocab_size;
    size_t C = config.channels;
    size_t maxT = config.max_seq_len;
    size_t L = config.num_layers;
    param_sizes[0] = Vp * C; // wte
    param_sizes[1] = maxT * C; // wpe
    param_sizes[2] = L * C; // ln1w
    param_sizes[3] = L * C; // ln1b
    param_sizes[4] = L * (3 * C) * C; // qkvw
    param_sizes[5] = L * (3 * C); // qkvb
    param_sizes[6] = L * C * C; // attprojw
    param_sizes[7] = L * C; // attprojb
    param_sizes[8] = L * C; // ln2w
    param_sizes[9] = L * C; // ln2b
    param_sizes[10] = L * (4 * C) * C; // fcw
    param_sizes[11] = L * (4 * C); // fcb
    param_sizes[12] = L * C * (4 * C); // fcprojw
    param_sizes[13] = L * C; // fcprojb
    param_sizes[14] = C; // lnfw
    param_sizes[15] = C; // lnfb

    // populate the parameter sizes in bytes (all the same for now, keeping for future use)
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        param_sizeof[i] = sizeof(floatX);
    }
}

// allocate memory for the parameters and point the individual tensors to the right places
void* malloc_and_point_parameters(ParameterTensors* params, size_t* param_elements, size_t *param_sizeof) {
    // calculate the total number of parameters and bytes across all tensors
    size_t num_parameters_bytes = 0;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        num_parameters_bytes += param_elements[i] * param_sizeof[i];
    }
    // malloc all parameters all at once on the device
    void* params_memory;
    cudaCheck(cudaMalloc((void**)&params_memory, num_parameters_bytes));
    // assign all the tensors their place in the array
    floatX** ptrs[] = {
        &params->wte, &params->wpe, &params->ln1w, &params->ln1b, &params->qkvw, &params->qkvb,
        &params->attprojw, &params->attprojb, &params->ln2w, &params->ln2b, &params->fcw, &params->fcb,
        &params->fcprojw, &params->fcprojb, &params->lnfw, &params->lnfb
    };
    char* params_memory_iterator = (char*)params_memory;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        *(ptrs[i]) = (floatX*)params_memory_iterator;
        params_memory_iterator += param_elements[i] * param_sizeof[i];
    }
    return params_memory;
}

#define NUM_ACTIVATION_TENSORS 21
typedef struct {
    floatX* encoded; // (B, T, C)
    floatX* ln1; // (L, B, T, C)
    floatX* ln1_mean; // (L, B, T)
    floatX* ln1_rstd; // (L, B, T)
    floatX* atty; // (L, B, T, C)
    floatX* att; // (L, B, NH, T, T) (smaller with cuDNN)
    floatX* attproj; // (L, B, T, C)
    floatX* residual2; // (L, B, T, C)
    floatX* ln2; // (L, B, T, C)
    floatX* ln2_mean; // (L, B, T)
    floatX* ln2_rstd; // (L, B, T)
    floatX* fch; // (L, B, T, 4*C)
    floatX* fch_gelu; // (L, B, T, 4*C)
    floatX* fcproj; // (L, B, T, C)
    floatX* residual3; // (L, B, T, C)
    floatX* lnf; // (B, T, C);   if LN recomputation is enabled (-r 2 and above), will be used for _all_ layernorms
    floatX* lnf_mean; // (B, T)
    floatX* lnf_rstd; // (B, T)
    floatX* losses; // (B, T)
    // adding these two compared to the CPU .c code, needed for attention kernel as buffers
    floatX* qkvr; // (L, B, T, 3*C)
    // in inference mode, this buffer will store the logits
    // in training mode, this buffer will contain the *gradients* of the logits.
    // during the processing of transformer blocks, we will also use this as a
    // general scratchpad buffer. Allocation is made large enough to hold (B, T, 3C),
    // (B, NH, T, T), and (B, T, V) shaped tensors.
    floatX* output;
} ActivationTensors;

void fill_in_activation_sizes(size_t* act_sizes, size_t B, size_t T, GPT2Config config, int recompute) {
    size_t Vp = config.padded_vocab_size;
    size_t L = config.num_layers;
    size_t NH = config.num_heads;
    size_t C = config.channels;
    act_sizes[0] = B * T * C; // encoded
    // if recompute >= 1 then we will recompute the layernorm forward activation during backward pass
    act_sizes[1] = (recompute < 2) ? L * B * T * C : 0; // ln1
    act_sizes[2] = L * B * T; // ln1_mean
    act_sizes[3] = L * B * T; // ln1_rstd
    act_sizes[4] = L * B * T * C; // atty
    #ifdef ENABLE_CUDNN
    // FP32 stats tensor for cuDNN to be passed to backward pass
    act_sizes[5] = L * B * NH * T * (sizeof(float) / sizeof(floatX));
    #else
    act_sizes[5] = L * B * NH * T * T; // att
    #endif
    act_sizes[6] = L * B * T * C; // attproj
    act_sizes[7] = L * B * T * C; // residual2
    // if recompute >= 1 then we will recompute the layernorm forward activation during backward pass
    act_sizes[8] = (recompute < 2) ? L * B * T * C : 0; // ln2
    act_sizes[9] = L * B * T; // ln2_mean
    act_sizes[10] = L * B * T; // ln2_rstd
    act_sizes[11] = L * B * T * 4*C; // fch
    // if recompute >= 1 then we will recompute gelu_forward during backward and use this as scratch buffer
    act_sizes[12] = (recompute < 1) ? L * B * T * 4*C : B * T * 4*C;
    act_sizes[13] = L * B * T * C; // fcproj
    act_sizes[14] = L * B * T * C; // residual3
    act_sizes[15] = B * T * C; // lnf
    act_sizes[16] = B * T; // lnf_mean
    act_sizes[17] = B * T; // lnf_rstd
    act_sizes[18] = B * T; // losses
    act_sizes[19] = L * B * T * 3*C; // qkvr
    act_sizes[20] = B * T * max(3*C, max(NH*T, Vp)); // output / scratch
}

// Backward pass is conceptually quite different from forward, because we can discard
// the activations of a layer as soon as we're done with it. This lets us aggressively
// reuse memory, so that we need far fewer tensors for backward state.
#ifdef ENABLE_CUDNN
#define NUM_BACKWARD_TENSORS 2
#else
#define NUM_BACKWARD_TENSORS 3
#endif

typedef struct {
    floatX* bt4c; // (B, T, 4*C)
    floatX* residual3; // (B, T, C)
    #ifndef ENABLE_CUDNN
    floatX* preatt; // (B, NH, T, T)
    #endif
} GradActTensors;

void fill_in_grad_act_sizes(size_t* act_sizes, size_t B, size_t T, GPT2Config config) {
    size_t C = config.channels;
    act_sizes[0] = B * T * 4 * C; // bt4c
    act_sizes[1] = B * T * C; // residual3

    #ifndef ENABLE_CUDNN
    size_t NH = config.num_heads;
    act_sizes[2] = B * NH * T * T; // preatt
    #endif
}

void* malloc_and_point(floatX** targets[], const size_t* act_sizes, size_t n) {
    size_t num_activations = 0;
    for (size_t i = 0; i < n; i++) {
        num_activations += act_sizes[i];
    }
    void* acts_memory;
    cudaCheck(cudaMalloc((void**)&acts_memory, num_activations * sizeof(floatX)));
    char* acts_memory_iterator = (char*)acts_memory;
    for (size_t i = 0; i < n; i++) {
        // extra protection so we don't accidentally use an empty buffer
        if(act_sizes[i] == 0) {
            *(targets[i]) = NULL;
        }else {
            *(targets[i]) = (floatX*) acts_memory_iterator;
            acts_memory_iterator += act_sizes[i] * sizeof(floatX);
        }
    }
    return acts_memory;
}

void* malloc_and_point_activations(ActivationTensors* acts, const size_t* act_sizes) {
    floatX** ptrs[] = {
        &acts->encoded, &acts->ln1, &acts->ln1_mean, &acts->ln1_rstd, &acts->atty,
        &acts->att, &acts->attproj, &acts->residual2, &acts->ln2, &acts->ln2_mean,
        &acts->ln2_rstd, &acts->fch, &acts->fch_gelu, &acts->fcproj, &acts->residual3, &acts->lnf,
        &acts->lnf_mean, &acts->lnf_rstd, &acts->losses, &acts->qkvr, &acts->output
    };
    return malloc_and_point(ptrs, act_sizes, NUM_ACTIVATION_TENSORS);
}

void* malloc_and_point_backward(GradActTensors* acts, const size_t* act_sizes) {
    floatX** ptrs[] = {
        &acts->bt4c, &acts->residual3,
        #ifndef ENABLE_CUDNN
        &acts->preatt,
        #endif
    };
    return malloc_and_point(ptrs, act_sizes, NUM_BACKWARD_TENSORS);
}

typedef struct {
    GPT2Config config;
    // the weights of the model, and their sizes
    ParameterTensors params;
    size_t param_elements[NUM_PARAMETER_TENSORS];
    size_t param_sizeof[NUM_PARAMETER_TENSORS];
    void* params_memory;
    size_t num_parameters;
    size_t num_parameters_bytes;
    // gradients of the weights
    ParameterTensors grads;
    void* grads_memory;
    // buffers for the AdamW optimizer
    float* m_memory;
    float* v_memory;
    float* master_weights;     // is NULL unless fp32 weights is enabled.
    // the activations of the model, and their sizes
    ActivationTensors acts;
    size_t act_sizes[NUM_ACTIVATION_TENSORS];
    void* acts_memory;
    size_t num_activations;
    // gradients of the activations
    GradActTensors grads_acts;
    size_t num_grad_acts;
    void* grads_acts_memory;
    // other run state configuration
    int batch_size; // the batch size (B) of current forward pass
    int seq_len; // the sequence length (T) of current forward pass
    int* inputs; // the input tokens for the current forward pass
    int* targets; // the target tokens for the current forward pass
    float mean_loss; // after a forward pass with targets, will be populated with the mean loss
    float accumulated_mean_loss; // Mean loss after aggregating it on all GPUs
    floatX* cpu_losses; // CPU buffer to copy the losses to, allocated with cudaMallocHost
    float* cpu_losses_fp32; // same but fp32
    unsigned long long rng_state; // the RNG state for seeding stochastic rounding etc.
    int use_master_weights; // keep master weights copy in float for optim update? 0|1
    int recompute; // recompute gelu | layernorm forward during model backward? 0|1|2
    // todo - if other functions need cpu scratch buffers in the future, reuse as generic scratch?
    int* workload_indices; // encoder_backward, B*T*num_c_groups (int)
    int4* bucket_info;     // encoder_backward, B*T*num_c_groups (int4) - size for worst case
} GPT2;

void gpt2_init_common(GPT2 *model) {
    // common inits outside of the model weights
    // the weights are initialized either in:
    // - gpt2_build_from_checkpoint() if loading from a checkpoint
    // - gpt2_build_from_random() if starting from scratch
    // memory lazily initialized in forward()
    model->acts_memory = NULL;
    model->inputs = NULL;
    model->targets = NULL;
    model->cpu_losses = NULL;
    model->cpu_losses_fp32 = NULL;
    // the B,T params are determined and set, fixed on first batch in forward()
    model->batch_size = 0;
    model->seq_len = 0;
    model->mean_loss = -1.0f; // -1.0f designates no loss, set at end of forward()
    // memory lazily initialized in backward()
    model->grads_memory = NULL;
    model->grads_acts_memory = NULL;
    model->workload_indices = NULL; // on cpu, for encoder_backward
    model->bucket_info = NULL; // on cpu, for encoder_backward
    // memory lazily initialized in update()
    model->m_memory = NULL;
    model->v_memory = NULL;
    model->master_weights = NULL;
    // other default settings
    model->rng_state = 13371337; // used in stochastic rounding
    model->use_master_weights = 1; // safe default: do keep master weights in fp32
    model->recompute = 1; // good default: recompute gelu but not layernorm
}

void gpt2_write_to_checkpoint(GPT2 *model, const char* checkpoint_path) {
    // write the model to a checkpoint file
    printf0("Writing model to %s\n", checkpoint_path);
    FILE *model_file = fopenCheck(checkpoint_path, "wb");
    // write the header first
    int model_header[256];
    memset(model_header, 0, sizeof(model_header));
    model_header[0] = 20240326; // magic number
    assert(PRECISION_MODE == PRECISION_FP32 || PRECISION_MODE == PRECISION_BF16);
    model_header[1] = PRECISION_MODE == PRECISION_FP32 ? 3 : 5; // version
    model_header[2] = model->config.max_seq_len;
    model_header[3] = model->config.vocab_size;
    model_header[4] = model->config.num_layers;
    model_header[5] = model->config.num_heads;
    model_header[6] = model->config.channels;
    model_header[7] = model->config.padded_vocab_size;
    fwrite(model_header, sizeof(int), 256, model_file);
    // write the parameters
    void* params_memory_cpu = (void*)mallocCheck(model->num_parameters_bytes);
    cudaCheck(cudaMemcpy(params_memory_cpu, model->params_memory, model->num_parameters_bytes, cudaMemcpyDeviceToHost));
    fwrite(params_memory_cpu, 1, model->num_parameters_bytes, model_file);
    free(params_memory_cpu);
    // close file, we're done
    fcloseCheck(model_file);
}

void gpt2_build_from_checkpoint(GPT2 *model, const char* checkpoint_path) {

    if (PRECISION_MODE == PRECISION_FP16) {
        // TODO for later perhaps, would require us dynamically converting the
        // model weights from fp32 to fp16 online, here in this function, or writing
        // the fp16 weights directly from Python, which we only do for fp32/bf16 atm.
        fprintf(stderr, "build_from_checkpoint() does not support fp16 right now.\n");
        exit(EXIT_FAILURE);
    }

    // read in model from a checkpoint file
    FILE *model_file = fopenCheck(checkpoint_path, "rb");
    int model_header[256];
    freadCheck(model_header, sizeof(int), 256, model_file);
    if (model_header[0] != 20240326) { printf("Bad magic model file\n"); exit(EXIT_FAILURE); }
    int version = model_header[1];
    if (!(version == 3 || version == 5)) {
        // 3 = fp32, padded vocab
        // 5 = bf16, padded vocab, layernorms also in bf16
        fprintf(stderr, "Bad version in model file\n");
        fprintf(stderr, "---> HINT: try to re-run `python train_gpt2.py`\n");
        exit(EXIT_FAILURE);
    }
    if (PRECISION_MODE == PRECISION_BF16 && version != 5) {
        fprintf(stderr, "Precision is configured as BF16 but model at %s is not.\n", checkpoint_path);
        fprintf(stderr, "---> HINT: are you sure you're loading a _bf16.bin file?\n");
        exit(EXIT_FAILURE);
    }
    if (PRECISION_MODE == PRECISION_FP32 && version != 3) {
        fprintf(stderr, "Precision is configured as FP32 but model at %s is not.\n", checkpoint_path);
        fprintf(stderr, "---> HINT: to turn on FP32 you have to compile like: `make train_gpt2cu PRECISION=FP32`\n");
        fprintf(stderr, "---> HINT: are you sure you're loading a .bin file without any _bf16 in the name?\n");
        exit(EXIT_FAILURE);
    }

    // read in hyperparameters
    model->config.max_seq_len = model_header[2];
    model->config.vocab_size = model_header[3];
    model->config.num_layers = model_header[4];
    model->config.num_heads = model_header[5];
    model->config.channels = model_header[6];
    model->config.padded_vocab_size = model_header[7];

    // allocate space for all the parameters and read them in
    fill_in_parameter_sizes(model->param_elements, model->param_sizeof, model->config);

    model->num_parameters = 0;
    model->num_parameters_bytes = 0;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        model->num_parameters += model->param_elements[i];
        model->num_parameters_bytes += model->param_elements[i] * model->param_sizeof[i];
    }

    // create memory for model parameters on the device
    model->params_memory = malloc_and_point_parameters(&model->params, model->param_elements, model->param_sizeof);

    // read in all the parameters from file and copy them to device
    void* params_memory_cpu = (void*)mallocCheck(model->num_parameters_bytes);
    freadCheck(params_memory_cpu, 1, model->num_parameters_bytes, model_file);
    cudaCheck(cudaMemcpy(model->params_memory, params_memory_cpu, model->num_parameters_bytes, cudaMemcpyHostToDevice));
    free(params_memory_cpu);
    fcloseCheck(model_file);

    gpt2_init_common(model);
    // only return from this function once we are certain the params are ready on the GPU
    cudaCheck(cudaDeviceSynchronize());
}

void gpt2_build_from_random(GPT2 *model, int depth) {
    // init random (training from scratch)

    // parameterize the size of gpt2 based only on the depth of the model (num_layers)
    model->config.num_layers = depth;
    // follows GPT-2 sizes
    int channels, num_heads;
    if      (depth == 6)  { channels = 384; num_heads = 6; } // gpt2-tiny (30M)
    else if (depth == 12) { channels = 768; num_heads = 12; } // gpt2 (124M)
    else if (depth == 24) { channels = 1024; num_heads = 16; } // gpt2-medium (350M)
    else if (depth == 36) { channels = 1280; num_heads = 20; } // gpt2-large (774M)
    else if (depth == 48) { channels = 1600; num_heads = 25; } // gpt2-xl (1558M)
    else { fprintf(stderr, "Unsupported depth for now\n"); exit(EXIT_FAILURE); }
    model->config.channels = channels;
    model->config.num_heads = num_heads;
    model->config.max_seq_len = 1024;
    model->config.vocab_size = 50257;
    model->config.padded_vocab_size = 50304; // padded to 128

    // fill in all the parameter tensor dimensions and types
    fill_in_parameter_sizes(model->param_elements, model->param_sizeof, model->config);
    model->num_parameters = 0;
    model->num_parameters_bytes = 0;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        model->num_parameters += model->param_elements[i];
        model->num_parameters_bytes += model->param_elements[i] * model->param_sizeof[i];
    }
    // create memory for model parameters on the device
    model->params_memory = malloc_and_point_parameters(&model->params, model->param_elements, model->param_sizeof);

    // allocate and random init the memory for all the parameters with GPT-2 schema
    // weights ~N(0, 0.02), biases 0, c_proj weights ~N(0, 0.02/(2*L)**0.5)
    // NOTE: assuming all parameters are of the type floatX, could be relaxed later
    mt19937_state init_rng;
    manual_seed(&init_rng, 42);
    floatX* params_memory_cpu = (floatX*)mallocCheck(model->num_parameters_bytes);
    memset(params_memory_cpu, 0, model->num_parameters_bytes);
    // fill in all the weights with random values
    float residual_scale = 1.0f / sqrtf(2.0f * model->config.num_layers);
    // we have to init all these tensors exactly in the order that PyTorch initializes them
    // so that we can match them up and get correctness and exactly the same initial conditions
    size_t L = model->config.num_layers;
    size_t offset = 0;
    for (int l = 0; l < L; l++) {
        offset = 0;
        for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
            // the layernorm parameters are all initialized to 1
            if (l == 0 && (i == 2 || i == 8 || i == 14)) { // only at l = 0 to init these just once
                for (size_t j = 0; j < model->param_elements[i]; j++) {
                    params_memory_cpu[offset + j] = 1.0f;
                }
            }
            // weights tensors are handled here
            if ((l == 0 && (i == 0 || i == 1)) // only at l = 0, init the wte and wpe tensors
              || i == 4 || i == 6 || i == 10 || i == 12) {
                int n = model->param_elements[i];
                size_t layer_offset = 0;
                if (i == 0) {
                    // for wte tensor (padded vocab) override to init V instead of Vp rows
                    n = model->config.vocab_size * model->config.channels;
                }
                if (i == 4 || i == 6 || i == 10 || i == 12) {
                    // weight tensors, we are only initializing layer l
                    assert(n % L == 0);
                    n = n / L;
                    layer_offset = l * n;
                }
                // in GPT-2, the projections back into the residual stream are additionally
                // scaled by 1/sqrt(2*L) for training stability
                float scale = (i == 6 || i == 12) ? 0.02f * residual_scale : 0.02f;
                // okay let's draw the random numbers and write them
                float *fp32_buffer = (float*)mallocCheck(n * sizeof(float));
                normal_(fp32_buffer, n, 0.0f, scale, &init_rng);
                for (size_t j = 0; j < n; j++) {
                    params_memory_cpu[offset + layer_offset + j] = (floatX)fp32_buffer[j];
                }
                free(fp32_buffer);
            }
            offset += model->param_elements[i];
        }
    }

    // copy them to GPU
    cudaCheck(cudaMemcpy(model->params_memory, params_memory_cpu, model->num_parameters_bytes, cudaMemcpyHostToDevice));
    free(params_memory_cpu);

    gpt2_init_common(model);
}

void gpt2_forward(GPT2 *model, const int* inputs, const int* targets, size_t B, size_t T, int grad_accum_steps=1) {
    // right now, this function is fully synchronous with the host
    NVTX_RANGE_FN();
    // targets are optional and could be NULL
    // in this function we must be careful and use size_t instead of int, otherwise
    // we could overflow int. E.g. l * B * NH * T * T overflows int at B 16.

    // ensure the model was initialized or error out
    if (model->params_memory == NULL) {
        printf("Error: model was not initialized properly.\n");
        exit(EXIT_FAILURE);
    }

    // convenience parameters
    const size_t V = model->config.vocab_size;
    const size_t Vp = model->config.padded_vocab_size;
    const size_t L = model->config.num_layers;
    const size_t NH = model->config.num_heads;
    const size_t C = model->config.channels;

    // allocate space for all the activations if needed (done here, lazily)
    if(model->acts_memory == NULL) {
        NvtxRange rng("InitActs");
        // record the current B,T as well
        model->batch_size = B;
        model->seq_len = T;
        // allocate the space
        fill_in_activation_sizes(model->act_sizes, B, T, model->config, model->recompute);
        size_t num_activations = 0;
        for (size_t i = 0; i < NUM_ACTIVATION_TENSORS; i++) {
            num_activations += model->act_sizes[i];
        }
        model->num_activations = num_activations;
        printf0("allocating %d MiB for activations\n", (int)round(num_activations * sizeof(floatX) / (1024 * 1024)));
        model->acts_memory = malloc_and_point_activations(&model->acts, model->act_sizes);
        // also create memory for caching inputs and targets
        cudaCheck(cudaMalloc((void**)&model->inputs, B * T * sizeof(int)));
        cudaCheck(cudaMalloc((void**)&model->targets, B * T * sizeof(int)));
        cudaCheck(cudaMallocHost((void**)&model->cpu_losses, B * T * sizeof(floatX)));
        cudaCheck(cudaMallocHost((void**)&model->cpu_losses_fp32, B * T * sizeof(float)));
    } else {
        // validate B,T is consistent with how we've allocated the memory before
        // in principle we could get more clever here in the future, for now this is safest
        if (B != model->batch_size || T != model->seq_len) {
            printf("Model: B=%d T=%d, Desired: B=%d T=%d\n", model->batch_size, model->seq_len, (int)B, (int)T);
            exit(EXIT_FAILURE);
        }
    }

    // copy inputs/targets to the model
    cudaCheck(cudaMemcpy(model->inputs, inputs, B * T * sizeof(int), cudaMemcpyHostToDevice));
    if (targets != NULL) {
        cudaCheck(cudaMemcpy(model->targets, targets, B * T * sizeof(int), cudaMemcpyHostToDevice));
    }

    // validate inputs, all indices must be in the range [0, V)
    // we can do this while the copies are already underway
    for(int i = 0; i < B * T; i++) {
        assert(0 <= inputs[i] && inputs[i] < V);
        if (targets != NULL) {
            assert(0 <= targets[i] && targets[i] < V);
        }
    }

    // forward pass
    ParameterTensors params = model->params; // for brevity
    ActivationTensors acts = model->acts;
    encoder_forward(acts.encoded, model->inputs, params.wte, params.wpe, B, T, C, main_stream); // encoding goes into residual[0]

    // first layernorm isn't fused
    layernorm_forward((model->recompute < 2) ? acts.ln1 : acts.lnf, acts.ln1_mean, acts.ln1_rstd, acts.encoded, params.ln1w, params.ln1b, B, T, C, main_stream);

    for (int l = 0; l < L; l++) {
        NvtxRange layer_range("Layer", l);

        floatX* residual = l == 0 ? acts.encoded : acts.residual3 + (l-1) * B * T * C;

        // get the pointers of the weights for this layer
        floatX* l_qkvw = params.qkvw + l * 3*C * C;
        floatX* l_qkvb = params.qkvb + l * 3*C;
        floatX* l_attprojw = params.attprojw + l * C * C;
        floatX* l_attprojb = params.attprojb + l * C;
        floatX* l_ln2w = params.ln2w + l * C;
        floatX* l_ln2b = params.ln2b + l * C;
        floatX* l_fcw = params.fcw + l * 4*C * C;
        floatX* l_fcb = params.fcb + l * 4*C;
        floatX* l_fcprojw = params.fcprojw + l * C * 4*C;
        floatX* l_fcprojb = params.fcprojb + l * C;

        // get the pointers of the activations for this layer
        floatX* l_ln1 = (model->recompute < 2) ? acts.ln1 + l * B * T * C : acts.lnf;
        floatX* l_qkvr = acts.qkvr + l * B * T * 3*C;
        floatX* l_atty = acts.atty + l * B * T * C;
        floatX* l_attproj = acts.attproj + l * B * T * C;
        floatX* l_residual2 = acts.residual2 + l * B * T * C;
        floatX* l_ln2 = (model->recompute < 2) ? acts.ln2 + l * B * T * C : acts.lnf;
        floatX* l_ln2_mean = acts.ln2_mean + l * B * T;
        floatX* l_ln2_rstd = acts.ln2_rstd + l * B * T;
        floatX* l_fch = acts.fch + l * B * T * 4*C;
        // reuse the same activation buffer at each layer, as we'll re-compute the gelu during backward
        // very useful because we dramatically reduce VRAM usage, and may be able to fit larger batch size
        floatX* l_fch_gelu = (model->recompute < 1) ? acts.fch_gelu + l * B * T * 4*C : acts.fch_gelu;
        floatX* l_fcproj = acts.fcproj + l * B * T * C;
        floatX* l_residual3 = acts.residual3 + l * B * T * C;

        // now do the forward pass
        #ifdef ENABLE_CUDNN
        float* l_att = (float*)acts.att + l * B * NH * T; // cuDNN needs a smaller FP32 tensor
        matmul_forward_cublaslt(l_qkvr, l_ln1, l_qkvw, l_qkvb, B, T, C, 3*C, main_stream);
        attention_forward_cudnn(l_atty, (float*)l_att, l_qkvr, B, T, NH, C, main_stream);
        #else
        floatX* l_att = acts.att + l * B * NH * T * T;
        // these are only needed as scratchpads for the forward pass, but
        // need not be stored for backward
        floatX* scratch = (floatX*)acts.output;
        matmul_forward_cublaslt(scratch, l_ln1, l_qkvw, l_qkvb, B, T, C, 3*C, main_stream);
        attention_forward(l_atty, l_qkvr, l_att, scratch, B, T, C, NH, main_stream);
        #endif

        matmul_forward_cublaslt(l_attproj, l_atty, l_attprojw, l_attprojb, B, T, C, C, main_stream);
        fused_residual_forward5(l_residual2, l_ln2, l_ln2_mean, l_ln2_rstd, residual, l_attproj, l_ln2w, l_ln2b, B*T, C, main_stream);
        matmul_forward_cublaslt(l_fch, l_ln2, l_fcw, l_fcb, B, T, C, 4*C, main_stream);
        gelu_forward(l_fch_gelu, l_fch, B*T*4*C, main_stream);
        matmul_forward_cublaslt(l_fcproj, l_fch_gelu, l_fcprojw, l_fcprojb, B, T, 4*C, C, main_stream);

        // OK, fusion across blocks.
        if(l+1 != L) {
            floatX* l_ln1 = (model->recompute < 2) ? acts.ln1 + (l + 1) * B * T * C : acts.lnf;
            floatX* l_ln1_mean = acts.ln1_mean + (l + 1) * B * T;
            floatX* l_ln1_rstd = acts.ln1_rstd + (l + 1) * B * T;
            const floatX* l_ln1w = params.ln1w + (l + 1) * C;
            const floatX* l_ln1b = params.ln1b + (l + 1) * C;
            fused_residual_forward5(l_residual3, l_ln1, l_ln1_mean, l_ln1_rstd, l_residual2, l_fcproj, l_ln1w, l_ln1b,
                                    B * T, C, main_stream);
        } else {
            fused_residual_forward5(l_residual3, acts.lnf, acts.lnf_mean, acts.lnf_rstd, l_residual2, l_fcproj,
                                    params.lnfw, params.lnfb,
                                    B * T, C, main_stream);
        }
    }

    matmul_forward_cublaslt(acts.output, acts.lnf, params.wte, NULL, B, T, C, Vp, main_stream);

    // also forward the cross-entropy loss function if we have the targets
    if (targets != NULL) {
        NvtxRange classifier_and_loss_range("classifier_and_loss");
        // fused classifier: does the forward pass and first part of the backward pass
        const float dloss = 1.0f / (B * T * grad_accum_steps); // results in the uniform average loss over all elements
        fused_classifier(acts.output, acts.losses, dloss, model->targets, B, T, V, Vp, main_stream);
        // for convenience also evaluate the mean loss (TODO re-think this compute+sync point)
        cudaCheck(cudaMemcpy(model->cpu_losses, acts.losses, B * T * sizeof(floatX), cudaMemcpyDeviceToHost));
        float mean_loss = 0.0f;
        for (int i = 0; i < B*T; i++) {
            float loss = (float)(model->cpu_losses[i]);
            model->cpu_losses_fp32[i] = loss;
            mean_loss += loss;
        }
        mean_loss /= B*T*grad_accum_steps;
        model->mean_loss = mean_loss;
    } else {
        // if we don't have targets, we don't have loss
        model->mean_loss = -1.0f;
    }
    cudaCheck(cudaDeviceSynchronize());
}

void gpt2_zero_grad(GPT2 *model) {
    NVTX_RANGE_FN();
    if (model->grads_memory != NULL) {
        cudaCheck(cudaMemset(model->grads_memory, 0, model->num_parameters * sizeof(floatX)));
    }
    cudaCheck(cudaDeviceSynchronize());
}

void gpt2_backward(GPT2 *model, int* inputs) {
    NVTX_RANGE_FN();
    // double check we forwarded previously, with targets
    if (model->mean_loss == -1.0f) {
        printf("Error: must forward with targets before backward\n");
        exit(EXIT_FAILURE);
    }

    // lazily allocate the memory for gradients of the weights and activations, if needed
    if (model->grads_memory == NULL) {
        NvtxRange rng("InitGrads");
        // allocate buffers for weight gradients
        printf0("allocating %d MiB for parameter gradients\n", (int)round(model->num_parameters * sizeof(floatX) / (1024 * 1024)));
        model->grads_memory = malloc_and_point_parameters(&model->grads, model->param_elements, model->param_sizeof);
        // we're going to be clever for the activations backward pass. we don't need to exactly
        // mirror the forward pass activations and we will save memory.
        size_t bw_act_sizes[NUM_BACKWARD_TENSORS];
        fill_in_grad_act_sizes(bw_act_sizes, model->batch_size, model->seq_len, model->config);
        // count up and allocate the space
        model->num_grad_acts = 0;
        for (size_t i = 0; i < NUM_BACKWARD_TENSORS; i++) {
            model->num_grad_acts += bw_act_sizes[i];
        }
        printf0("allocating %d MiB for activation gradients\n", (int)round(model->num_grad_acts * sizeof(floatX) / (1024 * 1024)));
        model->grads_acts_memory = malloc_and_point_backward(&model->grads_acts, bw_act_sizes);
        // init gradients of parameters and activations to zero
        gpt2_zero_grad(model);
        // initialise cpu scratch buffers for encoder backward
        size_t num_c_groups = CEIL_DIV(model->config.channels, (WARP_SIZE * x128::size));
        assert((size_t)(model->batch_size * model->seq_len) * num_c_groups < (1ULL<<31ULL)); // todo - maybe an issue for llama3-400B(?)
        model->workload_indices = (int*)mallocCheck(sizeof(int) * model->batch_size * model->seq_len * num_c_groups);
        model->bucket_info = (int4*)mallocCheck(sizeof(int4) * model->batch_size * model->seq_len * num_c_groups);
    }

    // convenience shortcuts, size_t instead of int so that pointer arithmetics don't overflow
    const size_t B = model->batch_size;
    const size_t T = model->seq_len;
    const size_t Vp = model->config.padded_vocab_size;
    const size_t L = model->config.num_layers;
    const size_t NH = model->config.num_heads;
    const size_t C = model->config.channels;

    // backward pass: go in the reverse order of the forward pass, and call backward() functions
    ParameterTensors params = model->params; // for brevity
    ParameterTensors grads = model->grads;
    ActivationTensors acts = model->acts;
    GradActTensors grads_acts = model->grads_acts;

    // reset residual stream gradients (put here to work with gradient accumulation)
    cudaCheck(cudaMemset(model->grads_acts.residual3, 0, B * T * C * sizeof(floatX)));

    // re-use the output buffer of the forward pass as a scratchpad during backward pass
    float*  scratchF = (float*)acts.output;
    floatX* scratchX = (floatX*)acts.output;

    // we kick off the chain rule by filling in dlosses with 1.0f/(B*T)
    // this was done in the fused classifier kernel as last step of forward pass
    // technically that is a small, inline backward() pass of calculating
    // total, final loss as the mean over all losses over all (B,T) positions in the batch
    // next: backward the classifier matmul
    matmul_backward(grads_acts.bt4c, grads.wte, NULL, acts.output, acts.lnf, params.wte, NULL, B, T, C, Vp, main_stream);
    // backward the final layernorm
    floatX* residual = acts.residual3 + (L-1) * B * T * C; // last residual is in residual3
    floatX* dresidual = (floatX*)grads_acts.residual3; // the main buffer holding the gradient in the backward pass
    layernorm_backward(dresidual, grads.lnfw, grads.lnfb, scratchF, grads_acts.bt4c, residual, params.lnfw, acts.lnf_mean, acts.lnf_rstd, B, T, C, main_stream);

    // from this point on, we no longer need the values stored in the last residual, so we can reuse that memory as generic
    // scratch for backward computations
    floatX* dl_btc = residual;

    // now backward all the layers
    for (int l = L-1; l >= 0; l--) {
        NvtxRange layer_range("Layer", l);

        residual = l == 0 ? acts.encoded : acts.residual3 + (l-1) * B * T * C;

        // get the pointers of the weights for this layer
        floatX* l_ln1w = params.ln1w + l * C;
        floatX* l_ln1b = params.ln1b + l * C;
        floatX* l_qkvw = params.qkvw + l * 3*C * C;
        floatX* l_attprojw = params.attprojw + l * C * C;
        floatX* l_ln2w = params.ln2w + l * C;
        floatX* l_ln2b = params.ln2b + l * C;
        floatX* l_fcw = params.fcw + l * 4*C * C;
        floatX* l_fcprojw = params.fcprojw + l * C * 4*C;
        // get the pointers of the gradients of the weights for this layer
        floatX* dl_ln1w = grads.ln1w + l * C;
        floatX* dl_ln1b = grads.ln1b + l * C;
        floatX* dl_qkvw = grads.qkvw + l * 3*C * C;
        floatX* dl_qkvb = grads.qkvb + l * 3*C;
        floatX* dl_attprojw = grads.attprojw + l * C * C;
        floatX* dl_attprojb = grads.attprojb + l * C;
        floatX* dl_ln2w = grads.ln2w + l * C;
        floatX* dl_ln2b = grads.ln2b + l * C;
        floatX* dl_fcw = grads.fcw + l * 4*C * C;
        floatX* dl_fcb = grads.fcb + l * 4*C;
        floatX* dl_fcprojw = grads.fcprojw + l * C * 4*C;
        floatX* dl_fcprojb = grads.fcprojb + l * C;
        // get the pointers of the activations for this layer
        floatX* l_ln1 = (model->recompute < 2) ? acts.ln1 + l * B * T * C : acts.lnf;
        floatX* l_ln1_mean = acts.ln1_mean + l * B * T;
        floatX* l_ln1_rstd = acts.ln1_rstd + l * B * T;
        floatX* l_qkvr = acts.qkvr + l * B * T * 3*C;
        floatX* l_atty = acts.atty + l * B * T * C;
        floatX* l_residual2 = acts.residual2 + l * B * T * C;
        floatX* l_ln2 = (model->recompute < 2) ? acts.ln2 + l * B * T * C : acts.lnf;
        floatX* l_ln2_mean = acts.ln2_mean + l * B * T;
        floatX* l_ln2_rstd = acts.ln2_rstd + l * B * T;
        floatX* l_fch = acts.fch + l * B * T * 4*C;
        floatX* l_fch_gelu = (model->recompute < 1) ? acts.fch_gelu + l * B * T * 4*C : acts.fch_gelu;
        // get the pointers of the gradients of the activations for this layer
        // notice that there is no l *, because we just have a single copy, and keep
        // re-using this memory in every Transformer block as we calculate backward pass

        floatX* dl_bt4c = (floatX*)grads_acts.bt4c;

        // start the backward pass for this layer
        if(model->recompute >= 1) {
            // recompute >= 1 means we recompute gelu. in this case,
            // l_fch_gelu is just a buffer, so re-compute the gelu from l_fch here
            gelu_forward(l_fch_gelu, l_fch, B*T*4*C, main_stream);
        }
        matmul_backward(dl_bt4c, dl_fcprojw, dl_fcprojb, dresidual, l_fch_gelu, l_fcprojw, scratchF, B, T, 4*C, C, main_stream);
        gelu_backward_inplace(dl_bt4c, l_fch, B*T*4*C, main_stream);
        if(model->recompute >= 2) {
            // same as gelu above, l_ln1 and l_ln2 are just buffers if recompute >= 2, recompute them here on demand
            layernorm_forward(l_ln2, l_ln2_mean, l_ln2_rstd, l_residual2, l_ln2w, l_ln2b, B, T, C, main_stream);
        }
        matmul_backward(dl_btc, dl_fcw, dl_fcb, dl_bt4c, l_ln2, l_fcw, scratchF, B, T, C, 4 * C, main_stream);
        // layernorm backward does += to the dresidual, so it correctly accumulates grad from the MLP block above
        layernorm_backward(dresidual, dl_ln2w, dl_ln2b, scratchF, dl_btc, l_residual2, l_ln2w, l_ln2_mean, l_ln2_rstd, B, T, C, main_stream);
        matmul_backward(dl_btc, dl_attprojw, dl_attprojb, dresidual, l_atty, l_attprojw, scratchF, B, T, C, C, main_stream);

        #ifdef ENABLE_CUDNN
        float* l_att = (float*)acts.att + l * B * NH * T; // cuDNN needs a smaller FP32 tensor
        attention_backward_cudnn(dl_bt4c, dl_btc, l_qkvr, l_atty, (float*)l_att, B, T, NH, C, main_stream);
        #else
        floatX* l_att = acts.att + l * B * NH * T * T;
        // we need B x T x (4)C buffers. l_atty and l_fch aren't needed anymore at this point, so reuse their memory
        floatX* buffer_a = l_atty;
        floatX* buffer_b = l_fch;        // this is B x T x 4C, so even larger than what we need
        floatX* dl_preatt = (floatX*)grads_acts.preatt; // dedicated scratchpad allocation
        attention_backward(dl_bt4c, buffer_b, dl_preatt, scratchX, buffer_a, dl_btc, l_qkvr, l_att, B, T, C, NH, main_stream);
        #endif
        if(model->recompute >= 2) {
            layernorm_forward(l_ln1, l_ln1_mean, l_ln1_rstd, residual, l_ln1w, l_ln1b, B, T, C, main_stream);
        }
        // QKV parameter gradients
        matmul_backward(dl_btc, dl_qkvw, dl_qkvb, dl_bt4c, l_ln1, l_qkvw, scratchF, B, T, C, 3 * C, main_stream);
        // layernorm backward does += to dresidual, so it correctly accumulates gradient for the Attention block above
        layernorm_backward(dresidual, dl_ln1w, dl_ln1b, scratchF, dl_btc, residual, l_ln1w, l_ln1_mean, l_ln1_rstd, B, T, C, main_stream);
    }
    encoder_backward(grads.wte, grads.wpe, scratchX, model->workload_indices, model->bucket_info,
                     dresidual, model->inputs, inputs, B, T, C, random_u32(&model->rng_state), main_stream);

    cudaCheck(cudaDeviceSynchronize());
}

// Compute sum of a single CPU value across all GPU processes. No-op when multi-GPU is disabled.
float multi_gpu_cpu_float_sum(float value) {
#ifdef MULTI_GPU
    // note MPI doesn't support all reduce with mean, only sum
    float result;
    mpiCheck(MPI_Allreduce(&value, &result, 1, MPI_FLOAT, MPI_SUM, MPI_COMM_WORLD));
    return result;
#else
    return value;
#endif
}

// Averages out the loss and gradients across all GPUs. No-op when multi-GPU is disabled.
// todo - this version only works if all the parameters are the same size (floatX)
void gpt2_multi_gpu_loss_and_grad_reduce(GPT2* model, MultiGpuConfig* multi_gpu_config) {
#ifdef MULTI_GPU
    NVTX_RANGE_FN();
    // If there's only one process, there is nothing to do
    if (multi_gpu_config->num_processes == 1) { return; }
    // Average all losses.
    model->accumulated_mean_loss = multi_gpu_cpu_float_sum(model->mean_loss) / multi_gpu_config->num_processes;
    // Now average the gradients
    if(multi_gpu_config->zero_stage == 0) {
        // no ZERO == standard DDP: Average all gradients.
        ncclCheck(ncclAllReduce(model->grads_memory, model->grads_memory,
                                model->num_parameters,
                                ncclFloatX, ncclAvg,
                                multi_gpu_config->nccl_comm, main_stream));
    } else if (multi_gpu_config->zero_stage == 1) {
        // ZERO-1: Get the average gradient only for local shard
        floatX* local_grads_memory = (floatX*) model->grads_memory + multi_gpu_config->shard_offset;
        ncclCheck(ncclReduceScatter(model->grads_memory, local_grads_memory,
                                    multi_gpu_config->shard_num_parameters,
                                    ncclFloatX, ncclAvg,
                                    multi_gpu_config->nccl_comm, main_stream));
    }
#endif
    cudaCheck(cudaDeviceSynchronize());
}

float gpt2_update(GPT2 *model, float learning_rate, float beta1, float beta2, float eps, float weight_decay, float grad_clip, int t, MultiGpuConfig* multi_gpu_config) {
    // update the model parameters using the AdamW optimizer
    // keep in mind that optimizer sharding (ZeRO-1) assigns different parameters to different GPUs
    // so we may not be responsible for the entire parameter tensor
    // also, this function was very simple a while back but become very complex, only because we want to
    // selectively weight decay some, but not all tensors :(
    // TODO: revisit and probably refactor this entire function
    NVTX_RANGE_FN();
    size_t shard_num_parameters = multi_gpu_config->shard_num_parameters; // num parameters we are responsible for
    size_t shard_offset = multi_gpu_config->shard_offset; // offset into the full parameter tensor
    floatX* params_memory = (floatX*)model->params_memory;
    floatX* grads_memory = (floatX*)model->grads_memory;

    // lazily allocate m,v memory and master weights (usually on the first iteration)
    if (model->m_memory == NULL) {
        NvtxRange rng("InitOpt");
        printf0("allocating %zu MiB for AdamW optimizer state m\n", (shard_num_parameters * sizeof(float)) >> 20);
        printf0("allocating %zu MiB for AdamW optimizer state v\n", (shard_num_parameters * sizeof(float)) >> 20);
        cudaCheck(cudaMalloc((void**)&model->m_memory, shard_num_parameters * sizeof(float)));
        cudaCheck(cudaMalloc((void**)&model->v_memory, shard_num_parameters * sizeof(float)));
        cudaCheck(cudaMemset(model->m_memory, 0, shard_num_parameters * sizeof(float)));
        cudaCheck(cudaMemset(model->v_memory, 0, shard_num_parameters * sizeof(float)));
    }
    if (model->use_master_weights == 1 && model->master_weights == NULL) {
        printf0("allocating %zu MiB for master copy of params\n", (shard_num_parameters * sizeof(float)) >> 20);
        cudaCheck(cudaMalloc((void**)&model->master_weights, shard_num_parameters * sizeof(float)));
        size_t grid_size = CEIL_DIV(shard_num_parameters, 512);
        copy_and_cast_kernel<<<grid_size, 512, 0, main_stream>>>(model->master_weights, params_memory + shard_offset, shard_num_parameters);
        cudaCheck(cudaGetLastError());
    }

    // gradient clipping
    // repurposing this buffer (which isn't needed now) to write grad norm into it
    float* grad_norm_squared = (float*)model->acts.output;
    if (multi_gpu_config->zero_stage == 1) {
        // ^1 because of the ncclReduceScatter() in gpt2_multi_gpu_loss_and_grad_reduce,
        // grads_memory only contains the averaged gradients at the local shard
        // so we only calculate the grad norm at the grads_memory belonging to the local shard
        global_norm_squared(grad_norm_squared, grads_memory + shard_offset, shard_num_parameters, main_stream);
    } else {
        // the ncclAllReduce() in gpt2_multi_gpu_loss_and_grad_reduce has averaged the gradients across all GPUs
        // so each GPU can compute the squared norm over the whole grad vector, with no added comms needed
        global_norm_squared(grad_norm_squared, grads_memory, model->num_parameters, main_stream);
    }
    // transfer the gradient norm to CPU
    float grad_norm_squared_cpu = 0.0f;
    cudaCheck(cudaMemcpy(&grad_norm_squared_cpu, grad_norm_squared, sizeof(float), cudaMemcpyDeviceToHost));
    if (multi_gpu_config->zero_stage == 1) {
        // further sum the (partial) squared norm across all GPUs (see comment ^1 above)
        grad_norm_squared_cpu = multi_gpu_cpu_float_sum(grad_norm_squared_cpu);
    }

    if(!isfinite(grad_norm_squared_cpu)) {
        // may happen due to some issue (e.g. overflow?)
        // TODO: later may want to keep a global counter of instabilities like this
        printf0("[WARNING]: grad norm is not finite, skipping AdamW update\n");
        return -1.0f;
    }
    float grad_norm_cpu = sqrtf(grad_norm_squared_cpu);
    float grad_scale = (grad_norm_cpu > grad_clip) ? grad_clip / grad_norm_cpu : 1.0f;

    // AdamW update
    unsigned int seed = random_u32(&model->rng_state);
    // individually call the adamw_kernel3 on all parameter tensors separately
    size_t offset = 0;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        size_t num_parameters = model->param_elements[i];
        // the scope of this GPU's work is the range: [shard_offset, shard_offset + shard_num_parameters)
        // this parameter's values are in the range:  [offset, offset + num_parameters)
        // so we are responsible for some of its parameters if:
        // 1) this parameter ends after we begin (i.e. offset + num_parameters > shard_offset)
        // 2) this parameter begins before we end (i.e. offset < shard_offset + shard_num_parameters)
        if(offset + num_parameters > shard_offset && offset < shard_offset + shard_num_parameters) {

            // ok this tensor has at least one element inside the range of responsibility of this GPU
            // let's figure out the exact span we wish to call the AdamW kernel on
            floatX* params_ptr = NULL;
            floatX* grad_ptr = NULL;
            float* m_ptr = NULL;
            float* v_ptr = NULL;
            float* master_ptr = NULL;
            size_t local_params = 0;
            // does the tensor begin before our responsibility?
            if(offset <= shard_offset) {
                // if so, our start point is exactly that of our responsibility, i.e. shard_offset
                params_ptr = params_memory + shard_offset;
                grad_ptr = grads_memory + shard_offset;
                // note that (master_weights, m, v) are already only the "local slice" for this GPU,
                // and are of size shard_num_parameters, instead of the total number of parameters
                // so they do not get offset, i.e. we just start at their index 0
                if (model->master_weights != NULL) { master_ptr = model->master_weights; }
                m_ptr = model->m_memory;
                v_ptr = model->v_memory;
                // the number of parameters we have to update is the minimum of two ranges
                local_params = min(shard_num_parameters, (offset + num_parameters) - shard_offset);
            } else {
                // our start point is the location of this tensor, i.e. offset
                params_ptr = params_memory + offset;
                grad_ptr = grads_memory + offset;
                // this arithmetic gave me a headache but my little doodle example says it's right
                size_t delta = offset - shard_offset;
                if (model->master_weights != NULL) { master_ptr = model->master_weights + delta; }
                m_ptr = model->m_memory + delta;
                v_ptr = model->v_memory + delta;
                local_params = min(num_parameters, shard_num_parameters - delta);
            }
            // we only want to weight decay the 2D tensors and leave all 1D tensors alone
            // in particular this also decays the embedding weights, but this is ok:
            // - the token embeddings are weight shared and participate in the final projection to logits
            // - the position embeddings actively participate at every forward/backward pass
            float wd = (i == 0 || i == 1 || i == 4 || i == 6 || i == 10 || i == 12) ? weight_decay : 0.0f;
            // ok finally call the kernel
            adamw_update(params_ptr, master_ptr, grad_ptr,
                         m_ptr, v_ptr, local_params, learning_rate,
                         beta1, beta2, t, eps, wd, grad_scale, seed, main_stream);
        }
        // advance the offset pointer to the next parameter tensor
        offset += num_parameters;
    }
    cudaCheck(cudaGetLastError());

    cudaCheck(cudaDeviceSynchronize());
    return grad_norm_cpu;
}

void gpt2_multi_gpu_param_gather(GPT2 *model, MultiGpuConfig* multi_gpu_config)
{
#ifdef MULTI_GPU
    if (multi_gpu_config->num_processes == 1) { return; } // 1 process => noop
    if (multi_gpu_config->zero_stage == 1) {
        // gather updated shards of model->params_memory from each process
        ncclCheck(ncclAllGather((floatX*)model->params_memory + multi_gpu_config->shard_offset, (floatX*)model->params_memory,
                                multi_gpu_config->shard_num_parameters, ncclFloatX,
                                multi_gpu_config->nccl_comm, main_stream));
    }
    cudaCheck(cudaGetLastError());
#endif
    cudaCheck(cudaDeviceSynchronize());
}

float gpt2_estimate_mfu(GPT2 *model, int num_tokens, float dt) {
    /*
    Estimate model flops utilization (MFU)
    ref: Section 2.1 of https://arxiv.org/pdf/2001.08361
    Note: Ideally, the N here would be only the parameters that actually
    participate in matrix multiplications. In this N, we are over-estimating by
    including LayerNorm params, biases, and the position embedding weights,
    but these are very small terms. Also keep in mind that we would want to exclude
    the token embedding weights, but in GPT-2 these are weight shared, so they
    participate in the classifier matmul, so they are correct to be included in N.
    Note 2: The first term (6 * N) in flops_per_token is all weight matmuls, the
    second is the attention matmul, which is also usually a small contribution.
    */
    size_t N = model->num_parameters;
    int L = model->config.num_layers;
    int C = model->config.channels;
    int T = model->seq_len;
    size_t flops_per_token = 6 * N + (size_t)6 * L * C * T;
    size_t flops_per_step = flops_per_token * num_tokens;
    // express our flops throughput as ratio of A100 bfloat16 peak flops
    float flops_achieved = (float)flops_per_step * (1.0f / dt); // per second
    float flops_promised = get_flops_promised(deviceProp.name, PRECISION_MODE) * 1e12f;
    if(flops_promised < 0) {
        return -1.f;   // don't know
    }
    float mfu = flops_achieved / flops_promised;
    return mfu;
}

void gpt2_free(GPT2 *model) {
    cudaCheck(cudaFree(model->params_memory));
    cudaCheck(cudaFree(model->grads_memory));
    cudaCheck(cudaFree(model->m_memory));
    cudaCheck(cudaFree(model->v_memory));
    cudaCheck(cudaFree(model->master_weights));
    cudaCheck(cudaFree(model->acts_memory));
    cudaCheck(cudaFree(model->grads_acts_memory));
    cudaCheck(cudaFree(model->inputs));
    cudaCheck(cudaFree(model->targets));
    cudaCheck(cudaFreeHost(model->cpu_losses));
    cudaCheck(cudaFreeHost(model->cpu_losses_fp32));
    free(model->workload_indices);
    free(model->bucket_info);
}

// ----------------------------------------------------------------------------
// common init & free code for all of train/test/profile

void common_start(bool override_enable_tf32 = true, bool print_device_info = true) {

    // get CUDA device infos
    cudaGetDeviceProperties(&deviceProp, multi_gpu_config.local_device_idx);
    if (print_device_info) {
        printf("[System]\n");
        printf("Device %d: %s\n", multi_gpu_config.local_device_idx, deviceProp.name);
    }

    // set up the cuda streams. atm everything is on the single main stream
    cudaStreamCreate(&main_stream);
    nvtxNameCudaStreamA(main_stream, "main stream");

    // set up cuBLAS and cuBLASLt
    cublasCheck(cublasCreate(&cublas_handle));
    cublasCheck(cublasLtCreate(&cublaslt_handle));
    cudaCheck(cudaMalloc(&cublaslt_workspace, cublaslt_workspace_size));

    // TF32 precision is equivalent to torch.set_float32_matmul_precision('high')
    bool enable_tf32 = PRECISION_MODE == PRECISION_FP32 && deviceProp.major >= 8 && override_enable_tf32;
    cublasCheck(cublasSetMathMode(cublas_handle, enable_tf32 ? CUBLAS_TF32_TENSOR_OP_MATH : CUBLAS_DEFAULT_MATH));
    cublas_compute = enable_tf32 ? CUBLAS_COMPUTE_32F_FAST_TF32 : CUBLAS_COMPUTE_32F;

    #ifdef ENABLE_CUDNN
    create_cudnn();
    #endif
}

void common_free(GPT2 &model) {
    cudaCheck(cudaStreamDestroy(main_stream));
    cudaCheck(cudaFree(cublaslt_workspace));
    cublasCheck(cublasDestroy(cublas_handle));
    cublasCheck(cublasLtDestroy(cublaslt_handle));
    #ifdef ENABLE_CUDNN
    destroy_cudnn();
    #endif
}

#ifndef TESTING
// if we are TESTING (see test_gpt2.cu), we'll skip everything below this point

// ----------------------------------------------------------------------------
// training resumption logic, very useful when jobs crash once in a while
// the goal is that we can resume optimization from any checkpoint, bit-perfect
// note that "state" refers to things not already saved in the model checkpoint file

void save_state(const char* filename, int step, GPT2* model, DataLoader* loader) {
    printf("Writing state to %s\n", filename);
    FILE *state_file = fopenCheck(filename, "wb");
    int state_header[256];
    memset(state_header, 0, sizeof(state_header));
    // basic identifying information
    state_header[0] = 20240527; // magic number
    state_header[1] = 1; // version number
    state_header[2] = multi_gpu_config.num_processes; // number of processes
    state_header[3] = multi_gpu_config.process_rank; // rank of this process
    // int main state, start at 10 to leave some padding
    state_header[10] = step; // step of the optimization
    // model state, state, start at 20 to leave some padding
    *((unsigned long long*)&state_header[20]) = model->rng_state; // random number generator state
    // dataloader state, start at 30 to leave some padding
    state_header[30] = loader->current_shard; // shard of the dataset
    *((int64_t*)&state_header[31]) = loader->current_position; // position in shard
    fwrite(state_header, sizeof(int), 256, state_file);
    // write AdamW m, v, and master_weights here (they are all float)
    size_t shard_num_parameters = multi_gpu_config.shard_num_parameters;
    float* cpu_buffer = (float*)mallocCheck(shard_num_parameters * sizeof(float));
    cudaCheck(cudaMemcpy(cpu_buffer, model->m_memory, shard_num_parameters * sizeof(float), cudaMemcpyDeviceToHost));
    fwrite(cpu_buffer, sizeof(float), shard_num_parameters, state_file);
    cudaCheck(cudaMemcpy(cpu_buffer, model->v_memory, shard_num_parameters * sizeof(float), cudaMemcpyDeviceToHost));
    fwrite(cpu_buffer, sizeof(float), shard_num_parameters, state_file);
    free(cpu_buffer);
    fclose(state_file);
}

void load_state(int* step, GPT2* model, DataLoader* loader, const char* filename) {
    FILE *state_file = fopenCheck(filename, "rb");
    int state_header[256];
    freadCheck(state_header, sizeof(int), 256, state_file);
    assert(state_header[0] == 20240527); // magic number
    assert(state_header[1] == 1); // version number
    assert(state_header[2] == multi_gpu_config.num_processes); // number of processes
    assert(state_header[3] == multi_gpu_config.process_rank); // rank of this process
    *step = state_header[10]; // step of the optimization
    model->rng_state = *((unsigned long long*)&state_header[20]); // random number generator state
    int current_shard = state_header[30]; // shard of the dataset
    int64_t current_position = *((int64_t*)&state_header[31]); // position in shard
    dataloader_resume(loader, current_shard, current_position);
    // read AdamW m, v (they are all float)
    // also allocate the m, v memory in the model, if it does not yet exist
    size_t shard_num_parameters = multi_gpu_config.shard_num_parameters;
    if (model->m_memory == NULL) {
        printf0("allocating %zu MiB for AdamW optimizer state m\n", (shard_num_parameters * sizeof(float)) >> 20);
        printf0("allocating %zu MiB for AdamW optimizer state v\n", (shard_num_parameters * sizeof(float)) >> 20);
        cudaCheck(cudaMalloc((void**)&model->m_memory, shard_num_parameters * sizeof(float)));
        cudaCheck(cudaMalloc((void**)&model->v_memory, shard_num_parameters * sizeof(float)));
    }
    float* cpu_buffer = (float*)mallocCheck(shard_num_parameters * sizeof(float));
    freadCheck(cpu_buffer, sizeof(float), shard_num_parameters, state_file);
    cudaCheck(cudaMemcpy(model->m_memory, cpu_buffer, shard_num_parameters * sizeof(float), cudaMemcpyHostToDevice));
    freadCheck(cpu_buffer, sizeof(float), shard_num_parameters, state_file);
    cudaCheck(cudaMemcpy(model->v_memory, cpu_buffer, shard_num_parameters * sizeof(float), cudaMemcpyHostToDevice));
    free(cpu_buffer);
    fclose(state_file);
}

// ----------------------------------------------------------------------------
// CLI, poor man's argparse
// unclaimed flags lol: k,p

void error_usage() {
    fprintf(stderr, "Usage:   ./train_gpt2cu [options]\n");
    fprintf(stderr, "Options:\n");
    // file system input / output
    fprintf(stderr, "  -i <string> train data filename pattern (default = dev/data/tinyshakespeare/tiny_shakespeare_train.bin)\n");
    fprintf(stderr, "  -j <string> val data filename pattern (default = dev/data/tinyshakespeare/tiny_shakespeare_val.bin)\n");
    fprintf(stderr, "  -e <string> input from model at this filename (default = gpt2_124M_bf16.bin)\n");
    fprintf(stderr, "  -o <string> output log dir (default = NULL, no logging)\n");
    fprintf(stderr, "  -n <int>    write optimization checkpoints every how many steps? (default 0, don't)\n");
    fprintf(stderr, "  -y <int>    resume optimization found inside output log dir? (0=restart/overwrite, 1=resume/append)\n");
    // token layout for each step of the optimization
    fprintf(stderr, "  -b <int>    (per-GPU, micro) batch size B (default = 4)\n");
    fprintf(stderr, "  -t <int>    sequence length T (default = 1024)\n");
    fprintf(stderr, "  -d <int>    total desired batch size (default = B * T * num_processes, i.e. no grad accumulation\n");
    // workload (number of steps)
    fprintf(stderr, "  -x <int>    max_steps of optimization to run (-1 (default) = disable, run 1 epoch)\n");
    // optimization
    fprintf(stderr, "  -l <float>  learning rate (default = 3e-4f)\n");
    fprintf(stderr, "  -u <int>    learning rate warmup iterations (default = 0, no warmup)\n");
    fprintf(stderr, "  -q <float>  learning rate decay: final fraction, at end of training (default = 1.0 (no decay))\n");
    fprintf(stderr, "  -c <float>  weight decay (default = 0.0f)\n");
    // evaluation
    fprintf(stderr, "  -v <int>    val_loss_every, how often we evaluate val loss (default = 20)\n");
    fprintf(stderr, "  -m <int>    val_max_steps, up to how many val batches to estimate val loss? (default = 20)\n");
    fprintf(stderr, "  -s <int>    sample_every, how often we inference the model (default = 20)\n");
    fprintf(stderr, "  -g <int>    genT, how many steps of inference we do (default = 64)\n");
    fprintf(stderr, "  -h <int>    hellaswag eval run? (default = 0)\n");
    // debugging
    fprintf(stderr, "  -a <int>    overfit a single batch? 0/1. useful for debugging\n");
    // numerics
    fprintf(stderr, "  -f <int>    enable_tf32 override (default: 1, set to 0 to disable tf32)\n");
    fprintf(stderr, "  -w <int>    keep f32 copy of weights for the optimizer? (default: 1)\n");
    // memory management
    fprintf(stderr, "  -z <int>    zero_stage, Zero Optimization Stage, 0,1,2,3 (default = 0)\n");
    fprintf(stderr, "  -r <int>    recompute: less memory but less speed. (default = 1), 0|1|2 = none,gelu,gelu+ln\n");
    exit(EXIT_FAILURE);
}

// ----------------------------------------------------------------------------
// main training loop
int main(int argc, char *argv[]) {
    multi_gpu_config = multi_gpu_config_init(&argc, &argv);

    // read in the (optional) command line arguments
    const char* train_data_pattern = "dev/data/tinyshakespeare/tiny_shakespeare_train.bin";
    const char* val_data_pattern = "dev/data/tinyshakespeare/tiny_shakespeare_val.bin";
    const char* load_filename = "gpt2_124M_bf16.bin"; // bf16 weights of the model
    const char* output_log_dir = NULL;
    int checkpoint_every = 0; // write optimization checkpoints every how many steps?
    int resume = 0; // resume the optimization, if one is found inside output_log_dir?
    int B = 4; // batch size
    int T = 1024; // sequence length max
    int total_batch_size = -1; // will be calculated down below later, if not provided
    float learning_rate = 3e-4f;
    int warmup_iterations = 0;
    float final_learning_rate_frac = 1.0f; // final fraction of learning rate, at end of training
    float weight_decay = 0.0f;
    int val_loss_every = 20; // every how many steps do we eval validation loss?
    int val_max_steps = 20; // how many batches max do we eval for validation loss?
    int sample_every = 20; // every how many steps to do inference?
    int genT = 64; // number of steps of inference we will do
    int overfit_single_batch = 0; // useful for debugging, 1 = only load a single data batch once
    int max_steps = -1;
    int override_enable_tf32 = 1;
    int use_master_weights = 1;
    int recompute = 1; // recompute during backward setting, 0 = none, 1 = recompute gelu
    int zero_stage = 0; // Zero Optimization Stage for Multi-GPU training
    int hellaswag_eval = 0;
    for (int i = 1; i < argc; i+=2) {
        if (i + 1 >= argc) { error_usage(); } // must have arg after flag
        if (argv[i][0] != '-') { error_usage(); } // must start with dash
        if (strlen(argv[i]) != 2) { error_usage(); } // must be -x (one dash, one letter)
        // read in the args
        if (argv[i][1] == 'i') { train_data_pattern = argv[i+1]; }
        else if (argv[i][1] == 'j') { val_data_pattern = argv[i+1]; }
        else if (argv[i][1] == 'e') { load_filename = argv[i+1]; }
        else if (argv[i][1] == 'o') { output_log_dir = argv[i+1]; }
        else if (argv[i][1] == 'n') { checkpoint_every = atoi(argv[i+1]); }
        else if (argv[i][1] == 'y') { resume = atoi(argv[i+1]); }
        else if (argv[i][1] == 'b') { B = atoi(argv[i+1]); } // Per-GPU (micro) batch size
        else if (argv[i][1] == 't') { T = atoi(argv[i+1]); }
        else if (argv[i][1] == 'd') { total_batch_size = atoi(argv[i+1]); }
        else if (argv[i][1] == 'l') { learning_rate = atof(argv[i+1]); }
        else if (argv[i][1] == 'u') { warmup_iterations = atoi(argv[i+1]); }
        else if (argv[i][1] == 'q') { final_learning_rate_frac = atof(argv[i+1]); }
        else if (argv[i][1] == 'c') { weight_decay = atof(argv[i+1]); }
        else if (argv[i][1] == 'x') { max_steps = atoi(argv[i+1]); }
        else if (argv[i][1] == 'v') { val_loss_every = atoi(argv[i+1]); }
        else if (argv[i][1] == 'm') { val_max_steps = atoi(argv[i+1]); }
        else if (argv[i][1] == 's') { sample_every = atoi(argv[i+1]); }
        else if (argv[i][1] == 'g') { genT = atoi(argv[i+1]); }
        else if (argv[i][1] == 'a') { overfit_single_batch = atoi(argv[i+1]); }
        else if (argv[i][1] == 'f') { override_enable_tf32 = atoi(argv[i+1]); }
        else if (argv[i][1] == 'w') { use_master_weights = atoi(argv[i+1]); }
        else if (argv[i][1] == 'z') { zero_stage = atoi(argv[i+1]); }
        else if (argv[i][1] == 'r') { recompute = atoi(argv[i+1]); }
        else if (argv[i][1] == 'h') { hellaswag_eval = atoi(argv[i+1]); }
        else { error_usage(); }
    }
    // should do a bit more error checking here
    assert(warmup_iterations >= 0);
    if (output_log_dir != NULL) {
        assert(strlen(output_log_dir) < 400); // careful bunch of hardcoded snprintf around this
    }
    // check if output_log_dir does not exist or is a file
    struct stat info;
    if (output_log_dir != NULL && (stat(output_log_dir, &info ) != 0 || !(info.st_mode & S_IFDIR))) {
        fprintf(stderr, "-o \"%s\" does not exist or is a file - are you specifying a file instead of dir?\n", output_log_dir);
        exit(EXIT_FAILURE);
    }
    int tokens_per_fwdbwd = B * T * multi_gpu_config.num_processes; // one micro-batch processes this many tokens
    // calculate sensible default for total batch size as assuming no gradient accumulation
    if (total_batch_size == -1) { total_batch_size = tokens_per_fwdbwd; }
    // calculate the number of gradient accumulation steps from the desired total batch size
    assert(total_batch_size % tokens_per_fwdbwd == 0);
    int grad_accum_steps = total_batch_size / tokens_per_fwdbwd;
    // if we're only overfitting a single batch for debugging, let's overfit the first batch
    // from val instead of train split, because val is smaller and faster. (train_gpt2.py does the same)
    if (overfit_single_batch == 1) { train_data_pattern = val_data_pattern; }
    printf0("+-----------------------+----------------------------------------------------+\n");
    printf0("| Parameter             | Value                                              |\n");
    printf0("+-----------------------+----------------------------------------------------+\n");
    printf0("| train data pattern    | %-50s |\n", train_data_pattern);
    printf0("| val data pattern      | %-50s |\n", val_data_pattern);
    printf0("| output log dir        | %-50s |\n", output_log_dir == NULL ? "NULL" : output_log_dir);
    printf0("| checkpoint_every      | %-50d |\n", checkpoint_every);
    printf0("| resume                | %-50d |\n", resume);
    printf0("| micro batch size B    | %-50d |\n", B);
    printf0("| sequence length T     | %-50d |\n", T);
    printf0("| total batch size      | %-50d |\n", total_batch_size);
    printf0("| learning rate (LR)    | %-50e |\n", learning_rate);
    printf0("| warmup iterations     | %-50d |\n", warmup_iterations);
    printf0("| final LR fraction     | %-50e |\n", final_learning_rate_frac);
    printf0("| weight decay          | %-50e |\n", weight_decay);
    printf0("| max_steps             | %-50d |\n", max_steps);
    printf0("| val_loss_every        | %-50d |\n", val_loss_every);
    printf0("| val_max_steps         | %-50d |\n", val_max_steps);
    printf0("| sample_every          | %-50d |\n", sample_every);
    printf0("| genT                  | %-50d |\n", genT);
    printf0("| overfit_single_batch  | %-50d |\n", overfit_single_batch);
    printf0("| use_master_weights    | %-50s |\n", use_master_weights ? "enabled" : "disabled");
    printf0("| recompute             | %-50d |\n", recompute);
    printf0("+-----------------------+----------------------------------------------------+\n");

    common_start(override_enable_tf32, false); // common init code for train/test/profile
    const char* precision_str = (PRECISION_MODE == PRECISION_FP32)
                              ? (cublas_compute == CUBLAS_COMPUTE_32F_FAST_TF32 ? "TF32" : "FP32")
                              : (PRECISION_MODE == PRECISION_FP16 ? "FP16" : "BF16");
    printf0("| device                | %-50s |\n", deviceProp.name);
    printf0("| peak TFlops           | %-50.1f |\n", get_flops_promised(deviceProp.name, PRECISION_MODE));
    printf0("| precision             | %-50s |\n", precision_str);
    printf0("+-----------------------+----------------------------------------------------+\n");

    // figure out if we are going to be resuming the optimization
    char filename_buffer[512];
    int resuming = 0;
    int resume_max_step = find_max_step(output_log_dir);
    if (resume == 1) {
        // find the DONE file with the highest step count
        assert(output_log_dir != NULL);
        if (resume_max_step == -1) {
        } else {
            resuming = 1;
            snprintf(filename_buffer, 512, "%s/model_%08d.bin", output_log_dir, resume_max_step);
        }
    }

    // build the GPT-2 model
    GPT2 model;
    // if load_filename is of the form "dX" where X is an integer (e.g. d12), then we build
    // a random model with the depth of the model specified by X (e.g. 12). otherwise interpret
    // this variable as a checkpoint filename, and load that checkpoint
    assert(strlen(load_filename) >= 2);
    if (resuming == 1) {
        gpt2_build_from_checkpoint(&model, filename_buffer);
    } else if (load_filename[0] == 'd') {
        int depth = atoi(load_filename + 1);
        if (depth > 1 && depth <= 1000) { // we're not going to train models this big right? heh
            gpt2_build_from_random(&model, depth);
        } else {
            exit(EXIT_FAILURE);
        }
    } else {
        gpt2_build_from_checkpoint(&model, load_filename);
    }

    model.use_master_weights = use_master_weights;
    model.recompute = recompute;
    printf0("| weight init method    | %-50s |\n", resuming == 1 ? "intermediate checkpoint" : (load_filename[0] == 'd' ? "random" : "OpenAI's GPT-2 checkpoint"));
    printf0("| max_sequence_length T | %-50d |\n", model.config.max_seq_len);
    printf0("| vocab_size V          | %-50d |\n", model.config.vocab_size);
    printf0("| padded_vocab_size Vp  | %-50d |\n", model.config.padded_vocab_size);
    printf0("| num_layers L          | %-50d |\n", model.config.num_layers);
    printf0("| num_heads NH          | %-50d |\n", model.config.num_heads);
    printf0("| channels C            | %-50d |\n", model.config.channels);
    printf0("| num_parameters        | %-50zu |\n", model.num_parameters);
    printf0("+-----------------------+----------------------------------------------------+\n");

    // build DataLoaders for both train and val
    DataLoader train_loader, val_loader;
    dataloader_init(&train_loader, train_data_pattern, B, T, multi_gpu_config.process_rank, multi_gpu_config.num_processes);
    dataloader_init(&val_loader, val_data_pattern, B, T, multi_gpu_config.process_rank, multi_gpu_config.num_processes);
    // figure out the number of training steps we will run for
    int train_num_batches = max_steps; // passed in from command line
    if (train_num_batches == -1) {
        // sensible default is to train for exactly one epoch
        size_t ntok = train_loader.num_tokens;
        // the number of (outer loop) steps each process should take for us to reach one epoch
        train_num_batches = ntok / total_batch_size;
    }
    // figure out the number of validation steps to run for
    int val_num_batches = val_max_steps; // passed in from command line
    if (val_num_batches == -1) {
        // sensible default is to evaluate the full validation split
        size_t ntok = val_loader.num_tokens;
        // note that unlike the training loop, there is no gradient accumulation inner loop here
        val_num_batches = ntok / tokens_per_fwdbwd;
    }
    printf0("| train_num_batches     | %-50d |\n", train_num_batches);
    printf0("| val_num_batches       | %-50d |\n", val_num_batches);
    printf0("+-----------------------+----------------------------------------------------+\n");

    // build an EvalLoader for HellaSwag
    EvalLoader eval_loader;
    const char* hellaswag_path = "dev/data/hellaswag/hellaswag_val.bin";
    const char hellaswag_available = access(hellaswag_path, F_OK) == 0;
    const char run_hellaswag = hellaswag_eval && hellaswag_available;
    if (run_hellaswag) {
        evalloader_init(&eval_loader, hellaswag_path, B, T, multi_gpu_config.process_rank, multi_gpu_config.num_processes);
    }
    printf0("| run hellaswag         | %-50s |\n", run_hellaswag ? "yes" : "no");
    printf0("+-----------------------+----------------------------------------------------+\n");

    // pretty print in a table the multi-gpu configuration as well
    set_zero_configs(&multi_gpu_config, zero_stage, model.num_parameters);
    printf0("| num_processes         | %-50d |\n", multi_gpu_config.num_processes);
    printf0("| zero_stage            | %-50d |\n", multi_gpu_config.zero_stage);
    printf0("+-----------------------+----------------------------------------------------+\n");

    // prints outside of pretty table to here and below
    if (!hellaswag_available) {
        printf0("HellaSwag eval not found at %s, skipping its evaluation\n", hellaswag_path);
        printf0("You can run `python dev/data/hellaswag.py` to export and use it with `-h 1`.\n");
    }
    // more prints related to allocations from gpt2_build_from_checkpoint down here to not mess up our table above
    printf0("num_parameters: %zu => bytes: %zu\n", model.num_parameters, model.num_parameters_bytes);
    printf0("allocated %d MiB for model parameters\n", (int)round(model.num_parameters_bytes / (1024 * 1024)));
    // few more prints for gradient accumulation math up above
    printf0("batch_size B=%d * seq_len T=%d * num_processes=%d and total_batch_size=%d\n",
            B, T, multi_gpu_config.num_processes, total_batch_size);
    printf0("=> setting grad_accum_steps=%d\n", grad_accum_steps);

    // set up logging
    create_dir_if_not_exists(output_log_dir);
    Logger logger;
    logger_init(&logger, output_log_dir, multi_gpu_config.process_rank, resume);

    // set up the Tokenizer
    Tokenizer tokenizer;
    tokenizer_init(&tokenizer, "gpt2_tokenizer.bin");

    // some memory for generating samples from the model
    int* gen_tokens = (int*)mallocCheck(B * T * sizeof(int));
    floatX* cpu_logits_raw = (floatX*)mallocCheck(model.config.vocab_size * sizeof(floatX));
    float*  cpu_logits = (float*)mallocCheck(model.config.vocab_size * sizeof(float));

    // if we found a checkpoint to resume from, load the optimization state
    int step = 0;
    if (resuming == 1) {
        snprintf(filename_buffer, 512, "%s/state_%08d_%05d.bin", output_log_dir, resume_max_step, multi_gpu_config.process_rank);
        load_state(&step, &model, &train_loader, filename_buffer);
    }

    // train
    cudaEvent_t start, end;
    cudaCheck(cudaEventCreate(&start));
    cudaCheck(cudaEventCreate(&end));
    cudaCheck(cudaProfilerStart());
    double total_sum_iteration_time_s = 0.0;
    float ema_tokens_per_second = 0.0f;
    for (; step <= train_num_batches; step++) {
        NvtxRange step_range("Train step", step);

        int last_step = step == train_num_batches;

        // once in a while estimate the validation loss (all processes collaborate)
        if (step % val_loss_every == 0 || last_step) {
            NvtxRange validation_range("validation");
            float val_loss = 0.0f;
            dataloader_reset(&val_loader);
            for (int i = 0; i < val_num_batches; i++) {
                dataloader_next_batch(&val_loader);
                gpt2_forward(&model, val_loader.inputs, val_loader.targets, B, T);
                val_loss += model.mean_loss;
            }
            val_loss /= val_num_batches;
            val_loss = multi_gpu_cpu_float_sum(val_loss) / multi_gpu_config.num_processes;
            printf0("val loss %f\n", val_loss);
            logger_log_val(&logger, step, val_loss);
        }

        // once in a while estimate HellaSwag accuracy (all processes collaborate)
        if (run_hellaswag &&
           ((step > 0 && step % val_loss_every == 0) || last_step)) {
            NvtxRange evaluation_range("evaluation");
            float eval_acc_norm = 0.0f;
            evalloader_reset(&eval_loader);
            for (int i = 0; i < eval_loader.num_batches; i++) {
                if (i % 10 == 0) { printf("evaluating HellaSwag: %d/%d\r", i, eval_loader.num_batches); }
                evalloader_next_batch(&eval_loader);
                gpt2_forward(&model, eval_loader.inputs, eval_loader.targets, B, T);
                int correct = evalloader_stat_losses(&eval_loader, model.cpu_losses_fp32);
                eval_acc_norm += (float)correct;
            }
            // careful because not all ranks may have the exact same allocation of number of examples
            eval_acc_norm = multi_gpu_cpu_float_sum(eval_acc_norm);
            printf0("HellaSwag: %d/%d = %f\n", (int)eval_acc_norm, eval_loader.num_examples, eval_acc_norm / eval_loader.num_examples);
            logger_log_eval(&logger, step, eval_acc_norm / eval_loader.num_examples);
        }

        // once in a while do model inference to print generated text (only rank 0)
        if (multi_gpu_config.process_rank == 0 && sample_every > 0 &&
           (step > 0 && (step % sample_every) == 0 || last_step)) {
            NvtxRange generation_range("generation");
            unsigned long long sample_rng_state = 1337;
            // fill up gen_tokens with the <|endoftext|> token, which kicks off the generation
            int eot_token = tokenizer.eot_token;
            for(int i = 0; i < B * T; ++i) {
                gen_tokens[i] = eot_token;
            }
            // now sample from the model autoregressively
            printf("generating:\n---\n");
            for (int t = 1; t < genT; t++) {
                NvtxRange generation_range("Generation step", t);
                // note that inference is very wasteful here because for each token
                // we re-calculate the forward pass for all of (B,T) positions from scratch
                // but the inference here is just for sanity checking anyway
                // and we can maybe optimize a bit more later, with careful tests
                gpt2_forward(&model, gen_tokens, NULL, B, T);
                // furthermore, below we're only using b=0 (i.e. the first row) of all B rows
                // we're in principle running B "inference streams" in parallel here
                // only using position 0 because it's a bit faster (copy less probs from GPU -> CPU)
                // get the V-dimensional vector probs[0, t-1, :]
                floatX* logits = model.acts.output + (t - 1) * model.config.padded_vocab_size;
                // move probs back to CPU and sample (note we only move the first vocab_size logits, ignoring the padding)
                cudaCheck(cudaMemcpy(cpu_logits_raw, logits, model.config.vocab_size * sizeof(floatX), cudaMemcpyDeviceToHost));
                // convert to FP32 into cpu_logits (this does nothing useful if floatX == float)
                for (int i = 0; i < model.config.vocab_size; i++) {
                    cpu_logits[i] = (float)cpu_logits_raw[i];
                }
                // sample the next token
                float coin = random_f32(&sample_rng_state);
                int next_token = sample_softmax(cpu_logits, model.config.vocab_size, coin);
                gen_tokens[t] = next_token;
                // print the generated token, either using the Tokenizer or a fallback
                if (tokenizer.init_ok) {
                    const char* token_str = tokenizer_decode(&tokenizer, next_token);
                    safe_printf(token_str);
                } else {
                    // fall back to printing the token id
                    printf("%d ", next_token);
                }
                fflush(stdout);
            }
            printf("\n---\n");
        }

        // once in a while checkpoint the optimization state (all ranks)
        if ((checkpoint_every > 0 && output_log_dir != NULL && resuming == 0) &&
            ((step > 0 && step % checkpoint_every == 0) || last_step)) {
            assert(strlen(output_log_dir) < 400); // being a bit lazy here
            // only rank 0 writes the model file because it is the same across all ranks
            if (multi_gpu_config.process_rank == 0) {
                snprintf(filename_buffer, 512, "%s/model_%08d.bin", output_log_dir, step);
                gpt2_write_to_checkpoint(&model, filename_buffer);
            }
            // all ranks write their state file
            snprintf(filename_buffer, 512, "%s/state_%08d_%05d.bin", output_log_dir, step, multi_gpu_config.process_rank);
            save_state(filename_buffer, step, &model, &train_loader);
            // DONE file is a signal that this checkpoint as a whole is complete
            multi_gpu_barrier(&multi_gpu_config);
            if (multi_gpu_config.process_rank == 0) {
                snprintf(filename_buffer, 512, "%s/DONE_%08d", output_log_dir, step);
                FILE* done_file = fopenCheck(filename_buffer, "w");
                fclose(done_file);
            }
            multi_gpu_barrier(&multi_gpu_config);
        }
        resuming = 0;

        // bit confusing: we want to make sure to eval and sample on 0th iteration
        // but also after the very last iteration. so we loop for step <= train_num_batches
        // instead of just < train_num_batches (one extra due to <=), only to do
        // the validation/sampling one last time, and then we break right here as we're done.
        if (last_step) { break; }

        // --------------- TRAINING SECTION BEGIN -----------------
        // do one training step, doing forward/backward/update on total_batch_size tokens
        cudaEventRecord(start);
        // gradient accumulation loop over micro-batches
        float lossf = 0.0f; // for getting the mean loss over the accumulation steps
        for (int micro_step = 0; micro_step < grad_accum_steps; micro_step++) {
            // fetch the next data batch
            // and if we're overfitting a single batch, we'll only call this a single time
            if (overfit_single_batch == 0 ||
               (overfit_single_batch == 1 && step == 0 && micro_step == 0)) {
                dataloader_next_batch(&train_loader);
            }
            // forward pass. note that we pass in grad_accum_steps, which scales down the loss
            gpt2_forward(&model, train_loader.inputs, train_loader.targets, B, T, grad_accum_steps);
            lossf += model.mean_loss; // the mean_loss was normalized by grad_accum_steps inside gpt2_forward
            // backward pass. all model params accumulate gradients with += inside this inner loop
            gpt2_backward(&model, train_loader.inputs);
        }
        // override the mean loss, accounting for the gradient accumulation loop
        // this is esp important to do here in multigpu update below, where model.mean_loss gets allreduced
        model.mean_loss = lossf;
        // average the loss and the gradients between all processes
        gpt2_multi_gpu_loss_and_grad_reduce(&model, &multi_gpu_config);
        // learning rate schedule: warmup linearly to max LR, then cosine decay to LR * final_learning_rate_frac
        float step_learning_rate = learning_rate;
        if (step < warmup_iterations) {
            step_learning_rate = learning_rate * ((float)(step + 1)) / warmup_iterations;
        } else {
            float decay_ratio = ((float)(step - warmup_iterations)) / (train_num_batches - warmup_iterations);
            assert(0.0f <= decay_ratio && decay_ratio <= 1.0f);
            float coeff = 0.5f * (1.0f + cosf(M_PI * decay_ratio)); // coeff starts at 1 and goes to 0
            assert(0.0f <= coeff && coeff <= 1.0f);
            float min_lr = learning_rate * final_learning_rate_frac;
            step_learning_rate = min_lr + coeff * (learning_rate - min_lr);
        }
        // update the model parameters
        float grad_norm = gpt2_update(&model, step_learning_rate, 0.9f, 0.95f, 1e-8f, weight_decay, 1.0f, step+1, &multi_gpu_config);
        gpt2_multi_gpu_param_gather(&model, &multi_gpu_config);
        // zero out the gradients for the next iteration
        gpt2_zero_grad(&model);
        cudaCheck(cudaEventRecord(end));
        cudaCheck(cudaEventSynchronize(end)); // wait for the end event to finish to get correct timings
        // --------------- TRAINING SECTION END -------------------
        // everything that follows now is just diagnostics, prints, logging, etc.

        // todo - move or double-buffer all of this timing logic to avoid idling the GPU at this point!
        float time_elapsed_ms;
        cudaCheck(cudaEventElapsedTime(&time_elapsed_ms, start, end));
        size_t tokens_processed = (size_t)multi_gpu_config.num_processes * B * T * grad_accum_steps;
        float tokens_per_second = tokens_processed / time_elapsed_ms * 1000.0f;
        float bias_corrected_ema_tokens_per_second = tokens_per_second; // by default set to non-ema version
        if (step > 0) { // consider the first batch to be a warmup (e.g. cuBLAS/cuDNN initialisation)
            total_sum_iteration_time_s += time_elapsed_ms / 1000.0f;
            // smooth out the tok/s with an exponential moving average, and bias correct just like in AdamW
            ema_tokens_per_second = 0.95f * ema_tokens_per_second + 0.05f * tokens_per_second;
            bias_corrected_ema_tokens_per_second = ema_tokens_per_second / (1.0f - powf(0.95f, step));
        }
        float accumulated_loss = multi_gpu_config.num_processes == 1 ? model.mean_loss : model.accumulated_mean_loss;
        float mfu = gpt2_estimate_mfu(&model, B * T * grad_accum_steps, time_elapsed_ms / 1000.0f);
        printf0("step %4d/%d | train loss %7.6f | norm %6.4f | lr %.2e | %.2f ms | %.1f%% bf16 MFU | %.0f tok/s\n",
                step + 1, train_num_batches, accumulated_loss, grad_norm, step_learning_rate,
                time_elapsed_ms, 100*mfu, bias_corrected_ema_tokens_per_second);
        logger_log_train(&logger, step, model.mean_loss, step_learning_rate, grad_norm);

        // disable the profiler after 3 steps of optimization
        if (step == 3) { cudaProfilerStop(); }
    }
    // add a total average, for optimizations that are only mild improvements (excluding 1st batch as warmup)
    printf0("total average iteration time: %f ms\n", total_sum_iteration_time_s / (train_num_batches-1) * 1000);

    // free and destroy everything
    cudaCheck(cudaEventDestroy(end));
    cudaCheck(cudaEventDestroy(start));
    if (run_hellaswag) { evalloader_free(&eval_loader); }
    dataloader_free(&train_loader);
    dataloader_free(&val_loader);
    tokenizer_free(&tokenizer);
    free(cpu_logits_raw);
    free(cpu_logits);
    free(gen_tokens);
    multi_gpu_config_free(&multi_gpu_config);
    gpt2_free(&model);
    common_free(model);
    return 0;
}
#endif
