#!/usr/bin/env python3
"""Minimal Android boot image packer (header v0, DTB appended to kernel).
Usage: make-bootimg.py <kernel+dtb> <ramdisk.gz> <output.img> "<cmdline>"
"""
import struct, sys

def align(x, p):
    return (x + p - 1) // p * p

def main():
    kernel = open(sys.argv[1], 'rb').read()
    ramdisk = open(sys.argv[2], 'rb').read()
    out_path = sys.argv[3]
    cmdline = sys.argv[4].encode()

    page = 4096
    header_size = 1632  # boot image header v0
    hdr = bytearray(header_size)
    hdr[0:8] = b'ANDROID!'
    struct.pack_into('<I', hdr, 0x08, len(kernel))
    struct.pack_into('<I', hdr, 0x0c, 0x80008000)  # kernel_addr
    struct.pack_into('<I', hdr, 0x10, len(ramdisk))
    struct.pack_into('<I', hdr, 0x14, 0x81000000)  # ramdisk_addr
    struct.pack_into('<I', hdr, 0x1c, 0x80f00000)  # second_addr (stock)
    struct.pack_into('<I', hdr, 0x20, 0x80000100)  # tags_addr
    struct.pack_into('<I', hdr, 0x24, page)
    struct.pack_into('<I', hdr, 0x28, 0)           # header_version
    struct.pack_into('<I', hdr, 0x2c, 0x0e041000)  # os_version (Android 7.1.2)
    hdr[0x40:0x40 + len(cmdline)] = cmdline

    out = bytearray(hdr) + bytearray(align(header_size, page) - len(hdr))
    out += kernel
    out += b'\x00' * (align(len(kernel), page) - len(kernel))
    out += ramdisk

    with open(out_path, 'wb') as f:
        f.write(out)
    print(f"{out_path}: kernel={len(kernel)} ramdisk={len(ramdisk)} total={len(out)}")

if __name__ == '__main__':
    main()
