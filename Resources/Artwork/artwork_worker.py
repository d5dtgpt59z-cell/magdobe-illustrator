#!/usr/bin/env python3
"""Local Codex App Server → image → editable contours. JSONL progress on stdout."""
import argparse, base64, json, os, queue, re, shutil, signal, subprocess, sys, threading, time, uuid
from collections import deque
from pathlib import Path
from xml.etree import ElementTree as ET

server = None

# Keep the existing three presets stable; Ultra is opt-in for dense illustrations.
TRACE_PRESETS = {
    'Simple': dict(filter_speckle=32, color_precision=5, layer_difference=40, length_threshold=6, path_precision=2),
    'Balanced': dict(filter_speckle=16, color_precision=6, layer_difference=24, length_threshold=4, path_precision=2),
    'Detailed': dict(filter_speckle=8, color_precision=7, layer_difference=16, length_threshold=3, path_precision=2),
    'Ultra': dict(filter_speckle=2, color_precision=8, layer_difference=6, length_threshold=2.5, path_precision=4),
}
MAX_TRACE_OBJECTS = 80000
MAX_TRACE_ANCHORS = 750000

def trace_options(detail):
    if detail not in TRACE_PRESETS:
        raise ValueError('Unknown vector detail. Choose Simple, Balanced, Detailed, or Ultra.')
    return dict(TRACE_PRESETS[detail])

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
        self.proc=server; self.q=queue.Queue(); self.pending=deque(); self.counter=0
        def read():
            for line in self.proc.stdout:
                try: self.q.put(json.loads(line))
                except ValueError: pass
            self.q.put(None)
        threading.Thread(target=read,daemon=True).start()
        self.call('initialize', {'clientInfo':{'name':'magdobe_illustrator','title':'Magdobe Illustrator','version':'0.7.2'},'capabilities':{'experimentalApi':True}})
        self.send({'method':'initialized','params':{}})
    def send(self, message):
        self.proc.stdin.write(json.dumps(message)+'\n'); self.proc.stdin.flush()
    def receive(self, timeout=60):
        if self.pending: return self.pending.popleft()
        return self._receive(timeout)
    def _receive(self, timeout=60):
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
            msg=self._receive(timeout=max(0.01, deadline-time.monotonic()))
            if msg.get('id')!=request:
                if 'method' in msg: self.pending.append(msg)
                continue
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
                      'Use the attached image as a visual reference if present. Finish immediately after successful image generation. If the image tool fails, do not retry; report its exact error. If image generation is unavailable, say so clearly.')
        thread=self.call('thread/start', {'cwd':str(job),'sandbox':'workspace-write','approvalPolicy':'never','ephemeral':True,'baseInstructions':instructions,'developerInstructions':instructions})
        thread_id=thread['thread']['id']
        brief=request['prompt']
        style=request.get('style','Illustration')
        brief+='\n\nOutput: one finished '+request.get('format','square')+' illustration. '+{'Illustration':'Rich illustrative detail with clear shapes and thoughtful shading.','Clean vector':'Crisp graphic shapes, restrained palette, smooth contours, suitable for vector conversion.','Painted detail':'Rich painted shading, expressive character detail, dimensional lighting and texture.'}.get(style,'')
        brief+=' Keep the full subject inside the frame. No watermarks or extra labels unless requested. The image will be converted into editable vector color contours.'
        inputs=[{'type':'text','text':brief}]
        if request.get('reference'): inputs.append({'type':'localImage','path':request['reference']})
        turn=self.call('turn/start',{'threadId':thread_id,'input':inputs})
        turn_id=turn.get('turn',{}).get('id')
        emit('generating',message='Codex is drawing your artwork…')
        result=None; failure=None; explanation=None; deadline=time.monotonic()+900
        diagnostics={'threadId':thread_id,'turnId':turn_id,'imageStatus':None}
        def record():
            (job/'generation-info.json').write_text(json.dumps(diagnostics,indent=2))
        record()
        while time.monotonic()<deadline:
            msg=self.receive(timeout=max(0.01,deadline-time.monotonic()))
            method=msg.get('method'); params=msg.get('params',{})
            if params.get('threadId',thread_id)!=thread_id: continue
            event_turn=params.get('turnId') or params.get('turn',{}).get('id')
            if turn_id and event_turn and event_turn!=turn_id: continue
            if method=='item/started' and params.get('item',{}).get('type')=='imageGeneration':
                emit('generating',message='Codex is generating your image…')
            if method=='item/completed':
                item=params.get('item',{})
                if item.get('type')=='agentMessage' and item.get('text','').strip():
                    explanation=item['text'].strip()[:1200]
                    diagnostics['codexMessage']=explanation
                if item.get('type')=='imageGeneration':
                    diagnostics['imageStatus']=item.get('status')
                    if item.get('failure'):
                        diagnostics['failure']=item['failure']
                        if item['failure'].get('type')=='usageLimitExceeded':
                            failure='Codex image-generation usage limit reached. Try again after the image limit resets.'
                        else: failure='The Codex image tool failed: '+str(item['failure'].get('message') or item['failure'].get('type') or 'unknown error')
                    elif item.get('status') in ('failed','cancelled'):
                        failure='The Codex image tool failed to generate this request. Try again later or change the prompt.'
                    else:
                        try: result=save_generated_image(item,job) or result
                        except (OSError,ValueError) as error: failure=str(error)
                record()
            if method=='turn/completed':
                turn=params.get('turn',{}); diagnostics['turnStatus']=turn.get('status')
                if turn.get('error'): diagnostics['turnError']=turn['error']
                record()
                if turn.get('status')=='failed':
                    raise RuntimeError('Codex: '+str((turn.get('error') or {}).get('message') or explanation or 'The image request failed.'))
                if turn.get('status')=='interrupted': raise RuntimeError('The Codex image request was cancelled.')
                if result: return result
                if failure and 'usage limit' in failure: raise RuntimeError(failure)
                if explanation: raise RuntimeError(generation_error_message(explanation))
                raise RuntimeError(failure or 'Codex returned no generated image. Retry, or use Vectorize an Existing Image. Your prompt and existing artwork are unchanged.')
        raise RuntimeError('Image generation timed out. Check Codex before retrying; the image may have completed there.')


def generation_error_message(explanation):
    if 'moderation_blocked' in explanation or 'rejected by the safety system' in explanation.lower():
        message='Codex’s image safety system rejected this request. Try a different prompt. Your prompt and existing artwork are unchanged.'
        request_id=re.search(r'request ID\s+([a-zA-Z0-9-]+)',explanation,re.IGNORECASE)
        if request_id: message+=' If this seems incorrect, contact OpenAI support with request ID '+request_id.group(1)+'.'
        return message
    return 'Codex: '+explanation


def save_generated_image(item,job):
    """Accept only an actual PNG from the requested generation item, never a reference image."""
    target=job/'source.png'
    saved=item.get('savedPath')
    if saved:
        source=Path(saved)
        if not source.is_absolute(): source=job/source
        if source.is_file():
            with source.open('rb') as stream: header=stream.read(24)
            if not header.startswith(b'\x89PNG\r\n\x1a\n') or len(header)<24:
                raise ValueError('Codex returned an unsupported image file. A PNG image is required for vector conversion.')
            if source.resolve()!=target.resolve(): shutil.copyfile(source,target)
            return target
    encoded=item.get('result')
    if encoded:
        if not isinstance(encoded,str): raise ValueError('Codex returned an unsupported image payload. Update Codex and retry.')
        try: raw=base64.b64decode(encoded.split(',',1)[-1],validate=True)
        except ValueError: raise ValueError('Codex returned invalid image data. Please retry.')
        if not raw.startswith(b'\x89PNG\r\n\x1a\n') or len(raw)<24:
            raise ValueError('Codex returned invalid PNG image data. Please retry.')
        target.write_bytes(raw); return target
    if item.get('fileId'):
        raise ValueError('Codex returned an image file reference without a local file or image data. This Codex output format cannot be imported yet. Use Vectorize an Existing Image, or update Codex and retry.')
    return None

def trace(source, job, detail):
    import vtracer
    from svgpathtools import parse_path, CubicBezier, QuadraticBezier, Line
    emit('tracing',message='Converting colors and shading into editable paths…')
    options = trace_options(detail)
    svgfile=job/'artwork.svg'
    vtracer.convert_image_to_svg_py(str(source),str(svgfile),colormode='color',hierarchical='stacked',mode='spline',corner_threshold=60,max_iterations=10,splice_threshold=45,**options)
    root=ET.parse(svgfile).getroot();shapes=[];nodes=0
    # Do not round a four-decimal Ultra trace back down while importing it.
    def point(z,offset):return dict(x=z.real+offset.real,y=z.imag+offset.imag)
    def anchor(z,offset):return dict(id=str(uuid.uuid4()).upper(),point=point(z,offset))
    paths=root.findall('{http://www.w3.org/2000/svg}path')
    if len(paths)>MAX_TRACE_OBJECTS: raise RuntimeError(f'This trace has {len(paths):,} paths, above the {MAX_TRACE_OBJECTS:,}-object limit. Choose a lower Vector detail setting. Your previous result is unchanged.')
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
        if nodes>MAX_TRACE_ANCHORS:raise RuntimeError(f'This trace exceeds {MAX_TRACE_ANCHORS:,} anchors. Choose a lower Vector detail setting. Your previous result is unchanged.')
        if not contours:continue
        fill=element.get('fill');rgb=[int(fill[j:j+2],16)/255 for j in (1,3,5)]
        s=dict(id=str(uuid.uuid4()).upper(),name=f'Artwork / color {i+1:04} {fill}',kind='path',x=0,y=0,width=0,height=0,anchors=contours[0],closed=True,fill=dict(red=rgb[0],green=rgb[1],blue=rgb[2],alpha=1),strokeWidth=0,opacity=1,visible=True,locked=False,text='',fontSize=48)
        if len(contours)>1:s['subpaths']=contours[1:]
        shapes.append(s)
    project=dict(version=1,width=float(root.get('width')),height=float(root.get('height')),shapes=shapes)
    target=job/'artwork.mvector';temporary=job/'artwork.mvector.tmp'
    temporary.write_text(json.dumps(project,separators=(',',':')));temporary.replace(target)
    (job/'trace-info.json').write_text(json.dumps(dict(detail=detail,settings=options,objects=len(shapes),anchors=nodes,width=project['width'],height=project['height']),indent=2))
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
    trace(source,job,request.get('detail','Detailed'))

if __name__=='__main__':
    try:main()
    except Exception as error:emit('error',message=str(error));sys.exit(1)
    finally:stop()
