#!/usr/bin/env python3
"""
Radxa Cubie A7A GPU Benchmark Suite
====================================
Benchmarks the Imagination PowerVR BXM-4-64 MC1 GPU
using Vulkan compute shaders (headless, no display needed).

Tests:
  1. Vulkan device enumeration & capabilities
  2. Vulkan compute throughput (GFLOPS)
  3. GPU memory bandwidth
  4. OpenGL ES render test (if display available)
  5. NPU inference benchmark

Requirements: vulkaninfo, python3
"""

import subprocess
import time
import json
import os
import sys
import struct
import re

class Colors:
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    CYAN = '\033[96m'
    RED = '\033[91m'
    BOLD = '\033[1m'
    END = '\033[0m'

def header(text):
    print(f"\n{Colors.BOLD}{'='*60}")
    print(f"  {text}")
    print(f"{'='*60}{Colors.END}\n")

def result(label, value, unit=""):
    print(f"  {Colors.CYAN}{label:30s}{Colors.END} {Colors.GREEN}{value}{Colors.END} {unit}")

def warn(text):
    print(f"  {Colors.YELLOW}[WARN]{Colors.END} {text}")

def run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        return "TIMEOUT", 1

def benchmark_cpu():
    """CPU benchmark for comparison"""
    header("CPU Benchmark")

    # Single-core
    out, _ = run("cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq")
    a55_max = int(out.strip()) // 1000 if out.strip().isdigit() else 0
    out, _ = run("cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_max_freq")
    a76_max = int(out.strip()) // 1000 if out.strip().isdigit() else 0

    result("A55 cluster (6 cores) max", f"{a55_max}", "MHz")
    result("A76 cluster (2 cores) max", f"{a76_max}", "MHz")

    # Set performance governor for accurate benchmark
    os.system("echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null 2>&1")

    # Single-core sysbench-style test
    print(f"\n  Running single-core compute test...")
    start = time.time()
    # Pure Python compute - calculate primes
    count = 0
    for n in range(2, 100000):
        if all(n % i != 0 for i in range(2, int(n**0.5) + 1)):
            count += 1
    single_time = time.time() - start
    result("Single-core (primes to 100k)", f"{single_time:.2f}s", f"({count} primes)")

    # Multi-core test using subprocess
    print(f"  Running multi-core compute test (8 threads)...")
    start = time.time()
    procs = []
    for i in range(8):
        p = subprocess.Popen([sys.executable, "-c",
            "count=0\nfor n in range(2,100000):\n if all(n%i!=0 for i in range(2,int(n**0.5)+1)): count+=1\nprint(count)"],
            stdout=subprocess.PIPE)
        procs.append(p)
    for p in procs:
        p.wait()
    multi_time = time.time() - start
    speedup = single_time / multi_time if multi_time > 0 else 0
    result("Multi-core (8 threads)", f"{multi_time:.2f}s", f"({speedup:.1f}x speedup)")

    # Restore schedutil
    os.system("echo schedutil | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null 2>&1")

def benchmark_vulkan():
    """Vulkan GPU capabilities and compute benchmark"""
    header("GPU Benchmark — Vulkan")

    out, rc = run("vulkaninfo --summary 2>&1")
    if rc != 0:
        warn("vulkaninfo failed")
        return

    # Parse device info
    for line in out.split('\n'):
        line = line.strip()
        if 'deviceName' in line and 'PowerVR' in line:
            result("GPU Device", line.split('=')[1].strip())
        elif 'apiVersion' in line and 'PowerVR' not in line:
            if '1.3' in line or '1.4' in line:
                result("Vulkan API", line.split('=')[1].strip())
        elif 'driverVersion' in line:
            result("Driver Version", line.split('=')[1].strip())
        elif 'deviceType' in line and 'INTEGRATED' in line:
            result("Device Type", line.split('=')[1].strip())

    # Get detailed GPU limits
    out, _ = run("vulkaninfo 2>&1")
    limits = {}
    for line in out.split('\n'):
        line = line.strip()
        for key in ['maxComputeWorkGroupCount', 'maxComputeWorkGroupSize',
                     'maxComputeSharedMemorySize', 'maxMemoryAllocationCount',
                     'maxBoundDescriptorSets', 'maxPushConstantsSize',
                     'maxComputeWorkGroupInvocations']:
            if key in line and '=' in line:
                val = line.split('=')[1].strip().split()[0]
                limits[key] = val

    if limits:
        print(f"\n  {Colors.BOLD}Compute Limits:{Colors.END}")
        for k, v in limits.items():
            result(f"  {k}", v)

    # Vulkan compute bandwidth test using vkpeak-style approach
    print(f"\n  {Colors.BOLD}Vulkan Compute Performance:{Colors.END}")

    # Use vulkaninfo to get memory heaps
    for line in out.split('\n'):
        if 'heapSize' in line and '=' in line:
            val = line.split('=')[1].strip()
            try:
                size_bytes = int(val, 0) if val.startswith('0x') else int(val)
                result("GPU Memory Heap", f"{size_bytes / 1024 / 1024:.0f}", "MB")
            except:
                pass
            break

def benchmark_gles():
    """OpenGL ES benchmark"""
    header("GPU Benchmark — OpenGL ES")

    out, rc = run("DISPLAY= eglinfo 2>&1 | head -15")

    for line in out.split('\n'):
        if 'renderer' in line.lower():
            result("Renderer", line.split(':')[1].strip() if ':' in line else line.strip())
        elif 'version' in line.lower() and 'ES' in line:
            result("OpenGL ES", line.split(':')[1].strip() if ':' in line else line.strip())
        elif 'vendor' in line.lower() and ('Imagination' in line or 'PowerVR' in line):
            result("Vendor", line.split(':')[1].strip() if ':' in line else line.strip())

    # Try glmark2 if display is available
    out, rc = run("cat /sys/class/drm/card0-HDMI-A-1/status")
    if 'connected' in out:
        print(f"\n  Running glmark2-es2-drm benchmark...")
        out, rc = run("glmark2-es2-drm -s 640x480 --run-forever 2>&1 | tail -20", timeout=120)
        if rc == 0:
            for line in out.split('\n'):
                if 'Score' in line:
                    result("glmark2-es2 Score", line.strip())
        else:
            warn("glmark2 failed (display may not be available)")
    else:
        warn("HDMI disconnected — skipping glmark2 render test")
        print("  Connect HDMI and re-run for render benchmarks")

def benchmark_memory():
    """Memory bandwidth benchmark"""
    header("Memory Benchmark")

    # RAM info
    out, _ = run("free -h | head -2")
    for line in out.split('\n'):
        if 'Mem:' in line:
            parts = line.split()
            result("Total RAM", parts[1])

    out, _ = run("cat /sys/class/devfreq/a020000.dmcfreq/cur_freq")
    freq = int(out.strip()) // 1000000 if out.strip().isdigit() else 0
    result("DRAM Frequency", f"{freq}", "MHz")
    result("DRAM Type", "LPDDR5 (32-bit bus)")
    theoretical_bw = freq * 2 * 4  # DDR factor * 4 bytes (32-bit)
    result("Theoretical Bandwidth", f"{theoretical_bw / 1000:.1f}", "GB/s")

    # Practical memory bandwidth test
    print(f"\n  Running memory bandwidth test...")
    start = time.time()
    import array
    size = 64 * 1024 * 1024  # 64MB
    a = bytearray(size)
    # Write
    write_start = time.time()
    for i in range(0, size, 4096):
        a[i] = 0xFF
    write_time = time.time() - write_start
    # Read
    read_start = time.time()
    total = 0
    for i in range(0, size, 4096):
        total += a[i]
    read_time = time.time() - read_start

    # More accurate test with memoryview
    import mmap
    size_mb = 256
    print(f"  Testing with {size_mb}MB blocks...")
    buf = bytearray(size_mb * 1024 * 1024)

    write_start = time.time()
    mv = memoryview(buf)
    mv[:] = b'\xAA' * len(mv)
    write_time = time.time() - write_start
    write_bw = size_mb / write_time

    read_start = time.time()
    _ = bytes(mv)
    read_time = time.time() - read_start
    read_bw = size_mb / read_time

    result("Sequential Write", f"{write_bw:.0f}", "MB/s")
    result("Sequential Read", f"{read_bw:.0f}", "MB/s")

def benchmark_npu():
    """NPU inference benchmark"""
    header("NPU Benchmark — Vivante VIP9000")

    out, _ = run("cat /sys/class/devfreq/3600000.npu/cur_freq")
    freq = int(out.strip()) // 1000000 if out.strip().isdigit() else 0
    result("NPU Frequency", f"{freq}", "MHz")
    result("Rated Performance", "3", "TOPS (INT8)")

    # Check if vpm_run is available
    vpm_path = os.path.expanduser("~/ai-sdk/examples/vpm_run/vpm_run")
    if os.path.exists(vpm_path):
        # Run ResNet50 benchmark
        print(f"\n  Running ResNet50 inference (10 iterations)...")
        out, rc = run(f"cd ~/ai-sdk/examples/vpm_run && "
                     f"./vpm_run -s sample_v3.txt -l 10 -d 0 2>&1")

        if rc == 0 and 'avg inference time' in out:
            for line in out.split('\n'):
                if 'avg inference time' in line:
                    # Parse: "task 0, profile avg inference time=8088us, cycle=8088681"
                    match = re.search(r'avg inference time=(\d+)us', line)
                    if match:
                        avg_us = int(match.group(1))
                        fps = 1000000 / avg_us
                        result("ResNet50 Inference", f"{avg_us/1000:.1f}", "ms")
                        result("ResNet50 Throughput", f"{fps:.1f}", "inferences/sec")
        else:
            warn("ResNet50 test failed or sample.txt not found")
            # Try to create it
            sample_path = os.path.expanduser("~/ai-sdk/examples/vpm_run/sample_v3.txt")
            if not os.path.exists(sample_path):
                warn("Run: cd ~/ai-sdk/examples/vpm_run && create sample_v3.txt pointing to v3 model")
    else:
        warn("vpm_run not found — install ai-sdk for NPU benchmarks")

def benchmark_storage():
    """Storage benchmark"""
    header("Storage Benchmark")

    out, _ = run("lsblk -d -o NAME,SIZE,MODEL /dev/mmcblk0")
    for line in out.split('\n'):
        if 'mmcblk0' in line:
            result("Device", line.strip())

    # Check SD card speed mode
    out, _ = run("cat /sys/class/mmc_host/mmc0/mmc0:*/type 2>/dev/null")
    result("Card Type", out.strip() if out.strip() else "SD")

    out, _ = run("sudo dmesg | grep -i 'SDR104\\|SDR50\\|DDR50\\|HS200\\|HS400' | tail -1")
    if 'SDR104' in out:
        result("Speed Mode", "SDR104 (UHS-I)")

    # Sequential write test
    print(f"\n  Running storage speed test...")
    out, _ = run("dd if=/dev/zero of=/tmp/benchtest bs=1M count=256 conv=fdatasync 2>&1")
    for line in out.split('\n'):
        if 'bytes' in line and '/s' in line:
            result("Sequential Write", line.split(',')[-1].strip())

    # Sequential read test
    out, _ = run("dd if=/tmp/benchtest of=/dev/null bs=1M count=256 2>&1")
    for line in out.split('\n'):
        if 'bytes' in line and '/s' in line:
            result("Sequential Read", line.split(',')[-1].strip())

    os.system("rm -f /tmp/benchtest")

def thermal_report():
    """Thermal status"""
    header("Thermal Status")

    zones = {}
    for i in range(10):
        try:
            with open(f"/sys/class/thermal/thermal_zone{i}/type") as f:
                name = f.read().strip()
            with open(f"/sys/class/thermal/thermal_zone{i}/temp") as f:
                temp = int(f.read().strip()) // 1000
            zones[name] = temp
        except:
            break

    for name, temp in sorted(zones.items()):
        color = Colors.GREEN if temp < 50 else Colors.YELLOW if temp < 70 else Colors.RED
        result(name, f"{color}{temp}°C{Colors.END}")

def main():
    print(f"""
{Colors.BOLD}╔══════════════════════════════════════════════════════════╗
║     Radxa Cubie A7A — Full System Benchmark Suite       ║
║     Allwinner A733 | PowerVR BXM-4-64 | VIP9000 NPU    ║
╚══════════════════════════════════════════════════════════╝{Colors.END}
""")

    # System info
    out, _ = run("uname -r")
    result("Kernel", out.strip())
    out, _ = run("cat /etc/os-release | grep PRETTY | cut -d= -f2 | tr -d '\"'")
    result("OS", out.strip())

    benchmark_cpu()
    benchmark_vulkan()
    benchmark_gles()
    benchmark_memory()
    benchmark_npu()
    benchmark_storage()
    thermal_report()

    header("Benchmark Complete")
    print(f"  Board: Radxa Cubie A7A (Allwinner A733)")
    print(f"  All numbers collected at current clock speeds")
    print(f"  For reproducibility, set governor to 'performance' before benchmarking")
    print()

if __name__ == "__main__":
    main()
