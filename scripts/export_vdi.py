#!/usr/bin/python3

import argparse
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
        description="Download a VDI as a disk image")
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
        '--vdi',
        required=True,
        help="VDI UUID")
    parser.add_argument(
        '--format',
        required=True,
        help="Output format")
    parser.add_argument(
        '--out',
        required=True,
        help="Output file")
    parser.add_argument(
        '--cert',
        help="TLS certificate to use with NBD")
    parser.add_argument(
        '-v',
        '--verbose',
        action='store_true',
        help="Display the NBD messages being sent and received")

    args = parser.parse_args()

    s = xmlrpc.client.ServerProxy('http://%s' % args.host)
    sref = parse(s.session.login_with_password(args.uname, args.pwd))
    try:
        print('Created xapi session {}'.format(sref))
        cmd = ['qemu-img']
        if args.verbose:
            cmd = cmd + ['-T', 'nbd*']
        cmd = cmd + ['convert']
        device = 'driver=nbd,host={},port=10809,export=/{}?session_id={}'.format(
            args.host, args.vdi, sref)
        if args.cert:
            cmd = cmd + ['--object', 'tls-creds-x509,id=tls0,endpoint=client,dir={}'.format(args.cert)]
            device = device + ',tls-creds=tls0'
        cmd = cmd + [device, '--image-opts', '-O', args.format, args.out]

        print('Running command: \n{}'.format(' '.join(cmd)))
        subprocess.run(cmd, check=True)
    finally:
        s.session.logout(sref)

if __name__ == '__main__':
    _main()
