from pathlib import Path
exec(Path(__file__).with_name('probe-private-sdk.py').read_text().split("run('clear'")[0])
original=exchange
reads=0
def exchange(obj,tx,n,rx,m,t,flag):
    global reads
    if n==0:
        reads+=1
        fb=bytes([0,3,14]);c.memmove(rx,fb,len(fb));traces.append(dict(operation=operation,tx='',rx=fb.hex(),timeout=t));return len(fb)
    return original(obj,tx,n,rx,m,t,flag)
hook(base+0x13630,c.CFUNCTYPE(c.c_int,c.c_void_p,c.c_void_p,c.c_size_t,c.c_void_p,c.c_size_t,c.c_int,c.c_int),exchange)
run('scan','Search_ID_Safe',[c.c_bool,c.c_int],False,1)
run('switch','Swmotor',[c.c_int,c.c_bool],0,False)
pack=d.PackTxAndGetMainData;pack.argtypes=[c.c_void_p,c.c_void_p,c.c_int];pack.restype=c.c_int
for name in ['Set_Control_Data_Out','Set_Control_Data_Rotor']:
 for mid in [0,15]:
  f=getattr(d,name);f.argtypes=[c.c_void_p,c.c_int,c.c_char_p,c.c_int]+[c.c_double]*5
  vals=[.01,.5,.25,.001,.0001];rc=f(motor,mid,b'Foc',1,*vals);b=c.create_string_buffer(1024);n=pack(motor,b,1024)
  print(name,mid,rc,b.raw[:n].hex(),flush=True)
  traces.append(dict(operation=name,tx=b.raw[:n].hex(),rx='',timeout=0,id=mid,values=vals))
Path(args.output).write_text(json.dumps(traces,indent=2)+'\n')
