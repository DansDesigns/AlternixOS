#!/usr/bin/env python3
"""Validate that a supplied Visor file is an x86-64 PE32+ EFI application."""
import pathlib
import struct
import sys


def validate(filename):
    path = pathlib.Path(filename)
    data = path.read_bytes()
    if len(data) < 512 or len(data) > 32 * 1024 * 1024:
        raise ValueError('unexpected EFI executable size')
    if data[:2] != b'MZ':
        raise ValueError('missing DOS MZ header')
    peoff, = struct.unpack_from('<I', data, 0x3C)
    if peoff < 64 or peoff + 4 + 20 + 70 > len(data):
        raise ValueError('invalid PE header offset')
    if data[peoff:peoff + 4] != b'PE\0\0':
        raise ValueError('missing PE signature')
    machine, = struct.unpack_from('<H', data, peoff + 4)
    if machine != 0x8664:
        raise ValueError(f'wrong EFI machine type (0x{machine:04x}, expected x86-64)')
    opts = peoff + 4 + 20
    magic, = struct.unpack_from('<H', data, opts)
    if magic != 0x20B:
        raise ValueError(f'not PE32+ (0x{magic:04x})')
    subsystem, = struct.unpack_from('<H', data, opts + 68)
    if subsystem != 10:
        raise ValueError(f'not an EFI application (subsystem {subsystem})')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: check-efi.py path/to/visor_x64.efi')
    try:
        validate(sys.argv[1])
    except (OSError, ValueError, struct.error) as exc:
        sys.exit(f'Invalid x64 Visor EFI executable: {exc}')
    print('Valid x86-64 PE32+ EFI application.')
