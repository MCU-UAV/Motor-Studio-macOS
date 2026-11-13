"""Offline SDK probe. Serial calls are replaced in memory; no hardware is opened.
Only supports the SDK SHA-256 documented in PRIVATE-PROTOCOL.md.
Usage (Windows Python): probe-private-sdk.py --dll UnitreeMotorSDK.dll --output vectors.json
"""
import argparse, ctypes as c, hashlib, json, struct, sys, tempfile
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--dll', required=True)
parser.add_argument('--output', required=True)
args=parser.parse_args()
expected='8330abd072b79b0b83e795894e4ff5b4558289be36319b6d69aaa0fa2dd06488'
if hashlib.sha256(Path(args.dll).read_bytes()).hexdigest()!=expected: raise SystemExit('SDK hash mismatch')
d=c.CDLL(str(Path(args.dll).resolve()));base=d._handle
new=d.NewUnitreeMotor;new.argtypes=[c.c_char_p,c.c_char_p,c.c_int,c.c_int];new.restype=c.c_void_p
motor=new(b'COM_DOES_NOT_EXIST',b'N1215-288',0,6000000)
vp=c.windll.kernel32.VirtualProtect;vp.argtypes=[c.c_void_p,c.c_size_t,c.c_uint32,c.POINTER(c.c_uint32)]
callbacks=[]
def hook(addr,sig,fn):
    cb=sig(fn);callbacks.append(cb);stub=b'\x48\xb8'+c.cast(cb,c.c_void_p).value.to_bytes(8,'little')+b'\xff\xe0'
    old=c.c_uint32();assert vp(addr,len(stub),0x40,c.byref(old));c.memmove(addr,stub,len(stub));vp(addr,len(stub),old.value,c.byref(old))
def crc(b):
    x=0xffffffff
    for(w,)in struct.iter_unpack('<I',b):
        x^=w
        for _ in range(32):x=((x<<1)^(0x04c11db7 if x&0x80000000 else 0))&0xffffffff
    return x
def crc16(b):
    x=0
    for v in b:
        x^=v
        for _ in range(8):x=(x>>1)^(0x8408 if x&1 else 0)
    return x
hook(base+0x13940,c.CFUNCTYPE(c.c_int,c.c_void_p,c.c_int,c.c_int),lambda*a:0)
hook(base+0x11a930,c.CFUNCTYPE(c.c_int64),lambda:1700000000000000000)
hook(base+0x808e0,c.CFUNCTYPE(c.c_int,c.c_void_p,c.c_int),lambda*a:0)
c.c_uint32.from_address(motor+0x9058).value=0x123456f9
traces=[];operation='';count=0
def exchange(obj,tx,n,rx,m,t,flag):
    global count
    count+=1
    if count>400:raise RuntimeError('bounded probe exhausted')
    b=c.string_at(tx,n);fb=bytearray()
    if m:
        if b[2]>>4==15:
            fb=bytearray(b'\xfc\xee'+b[4:8]+b[8:-4]+b'\x00'*8)
            fb[2]=(b[2]&15)|128
            if b[5]&15==0 and b[6]==32:
                length=len(b)-12
                fb[6:6+length]=bytes(range(length))
            if b[5]==5:fb[6:14]=b'OK ATB1\x00'
            if b[5]==0 and b[6]==14:fb[6]=60
            fb+=struct.pack('<I',crc(fb[2:]))
        else:
            fb=bytearray(b'\xfc\xee'+bytes([b[2]&127,30,35,48])+b[4:12]+bytes(8))
            if b[4:6]==b'\x00\xfe':fb[3]=128;fb[10:14]=bytes.fromhex('26020a03')
            if b[4:6] in [b'\x00\xfc',b'\x01\xfc']:
                fb[8:10]=struct.pack('<H',(128 if b[4]==1 else 0)|(2 if b[6:8]!=bytes(2) else 0))
                fb[10:14]=struct.pack('<i',int(struct.unpack('<h',b[8:10])[0]*70070/243))
            fb+=struct.pack('<I',crc(fb[2:]))
        assert len(fb)==m
        c.memmove(rx,bytes(fb),m)
    traces.append(dict(operation=operation,tx=b.hex(),rx=fb.hex(),timeout=t))
    return m
hook(base+0x13630,c.CFUNCTYPE(c.c_int,c.c_void_p,c.c_void_p,c.c_size_t,c.c_void_p,c.c_size_t,c.c_int,c.c_int),exchange)
def run(label,name,types,*args):
    global operation
    operation=label;f=getattr(d,name);f.argtypes=[c.c_void_p]+types;f.restype=c.c_int
    result=f(motor,*args);print(label,result,flush=True)
run('clear','Clear_Error',[c.c_bool],False)
run('version','Ask_Version_Value',[c.c_bool,c.c_int,c.c_int,c.c_bool],False,1,100,False)
run('id','Change_ID_Safe',[c.c_int,c.c_int,c.c_bool,c.c_int],0,3,False,1)
run('atb','Change_ATB',[c.c_int,c.c_bool,c.c_bool],0,True,False)
run('atb_off','Change_ATB',[c.c_int,c.c_bool,c.c_bool],0,False,False)
run('calibration','OutPosRotorCal',[c.c_float,c.c_float,c.c_bool,c.c_bool,c.c_bool],.2,1.5,True,True,False)
run('factory','OutPosRotorCal',[c.c_float,c.c_float,c.c_bool,c.c_bool,c.c_bool],0,0,True,False,False)
run('precise','OutPosRotorCal',[c.c_float,c.c_float,c.c_bool,c.c_bool,c.c_bool],0,0,True,True,False)
run('baud','Change_Motor_BaudRate',[c.c_int,c.c_bool,c.c_int],4000000,False,1)
for size in [768,777]:
    stem='N1215-288_APP_0226';p=Path(tempfile.gettempdir())/(stem+f'_{crc16(stem.encode()):04X}_ANY.bin')
    p.write_bytes(bytes(i%256 for i in range(size)))
    run(f'ota{size}','OTA_App_Safe',[c.c_char_p,c.c_bool,c.c_int],str(p).encode(),False,1)
buf=c.create_string_buffer(256)
run('sn','Ask_SN',[c.c_void_p,c.c_int,c.c_int],buf,256,1)
Path(args.output).write_text(json.dumps(traces,indent=2)+'\n')
