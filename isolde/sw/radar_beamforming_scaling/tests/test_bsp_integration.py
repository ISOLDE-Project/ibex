"""Checks against the production files, separate from host runtime mocks.

These are frontend/build-plan checks, not an RV32 assembly/link or FPGA run.
The tinyprintf test executes the real formatter with a host UART callback.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

import plot_cycles

APP = Path(__file__).resolve().parents[1]
SYSTEM = APP.parents[1] / 'system'


@unittest.skipUnless((SYSTEM / 'bsp/omp_redmule.h').exists(), 'requires the production BSP in the full checkout')
class BspIntegrationTests(unittest.TestCase):
    def test_firmware_with_real_bsp_headers(self):
        # Do not add tests/shim or BF_BENCH_HOST_TEST: those hid the original
        # libc/BSP putchar conflict. No machine instructions are emitted.
        command = shlex.split(os.environ.get('CC', 'cc')) + [
            '-std=gnu11', '-ffreestanding', '-fsyntax-only', '-Wall', '-Wextra', '-Werror',
            '-D__riscv=1', '-D__riscv_xlen=32',
            '-DTINYPRINTF_DEFINE_TFP_PRINTF=1', '-DTINYPRINTF_DEFINE_TFP_SPRINTF=0',
            '-I' + str(SYSTEM), str(APP / 'main.c')]
        subprocess.run(command, check=True, capture_output=True, text=True)

    def test_uart_records_through_production_tinyprintf(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            harness = folder / 'format_firmware.c'
            harness.write_text('''#include <stdio.h>
#include <bsp/tinyprintf.h>
#define main benchmark_main
#include "main.c"
#undef main
static void host_uart(void *unused, char c) { (void)unused; fputc(c, stdout); }
int main(void) { init_printf(0, host_uart); return benchmark_main(); }
''')
            binary = folder / 'format_firmware'
            compiler = shlex.split(os.environ.get('CC', 'cc'))
            formatter = folder / 'tinyprintf.o'
            # Compile the unmodified production formatter with its -Wall
            # policy; -Wextra also diagnoses its intentional fallthrough.
            subprocess.run(compiler + ['-std=c11', '-O2', '-Wall',
                           '-DTINYPRINTF_DEFINE_TFP_PRINTF=1', '-DTINYPRINTF_DEFINE_TFP_SPRINTF=0',
                           '-c', str(SYSTEM / 'bsp/tinyprintf.c'), '-o', str(formatter)],
                           check=True, capture_output=True, text=True)
            command = shlex.split(os.environ.get('CC', 'cc')) + [
                '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-ffp-contract=off',
                '-DBF_BENCH_HOST_TEST', '-DTINYPRINTF_DEFINE_TFP_PRINTF=1',
                '-DTINYPRINTF_DEFINE_TFP_SPRINTF=0',
                '-I' + str(APP / 'tests/shim'), '-I' + str(SYSTEM), '-I' + str(APP),
                str(APP / 'tests/mock_runtime.c'), str(formatter),
                str(harness), '-o', str(binary)]
            subprocess.run(command, check=True, capture_output=True, text=True)
            run = subprocess.run([str(binary)], check=True, capture_output=True)
            decoder = plot_cycles.Decoder(allow_host_mock=True)
            decoder.feed(run.stdout)
            decoder.finish()
            self.assertEqual(len(decoder.samples), 15)
            self.assertTrue(all(s.cycles == 0x8000007b for s in decoder.samples.values()))

    def test_production_bsp_make_plan(self):
        # Exercise the supplied BSP make rules without needing installed
        # RV32 tools. This inspects commands; it does not claim a firmware build.
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'scaling.elf'
            command = ['make', '-n', '-f', str(SYSTEM / 'bsp/Makefile'),
                       'APP_FILES=' + str(APP / 'main.c'),
                       'VPATH=' + str(APP) + ':' + str(SYSTEM / 'bsp'),
                       'CV_SW_TOOLCHAIN=/toolchain-check-only', 'RISCV_PREFIX=',
                       'RISCV_CC_SUFFIX=clang', 'RISCV_MARCH=rv32im_zicsr',
                       'RISCV_CPPFLAGS=-I' + str(SYSTEM) + ' -I' + str(APP),
                       'LD_FILE=' + str(SYSTEM / 'bsp/link.ld'), str(target)]
            run = subprocess.run(command, cwd=tmp, check=True, capture_output=True, text=True)
            self.assertIn('-c ' + str(APP / 'main.c'), run.stdout)
            self.assertIn('onnx_redmule_runtime.c', run.stdout)
            self.assertIn('spm_load.c', run.stdout)
            self.assertIn('-T ' + str(SYSTEM / 'bsp/link.ld'), run.stdout)
            self.assertNotIn('tests/mock_runtime.c', run.stdout)
            self.assertNotIn('tests/shim', run.stdout)
            self.assertFalse(target.exists())

    def test_system_wrapper_forwards_platform_and_cleans_first(self):
        # A recording make command exercises wrapper forwarding without
        # invoking the checkout's external hardware/toolchain dependencies.
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            record = folder / 'calls.jsonl'
            recorder = folder / 'record_make.py'
            recorder.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                                'with open(os.environ["BF_TEST_MAKE_LOG"], "a") as f:\n'
                                '    f.write(json.dumps(sys.argv[1:]) + "\\n")\n')
            recorder.chmod(0o755)
            env = dict(os.environ, BF_TEST_MAKE_LOG=str(record))
            subprocess.run(['make', '-C', str(SYSTEM), '-f', 'Makefile.radar-scaling.nodbg',
                            'MAKE=' + str(recorder), 'BF_BENCH_REPEATS=7',
                            'BF_BENCH_WARMUPS=0', 'test-build'], env=env, check=True,
                           capture_output=True, text=True)
            calls = [json.loads(line) for line in record.read_text().splitlines()]
            self.assertEqual([c[-1] for c in calls], ['test-clean', 'test-build'])
            for call in calls:
                for option in ['PE=', 'TEST=radar_beamforming_scaling', 'DBG_MODULE=0',
                               'ENABLE_SPM=1', 'VLT_TOP_MODULE=aida_tb',
                               'BENDER_EXTRA_TARGET=-t fpga_sim -D REDMULE_CLUSTER',
                               'TEST_FILES=' + str(APP / 'main.c')]:
                    self.assertIn(option, call)
                cppflags = next(c for c in call if c.startswith('TEST_CPPFLAGS='))
                self.assertIn('-DBF_BENCH_REPEATS=7', cppflags)
                self.assertIn('-DBF_BENCH_WARMUPS=0', cppflags)

    def test_existing_app_discovery_finds_the_new_app(self):
        run = subprocess.run(['bash', str(SYSTEM / 'build_apps.sh'), '--list'],
                             check=True, capture_output=True, text=True)
        self.assertIn('radar_beamforming_scaling', run.stdout.splitlines())


if __name__ == '__main__':
    unittest.main()
