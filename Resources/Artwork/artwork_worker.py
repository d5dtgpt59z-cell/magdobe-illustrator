#!/usr/bin/env python3
"""Local Codex App Server → image → editable contours. JSONL progress on stdout."""
import argparse, base64, json, os, queue, re, shutil, signal, subprocess, sys, threading, time, uuid
from pathlib import Path
from xml.etree import ElementTree as ET

server = None

def emit(stage, **values):
    print(json.dumps(dict(stage=stage, **values)), flush=True)

def stop(*_):
    if server and server.poll() is None:
        server.terminate()
        try: server.wait(timeout=3)
        except subprocess.TimeoutExpired: server.kill()
    if _: raise SystemExit(130)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

class Codex:
    def __init__(self, executable):
        global server
        server = subprocess.Popen([executable, 'app-server', '--stdio', '--disable', 'shell_tool', '--disable', 'apps'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.proc=server; self.q=queue.Queue(); self.counter=0
        def read():
            for line in self.proc.stdout:
                try: self.q.put(json.loads(line))
                except ValueError: pass
            self.q.put(None)
        threading.Thread(target=read,daemon=True).start()
        self.call('initialize', {'clientInfo':{'name':'magdobe_illustrator','title':'Magdobe Illustrator','version':'0.2.0'},'capabilities':{'experimentalApi':True}})
        self.send({'method':'initialized','params':{}})
    def send(self, message):
        self.proc.stdin.write(json.dumps(message)+'\n'); self.proc.stdin.flush()
    def receive(self, timeout=60):
        try: message=self.q.get(timeout=timeout)
        except queue.Empty: raise RuntimeError('Codex did not respond in time. Check your connection and try again.')
        if message is None: raise RuntimeError('The Codex connection closed unexpectedly.')
        if 'method' in message and 'id' in message:
            self.send({'id':message['id'],'error':{'code':-32601,'message':'This image-only client does not approve additional tools.'}})
            raise RuntimeError('Codex requested an additional action. Open Codex to resolve it, then retry.')
        return message
    def call(self, method, params):
        self.counter+=1; request=self.counter
        self.send({'id':request,'method':method,'params':params})
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            msg=self.receive()
            if msg.get('id')!=request: continue
            if 'error' in msg: raise RuntimeError('Codex: '+msg['error'].get('message','Request failed'))
            return msg.get('result',{})
        raise RuntimeError('Codex connection timed out.')
    def check(self):
        account=self.call('account/read', {'refreshToken':False}).get('account')
        if not account or account.get('type') not in ('chatgpt','chatgptAuthTokens'):
            raise RuntimeError('Sign in to Codex with ChatGPT first, then click Check Connection.')
        return account
    def generate(self, job, request):
        self.check()
        instructions=('You are the image-generation component of Magdobe Illustrator. Use the built-in image generation tool to create exactly one image from the user brief. '
                      'Do not use shell commands, external APIs, other apps, subagents or code to draw it. Do not ask follow-up questions. '
                      'Use the attached image as a visual reference if present. Finish immediately after successful image generation. If image generation is unavailable, say so clearly.')
        thread=self.call('thread/start', {'cwd':str(job),'sandbox':'workspace-write','approvalPolicy':'never','ephemeral':True,'baseInstructions':instructions,'developerInstructions':instructions})
        thread_id=thread['thread']['id']
        brief=request['prompt']
        style=request.get('style','Illustration')
        brief+='\n\nOutput: one finished '+request.get('format','square')+' illustration. '+{'Illustration':'Rich illustrative detail with clear shapes and thoughtful shading.','Clean vector':'Crisp graphic shapes, restrained palette, smooth contours, suitable for vector conversion.','Painted detail':'Rich painted shading, expressive character detail, dimensional lighting and texture.'}.get(style,'')
        brief+=' Keep the full subject inside the frame. No watermarks or extra labels unless requested. The image will be converted into editable vector color contours.'
        inputs=[{'type':'text','text':brief}]
        if request.get('reference'): inputs.append({'type':'localImage','path':request['reference']})
        self.call('turn/start',{'threadId':thread_id,'input':inputs})
        emit('generating',message='Codex is drawing your artwork…')
        result=None; failure=None; deadline=time.monotonic()+900
        while time.monotonic()<deadline:
            msg=self.receive(timeout=120)
            method=msg.get('method'); params=msg.get('params',{})
            if method=='item/completed':
                item=params.get('item',{})
                if item.get('type')=='imageGeneration':
                    if item.get('failure'): failure='Codex image generation reached a usage limit or failed. Check Codex and retry later.'
                    elif item.get('savedPath') and Path(item['savedPath']).is_file():
                        result=job/'source.png'; shutil.copyfile(item['savedPath'],result)
                    elif item.get('result'):
                        encoded=item['result'].split(',',1)[-1]
                        try:
                            raw=base64.b64decode(encoded,validate=True)
                            if len(raw)>100: result=job/'source.png';result.write_bytes(raw)
                        except ValueError: pass
            if method=='turn/completed':
                if result: return result
                status=params.get('turn',{}).get('status')
                raise RuntimeError(failure or 'Codex finished without an image. Image generation may be unavailable for this account or runtime. Open Codex and check the image tool.')
        raise RuntimeError('Image generation timed out. Check Codex before retrying; the image may have completed there.')

def trace(source, job, detail):
    import vtracer
    from svgpathtools import parse_path, CubicBezier, QuadraticBezier, Line
    emit('tracing',message='Converting colors and shading into editable paths…')
    presets={'Simple':(32,5,40,6), 'Balanced':(16,6,24,4), 'Detailed':(8,7,16,3)}
    speckle,precision,difference,length=presets.get(detail,presets['Balanced'])
    svgfile=job/'artwork.svg'
    vtracer.convert_image_to_svg_py(str(source),str(svgfile),colormode='color',hierarchical='stacked',mode='spline',filter_speckle=speckle,color_precision=precision,layer_difference=difference,corner_threshold=60,length_threshold=length,max_iterations=10,splice_threshold=45,path_precision=2)
    root=ET.parse(svgfile).getroot();shapes=[];nodes=0
    def point(z,offset):return dict(x=round(z.real+offset.real,3),y=round(z.imag+offset.imag,3))
    def anchor(z,offset):return dict(id=str(uuid.uuid4()).upper(),point=point(z,offset))
    paths=root.findall('{http://www.w3.org/2000/svg}path')
    if len(paths)>20000: raise RuntimeError('This image produces too many shapes. Retry with Simple detail.')
    for i,element in enumerate(paths):
        if i%100==0: emit('tracing',message=f'Building path {i+1:,} of {len(paths):,}…')
        transform=element.get('transform','translate(0,0)')
        match=re.fullmatch(r'translate\(\s*([-\d.]+)[,\s]+([-\d.]+)\s*\)',transform)
        if not match:raise RuntimeError('Unsupported trace transform.')
        offset=complex(*map(float,match.groups()));contours=[]
        for sub in parse_path(element.get('d')).continuous_subpaths():
            anchors=[anchor(sub[0].start,offset)]
            for seg in sub:
                if isinstance(seg,QuadraticBezier):seg=CubicBezier(seg.start,seg.start+2/3*(seg.control-seg.start),seg.end+2/3*(seg.control-seg.end),seg.end)
                if isinstance(seg,CubicBezier): anchors[-1]['outgoing']=point(seg.control1,offset)
                elif not isinstance(seg,Line): raise RuntimeError('Unsupported trace curve.')
                target=anchor(seg.end,offset)
                if isinstance(seg,CubicBezier):target['incoming']=point(seg.control2,offset)
                anchors.append(target)
            if abs(sub[-1].end-sub[0].start)<0.001:
                if 'incoming' in anchors[-1]:anchors[0]['incoming']=anchors[-1]['incoming']
                anchors.pop()
            contours.append(anchors);nodes+=len(anchors)
        if nodes>750000:raise RuntimeError('This image is too complex. Retry with Simple detail.')
        if not contours:continue
        fill=element.get('fill');rgb=[int(fill[j:j+2],16)/255 for j in (1,3,5)]
        s=dict(id=str(uuid.uuid4()).upper(),name=f'Artwork / color {i+1:04} {fill}',kind='path',x=0,y=0,width=0,height=0,anchors=contours[0],closed=True,fill=dict(red=rgb[0],green=rgb[1],blue=rgb[2],alpha=1),strokeWidth=0,opacity=1,visible=True,locked=False,text='',fontSize=48)
        if len(contours)>1:s['subpaths']=contours[1:]
        shapes.append(s)
    project=dict(version=1,width=float(root.get('width')),height=float(root.get('height')),shapes=shapes)
    target=job/'artwork.mvector';target.write_text(json.dumps(project,separators=(',',':')))
    emit('done',project=str(target),image=str(source),objects=len(shapes),anchors=nodes,message=f'{len(shapes):,} editable objects ready')

def main():
    p=argparse.ArgumentParser();p.add_argument('mode',choices=['check','generate','trace']);p.add_argument('--codex');p.add_argument('--request');p.add_argument('--job');args=p.parse_args()
    if args.mode=='check':
        Codex(args.codex).check();emit('connected',message='Connected to Codex · signed in with ChatGPT');return
    job=Path(args.job).resolve();job.mkdir(parents=True,exist_ok=True)
    request=json.loads(Path(args.request).read_text())
    if args.mode=='generate':
        emit('connecting',message='Connecting to Codex…');source=Codex(args.codex).generate(job,request);stop()
    else:
        source=job/'source.png';shutil.copyfile(request['image'],source)
    trace(source,job,request.get('detail','Balanced'))

if __name__=='__main__':
    try:main()
    except Exception as error:emit('error',message=str(error));sys.exit(1)
    finally:stop()
