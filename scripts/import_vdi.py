#!/usr/bin/python3

import argparse
import json
import subprocess
import xmlrpc.client


def parse(response):
    """Get useful data from xmlrpc response or fail miserably."""
    if response['Status'] == 'Success':
        return response['Value']
    else:
        raise Exception(response['ErrorDescription'])


def _main():
    parser = argparse.ArgumentParser(
        description="Import a disk image into a VDI")
    parser.add_argument(
        '--host',
        required=True,
        help="XenServer host")
    parser.add_argument(
        '--uname',
        required=True,
        help="Username")
    parser.add_argument(
        '--pwd',
        required=True,
        help="Password")
    parser.add_argument(
        '--file',
        required=True,
        help="Image file to import")
    parser.add_argument(
        '--sr',
        required=True,
        help="The UUID of the SR where the VDI should be imported")
    parser.add_argument(
        '--cert',
        help="TLS certificate to use with NBD")
    parser.add_argument(
        '-v',
        '--verbose',
        action='store_true',
        help="Display the NBD messages being sent and received")

    args = parser.parse_args()

    info = subprocess.check_output(['qemu-img', 'info', '--output=json', args.file])
    info = json.loads(info)

    s = xmlrpc.client.ServerProxy('http://%s' % args.host)
    sref = parse(s.session.login_with_password(args.uname, args.pwd))
    print('Created xapi session {}'.format(sref))
    try:
        sr = parse(s.SR.get_by_uuid(sref, args.sr))
        vdi_record = {
            'SR': sr,
            # ints are 64-bit and encoded as string in the XenAPI:
            'virtual_size': str(info['virtual-size']),
            'type': 'user',
            'sharable': False,
            'read_only': False,
            'other_config': {},
            'name_label': 'Imported VDI'
        }
        vdiref = parse(s.VDI.create(sref, vdi_record))
        vdi_uuid = parse(s.VDI.get_uuid(sref, vdiref))
        print('Created VDI {} of size {}'.format(vdi_uuid, info['virtual-size']))

        cmd = ['qemu-img']
        if args.verbose:
            cmd = cmd + ['-T', 'nbd*']
        cmd = cmd + ['convert', '-n', args.file]
        device = 'driver=nbd,host={},port=10809,export=/{}?session_id={}&rw'.format(
            args.host, vdi_uuid, sref)
        if args.cert:
            tls = 'tls-creds-x509,id=tls0,endpoint=client,dir={}'.format(args.cert)
            cmd = cmd + ['--object', tls]
            device = device + ',tls-creds=tls0'
        cmd = cmd + ['--target-image-opts', device]

        print('Running command: \n{}'.format(' '.join(cmd)))
        subprocess.run(cmd, check=True)
    finally:
        s.session.logout(sref)

if __name__ == '__main__':
    _main()
