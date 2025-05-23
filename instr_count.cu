/*
 * SPDX-FileCopyrightText: Copyright (c) 2019 NVIDIA CORPORATION & AFFILIATES.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <unordered_set>

/* every tool needs to include this once */
#include "nvbit_tool.h"

/* nvbit interface file */
#include "nvbit.h"

/* nvbit utility functions */
#include "utils/utils.h"

/* kernel id counter, maintained in system memory */
uint32_t kernel_id = 0;

/* total instruction counter, maintained in system memory, incremented by
 * "counter" every time a kernel completes  */
uint64_t tot_app_instrs = 0;

/* kernel instruction counter, updated by the GPU */
__managed__ uint64_t counter = 0;

/* global control variables for this tool */
uint32_t instr_begin_interval = 0;
uint32_t instr_end_interval = UINT32_MAX;
uint32_t start_grid_num = 0;
uint32_t end_grid_num = UINT32_MAX;
int verbose = 0;
int count_warp_level = 1;
int exclude_pred_off = 0;
int active_from_start = 1;
bool mangled = false;

/* used to select region of insterest when active from start is off */
bool active_region = true;

/* a pthread mutex, used to prevent multiple kernels to run concurrently and
 * therefore to "corrupt" the counter variable */
pthread_mutex_t mutex;

/* nvbit_at_init() is executed as soon as the nvbit tool is loaded. We typically
 * do initializations in this call. In this case for instance we get some
 * environment variables values which we use as input arguments to the tool */
void nvbit_at_init() {
  /* just make sure all managed variables are allocated on GPU */
  setenv("CUDA_MANAGED_FORCE_DEVICE_ALLOC", "1", 1);

  /* we get some environment variables that are going to be use to selectively
   * instrument (within a interval of kernel indexes and instructions). By
   * default we instrument everything. */
  GET_VAR_INT(
      instr_begin_interval, "INSTR_BEGIN", 0,
      "Beginning of the instruction interval where to apply instrumentation");
  GET_VAR_INT(instr_end_interval, "INSTR_END", UINT32_MAX,
              "End of the instruction interval where to apply instrumentation");
  GET_VAR_INT(start_grid_num, "START_GRID_NUM", 0,
              "Beginning of the kernel gird launch interval where to apply "
              "instrumentation");
  GET_VAR_INT(
      end_grid_num, "END_GRID_NUM", UINT32_MAX,
      "End of the kernel launch interval where to apply instrumentation");
  GET_VAR_INT(count_warp_level, "COUNT_WARP_LEVEL", 1,
              "Count warp level or thread level instructions");
  GET_VAR_INT(exclude_pred_off, "EXCLUDE_PRED_OFF", 0,
              "Exclude predicated off instruction from count");
  GET_VAR_INT(
      active_from_start, "ACTIVE_FROM_START", 1,
      "Start instruction counting from start or wait for cuProfilerStart "
      "and cuProfilerStop");
  GET_VAR_INT(mangled, "MANGLED_NAMES", 1, "Print kernel names mangled or not");

  GET_VAR_INT(verbose, "TOOL_VERBOSE", 0, "Enable verbosity inside the tool");
  if (active_from_start == 0) {
    active_region = false;
  }

  std::string pad(100, '-');
  printf("%s\n", pad.c_str());
}

/* Set used to avoid re-instrumenting the same functions multiple times */
std::unordered_set<CUfunction> already_instrumented;

/**
 * Truncates a mangled function name to make it suitable for use as a filename
 * @param mangled_name The original mangled name
 * @param truncated_buffer The buffer to store the truncated name in
 * @param buffer_size Size of the provided buffer
 */
 void truncate_mangled_name(const char *mangled_name, char *truncated_buffer, size_t buffer_size) {
    if (!truncated_buffer || buffer_size == 0) {
      return;
    }

    // Default to unknown if no name provided
    if (!mangled_name) {
      snprintf(truncated_buffer, buffer_size, "unknown_kernel");
      return;
    }

    // Truncate the name if it's longer than buffer_size - 1 (leave room for null terminator)
    size_t max_length = buffer_size - 1;
    size_t name_len = strlen(mangled_name);

    if (name_len > max_length) {
      strncpy(truncated_buffer, mangled_name, max_length);
      truncated_buffer[max_length] = '\0';  // Ensure null termination
    } else {
      strcpy(truncated_buffer, mangled_name);
    }
  }

void instrument_function_if_needed(CUcontext ctx, CUfunction func) {
  /* Get related functions of the kernel (device function that can be
   * called by the kernel) */
  std::vector<CUfunction> related_functions =
      nvbit_get_related_functions(ctx, func);

  /* add kernel itself to the related function vector */
  related_functions.push_back(func);

  /* iterate on function */
  for (auto f : related_functions) {
    /* "recording" function was instrumented, if set insertion failed
     * we have already encountered this function */
    if (!already_instrumented.insert(f).second) {
      continue;
    }

    /* Get the vector of instruction composing the loaded CUFunction "f" */
    const std::vector<Instr *> &instrs = nvbit_get_instrs(ctx, f);

    /* If verbose we print function name and number of" static" instructions
     */
    if (verbose) {
      printf("inspecting %s - num instrs %ld\n", nvbit_get_func_name(ctx, f),
             instrs.size());
    }
    const char *mangled_name = nvbit_get_func_name(ctx, f, true);
    // Dump all SASS instructions to a file
    if (mangled_name) {
      // Create a filename with the mangled name
      char truncated_name[201]; // 200 chars + null terminator
      truncate_mangled_name(mangled_name, truncated_name,
                            sizeof(truncated_name));

      char sass_filename[256];
      snprintf(sass_filename, sizeof(sass_filename), "%s.sass", truncated_name);

      // Open the file
      FILE *sass_file = fopen(sass_filename, "w");
      if (sass_file) {
        fprintf(sass_file, "// SASS instructions for kernel: %s\n",
                mangled_name);
        fprintf(sass_file, "// Format: [Instruction Index] [Offset] [Source "
                           "Location] [SASS Instruction]\n\n");

        // Track the last source location to avoid redundant printing
        std::string last_source_location = "";

        // Iterate through all instructions and write them to the file
        for (uint32_t i = 0; i < instrs.size(); i++) {
          auto instr = instrs[i];
          uint32_t offset = instr->getOffset();

          // Get source code location information
          char *file_name = NULL;
          char *dir_name = NULL;
          uint32_t line = 0;

          std::string source_location;
          bool has_line_info =
              nvbit_get_line_info(ctx, f, offset, &file_name, &dir_name, &line);

          if (has_line_info && file_name != nullptr && file_name[0] != '\0') {
            // File path might not include directory information
            std::string file_path;
            if (dir_name != nullptr && dir_name[0] != '\0') {
              file_path = std::string(dir_name) + "/" + std::string(file_name);
            } else {
              file_path = std::string(file_name);
            }

            source_location = file_path + ":" + std::to_string(line);
          } else {
            source_location = "unknown";
          }

          // Smart printing: if the source location is the same as the previous
          // instruction, only print the SASS instruction without repeating the
          // source location
          if (source_location != last_source_location) {
            fprintf(sass_file, "// Source: %s\n%d /*%04x*/ %s\n",
                    source_location.c_str(), instr->getIdx(), offset,
                    instr->getSass());
            last_source_location = source_location;
          } else {
            fprintf(sass_file, "%d /*%04x*/ %s\n", instr->getIdx(), offset,
                    instr->getSass());
          }
        }

        fclose(sass_file);
        if (verbose) {
          printf("Saved SASS instructions with source mapping to %s\n",
                  sass_filename);
        }
      } else {
        printf("Error: Could not create SASS file %s\n", sass_filename);
      }
    }
    // /* We iterate on the vector of instruction */
    // for (auto i : instrs) {
    //     /* Check if the instruction falls in the interval where we want to
    //      * instrument */
    //     if (i->getIdx() >= instr_begin_interval &&
    //         i->getIdx() < instr_end_interval) {
    //         /* If verbose we print which instruction we are instrumenting
    //          * (both offset in the function and SASS string) */
    //         if (verbose == 1) {
    //             i->print();
    //         } else if (verbose == 2) {
    //             i->printDecoded();
    //         }

    //         /* Insert a call to "count_instrs" before the instruction "i" */
    //         nvbit_insert_call(i, "count_instrs", IPOINT_BEFORE);
    //         if (exclude_pred_off) {
    //             /* pass predicate value */
    //             nvbit_add_call_arg_guard_pred_val(i);
    //         } else {
    //             /* pass always true */
    //             nvbit_add_call_arg_const_val32(i, 1);
    //         }

    //         /* add count warps option */
    //         nvbit_add_call_arg_const_val32(i, count_warp_level);
    //         /* add pointer to counter location */
    //         nvbit_add_call_arg_const_val64(i, (uint64_t)&counter);
    //     }
    // }
  }
}

/* This call-back is triggered every time a CUDA driver call is encountered.
 * Here we can look for a particular CUDA driver call by checking at the
 * call back ids  which are defined in tools_cuda_api_meta.h.
 * This call back is triggered bith at entry and at exit of each CUDA driver
 * call, is_exit=0 is entry, is_exit=1 is exit.
 * */
void nvbit_at_cuda_event(CUcontext ctx, int is_exit, nvbit_api_cuda_t cbid,
                         const char *name, void *params, CUresult *pStatus) {
  /* Identify all the possible CUDA launch events */
  if (cbid == API_CUDA_cuLaunch || cbid == API_CUDA_cuLaunchKernel_ptsz ||
      cbid == API_CUDA_cuLaunchGrid || cbid == API_CUDA_cuLaunchGridAsync ||
      cbid == API_CUDA_cuLaunchKernel || cbid == API_CUDA_cuLaunchKernelEx ||
      cbid == API_CUDA_cuLaunchKernelEx_ptsz) {
    /* cast params to launch parameter based on cbid since if we are here
     * we know these are the right parameters types */
    CUfunction func;
    if (cbid == API_CUDA_cuLaunchKernelEx_ptsz ||
        cbid == API_CUDA_cuLaunchKernelEx) {
      cuLaunchKernelEx_params *p = (cuLaunchKernelEx_params *)params;
      func = p->f;
    } else {
      cuLaunchKernel_params *p = (cuLaunchKernel_params *)params;
      func = p->f;
    }

    if (!is_exit) {
      /* if we are entering in a kernel launch:
       * 1. Lock the mutex to prevent multiple kernels to run concurrently
       * (overriding the counter) in case the user application does that
       * 2. Instrument the function if needed
       * 3. Select if we want to run the instrumented or original
       * version of the kernel
       * 4. Reset the kernel instruction counter */

      pthread_mutex_lock(&mutex);
      instrument_function_if_needed(ctx, func);

      if (active_from_start) {
        if (kernel_id >= start_grid_num && kernel_id < end_grid_num) {
          active_region = true;
        } else {
          active_region = false;
        }
      }

      if (active_region) {
        nvbit_enable_instrumented(ctx, func, true);
      } else {
        nvbit_enable_instrumented(ctx, func, false);
      }

      counter = 0;
    } else {
      /* if we are exiting a kernel launch:
       * 1. Wait until the kernel is completed using
       * cudaDeviceSynchronize()
       * 2. Get number of thread blocks in the kernel
       * 3. Print the thread instruction counters
       * 4. Release the lock*/
      CUDA_SAFECALL(cudaDeviceSynchronize());
      tot_app_instrs += counter;
      int num_ctas = 0;
      if (cbid == API_CUDA_cuLaunchKernel_ptsz ||
          cbid == API_CUDA_cuLaunchKernel) {
        cuLaunchKernel_params *p2 = (cuLaunchKernel_params *)params;
        num_ctas = p2->gridDimX * p2->gridDimY * p2->gridDimZ;
      } else if (cbid == API_CUDA_cuLaunchKernelEx_ptsz ||
                 cbid == API_CUDA_cuLaunchKernelEx) {
        cuLaunchKernelEx_params *p2 = (cuLaunchKernelEx_params *)params;
        num_ctas =
            p2->config->gridDimX * p2->config->gridDimY * p2->config->gridDimZ;
      }
      printf("\nkernel %d - %s - #thread-blocks %d,  kernel "
             "instructions %ld, total instructions %ld\n",
             kernel_id++, nvbit_get_func_name(ctx, func, mangled), num_ctas,
             counter, tot_app_instrs);
      pthread_mutex_unlock(&mutex);
    }
  } else if (cbid == API_CUDA_cuProfilerStart && is_exit) {
    if (!active_from_start) {
      active_region = true;
    }
  } else if (cbid == API_CUDA_cuProfilerStop && is_exit) {
    if (!active_from_start) {
      active_region = false;
    }
  }
}

void nvbit_at_term() {
  printf("Total app instructions: %ld\n", tot_app_instrs);
}
