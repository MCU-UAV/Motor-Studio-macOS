"""Offline duplicate-ID fixture probe; requires the same hashed SDK as probe-private-sdk.py."""
import argparse
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--dll', required=True)
parser.add_argument('--output', required=True)
duplicate_args=parser.parse_args()
source=Path(__file__).with_name('probe-private-sdk.py').read_text()
exec(source.split("run('clear'")[0])
original_exchange=exchange
serials={1:0, (1<<95)+3:0};serial_trace=[]
def exchange(obj,tx,n,rx,m,t,flag):
    global count
    b=c.string_at(tx,n)
    if b[2]>>4==15 and b[5]==0x97:
        words=struct.unpack('<8I',b[8:-4]);lo=(words[0]<<64)|(words[1]<<32)|words[2];hi=(words[3]<<64)|(words[4]<<32)|words[5]
        if words[6]==0:
            matches=[s for s in serials if lo<=s<=hi];print('RANGE',hex(lo),hex(hi),len(matches),flush=True)
            if not matches: return 0
            if len(matches)>1:
                fb=b'\xfc\xee'+bytes(m-2)
                c.memmove(rx,fb,m);serial_trace.append(dict(operation='collision',tx=b.hex(),rx=fb.hex(),timeout=t));return m
            sn=matches[0];p=struct.pack('<III',sn>>64,(sn>>32)&0xffffffff,sn&0xffffffff)+bytes(16)+struct.pack('<I',serials[sn])
        else:
            sn=lo;print('ASSIGN',hex(sn),words[7],flush=True);serials[sn]=words[7];p=b[8:-4]
        fb=bytearray(b'\xfc\xee'+bytes([(b[2]&15)|128,b[5]])+b[6:8]+p+bytes(8));fb+=struct.pack('<I',crc(fb[2:]));c.memmove(rx,bytes(fb),m)
        serial_trace.append(dict(operation='discover' if words[6]==0 else 'assign',tx=b.hex(),rx=fb.hex(),timeout=t));return m
    return original_exchange(obj,tx,n,rx,m,t,flag)
hook(base+0x13630,c.CFUNCTYPE(c.c_int,c.c_void_p,c.c_void_p,c.c_size_t,c.c_void_p,c.c_size_t,c.c_int,c.c_int),exchange)
run('resetid','Reset_ID',[c.c_int,c.c_bool,c.c_bool],0,True,True)
Path(duplicate_args.output).write_text(json.dumps(serial_trace+traces,indent=2))
