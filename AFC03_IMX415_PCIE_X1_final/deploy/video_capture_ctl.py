#!/usr/bin/env python3
"""Send a playback snapshot/record command to its Unix-domain control socket."""
import argparse
from pathlib import Path
import re
import socket


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('socket', type=Path, help='capture.sock printed by play_raw_video.sh/play_lz77_video.sh')
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('snapshot', help='save the next decoded frame as JPEG')
    start = sub.add_parser('record-start', help='start a hardware H.264 Matroska recording')
    start.add_argument('--name', help='optional output filename (default uses a timestamp)')
    sub.add_parser('record-stop', help='finalize and close the current recording')
    sub.add_parser('status', help='print recording status in the playback log')
    args = parser.parse_args()
    if not args.socket.exists():
        parser.error(f'capture socket does not exist: {args.socket}')
    if args.action == 'record-start' and args.name:
        if Path(args.name).name != args.name or not re.fullmatch(r'[A-Za-z0-9_.-]{1,96}', args.name):
            parser.error('name may contain only letters, digits, dot, dash and underscore')
        message = 'record-start ' + args.name
    else:
        message = args.action
    sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        sender.sendto(message.encode('utf-8'), str(args.socket))
    finally:
        sender.close()
    print('Sent:', message)


if __name__ == '__main__':
    main()
