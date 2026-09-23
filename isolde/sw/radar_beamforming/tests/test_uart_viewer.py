import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import numpy as np
from uart_viewer import Decoder, Receiver, ROWS, COLS


def packet(case='123abc', real='3c00', imag='bc00', newline='\n'):
    lines = [f'[RADAR] case={case} mode=runtime3 rows=36 cols=16',
             'ordinary printf output: cycles=12345']
    lines += [f'[BF16] {i} {real} {imag}' for i in range(ROWS*COLS)]
    lines += ['[RADAR] PASSED', 'unrelated trailing output']
    return (newline.join(lines)+newline).encode('ascii')


class UartViewerTests(unittest.TestCase):
    def test_partial_reads_crlf_and_numerics(self):
        data = packet(newline='\r\n')
        for size in (1, 7, 511, 32768):
            decoder = Decoder()
            result = []
            for start in range(0, len(data), size):
                result += decoder.feed(data[start:start+size])
            self.assertEqual(len(result), 1)
            np.testing.assert_array_equal(result[0].values, np.full((36, 16), 1-1j))
            self.assertEqual(decoder.accepted, 1)

    def test_repeated_frames_and_midframe_attach(self):
        decoder = Decoder()
        result = decoder.feed(packet()[100:] + packet('a') + packet('b', '4000', '0000'))
        self.assertEqual([frame.case_id for frame in result], ['a', 'b'])
        self.assertEqual([frame.sequence for frame in result], [1, 2])
        np.testing.assert_array_equal(result[1].values, np.full((36, 16), 2+0j))

    def test_corruption_rejected_and_next_header_recovers(self):
        full = packet()
        corruptions = [
            full.replace(b'[BF16] 1 ', b'[BF16] 0 '),
            full.replace(b'[BF16] 1 ', b'[BF16] 600 '),
            full.replace(b'[BF16] 1 3c00 bc00\n', b''),
            full.replace(b'[BF16] 1 3c00', b'[BF16] 1 xxxx'),
            full.replace(b'[BF16] 1 3c00', b'[BF16] 1 7c00'),
            full.replace(b'[BF16] 1 3c00', b'[BF16] 1 7e00'),
            full.replace(b'[BF16] 1 3c00', b'[BF16] 1 \xffc00'),
            full.replace(b'[RADAR] PASSED', b'[RADAR] FAILED'),
            full[:400],
            full.replace(b'[BF16] 1 3c00 bc00', b'x'*1200),
        ]
        for index, broken in enumerate(corruptions):
            with self.subTest(index=index):
                decoder = Decoder()
                frames = decoder.feed(broken+b'\n'+packet('f00d'))
                self.assertEqual([frame.case_id for frame in frames], ['f00d'])
                self.assertEqual(decoder.dropped, 1)

    def test_unsupported_shape_and_truncated_end(self):
        decoder = Decoder()
        self.assertEqual(decoder.feed(packet().replace(b'rows=36', b'rows=999999')), [])
        decoder.feed(packet()[:300])
        decoder.finish()
        self.assertEqual(decoder.dropped, 1)
        self.assertIsNone(decoder.current)

    @unittest.skipUnless(os.name == 'posix', 'POSIX pseudo-terminal required')
    def test_pyserial_pseudo_terminal_receive_and_capture(self):
        import pty
        master, slave = pty.openpty()
        with tempfile.TemporaryDirectory() as tmp:
            capture = Path(tmp)/'serial.log'
            args = SimpleNamespace(log=None, port=os.ttyname(slave), baud=115200,
                                   capture=capture, once=True, idle_timeout=3)
            receiver = Receiver(args)
            try:
                receiver.start()
                self.assertTrue(receiver.ready.wait(2), receiver.error)
                data = packet()
                for start in range(0, len(data), 137):
                    os.write(master, data[start:start+137])
                receiver.join(5)
                self.assertTrue(receiver.done.is_set())
                self.assertIsNone(receiver.error)
                frame = receiver.frames.get_nowait()
                np.testing.assert_array_equal(frame.values, np.full((36, 16), 1-1j))
                self.assertEqual(capture.read_bytes(), data)
            finally:
                receiver.stop.set()
                receiver.join(1)
                os.close(master)
                os.close(slave)


if __name__ == '__main__':
    unittest.main()
