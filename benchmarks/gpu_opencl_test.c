#include <stdio.h>
#include <stdlib.h>
#include <CL/cl.h>
#include <time.h>

const char *kernel_source =
    "__kernel void stress(__global float *a, __global float *b, __global float *c, int n) {\n"
    "    int i = get_global_id(0);\n"
    "    if (i < n) {\n"
    "        float val = a[i];\n"
    "        for (int j = 0; j < 1000; j++) {\n"
    "            val = val * b[i] + c[i];\n"
    "            val = val * 0.999f + 0.001f;\n"
    "        }\n"
    "        a[i] = val;\n"
    "    }\n"
    "}\n";

int main() {
    cl_platform_id platform;
    cl_device_id device;
    cl_int err;

    err = clGetPlatformIDs(1, &platform, NULL);
    if (err != CL_SUCCESS) { printf("No OpenCL platform: %d\n", err); return 1; }

    err = clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, 1, &device, NULL);
    if (err != CL_SUCCESS) {
        err = clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 1, &device, NULL);
        if (err != CL_SUCCESS) { printf("No device: %d\n", err); return 1; }
    }

    char name[256];
    clGetDeviceInfo(device, CL_DEVICE_NAME, sizeof(name), name, NULL);
    printf("GPU: %s\n", name);

    cl_uint compute_units;
    clGetDeviceInfo(device, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(compute_units), &compute_units, NULL);
    printf("Compute units: %u\n", compute_units);

    cl_uint max_freq;
    clGetDeviceInfo(device, CL_DEVICE_MAX_CLOCK_FREQUENCY, sizeof(max_freq), &max_freq, NULL);
    printf("Max clock: %u MHz\n", max_freq);

    int N = 1024 * 1024;
    size_t size = N * sizeof(float);

    cl_context ctx = clCreateContext(NULL, 1, &device, NULL, NULL, &err);
    cl_command_queue queue = clCreateCommandQueue(ctx, device, 0, &err);
    cl_program prog = clCreateProgramWithSource(ctx, 1, &kernel_source, NULL, &err);
    err = clBuildProgram(prog, 1, &device, NULL, NULL, NULL);
    if (err != CL_SUCCESS) { printf("Build failed: %d\n", err); return 1; }
    cl_kernel kernel = clCreateKernel(prog, "stress", &err);

    float *ha = malloc(size), *hb = malloc(size), *hc = malloc(size);
    for (int i = 0; i < N; i++) { ha[i] = 1.0f; hb[i] = 0.999f; hc[i] = 0.001f; }

    cl_mem da = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, size, ha, NULL);
    cl_mem db = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, size, hb, NULL);
    cl_mem dc = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, size, hc, NULL);

    clSetKernelArg(kernel, 0, sizeof(cl_mem), &da);
    clSetKernelArg(kernel, 1, sizeof(cl_mem), &db);
    clSetKernelArg(kernel, 2, sizeof(cl_mem), &dc);
    clSetKernelArg(kernel, 3, sizeof(int), &N);

    size_t global = N;

    printf("Running 50 iterations of 1M element FMA compute...\n");
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    for (int iter = 0; iter < 50; iter++) {
        clEnqueueNDRangeKernel(queue, kernel, 1, NULL, &global, NULL, 0, NULL, NULL);
    }
    clFinish(queue);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
    double gflops = (2.0 * 1000 * N * 50) / elapsed / 1e9;

    printf("Time: %.3f s\n", elapsed);
    printf("Throughput: %.1f GFLOPS (FP32 FMA)\n", gflops);

    free(ha); free(hb); free(hc);
    clReleaseMemObject(da); clReleaseMemObject(db); clReleaseMemObject(dc);
    clReleaseKernel(kernel); clReleaseProgram(prog);
    clReleaseCommandQueue(queue); clReleaseContext(ctx);
    return 0;
}
